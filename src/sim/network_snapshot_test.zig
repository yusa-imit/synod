//! Red tests for snapshots on the `Network` (plan 005 item 6, ADR-009 "Simulator"): a slot owns
//! a whole `install_snapshot` (snapshot bytes and the three configuration node lists), so
//! `send` no longer asserts against the kind and a duplicate or reorder never shares bytes.
//!
//! API these tests assume (ADR-009):
//!   - `Network.snapshot_ids_max: u32 = 3 * nodes_max` (the node ids one configuration carries).
//!   - `Message.Limits.snapshot_bytes_max` (exists) bounds the snapshot bytes of a slot.
//!   - `Network.bytes_required` adds `(messages_max + 1) * (snapshot_bytes_max + 8 *
//!     snapshot_ids_max)`, and `init` requests exactly that.
//!   - A `Network` that is handed an `install_snapshot` over `snapshot_bytes_max` bytes or a
//!     list over its share of `snapshot_ids_max` is a caller-contract violation (asserted, so
//!     not provoked here); exactly at the limits is accepted and tested.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const fx = @import("fixtures.zig");
const network_module = @import("network.zig");

const Network = network_module.Network;
const Message = types.Message;
const NodeId = types.NodeId;
const Prng = @import("prng.zig").Prng;
const Rig = fx.Rig;

const snapshot_bytes_max: u64 = 32;
const ids_max = Network.snapshot_ids_max;

/// A snapshot message description that owns its bytes and node lists.
const Owned = struct {
    data: [snapshot_bytes_max]u8,
    data_len: usize,
    voters: [7]NodeId,
    voters_len: usize,
    outgoing: [7]NodeId,
    outgoing_len: usize,
    learners: [7]NodeId,
    learners_len: usize,
    from: u64,
    to: u64,
    index: u64,

    fn build(owned: *const Owned) Message {
        return .{ .install_snapshot = .{
            .header = fx.header(owned.from, owned.to, 3),
            .snapshot = .{
                .index = @enumFromInt(owned.index),
                .term = @enumFromInt(2),
                .data = owned.data[0..owned.data_len],
            },
            .configuration = .{
                .voters = owned.voters[0..owned.voters_len],
                .voters_outgoing = owned.outgoing[0..owned.outgoing_len],
                .learners = owned.learners[0..owned.learners_len],
            },
        } };
    }
};

fn owned_of(from: u64, to: u64, index: u64, fill: u8, data_len: usize) Owned {
    var owned: Owned = undefined;
    owned.from = from;
    owned.to = to;
    owned.index = index;
    owned.data_len = data_len;
    for (&owned.data, 0..) |*byte, at| byte.* = fill +% @as(u8, @intCast(at));
    owned.voters_len = 3;
    owned.outgoing_len = 0;
    owned.learners_len = 1;
    for (0..3) |at| owned.voters[at] = @enumFromInt(at + 1);
    owned.learners[0] = @enumFromInt(4);
    return owned;
}

fn ids_eql(a: []const NodeId, b: []const NodeId) bool {
    return std.mem.eql(NodeId, a, b);
}

fn snapshot_eql(want: *const Message, got: *const Message) bool {
    if (std.meta.activeTag(got.*) != .install_snapshot) return false;
    const a = want.install_snapshot;
    const b = got.install_snapshot;
    if (!std.meta.eql(a.header, b.header)) return false;
    if (a.snapshot.index != b.snapshot.index or a.snapshot.term != b.snapshot.term) return false;
    if (!std.mem.eql(u8, a.snapshot.data, b.snapshot.data)) return false;
    return ids_eql(a.configuration.voters, b.configuration.voters) and
        ids_eql(a.configuration.voters_outgoing, b.configuration.voters_outgoing) and
        ids_eql(a.configuration.learners, b.configuration.learners);
}

fn options_with_snapshots(nodes_count: u8, model: Network.Model) Network.Options {
    var options = fx.options_of(nodes_count, model, .none);
    options.message_limits.snapshot_bytes_max = snapshot_bytes_max;
    return options;
}

fn fixture(rig: *Rig, model: Network.Model, seed: u64) !void {
    try rig.init(testing.allocator, options_with_snapshots(3, model), seed);
}

// ---- delivery --------------------------------------------------------------------------------

test "network snapshot: an install_snapshot is delivered intact after its delay" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const owned = owned_of(1, 2, 400, 0x10, 20);
    const sent = owned.build();
    rig.network.send(&sent);
    try testing.expect(rig.network.pop_due() == null); // not before its due time
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&sent, got));
    try testing.expect(rig.network.pop_due() == null);
    try testing.expectEqual(@as(u64, 1), rig.network.stats().delivered);
    try rig.network.check_invariants();
}

