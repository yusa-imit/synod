//! synod.sim.network — the simulator's virtual network (ADR-008, "Network"): a fixed table of
//! in-flight messages with seeded delay, loss and duplication, reorder by delay, and a
//! reachability matrix for partitions. It is a `Transport`.
//!
//! Layout: `messages_max` in-flight slots plus one delivery slot, each owning a `Message`, its
//! `Entry` array and the entry bytes, so a delivered message stays valid while the receiver
//! sends more (`pop_due` borrows the delivery slot until the next `pop_due`).
//!
//! Cost: `send`, `pop_due`, `next_due_ms` and `check_invariants` scan the slot table, so each
//! is O(messages_max) (256 in the sweep preset); the table is small and the scan keeps the
//! (at_ms, seq) order trivially correct. Time: the clock must stay at or below
//! `maxInt(u64) - delay_ms_max` whenever a due time is computed (asserted).
//!
//! Allocation: `init` only (four slices, sized by `bytes_required`). Determinism: every draw
//! comes from the `Prng` handed to `init`: one `chance(loss)` and one delay per send, one
//! `chance(duplicate)` per delivery of an original (and one delay when it re-arms).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
const clock_module = @import("clock.zig");
const prng_module = @import("prng.zig");

const Entry = types.Entry;
const Message = types.Message;
const NodeId = types.NodeId;
const Prng = prng_module.Prng;
const VirtualClock = clock_module.VirtualClock;

/// The most nodes a simulated cluster has (ADR-008 `nodes_max`); sizes the cut matrix.
const nodes_max: u8 = 7;
comptime {
    assert(nodes_max <= types.voters_max);
}

