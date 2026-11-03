//! synod.sim.crash_store — `CrashStore`, the simulator's crash-losing `LogStore` (ADR-008,
//! "Crash store"; plan 004 item 5).
//!
//! Two `MemoryStore`s, `durable` and `live`, and a journal of `journal_ops_max` mutations that
//! owns copies of their bytes. Mutations go to `live` and the journal; `sync` replays the
//! journal into `durable`; `crash(keep)` rebuilds `live` from `durable` plus the first `keep`
//! journal ops. One journal op per mutating call. A journal that cannot take the next op
//! (op count, entry-data bytes, or entry slots) first flushes into `durable`: durable before
//! `sync` is allowed (ADR-006). The entry-slot bound is `store.entries_max` (an addition to the
//! ADR's two bounds, needed so the journal never allocates). A single op larger than the whole
//! journal is applied to `durable` directly. `save_snapshot` is journalled like the rest (plan
//! 005 item 6, ADR-009 "Simulator"): the journal owns a copy of the snapshot bytes (in
//! `journal_data`, beside entry bytes) and node lists, an unsynced snapshot is lost by a crash
//! that keeps none of the unsynced ops, and a crash keeps whole ops only, so a snapshot is whole
//! or absent (bytes damaged below the store are the state machine's crc32 to catch).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const interfaces = @import("../interfaces.zig");
const store_module = @import("../store.zig");
const types = @import("../types.zig");

const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const MemoryStore = store_module.MemoryStore;
const NodeId = types.NodeId;
const Snapshot = types.Snapshot;
const Term = types.Term;

