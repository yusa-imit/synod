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
//! journal is applied to `durable` directly. `save_snapshot` is synchronous (flushes, then is
//! applied to both stores): snapshots are Phase 4 and `crash` asserts there is none.

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
const Snapshot = types.Snapshot;

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
    };

    /// What survives a crash plus the synced prefix; `live` is what the node sees.
    durable: MemoryStore,
    live: MemoryStore,
    fault: Fault,
    ops: []Op,
    ops_len: u32,
    journal_entries: []Entry,
    journal_entries_len: u32,
    journal_data: []u8,
    journal_data_len: u32,
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
            .armed = null,
            .hard_state_before = HardState.empty,
        };
        assert(crash_store.unsynced_count() == 0);
    }

    pub fn deinit(crash_store: *CrashStore, gpa: Allocator) void {
        assert(crash_store.ops.len > 0);
        assert(crash_store.ops_len <= crash_store.ops.len);
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
        assert(crash_store.durable.snapshot == null); // Snapshots are Phase 4.
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
        try crash_store.live.save_snapshot(snapshot, configuration);
        crash_store.flush();
        // `durable` holds the state `live` had before the call, so the call that succeeded on
        // `live` (same limits) succeeds here.
        // proof: see above.
        crash_store.durable.save_snapshot(snapshot, configuration) catch unreachable;
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
        }
    }

    fn copy_store(target: *MemoryStore, source: *const MemoryStore) void {
        assert(target.entries.len == source.entries.len);
        assert(source.snapshot == null);
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
        target.snapshot = null;
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

    /// The log length and hard state `live` must have: `durable` with the journal applied.
    fn expected_tail(crash_store: *const CrashStore) struct { length: u64, state: HardState } {
        var length = last_of(&crash_store.durable);
        var state = crash_store.durable.hard_state;
        for (crash_store.ops[0..crash_store.ops_len]) |op| switch (op) {
            .append => |batch| {
                const last = crash_store.journal_entries[batch.start + batch.len - 1];
                length = @intFromEnum(last.index);
            },
            .truncate => |from| length = @intFromEnum(from) - 1,
            .hard_state => |next| state = next,
        };
        return .{ .length = length, .state = state };
    }

    /// `live` equals `durable` plus the journal, without replaying it (no allocation).
    fn check_journal(crash_store: *const CrashStore) InvariantError!void {
        const live = &crash_store.live;
        const durable = &crash_store.durable;
        if (live.base_index != durable.base_index) return error.CrashStoreDiverged;
        const expected = crash_store.expected_tail();
        if (last_of(live) != expected.length) return error.CrashStoreDiverged;
        if (!live.hard_state.eql(&expected.state)) return error.CrashStoreDiverged;

        // Backwards: an op's entries survive only below every later op's first index.
        const base: u64 = @intFromEnum(live.base_index);
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
                        if (index >= later_min) continue;
                        if (!same_entry(live.entries[index - base - 1], entry)) {
                            return error.CrashStoreDiverged;
                        }
                        checked += 1;
                    }
                    later_min = @min(later_min, @intFromEnum(entries[0].index));
                },
                .truncate => |from| later_min = @min(later_min, @intFromEnum(from)),
                .hard_state => {},
            }
        }
        const kept = @min(last_of(durable), later_min - 1) - base;
        for (durable.entries[0..@intCast(kept)], 0..) |entry, position| {
            if (!same_entry(live.entries[position], entry)) return error.CrashStoreDiverged;
        }
        if (kept + checked != expected.length - base) return error.CrashStoreDiverged;
    }
};