pub const Network = struct {
    pub const Fault = enum(u8) { none = 1, forge_votes = 2, flip_data = 3 };

    pub const Model = struct {
        messages_max: u32,
        delay_ms_min: u32,
        delay_ms_max: u32,
        loss_percent: u8,
        duplicate_percent: u8,
    };

    pub const Options = struct {
        nodes_count: u8,
        message_limits: Message.Limits,
        model: Model,
        fault: Fault,
    };

    /// 0-based slots; node id = slot + 1.
    pub const Link = struct { from_index: u8, to_index: u8 };

    pub const Stats = struct {
        sent: u64,
        delivered: u64,
        duplicated: u64,
        dropped_loss: u64,
        dropped_full: u64,
        dropped_cut: u64,
        dropped_down: u64,
    };

    /// `NetworkStatsDiverged`: sent + duplicated != delivered + dropped_* + in_flight.
    /// `NetworkTableOverfull`: more messages in flight than `messages_max`.
    pub const InvariantError = error{ NetworkStatsDiverged, NetworkTableOverfull };

    /// Bytes of bookkeeping per in-flight slot, beside the message storage (amends ADR-008).
    pub const slot_meta_bytes: u64 = 24;

    /// Bookkeeping of one in-flight slot.
    const Meta = struct {
        at_ms: u64,
        seq: u64,
        from_index: u8,
        to_index: u8,
        used: bool,
        duplicated: bool,
    };

    comptime {
        assert(@sizeOf(Meta) == slot_meta_bytes);
    }

    options: Options,
    /// The running counters `stats()` returns. Only this file writes them; tests alone corrupt
    /// them, to provoke `InvariantError`.
    counters: Stats,
    /// Occupied in-flight slots, what `in_flight()` returns. Same rule: tests alone corrupt it.
    used: u32,
    virtual_clock: *VirtualClock,
    prng: Prng,
    messages: []Message,
    entries: []Entry,
    bytes: []u8,
    metas: []Meta,
    cut_matrix: [nodes_max][nodes_max]bool,
    trace: u64,
    delivered_last: bool,

    pub fn init(
        network: *Network,
        gpa: Allocator,
        options: *const Options,
        virtual_clock: *VirtualClock,
        prng: Prng,
    ) Allocator.Error!void {
        assert(options.nodes_count >= 2);
        assert(options.nodes_count <= nodes_max);
        assert(options.model.messages_max > 0);
        assert(options.model.messages_max < std.math.maxInt(u32));
        assert(options.model.delay_ms_min <= options.model.delay_ms_max);
        assert(options.model.loss_percent <= 100);
        assert(options.model.duplicate_percent <= 100);
        assert(options.message_limits.entries_max > 0);
        assert(options.message_limits.entry_bytes_max > 0);
        const delay_ms_max: u64 = options.model.delay_ms_max;
        assert(virtual_clock.time_ms <= std.math.maxInt(u64) - delay_ms_max);
        const slots = @as(usize, options.model.messages_max) + 1;
        const entries_count = slots * options.message_limits.entries_max;
        const bytes_count = entries_count * options.message_limits.entry_bytes_max;
        const messages = try gpa.alloc(Message, slots);
        errdefer gpa.free(messages);

        const entries = try gpa.alloc(Entry, entries_count);
        errdefer gpa.free(entries);

        const bytes = try gpa.alloc(u8, bytes_count);
        errdefer gpa.free(bytes);

        const metas = try gpa.alloc(Meta, options.model.messages_max);
        errdefer gpa.free(metas);

        @memset(metas, std.mem.zeroes(Meta));
        network.* = .{
            .options = options.*,
            .counters = std.mem.zeroes(Stats),
            .used = 0,
            .virtual_clock = virtual_clock,
            .prng = prng,
            .messages = messages,
            .entries = entries,
            .bytes = bytes,
            .metas = metas,
            .cut_matrix = @splat(@splat(false)),
            .trace = 0,
            .delivered_last = false,
        };
        assert(network.used == 0);
    }

    pub fn deinit(network: *Network, gpa: Allocator) void {
        assert(network.used <= network.options.model.messages_max);
        assert(network.messages.len == network.metas.len + 1);
        assert(network.metas.len == network.options.model.messages_max);
        gpa.free(network.metas);
        gpa.free(network.bytes);
        gpa.free(network.entries);
        gpa.free(network.messages);
        network.* = undefined;
    }

    /// Bytes `init` requests from `gpa`, summed over its allocations.
    pub fn bytes_required(options: *const Options) u64 {
        const slots: u64 = @as(u64, options.model.messages_max) + 1;
        const entries_max: u64 = options.message_limits.entries_max;
        const entry_bytes_max: u64 = options.message_limits.entry_bytes_max;
        const per_slot = @sizeOf(Message) + entries_max * (@sizeOf(Entry) + entry_bytes_max);
        const total = slots * per_slot + options.model.messages_max * slot_meta_bytes;
        assert(total >= slots * @sizeOf(Message));
        assert(total > 0);
        return total;
    }

    /// Copies `message` and its entry bytes into the network's own storage and queues it with
    /// a seeded delay, unless the draw says lost or the table is full. Never blocks, never
    /// grows. Preconditions (the `Transport.send` contract, asserted): protocol version
    /// non-zero, `from` and `to` not `.none`, in `1..nodes_count` and different; entries within
    /// the configured limits; not an `install_snapshot` (Phase 4); the clock within
    /// `maxInt(u64) - delay_ms_max`.
    pub fn send(network: *Network, message: *const Message) void {
        const head = message.header();
        assert(head.protocol_version != 0);
        assert(head.from != .none);
        assert(head.to != .none);
        assert(head.from != head.to);
        assert(std.meta.activeTag(message.*) != .install_snapshot);
        const from_index = network.index_of(head.from);
        const to_index = network.index_of(head.to);
        const seq = network.counters.sent;
        network.counters.sent += 1;
        const lost = network.prng.chance(network.options.model.loss_percent);
        const delay_ms = network.draw_delay_ms();
        if (lost) {
            network.counters.dropped_loss += 1;
            return;
        }
        const slot = network.find_free() orelse {
            network.counters.dropped_full += 1;
            return;
        };
        network.copy_message(slot, message);
        network.metas[slot] = .{
            .at_ms = network.due_at_ms(delay_ms),
            .seq = seq,
            .from_index = from_index,
            .to_index = to_index,
            .used = true,
            .duplicated = false,
        };
        network.used += 1;
        assert(network.used <= network.options.model.messages_max);
    }

    /// Replaces every cut with a partition: each node of `side_a` and each of `side_b` can no
    /// longer reach the other, in both directions. Nodes on neither side keep every link.
    /// Preconditions (asserted before anything changes): every node `< nodes_count`, no node
    /// twice on one side, no node on both sides.
    pub fn set_partition(network: *Network, side_a: []const u8, side_b: []const u8) void {
        assert(side_a.len + side_b.len <= network.options.nodes_count);
        network.assert_side(side_a);
        network.assert_side(side_b);
        for (side_a) |a| {
            for (side_b) |b| assert(a != b);
        }
        network.heal();
        for (side_a) |a| {
            for (side_b) |b| {
                network.cut_matrix[a][b] = true;
                network.cut_matrix[b][a] = true;
            }
        }
    }

    /// Asserts every node of `side` is in range and none repeats.
    fn assert_side(network: *const Network, side: []const u8) void {
        assert(side.len <= network.options.nodes_count);
        for (side, 0..) |node, i| {
            assert(node < network.options.nodes_count);
            for (side[0..i]) |earlier| assert(earlier != node);
        }
    }

    /// Cuts one direction; idempotent. Messages already in flight on it are dropped at
    /// delivery.
    pub fn cut(network: *Network, link: Link) void {
        assert(link.from_index != link.to_index);
        assert(link.from_index < network.options.nodes_count);
        assert(link.to_index < network.options.nodes_count);
        network.cut_matrix[link.from_index][link.to_index] = true;
    }

    pub fn heal(network: *Network) void {
        assert(network.options.nodes_count <= nodes_max);
        network.cut_matrix = @splat(@splat(false));
        for (network.cut_matrix) |row| {
            for (row) |cut_link| assert(!cut_link);
        }
    }

    pub fn reachable(network: *const Network, link: Link) bool {
        assert(link.from_index != link.to_index);
        assert(link.from_index < network.options.nodes_count);
        assert(link.to_index < network.options.nodes_count);
        return !network.cut_matrix[link.from_index][link.to_index];
    }

    /// The due time of the earliest in-flight message, cut or not; null when none.
    pub fn next_due_ms(network: *const Network) ?u64 {
        var earliest: ?u64 = null;
        var seen: u32 = 0;
        for (network.metas) |meta| {
            if (!meta.used) continue;
            seen += 1;
            if (earliest == null or meta.at_ms < earliest.?) earliest = meta.at_ms;
        }
        assert(seen == network.used);
        if (earliest == null) assert(seen == 0);
        if (earliest != null) assert(seen > 0);
        return earliest;
    }

    /// Delivers the least `(at_ms, seq)` message due by now whose link is open, consuming
    /// (and counting `dropped_cut`) any cut ones on the way; null when nothing deliverable is
    /// due. The result is borrowed until the next `pop_due`.
    pub fn pop_due(network: *Network) ?*const Message {
        network.delivered_last = false;
        const now_ms = network.virtual_clock.now_ms();
        // Each pass consumes one slot or returns, so `messages_max + 1` passes always return.
        for (0..network.metas.len + 1) |_| {
            const slot = network.find_due(now_ms) orelse return null;
            const meta = network.metas[slot];
            const link: Link = .{ .from_index = meta.from_index, .to_index = meta.to_index };
            if (!network.reachable(link)) {
                network.release(slot);
                network.counters.dropped_cut += 1;
                continue;
            }
            return network.deliver(slot);
        }
        assert(network.used == 0);
        return null;
    }

    /// Reclassifies the delivery the last `pop_due` returned: its target was crashed.
    pub fn drop_down(network: *Network) void {
        assert(network.delivered_last);
        assert(network.counters.delivered > 0);
        network.counters.delivered -= 1;
        network.counters.dropped_down += 1;
        network.delivered_last = false;
    }

    pub fn in_flight(network: *const Network) u32 {
        assert(network.used <= network.options.model.messages_max);
        return network.used;
    }

    /// A hash over `(seq, at_ms, from, to, kind)` of every delivery, in order: two runs agree
    /// on it iff they delivered the same messages at the same times.
    pub fn trace_hash(network: *const Network) u64 {
        assert(network.used <= network.options.model.messages_max);
        const deliveries = network.counters.delivered + network.counters.dropped_down;
        if (network.trace != 0) assert(deliveries > 0);
        return network.trace;
    }

    pub fn stats(network: *const Network) Stats {
        assert(network.counters.sent >= network.counters.dropped_loss);
        assert(network.counters.sent >= network.counters.dropped_full);
        return network.counters;
    }

    /// Checks the table against the counters; see `InvariantError`.
    pub fn check_invariants(network: *const Network) InvariantError!void {
        assert(network.metas.len == network.options.model.messages_max);
        assert(network.messages.len == network.metas.len + 1);
        if (network.used > network.options.model.messages_max) return error.NetworkTableOverfull;
        const counters = network.counters;
        const dropped = counters.dropped_loss + counters.dropped_full + counters.dropped_cut +
            counters.dropped_down;
        const inflow = counters.sent + counters.duplicated;
        if (inflow != counters.delivered + dropped + network.used) {
            return error.NetworkStatsDiverged;
        }
        var occupied: u32 = 0;
        for (network.metas) |meta| {
            if (meta.used) occupied += 1;
        }
        if (occupied != network.used) return error.NetworkStatsDiverged;
        assert(occupied <= network.options.model.messages_max);
    }

    pub fn as_transport(network: *Network) interfaces.Transport {
        assert(network.used <= network.options.model.messages_max);
        return interfaces.Transport.init(network);
    }

    fn index_of(network: *const Network, id: NodeId) u8 {
        const raw = @intFromEnum(id);
        assert(raw >= 1);
        assert(raw <= network.options.nodes_count);
        return @intCast(raw - 1);
    }

    /// Now plus `delay_ms`, which never overflows: the clock is within `delay_ms_max` of the
    /// top at worst, and that is asserted.
    fn due_at_ms(network: *Network, delay_ms: u64) u64 {
        const now_ms = network.virtual_clock.now_ms();
        assert(delay_ms <= network.options.model.delay_ms_max);
        const delay_ms_max: u64 = network.options.model.delay_ms_max;
        assert(now_ms <= std.math.maxInt(u64) - delay_ms_max);
        return now_ms + delay_ms;
    }

    /// One delay draw in `[delay_ms_min, delay_ms_max]`.
    fn draw_delay_ms(network: *Network) u64 {
        const model = network.options.model;
        const span: u64 = @as(u64, model.delay_ms_max) - model.delay_ms_min + 1;
        const delay_ms = model.delay_ms_min + network.prng.uint_less_than(span);
        assert(delay_ms >= model.delay_ms_min);
        assert(delay_ms <= model.delay_ms_max);
        return delay_ms;
    }

    fn find_free(network: *const Network) ?usize {
        assert(network.used <= network.options.model.messages_max);
        for (network.metas, 0..) |meta, slot| {
            if (!meta.used) return slot;
        }
        assert(network.used == network.options.model.messages_max);
        return null;
    }

    /// The used slot with the least `(at_ms, seq)` among those due by `now_ms`.
    fn find_due(network: *const Network, now_ms: u64) ?usize {
        var best: ?usize = null;
        for (network.metas, 0..) |meta, slot| {
            if (!meta.used or meta.at_ms > now_ms) continue;
            const current = if (best) |b| network.metas[b] else {
                best = slot;
                continue;
            };
            if (meta.at_ms < current.at_ms) best = slot;
            if (meta.at_ms == current.at_ms and meta.seq < current.seq) best = slot;
        }
        if (best) |found| {
            assert(network.metas[found].used);
            assert(network.metas[found].at_ms <= now_ms);
        }
        return best;
    }

    fn release(network: *Network, slot: usize) void {
        assert(network.metas[slot].used);
        assert(network.used > 0);
        network.metas[slot].used = false;
        network.used -= 1;
    }

    /// Copies slot `slot`'s message to the delivery slot, applies the planted fault, counts
    /// the delivery and either re-arms the slot as a duplicate or frees it.
    fn deliver(network: *Network, slot: usize) *const Message {
        const meta = network.metas[slot];
        assert(meta.used);
        const delivery_slot = network.metas.len;
        network.copy_message(delivery_slot, &network.messages[slot]);
        network.apply_fault(delivery_slot);
        network.counters.delivered += 1;
        network.delivered_last = true;
        network.fold_trace(&meta);
        const duplicate = !meta.duplicated and
            network.prng.chance(network.options.model.duplicate_percent);
        if (duplicate) {
            network.metas[slot].at_ms = network.due_at_ms(network.draw_delay_ms());
            network.metas[slot].duplicated = true;
            network.counters.duplicated += 1;
        } else {
            network.release(slot);
        }
        assert(network.delivered_last);
        assert(network.used <= network.options.model.messages_max);
        return &network.messages[delivery_slot];
    }

    fn fold_trace(network: *Network, meta: *const Meta) void {
        const message = &network.messages[network.metas.len];
        var record: [19]u8 = undefined;
        std.mem.writeInt(u64, record[0..8], meta.seq, .little);
        std.mem.writeInt(u64, record[8..16], meta.at_ms, .little);
        record[16] = meta.from_index;
        record[17] = meta.to_index;
        record[18] = @intFromEnum(std.meta.activeTag(message.*));
        network.trace = std.hash.Wyhash.hash(network.trace, &record);
        assert(meta.used);
        assert(meta.from_index != meta.to_index);
    }

    /// Copies `message` into storage slot `slot` (entry bytes included).
    fn copy_message(network: *Network, slot: usize, message: *const Message) void {
        const limits = network.options.message_limits;
        assert(slot <= network.metas.len);
        network.messages[slot] = message.*;
        switch (message.*) {
            .append_entries => |request| {
                assert(request.entries.len <= limits.entries_max);
                const entries_base = slot * limits.entries_max;
                const bytes_base = entries_base * limits.entry_bytes_max;
                for (request.entries, 0..) |entry, k| {
                    assert(entry.data.len <= limits.entry_bytes_max);
                    const offset = bytes_base + k * limits.entry_bytes_max;
                    const data = network.bytes[offset..][0..entry.data.len];
                    @memcpy(data, entry.data);
                    network.entries[entries_base + k] = entry;
                    network.entries[entries_base + k].data = data;
                }
                const copied = network.entries[entries_base..][0..request.entries.len];
                network.messages[slot].append_entries.entries = copied;
            },
            .request_vote,
            .request_vote_response,
            .pre_vote,
            .pre_vote_response,
            .append_entries_response,
            .install_snapshot_response,
            => {},
            .install_snapshot => unreachable, // `send` asserts it is never queued.
        }
    }

    /// The planted fault (ADR-008) on the delivery copy; the queued original is untouched.
    fn apply_fault(network: *Network, slot: usize) void {
        const limits = network.options.message_limits;
        assert(slot == network.metas.len);
        switch (network.options.fault) {
            .none => {},
            .forge_votes => switch (network.messages[slot]) {
                .request_vote_response => |*response| response.granted = true,
                else => {},
            },
            .flip_data => switch (network.messages[slot]) {
                .append_entries => |request| {
                    const bytes_base = slot * limits.entries_max * limits.entry_bytes_max;
                    for (request.entries, 0..) |entry, k| {
                        if (entry.data.len == 0) continue;
                        network.bytes[bytes_base + k * limits.entry_bytes_max] ^= 0xff;
                        break;
                    }
                },
                else => {},
            },
        }
    }
};