test "network snapshot: the network owns a copy, so mutating the source changes nothing" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 2);
    defer rig.deinit(testing.allocator);
    var owned = owned_of(1, 2, 400, 0x20, 24);
    const sent = owned.build();
    const reference = owned; // the bytes as sent
    rig.network.send(&sent);
    @memset(&owned.data, 0xEE);
    owned.voters[0] = @enumFromInt(7);
    owned.learners[0] = @enumFromInt(7);
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&reference.build(), got));
    const got_ptr = @intFromPtr(got.install_snapshot.snapshot.data.ptr);
    try testing.expect(got_ptr != @intFromPtr(&owned.data));
    try testing.expect(got_ptr != @intFromPtr(&reference.data));
}

test "network snapshot: bytes at snapshot_bytes_max and a full set of node ids survive intact" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 3);
    defer rig.deinit(testing.allocator);
    var owned = owned_of(2, 1, 99, 0x30, snapshot_bytes_max);
    owned.voters_len = 7;
    owned.outgoing_len = 7;
    owned.learners_len = 7;
    for (0..7) |at| {
        owned.voters[at] = @enumFromInt(at + 1);
        owned.outgoing[at] = @enumFromInt(at + 11);
        owned.learners[at] = @enumFromInt(at + 21);
    }
    try testing.expectEqual(@as(usize, ids_max), owned.voters_len + owned.outgoing_len + 7);
    const sent = owned.build();
    rig.network.send(&sent);
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&sent, got));
}

test "network snapshot: an empty snapshot payload and empty lists are delivered as empty" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 4);
    defer rig.deinit(testing.allocator);
    var owned = owned_of(1, 3, 5, 0, 0);
    owned.learners_len = 0;
    const sent = owned.build();
    rig.network.send(&sent);
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&sent, got));
    try testing.expectEqual(@as(usize, 0), got.install_snapshot.snapshot.data.len);
}

// ---- slots do not share bytes ------------------------------------------------------------------

test "network snapshot: two snapshots in flight each keep their own bytes" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 5);
    defer rig.deinit(testing.allocator);
    var first = owned_of(1, 2, 100, 0x40, 32);
    var second = owned_of(1, 3, 200, 0x80, 32);
    const first_sent = first;
    const second_sent = second;
    rig.network.send(&first.build());
    rig.network.send(&second.build());
    @memset(&first.data, 0);
    @memset(&second.data, 0);
    rig.advance(5);
    const one = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&first_sent.build(), one));
    const copy = @intFromPtr(one.install_snapshot.snapshot.data.ptr);
    const two = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&second_sent.build(), two));
    try testing.expect(copy != @intFromPtr(two.install_snapshot.snapshot.data.ptr));
}

test "network snapshot: a send during processing does not overwrite the borrowed delivery" {
    var model = fx.base_model;
    model.messages_max = 3;
    var rig: Rig = undefined;
    try fixture(&rig, model, 6);
    defer rig.deinit(testing.allocator);
    var original = owned_of(1, 2, 400, 0x50, 32);
    const reference = original;
    const sent = reference.build();
    rig.network.send(&original.build());
    @memset(&original.data, 0);
    rig.advance(5);
    const borrowed = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    const other = owned_of(2, 1, 900, 0xA0, 32);
    for (0..6) |_| { // Fills the table and overflows it: every slot is touched.
        rig.network.send(&other.build());
        try testing.expect(snapshot_eql(&sent, borrowed));
    }
}

test "network snapshot: duplicate_percent 100 delivers the snapshot twice, both intact" {
    var model = fx.base_model;
    model.duplicate_percent = 100;
    var rig: Rig = undefined;
    try fixture(&rig, model, 7);
    defer rig.deinit(testing.allocator);
    const owned = owned_of(1, 2, 400, 0x60, 32);
    const sent = owned.build();
    rig.network.send(&sent);
    const noise = owned_of(3, 2, 7, 0xC0, 32);
    var delivered: u32 = 0;
    var rounds: u32 = 0;
    while (rig.network.next_due_ms()) |due| {
        rounds += 1;
        try testing.expect(rounds < 100);
        if (due > rig.clock.time_ms) rig.clock.advance_to(due);
        while (rig.network.pop_due()) |got| {
            // Every delivery is either an intact copy of the snapshot or the noise message.
            const noise_message = noise.build();
            if (snapshot_eql(&noise_message, got)) continue;
            try testing.expect(snapshot_eql(&sent, got));
            delivered += 1;
            rig.network.send(&noise_message); // reuse of freed slots must not corrupt the rest
        }
    }
    try testing.expect(delivered >= 2);
    try rig.network.check_invariants();
}