pub const CrashStore = struct {
    pub const Fault = enum(u8) { none = 1, lose_synced_hard_state = 2 };
    pub const Options = struct {
        store: store_module.Options,
        journal_ops_max: u32,
        journal_bytes_max: u32,
        fault: Fault,
    };
    pub const InvariantError = store_module.InvariantError || error{CrashStoreDiverged};

    const Op = union(enum) {
        append: struct { start: u32, len: u32 },
        truncate: Index,
        hard_state: HardState,
        snapshot: SnapshotOp,
    };

    /// A journalled `save_snapshot`: where its bytes and node lists sit in the journal, and
    /// what it did to the log of `live` (`MemoryStore` keeps the suffix above `index` only when
    /// it holds the snapshot's term at `index`), so the invariant check need not replay it.
    const SnapshotOp = struct {
        index: Index,
        term: Term,
        data_start: u32,
        data_len: u32,
        nodes_start: u32,
        voters_len: u8,
        outgoing_len: u8,
        learners_len: u8,
        suffix_kept: bool,
        length_after: u64,
    };

    /// Node ids one snapshot's configuration can carry (mirrors `MemoryStore.init`).
    const snapshot_nodes_max: u32 = 2 * types.voters_max + types.learners_max;

    /// What survives a crash plus the synced prefix; `live` is what the node sees.
    durable: MemoryStore,
    live: MemoryStore,
    truncates: u64 = 0,
    fault: Fault,
    ops: []Op,
    ops_len: u32,
    journal_entries: []Entry,
    journal_entries_len: u32,
    journal_data: []u8,
    journal_data_len: u32,
    /// Node lists of the journalled snapshots, `ops.len * snapshot_nodes_max` ids.
    journal_nodes: []NodeId,
    journal_nodes_len: u32,
    /// Failure countdown: calls to let pass before one fails; null = disarmed.
    armed: ?u32,
    /// `durable`'s hard state before the last one a flush replayed (the plant's revert value).
    hard_state_before: HardState,

    pub fn init(
        crash_store: *CrashStore,
        gpa: Allocator,
        options: *const Options,
    ) Allocator.Error!void {
        assert(options.journal_ops_max > 0);
        assert(options.store.entries_max > 0);
        var durable: MemoryStore = undefined;
        try durable.init(gpa, options.store);
        errdefer durable.deinit(gpa);

        var live: MemoryStore = undefined;
        try live.init(gpa, options.store);
        errdefer live.deinit(gpa);

        const ops = try gpa.alloc(Op, options.journal_ops_max);
        errdefer gpa.free(ops);

        const journal_entries = try gpa.alloc(Entry, options.store.entries_max);
        errdefer gpa.free(journal_entries);

        const journal_data = try gpa.alloc(u8, options.journal_bytes_max);
        errdefer gpa.free(journal_data);

        const nodes_count = @as(usize, options.journal_ops_max) * snapshot_nodes_max;
        const journal_nodes = try gpa.alloc(NodeId, nodes_count);
        errdefer gpa.free(journal_nodes);

        crash_store.* = .{
            .durable = durable,
            .live = live,
            .fault = options.fault,
            .ops = ops,
            .ops_len = 0,
            .journal_entries = journal_entries,
            .journal_entries_len = 0,
            .journal_data = journal_data,
            .journal_data_len = 0,
            .journal_nodes = journal_nodes,
            .journal_nodes_len = 0,
            .armed = null,
            .hard_state_before = HardState.empty,
        };
        assert(crash_store.unsynced_count() == 0);
    }

    pub fn deinit(crash_store: *CrashStore, gpa: Allocator) void {
        assert(crash_store.ops.len > 0);
        assert(crash_store.ops_len <= crash_store.ops.len);
        gpa.free(crash_store.journal_nodes);
        gpa.free(crash_store.journal_data);
        gpa.free(crash_store.journal_entries);
        gpa.free(crash_store.ops);
        crash_store.live.deinit(gpa);
        crash_store.durable.deinit(gpa);
        crash_store.* = undefined;
    }

    pub fn as_log_store(crash_store: *CrashStore) LogStore {
        return LogStore.init(crash_store);
    }

    /// The `n`-th next mutation or `sync` (0 = the next) fails with `StoreIoFailed`.
    pub fn arm_failure(crash_store: *CrashStore, calls_until: u32) void {
        assert(crash_store.live.entries.len > 0);
        crash_store.armed = calls_until;
        assert(crash_store.armed != null);
    }

    /// Rebuilds `live` from `durable` plus the first `keep_count` unsynced ops.
    pub fn crash(crash_store: *CrashStore, keep_count: u32) void {
        assert(keep_count <= crash_store.ops_len);
        if (crash_store.fault == .lose_synced_hard_state) {
            crash_store.durable.hard_state = crash_store.hard_state_before;
        }
        for (crash_store.ops[0..keep_count]) |op| crash_store.replay(op);
        crash_store.hard_state_before = crash_store.durable.hard_state; // The revert is used up.
        crash_store.clear_journal();
        crash_store.armed = null;
        copy_store(&crash_store.live, &crash_store.durable);
        assert(crash_store.unsynced_count() == 0);
    }

    pub fn unsynced_count(crash_store: *const CrashStore) u32 {
        assert(crash_store.ops_len <= crash_store.ops.len);
        return crash_store.ops_len;
    }

    pub fn check_invariants(crash_store: *const CrashStore) InvariantError!void {
        try crash_store.live.check_invariants();
        try crash_store.durable.check_invariants();
        try crash_store.check_journal();
    }

    pub fn last_index(crash_store: *CrashStore) Index {
        return crash_store.live.last_index();
    }

    pub fn append(crash_store: *CrashStore, entries: []const Entry) LogStore.WriteError!void {
        assert(entries.len > 0);
        if (crash_store.fires()) return error.StoreIoFailed;
        try crash_store.live.append(entries);
        var bytes: u32 = 0;
        for (entries) |entry| bytes += @intCast(entry.data.len);
        const count: u32 = @intCast(entries.len);
        if (!crash_store.make_room(count, bytes)) {
            // proof: same as `replay`: `durable` holds the journal-free prefix of `live`.
            crash_store.durable.append(entries) catch unreachable;
            return;
        }
        const start = crash_store.journal_entries_len;
        for (entries) |entry| {
            const at = crash_store.journal_data_len;
            const data = crash_store.journal_data[at..][0..entry.data.len];
            @memcpy(data, entry.data);
            crash_store.journal_entries[crash_store.journal_entries_len] = entry;
            crash_store.journal_entries[crash_store.journal_entries_len].data = data;
            crash_store.journal_entries_len += 1;
            crash_store.journal_data_len += @intCast(entry.data.len);
        }
        crash_store.push(.{ .append = .{ .start = start, .len = count } });
    }

    pub fn truncate(crash_store: *CrashStore, from: Index) LogStore.UpdateError!void {
        if (crash_store.fires()) return error.StoreIoFailed;
        crash_store.truncates += 1;
        try crash_store.live.truncate(from);
        _ = crash_store.make_room(0, 0);
        crash_store.push(.{ .truncate = from });
    }

    pub fn get(crash_store: *CrashStore, index: Index) LogStore.ReadError!Entry {
        return crash_store.live.get(index);
    }

    pub fn save_hard_state(
        crash_store: *CrashStore,
        hard_state: *const HardState,
    ) LogStore.UpdateError!void {
        if (crash_store.fires()) return error.StoreIoFailed;
        try crash_store.live.save_hard_state(hard_state);
        _ = crash_store.make_room(0, 0);
        crash_store.push(.{ .hard_state = hard_state.* });
    }

    pub fn load_hard_state(crash_store: *CrashStore) LogStore.ReadError!HardState {
        return crash_store.live.load_hard_state();
    }

    pub fn save_snapshot(
        crash_store: *CrashStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) LogStore.WriteError!void {
        if (crash_store.fires()) return error.StoreIoFailed;
        const length_before = last_of(&crash_store.live);
        try crash_store.live.save_snapshot(snapshot, configuration);
        const length_after = last_of(&crash_store.live);
        const index: u64 = @intFromEnum(snapshot.index);
        const suffix_kept = length_before > index and length_after == length_before;
        const bytes: u32 = @intCast(snapshot.data.len);
        if (!crash_store.make_room(0, bytes)) {
            // `durable` holds the journal-free prefix of `live`, so the call that succeeded on
            // `live` (same limits) succeeds here.
            // proof: same as `replay`.
            crash_store.durable.save_snapshot(snapshot, configuration) catch unreachable;
            return;
        }
        const op = crash_store.journal_snapshot(snapshot, configuration);
        crash_store.push(.{ .snapshot = .{
            .index = snapshot.index,
            .term = snapshot.term,
            .data_start = op.data_start,
            .data_len = bytes,
            .nodes_start = op.nodes_start,
            .voters_len = @intCast(configuration.voters.len),
            .outgoing_len = @intCast(configuration.voters_outgoing.len),
            .learners_len = @intCast(configuration.learners.len),
            .suffix_kept = suffix_kept,
            .length_after = length_after,
        } });
    }

    pub fn load_snapshot(
        crash_store: *CrashStore,
    ) LogStore.ReadError!?interfaces.SnapshotRecord {
        return crash_store.live.load_snapshot();
    }

    pub fn sync(crash_store: *CrashStore) LogStore.UpdateError!void {
        if (crash_store.fires()) return error.StoreIoFailed;
        crash_store.flush();
        assert(crash_store.ops_len == 0);
    }

    // -----------------------------------------------------------------------------------
    // Journal.
    // -----------------------------------------------------------------------------------

    /// One mutation or `sync` call: true when the armed failure fires on it (and disarms).
    fn fires(crash_store: *CrashStore) bool {
        const left = crash_store.armed orelse return false;
        if (left > 0) {
            crash_store.armed = left - 1;
            return false;
        }
        crash_store.armed = null;
        return true;
    }

    /// Flushes when the next op does not fit; true when it fits the (now emptied) journal.
    fn make_room(crash_store: *CrashStore, entries_count: u32, bytes: u32) bool {
        const entries_cap: u64 = crash_store.journal_entries.len;
        const bytes_cap: u64 = crash_store.journal_data.len;
        const full = crash_store.ops_len == crash_store.ops.len or
            crash_store.journal_data_len + @as(u64, bytes) > bytes_cap or
            crash_store.journal_entries_len + @as(u64, entries_count) > entries_cap;
        if (full) crash_store.flush();
        return entries_count <= entries_cap and bytes <= bytes_cap;
    }

    fn push(crash_store: *CrashStore, op: Op) void {
        assert(crash_store.ops_len < crash_store.ops.len);
        crash_store.ops[crash_store.ops_len] = op;
        crash_store.ops_len += 1;
    }

    fn clear_journal(crash_store: *CrashStore) void {
        crash_store.ops_len = 0;
        crash_store.journal_entries_len = 0;
        crash_store.journal_data_len = 0;
        crash_store.journal_nodes_len = 0;
    }

    /// Copies the snapshot bytes and node lists into the journal (the room was made by the
    /// caller); returns where they went.
    fn journal_snapshot(
        crash_store: *CrashStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) struct { data_start: u32, nodes_start: u32 } {
        const data_start = crash_store.journal_data_len;
        const nodes_start = crash_store.journal_nodes_len;
        const data = crash_store.journal_data[data_start..][0..snapshot.data.len];
        @memcpy(data, snapshot.data);
        crash_store.journal_data_len += @intCast(snapshot.data.len);
        const lists = [_][]const NodeId{
            configuration.voters, configuration.voters_outgoing, configuration.learners,
        };
        for (lists) |list| {
            assert(crash_store.journal_nodes_len + list.len <= crash_store.journal_nodes.len);
            const at = crash_store.journal_nodes_len;
            @memcpy(crash_store.journal_nodes[at..][0..list.len], list);
            crash_store.journal_nodes_len += @intCast(list.len);
        }
        assert(crash_store.journal_nodes_len - nodes_start <= snapshot_nodes_max);
        return .{ .data_start = data_start, .nodes_start = nodes_start };
    }

    /// The journalled snapshot `op` as a record viewing the journal's copies.
    fn snapshot_view(crash_store: *const CrashStore, op: SnapshotOp) interfaces.SnapshotRecord {
        const voters_end = op.nodes_start + op.voters_len;
        const outgoing_end = voters_end + op.outgoing_len;
        const learners_end = outgoing_end + op.learners_len;
        assert(learners_end <= crash_store.journal_nodes_len);
        assert(op.data_start + op.data_len <= crash_store.journal_data_len);
        const nodes = crash_store.journal_nodes;
        return .{
            .snapshot = .{
                .index = op.index,
                .term = op.term,
                .data = crash_store.journal_data[op.data_start..][0..op.data_len],
            },
            .configuration = .{
                .voters = nodes[op.nodes_start..voters_end],
                .voters_outgoing = nodes[voters_end..outgoing_end],
                .learners = nodes[outgoing_end..learners_end],
            },
        };
    }

    /// Replays the whole journal into `durable`.
    fn flush(crash_store: *CrashStore) void {
        for (crash_store.ops[0..crash_store.ops_len]) |op| crash_store.replay(op);
        crash_store.clear_journal();
        assert(crash_store.ops_len == 0);
        assert(crash_store.journal_data_len == 0);
    }

    fn replay(crash_store: *CrashStore, op: Op) void {
        // proof: the journal is the exact diff of `live` over `durable`, so every replayed op
        // is valid on `durable` and within its limits.
        switch (op) {
            .append => |batch| {
                const entries = crash_store.journal_entries[batch.start..][0..batch.len];
                // proof: as above.
                crash_store.durable.append(entries) catch unreachable;
            },
            .truncate => |from| {
                // proof: as above.
                crash_store.durable.truncate(from) catch unreachable;
            },
            .hard_state => |state| {
                crash_store.hard_state_before = crash_store.durable.hard_state;
                // proof: as above.
                crash_store.durable.save_hard_state(&state) catch unreachable;
            },
            .snapshot => |snapshot_op| {
                const record = crash_store.snapshot_view(snapshot_op);
                const snapshot = &record.snapshot;
                const configuration = &record.configuration;
                // proof: as above.
                crash_store.durable.save_snapshot(snapshot, configuration) catch unreachable;
            },
        }
    }

    fn copy_store(target: *MemoryStore, source: *const MemoryStore) void {
        assert(target.entries.len == source.entries.len);
        const used = source.data_used;
        @memcpy(target.data[0..used], source.data[0..used]);
        for (source.entries[0..source.count], 0..) |entry, position| {
            const offset = @intFromPtr(entry.data.ptr) - @intFromPtr(source.data.ptr);
            target.entries[position] = entry;
            target.entries[position].data = target.data[offset..][0..entry.data.len];
        }
        target.count = source.count;
        target.data_used = used;
        target.base_index = source.base_index;
        target.base_term = source.base_term;
        target.hard_state = source.hard_state;
        target.snapshot = copy_snapshot(target, source);
        assert(target.base_index == source.base_index);
        assert((target.snapshot == null) == (source.snapshot == null));
    }

    /// `source`'s snapshot record rebuilt over `target`'s own buffers (bytes and node ids).
    fn copy_snapshot(target: *MemoryStore, source: *const MemoryStore) ?interfaces.SnapshotRecord {
        const record = source.snapshot orelse return null;
        assert(target.snapshot_data.len == source.snapshot_data.len);
        assert(target.node_ids.len == source.node_ids.len);
        const data_len = record.snapshot.data.len;
        @memcpy(target.snapshot_data[0..data_len], record.snapshot.data);
        const lists = [_][]const NodeId{
            record.configuration.voters,
            record.configuration.voters_outgoing,
            record.configuration.learners,
        };
        var views: [3][]const NodeId = undefined;
        var used: usize = 0;
        for (lists, 0..) |list, which| {
            @memcpy(target.node_ids[used..][0..list.len], list);
            views[which] = target.node_ids[used..][0..list.len];
            used += list.len;
        }
        return .{
            .snapshot = .{
                .index = record.snapshot.index,
                .term = record.snapshot.term,
                .data = target.snapshot_data[0..data_len],
            },
            .configuration = .{
                .voters = views[0],
                .voters_outgoing = views[1],
                .learners = views[2],
            },
        };
    }

    // -----------------------------------------------------------------------------------
    // Invariants.
    // -----------------------------------------------------------------------------------

    fn last_of(store: *const MemoryStore) u64 {
        return @intFromEnum(store.base_index) + store.count;
    }

    fn same_entry(a: Entry, b: Entry) bool {
        if (a.index != b.index or a.term != b.term or a.kind != b.kind) return false;
        return std.mem.eql(u8, a.data, b.data);
    }

    /// The base, log length and hard state `live` must have: `durable` with the journal
    /// applied.
    fn expected_tail(crash_store: *const CrashStore) struct {
        base: u64,
        length: u64,
        state: HardState,
    } {
        var base: u64 = @intFromEnum(crash_store.durable.base_index);
        var length = last_of(&crash_store.durable);
        var state = crash_store.durable.hard_state;
        for (crash_store.ops[0..crash_store.ops_len]) |op| switch (op) {
            .append => |batch| {
                const last = crash_store.journal_entries[batch.start + batch.len - 1];
                length = @intFromEnum(last.index);
            },
            .truncate => |from| length = @intFromEnum(from) - 1,
            .hard_state => |next| state = next,
            .snapshot => |snapshot_op| {
                base = @intFromEnum(snapshot_op.index);
                length = snapshot_op.length_after;
            },
        };
        return .{ .base = base, .length = length, .state = state };
    }

    /// `live` equals `durable` plus the journal, without replaying it (no allocation).
    fn check_journal(crash_store: *const CrashStore) InvariantError!void {
        const live = &crash_store.live;
        const expected = crash_store.expected_tail();
        if (@intFromEnum(live.base_index) != expected.base) return error.CrashStoreDiverged;
        if (last_of(live) != expected.length) return error.CrashStoreDiverged;
        if (!live.hard_state.eql(&expected.state)) return error.CrashStoreDiverged;
        try crash_store.check_last_snapshot();
        try crash_store.check_entries(expected.base);
    }

    /// The newest journalled snapshot, if any, is what `live` holds, byte for byte.
    fn check_last_snapshot(crash_store: *const CrashStore) InvariantError!void {
        var at = crash_store.ops_len;
        while (at > 0) {
            at -= 1;
            const snapshot_op = switch (crash_store.ops[at]) {
                .snapshot => |found| found,
                else => continue,
            };
            const want = crash_store.snapshot_view(snapshot_op);
            const got = crash_store.live.snapshot orelse return error.CrashStoreDiverged;
            if (got.snapshot.index != want.snapshot.index) return error.CrashStoreDiverged;
            if (got.snapshot.term != want.snapshot.term) return error.CrashStoreDiverged;
            if (!std.mem.eql(u8, got.snapshot.data, want.snapshot.data)) {
                return error.CrashStoreDiverged;
            }
            const same_voters = std.mem.eql(
                NodeId,
                got.configuration.voters,
                want.configuration.voters,
            );
            const same_outgoing = std.mem.eql(
                NodeId,
                got.configuration.voters_outgoing,
                want.configuration.voters_outgoing,
            );
            const same_learners = std.mem.eql(
                NodeId,
                got.configuration.learners,
                want.configuration.learners,
            );
            if (!same_voters or !same_outgoing or !same_learners) return error.CrashStoreDiverged;
            return;
        }
    }

    /// The entries of `live` above `base` are the journalled and the durable ones that no
    /// later truncate or snapshot dropped.
    fn check_entries(crash_store: *const CrashStore, base: u64) InvariantError!void {
        const live = &crash_store.live;
        const durable = &crash_store.durable;
        // Backwards: an op's entries survive only below every later op's first index.
        var later_min: u64 = std.math.maxInt(u64);
        var checked: u64 = 0;
        var at = crash_store.ops_len;
        while (at > 0) {
            at -= 1;
            switch (crash_store.ops[at]) {
                .append => |batch| {
                    const entries = crash_store.journal_entries[batch.start..][0..batch.len];
                    for (entries) |entry| {
                        const index: u64 = @intFromEnum(entry.index);
                        if (index >= later_min or index <= base) continue;
                        if (!same_entry(live.entries[index - base - 1], entry)) {
                            return error.CrashStoreDiverged;
                        }
                        checked += 1;
                    }
                    later_min = @min(later_min, @intFromEnum(entries[0].index));
                },
                .truncate => |from| later_min = @min(later_min, @intFromEnum(from)),
                .hard_state => {},
                .snapshot => |snapshot_op| {
                    // A snapshot that does not hold its term drops everything above it.
                    if (snapshot_op.suffix_kept) continue;
                    later_min = @min(later_min, @intFromEnum(snapshot_op.index) + 1);
                },
            }
        }
        const kept_end = @min(last_of(durable), later_min - 1);
        const kept: u64 = if (kept_end > base) kept_end - base else 0;
        if (kept > 0) {
            const skip: usize = @intCast(base - @intFromEnum(durable.base_index));
            const durable_kept = durable.entries[skip..][0..@intCast(kept)];
            for (durable_kept, live.entries[0..@intCast(kept)]) |old, entry| {
                if (!same_entry(entry, old)) return error.CrashStoreDiverged;
            }
        }
        if (kept + checked != last_of(live) - base) return error.CrashStoreDiverged;
    }
};