test "network snapshot: a snapshot and an append in one table keep their own bytes" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 8);
    defer rig.deinit(testing.allocator);
    const owned = owned_of(1, 2, 400, 0x70, 32);
    const entries = [_]types.Entry{ fx.entry_of(5, 2, "keep"), fx.entry_of(6, 2, "me") };
    const append = fx.append(2, 1, 2, &entries);
    rig.network.send(&owned.build());
    rig.network.send(&append);
    rig.advance(5);
    const first = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(snapshot_eql(&owned.build(), first));
    const second = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(fx.message_eql(&append, second));
    try testing.expectEqualStrings("keep", second.append_entries.entries[0].data);
}

// ---- table limits and accounting ---------------------------------------------------------------

test "network snapshot: a full table drops a snapshot and counts dropped_full, no assert" {
    var model = fx.base_model;
    model.messages_max = 2;
    var rig: Rig = undefined;
    try fixture(&rig, model, 9);
    defer rig.deinit(testing.allocator);
    const owned = owned_of(1, 2, 400, 0x11, 32);
    for (0..3) |_| rig.network.send(&owned.build());
    const stats = rig.network.stats();
    try testing.expectEqual(@as(u64, 3), stats.sent);
    try testing.expectEqual(@as(u64, 1), stats.dropped_full);
    try testing.expectEqual(@as(u32, 2), rig.network.in_flight());
    try rig.network.check_invariants();
}

test "network snapshot: a cut link drops a snapshot at delivery like any message" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 10);
    defer rig.deinit(testing.allocator);
    rig.network.cut(fx.link_of(0, 1));
    rig.network.send(&owned_of(1, 2, 400, 0x12, 32).build());
    rig.advance(5);
    try testing.expect(rig.network.pop_due() == null);
    try testing.expectEqual(@as(u64, 1), rig.network.stats().dropped_cut);
    try rig.network.check_invariants();
}

test "network snapshot: bytes_required grows by messages_max + 1 times the snapshot bytes" {
    var without = options_with_snapshots(3, fx.base_model);
    without.message_limits.snapshot_bytes_max = 0;
    var with = without;
    with.message_limits.snapshot_bytes_max = snapshot_bytes_max;
    const slots: u64 = fx.base_model.messages_max + 1;
    try testing.expectEqual(
        Network.bytes_required(&without) + slots * snapshot_bytes_max,
        Network.bytes_required(&with),
    );
    try testing.expectEqual(@as(u32, 21), Network.snapshot_ids_max);
}

test "network snapshot: init allocates exactly bytes_required with snapshots on" {
    const options = options_with_snapshots(5, fx.base_model);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rig: Rig = undefined;
    try rig.init(failing.allocator(), options, 11);
    try testing.expectEqual(Network.bytes_required(&options), failing.allocated_bytes);
    const allocations = failing.allocations;
    for (0..40) |round| { // Snapshot traffic allocates nothing more.
        rig.network.send(&owned_of(1, 2, round + 1, @intCast(round), 32).build());
        if (round % 3 == 0) rig.advance(5);
        _ = rig.network.pop_due();
    }
    try testing.expectEqual(allocations, failing.allocations);
    rig.deinit(failing.allocator());
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "network snapshot: init fails cleanly with OutOfMemory at every allocation" {
    const options = options_with_snapshots(3, fx.base_model);
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var rig: Rig = undefined;
        if (rig.init(failing.allocator(), options, 12)) |_| {
            rig.deinit(failing.allocator());
            try testing.expect(fail_index >= failing.allocations);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(fail_index > 0);
}

// ---- model -------------------------------------------------------------------------------------

test "network snapshot: seeded mixed traffic delivers every message intact, in send order" {
    for (1..21) |seed| {
        var prng = Prng.init(seed);
        var rig: Rig = undefined;
        try fixture(&rig, fx.base_model, seed);
        defer rig.deinit(testing.allocator);
        var sent: [8]Owned = undefined;
        for (&sent, 0..) |*slot, at| {
            const len = @as(usize, @intCast(prng.uint_less_than(snapshot_bytes_max + 1)));
            slot.* = owned_of(1, 2, at + 1, @as(u8, @truncate(prng.next_u64())), len);
            rig.network.send(&slot.build());
        }
        rig.advance(5);
        for (sent) |slot| {
            const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
            try testing.expect(snapshot_eql(&slot.build(), got));
        }
        try testing.expect(rig.network.pop_due() == null);
        try rig.network.check_invariants();
    }
}
