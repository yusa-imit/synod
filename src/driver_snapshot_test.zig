//! Red tests for the driver snapshot path and restart from a snapshot (plan 005 item 4,
//! ADR-009 "Who snapshots" and "Restart"), written from the contract, not from an implementation.
//!
//! Contract under test: on `snapshot_due` the driver snapshots the state machine into a buffer of
//! `config.message_limits.snapshot_bytes_max` bytes allocated by `Driver.init`, saves it with
//! `save_snapshot`, `sync`s, and only then feeds `snapshot_saved` to the node, so the log base
//! advances. A snapshot over the buffer is `error.SnapshotTooLarge` (a `Driver.Fault`), fail-stop.
//! `Driver.init` restores the state machine from the store's snapshot and replays `(base, commit]`
//! only; a bad stream or record is a typed init error.
//!
//! Fixtures: one `Rig` is the single construction path (a `MemoryStore` behind a recording
//! `LogStore`, a `KvSm` state machine with a real snapshot stream, a manual clock, a seeded `Rng`).
//! The `KvSm` stream is magic, applied index, key count, `(key, value)` pairs and a crc32, so a
//! corrupt or short stream is detectable. The reference model for the state is `KvSm.apply_op`
//! applied directly, never through a driver. Every buffer comes from `std.testing.allocator`.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");
const raft = @import("raft.zig");
const fx = @import("raft/fixtures.zig");
const store_module = @import("store.zig");
const driver_module = @import("driver.zig");

const Clock = interfaces.Clock;
const Configuration = types.Configuration;
const Crc32 = std.hash.Crc32;
const Driver = driver_module.Driver;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const MemoryStore = store_module.MemoryStore;
const Message = types.Message;
const NodeId = types.NodeId;
const Rng = interfaces.Rng;
const StateMachine = interfaces.StateMachine;
const Transport = interfaces.Transport;

const tick_ms = 10;
const options: Driver.Options = .{ .tick_ms = tick_ms, .ticks_per_poll_max = 3 };
const trace_max = 64;
const keys_max = 16;
const op_bytes = 6; // op u8 (1 put, 2 delete), key u8, value u32 big endian
const snapshot_head = 14; // magic 4, applied index 8, key count 2
const snapshot_empty_bytes = snapshot_head + 4; // plus the crc32
const snapshot_full_bytes = snapshot_empty_bytes + 5 * keys_max;
const restart_index = 400; // the snapshot the restart tests start from
const restart_tail = 20; // entries after it
const restart_snapshot_term = 3;
const restart_tail_term = 4;

const one_voter_ids = [_]NodeId{fx.node_id(1)};
const one_voter: Configuration = .{
    .voters = &one_voter_ids,
    .voters_outgoing = &.{},
    .learners = &.{},
};

// ---- recording seams ------------------------------------------------------------------------

const Kind = enum {
    append,
    truncate,
    save_hard_state,
    save_snapshot,
    sync,
    send,
    apply,
    sm_snapshot,
};

/// Persist = 1, sync = 2, send = 3, apply = 4 (ADR-007); the snapshot suffix is checked apart.
fn rank(kind: Kind) u8 {
    return switch (kind) {
        .append, .truncate, .save_hard_state => 1,
        .sync => 2,
        .send => 3,
        .apply => 4,
        .sm_snapshot, .save_snapshot => 5,
    };
}

const Trace = struct {
    kinds: [trace_max]Kind = undefined,
    len: u32 = 0,

    fn push(trace: *Trace, kind: Kind) void {
        assert(trace.len < trace_max);
        trace.kinds[trace.len] = kind;
        trace.len += 1;
    }

    fn count(trace: *const Trace, kind: Kind) u32 {
        var total: u32 = 0;
        for (trace.kinds[0..trace.len]) |seen| total += @intFromBool(seen == kind);
        return total;
    }
};

/// One driver call. Either no snapshot ran, and the calls never go back a phase, with exactly
/// one `sync` iff something was persisted; or it ends `sm_snapshot, save_snapshot, sync` with
/// nothing after that sync and the same phase rules before it (apply precedes the snapshot).
fn check_trace(trace: *const Trace) !void {
    const saved = trace.count(.save_snapshot);
    try testing.expectEqual(saved, trace.count(.sm_snapshot));
    try testing.expect(saved <= 1);
    var body: u32 = trace.len;
    if (saved == 1) {
        try testing.expect(trace.len >= 3);
        body = trace.len - 3;
        try testing.expectEqual(Kind.sm_snapshot, trace.kinds[body]);
        try testing.expectEqual(Kind.save_snapshot, trace.kinds[body + 1]);
        try testing.expectEqual(Kind.sync, trace.kinds[body + 2]);
    }
    var previous: u8 = 0;
    var persists: u32 = 0;
    var syncs: u32 = 0;
    for (trace.kinds[0..body]) |kind| {
        try testing.expect(rank(kind) >= previous and rank(kind) <= 4);
        previous = rank(kind);
        persists += @intFromBool(rank(kind) == 1);
        syncs += @intFromBool(kind == .sync);
    }
    try testing.expect(syncs <= 1);
    if (persists > 0) try testing.expectEqual(@as(u32, 1), syncs);
}

const RecStore = struct {
    inner: *MemoryStore,
    trace: *Trace,
    fail_save_snapshot: bool = false,
    fail_snapshot_sync: bool = false,
    fail_load_snapshot: bool = false,
    snapshot_unsynced: bool = false,

    pub fn append(self: *RecStore, entries: []const Entry) LogStore.WriteError!void {
        self.trace.push(.append);
        return self.inner.append(entries);
    }

    pub fn truncate(self: *RecStore, from: Index) LogStore.UpdateError!void {
        self.trace.push(.truncate);
        return self.inner.truncate(from);
    }

    pub fn get(self: *RecStore, index: Index) LogStore.ReadError!Entry {
        return self.inner.get(index);
    }

    pub fn last_index(self: *RecStore) Index {
        return self.inner.last_index();
    }

    pub fn save_hard_state(self: *RecStore, hs: *const HardState) LogStore.UpdateError!void {
        self.trace.push(.save_hard_state);
        return self.inner.save_hard_state(hs);
    }

    pub fn load_hard_state(self: *RecStore) LogStore.ReadError!HardState {
        return self.inner.load_hard_state();
    }

    pub fn save_snapshot(
        self: *RecStore,
        snapshot: *const types.Snapshot,
        configuration: *const Configuration,
    ) LogStore.WriteError!void {
        self.trace.push(.save_snapshot);
        if (self.fail_save_snapshot) return error.StoreIoFailed;
        try self.inner.save_snapshot(snapshot, configuration);
        self.snapshot_unsynced = true;
    }

    pub fn load_snapshot(self: *RecStore) LogStore.ReadError!?interfaces.SnapshotRecord {
        if (self.fail_load_snapshot) return error.StoreIoFailed;
        return self.inner.load_snapshot();
    }

    pub fn sync(self: *RecStore) LogStore.UpdateError!void {
        self.trace.push(.sync);
        if (self.fail_snapshot_sync and self.snapshot_unsynced) return error.StoreIoFailed;
        self.snapshot_unsynced = false;
        return self.inner.sync();
    }
};

fn restore_error(err: std.Io.Reader.Error) StateMachine.RestoreError {
    return switch (err) {
        error.EndOfStream => error.StateMachineSnapshotInvalid,
        error.ReadFailed => error.ReadFailed,
    };
}

/// A key-value state machine with a self-describing snapshot stream. Entry data is `op_bytes`
/// long; anything else (a leader's empty no-op) changes nothing.
const KvSm = struct {
    trace: ?*Trace,
    values: [keys_max]u32 = @splat(0),
    present: u16 = 0,
    applied_index: u64 = 0,
    apply_calls: u32 = 0,
    first_apply_index: u64 = 0,
    restore_calls: u32 = 0,
    snapshot_calls: u32 = 0,
    out_of_order: bool = false,
    fail_snapshot: bool = false,
    fail_restore: bool = false,

    /// The reference model: the state change of one command, with no index bookkeeping.
    fn apply_op(sm: *KvSm, data: []const u8) void {
        if (data.len != op_bytes or data[1] >= keys_max) return;
        const bit = @as(u16, 1) << @intCast(data[1]);
        switch (data[0]) {
            1 => {
                sm.values[data[1]] = std.mem.readInt(u32, data[2..6], .big);
                sm.present |= bit;
            },
            2 => {
                sm.values[data[1]] = 0;
                sm.present &= ~bit;
            },
            else => {},
        }
    }

    pub fn apply(sm: *KvSm, entry: *const Entry) StateMachine.ApplyError!void {
        if (sm.trace) |trace| trace.push(.apply);
        const index = @intFromEnum(entry.index);
        if (index != sm.applied_index + 1) {
            sm.out_of_order = true;
            return error.StateMachineFailed;
        }
        sm.apply_calls += 1;
        if (sm.first_apply_index == 0) sm.first_apply_index = index;
        sm.applied_index = index;
        sm.apply_op(entry.data);
    }

    fn encode(sm: *const KvSm, out: *[snapshot_full_bytes]u8) []const u8 {
        @memcpy(out[0..4], "KV01");
        std.mem.writeInt(u64, out[4..12], sm.applied_index, .big);
        var count: u16 = 0;
        var at: usize = snapshot_head;
        for (0..keys_max) |key| {
            if ((sm.present >> @intCast(key)) & 1 == 0) continue;
            out[at] = @intCast(key);
            std.mem.writeInt(u32, out[at + 1 ..][0..4], sm.values[key], .big);
            at += 5;
            count += 1;
        }
        std.mem.writeInt(u16, out[12..14], count, .big);
        std.mem.writeInt(u32, out[at..][0..4], Crc32.hash(out[0..at]), .big);
        return out[0 .. at + 4];
    }

    pub fn snapshot(sm: *KvSm, writer: *std.Io.Writer) StateMachine.SnapshotError!void {
        if (sm.trace) |trace| trace.push(.sm_snapshot);
        sm.snapshot_calls += 1;
        if (sm.fail_snapshot) return error.StateMachineFailed;
        var buffer: [snapshot_full_bytes]u8 = undefined;
        try writer.writeAll(sm.encode(&buffer));
    }

    pub fn restore(sm: *KvSm, reader: *std.Io.Reader) StateMachine.RestoreError!void {
        sm.restore_calls += 1;
        if (sm.fail_restore) return error.StateMachineFailed;
        var buffer: [snapshot_full_bytes]u8 = undefined;
        reader.readSliceAll(buffer[0..snapshot_head]) catch |err| return restore_error(err);
        if (!std.mem.eql(u8, buffer[0..4], "KV01")) return error.StateMachineSnapshotInvalid;
        const count = std.mem.readInt(u16, buffer[12..14], .big);
        if (count > keys_max) return error.StateMachineSnapshotInvalid;
        const body = snapshot_head + 5 * @as(usize, count);
        reader.readSliceAll(buffer[snapshot_head .. body + 4]) catch |err| {
            return restore_error(err);
        };
        const want = std.mem.readInt(u32, buffer[body..][0..4], .big);
        if (Crc32.hash(buffer[0..body]) != want) return error.StateMachineSnapshotInvalid;
        if (reader.peekByte()) |_| {
            return error.StateMachineSnapshotInvalid; // Bytes after the checksum.
        } else |err| if (err != error.EndOfStream) return err;

        var fresh: KvSm = .{ .trace = sm.trace };
        var at: usize = snapshot_head;
        for (0..count) |_| {
            const key = buffer[at];
            if (key >= keys_max) return error.StateMachineSnapshotInvalid;
            if ((fresh.present >> @intCast(key)) != 0) return error.StateMachineSnapshotInvalid;
            fresh.present |= @as(u16, 1) << @intCast(key);
            fresh.values[key] = std.mem.readInt(u32, buffer[at + 1 ..][0..4], .big);
            at += 5;
        }
        fresh.applied_index = std.mem.readInt(u64, buffer[4..12], .big);
        fresh.restore_calls = sm.restore_calls;
        fresh.snapshot_calls = sm.snapshot_calls;
        sm.* = fresh;
    }

    /// A checksum of the key-value content alone (not the applied index).
    fn digest(sm: *const KvSm) u32 {
        var hash = Crc32.init();
        for (0..keys_max) |key| {
            if ((sm.present >> @intCast(key)) & 1 == 0) continue;
            var pair: [5]u8 = undefined;
            pair[0] = @intCast(key);
            std.mem.writeInt(u32, pair[1..5], sm.values[key], .big);
            hash.update(&pair);
        }
        return hash.final();
    }

    fn keys(sm: *const KvSm) u32 {
        return @popCount(sm.present);
    }
};

const Manual = struct {
    now: u64,
    pub fn now_ms(self: *Manual) u64 {
        return self.now;
    }
};

const Wire = struct {
    trace: *Trace,
    pub fn send(self: *Wire, message: *const Message) void {
        _ = message;
        self.trace.push(.send);
    }
};

/// The `i`-th command of the scripted workload: a put on most draws, a delete on one in five.
fn op_data(buffer: *[op_bytes]u8, i: u64) []const u8 {
    const mixed = (i +% 1) *% 0x9e3779b97f4a7c15;
    buffer[0] = if ((mixed >> 20) % 5 == 0) 2 else 1;
    buffer[1] = @intCast((mixed >> 40) % 12);
    std.mem.writeInt(u32, buffer[2..6], @truncate(mixed >> 8), .big);
    return buffer;
}

fn put_op(buffer: *[op_bytes]u8, key: u8, value: u32) []const u8 {
    buffer[0] = 1;
    buffer[1] = key;
    std.mem.writeInt(u32, buffer[2..6], value, .big);
    return buffer;
}

fn delete_op(buffer: *[op_bytes]u8, key: u8) []const u8 {
    _ = put_op(buffer, key, 0);
    buffer[0] = 2;
    return buffer;
}

// ---- the one construction path --------------------------------------------------------------

/// `buffer` is `message_limits.snapshot_bytes_max`, the driver's snapshot buffer.
const Spec = struct {
    log_entries: u32,
    snap_min: u32,
    trailing: u32,
    buffer: u64,
    store_snapshot_bytes: u32,
};

const spec_small: Spec = .{
    .log_entries = 16,
    .snap_min = 4,
    .trailing = 1,
    .buffer = snapshot_full_bytes,
    .store_snapshot_bytes = 256,
};

const spec_restart: Spec = .{
    .log_entries = 64,
    .snap_min = 32,
    .trailing = 8,
    .buffer = snapshot_full_bytes,
    .store_snapshot_bytes = 256,
};

fn config_of(spec: Spec) raft.Config {
    var config = fx.config;
    config.log_entries_max = spec.log_entries;
    config.log_bytes_max = spec.log_entries * 8;
    config.snapshot_entries_min = spec.snap_min;
    config.snapshot_trailing = spec.trailing;
    config.message_limits.snapshot_bytes_max = spec.buffer;
    return config;
}

/// Initialize in place with `create`, then `boot`; the caller runs `destroy`.
const Rig = struct {
    spec: Spec,
    configuration: *const Configuration,
    store: MemoryStore,
    rec: RecStore,
    wire: Wire,
    sm: KvSm,
    clock: Manual,
    rng: fx.SplitMix,
    trace: Trace,
    driver: Driver,
    booted: bool,
    saves: u32,

    fn create(rig: *Rig, gpa: std.mem.Allocator, spec: Spec, cfg: *const Configuration) !void {
        rig.* = .{
            .spec = spec,
            .configuration = cfg,
            .store = undefined,
            .rec = undefined,
            .wire = .{ .trace = &rig.trace },
            .sm = .{ .trace = &rig.trace },
            .clock = .{ .now = 1000 },
            .rng = .{ .state = 7919 },
            .trace = .{},
            .driver = undefined,
            .booted = false,
            .saves = 0,
        };
        try rig.store.init(gpa, .{
            .entries_max = spec.log_entries,
            .data_bytes_max = spec.log_entries * 8,
            .snapshot_bytes_max = spec.store_snapshot_bytes,
        });
        rig.rec = .{ .inner = &rig.store, .trace = &rig.trace };
    }

    fn boot(rig: *Rig, gpa: std.mem.Allocator) !void {
        assert(!rig.booted);
        const deps: Driver.Deps = .{
            .store = LogStore.init(&rig.rec),
            .transport = Transport.init(&rig.wire),
            .state_machine = StateMachine.init(&rig.sm),
            .clock = Clock.init(&rig.clock),
            .rng = Rng.init(&rig.rng),
        };
        const config = config_of(rig.spec);
        try rig.driver.init(testing.io, gpa, config, options, rig.configuration, deps);
        rig.booted = true;
    }

    fn halt(rig: *Rig, gpa: std.mem.Allocator) void {
        if (!rig.booted) return;
        rig.driver.deinit(testing.io, gpa);
        rig.booted = false;
    }

    fn destroy(rig: *Rig, gpa: std.mem.Allocator) void {
        rig.halt(gpa);
        rig.store.deinit(gpa);
    }

    /// A crash and restart: same store, fresh state machine, fresh driver.
    fn restart(rig: *Rig, gpa: std.mem.Allocator) !void {
        rig.halt(gpa);
        rig.sm = .{ .trace = &rig.trace };
        rig.trace.len = 0;
        try rig.boot(gpa);
    }

    fn status(rig: *const Rig) raft.Status {
        return rig.driver.node.status();
    }

    /// After a successful call: the node, the store and the trace agree, and when a snapshot
    /// was saved it was confirmed to the node (the reference model is the store).
    fn settle(rig: *Rig) !void {
        try check_trace(&rig.trace);
        try rig.driver.node.check_invariants();
        try rig.store.check_invariants();
        try testing.expect(!rig.driver.stopped);
        const now = rig.status();
        try testing.expectEqual(now.last_index, rig.store.last_index());
        try testing.expect(rig.store.hard_state.commit_index.order(now.commit_index) != .gt);
        try testing.expect(now.snapshot_index.order(now.applied_index) != .gt);
        if (rig.trace.count(.save_snapshot) == 1) {
            rig.saves += 1;
            try rig.expect_confirmed();
        }
    }

    fn expect_confirmed(rig: *Rig) !void {
        const record = rig.store.snapshot orelse return error.TestUnexpectedResult;
        const index = @intFromEnum(record.snapshot.index);
        try testing.expectEqual(rig.sm.applied_index, index); // State as of `applied`, no later.
        try testing.expectEqual(record.snapshot.index, rig.status().snapshot_index);
        const base = @intFromEnum(rig.driver.node.log.base.index);
        try testing.expectEqual(index - rig.spec.trailing, base); // index - trailing
        var copy: KvSm = .{ .trace = null };
        var reader = std.Io.Reader.fixed(record.snapshot.data);
        try copy.restore(&reader);
        try testing.expectEqual(rig.sm.digest(), copy.digest());
        try testing.expectEqual(index, copy.applied_index);
    }

    fn tick(rig: *Rig) !void {
        rig.clock.now += tick_ms;
        rig.trace.len = 0;
        try rig.driver.poll(testing.io);
        try rig.settle();
    }

    fn propose(rig: *Rig, data: []const u8) !void {
        rig.trace.len = 0;
        try rig.driver.propose(testing.io, data);
        try rig.settle();
    }

    fn put(rig: *Rig, i: u64) !void {
        var buffer: [op_bytes]u8 = undefined;
        try rig.propose(put_op(&buffer, @intCast(i % 12), @intCast(i)));
    }

    /// A single voter wins its own election within a bounded number of ticks.
    fn elect(rig: *Rig) !void {
        for (0..60) |_| {
            try rig.tick();
            if (rig.status().role == .leader) return;
        }
        return error.TestUnexpectedResult;
    }

    /// Ticks until the state machine has applied everything the node committed.
    fn catch_up(rig: *Rig) !void {
        for (0..12) |_| {
            if (rig.sm.applied_index == @intFromEnum(rig.status().commit_index)) return;
            try rig.tick();
        }
        try testing.expectEqual(@intFromEnum(rig.status().commit_index), rig.sm.applied_index);
    }
};

/// Boot must fail with exactly `want`; `testing.allocator` then proves `init` leaked nothing.
fn expect_boot_error(rig: *Rig, want: anyerror) !void {
    rig.boot(testing.allocator) catch |err| {
        try testing.expectEqualStrings(@errorName(want), @errorName(err));
        return;
    };
    rig.halt(testing.allocator);
    return error.TestUnexpectedResult;
}

/// Puts a snapshot at `restart_index` and `tail` entries after it straight into the store, as a
/// crashed node would have left them. Returns the reference digests of the state at the snapshot
/// and at the end of the tail (the never-crashed replica applied everything directly).
const Preloaded = struct { at_snapshot: u32, at_end: u32 };

fn preload(rig: *Rig, tail: u32, commit_extra: u32) !Preloaded {
    var reference: KvSm = .{ .trace = null };
    var buffer: [op_bytes]u8 = undefined;
    for (1..restart_index + 1) |i| reference.apply_op(op_data(&buffer, i));
    reference.applied_index = restart_index;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const snapshot: types.Snapshot = .{
        .index = fx.idx(restart_index),
        .term = fx.term(restart_snapshot_term),
        .data = reference.encode(&bytes),
    };
    try rig.store.save_snapshot(&snapshot, &fx.configuration);
    const at_snapshot = reference.digest();

    var data: [restart_tail][op_bytes]u8 = undefined;
    var entries: [restart_tail]Entry = undefined;
    for (0..tail) |k| {
        const index = restart_index + 1 + k;
        const slice = op_data(&data[k], index);
        entries[k] = fx.entry(index, restart_tail_term, slice);
        reference.apply_op(slice);
    }
    if (tail > 0) try rig.store.append(entries[0..tail]);
    const commit = restart_index + tail * commit_extra;
    try rig.store.save_hard_state(&fx.hard_state_of(restart_tail_term, 0, commit));
    return .{ .at_snapshot = at_snapshot, .at_end = reference.digest() };
}

// ---- 1. the snapshot path -------------------------------------------------------------------

test "driver snapshot: due saves, syncs, confirms, and the log base advances" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_small, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();
    try testing.expectEqual(Index.zero, rig.driver.node.log.base.index);

    var last_snapshot: u64 = 0;
    for (0..60) |i| {
        try rig.put(i); // 61 entries through a 16-slot log: only compaction lets this finish.
        const index = @intFromEnum(rig.store.base_index);
        try testing.expect(index >= last_snapshot); // Never backwards.
        last_snapshot = index;
    }
    try testing.expect(rig.saves >= 10); // One per `snap_min - trailing` = 3 applied entries.
    try testing.expectEqual(rig.saves, rig.sm.snapshot_calls);
    try testing.expect(rig.driver.node.log.base.index != Index.zero);
    try testing.expect(rig.status().snapshot_index != Index.zero);
}

test "driver snapshot: the first snapshot is taken at snap_min applied entries, not before" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_small, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();

    var i: u64 = 0;
    while (rig.saves == 0) : (i += 1) {
        try testing.expect(i < 10);
        try testing.expectEqual(@as(u32, 0), rig.sm.snapshot_calls);
        try rig.put(i);
    }
    const record = rig.store.snapshot.?;
    try testing.expect(@intFromEnum(record.snapshot.index) >= rig.spec.snap_min);
    try testing.expectEqual(@as(u32, 1), rig.sm.snapshot_calls);
    try testing.expectEqual(record.snapshot.index, rig.status().snapshot_index);
}

test "driver snapshot: a node below snap_min never snapshots" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_small, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();
    for (0..2) |i| try rig.put(i);
    try testing.expect(rig.status().applied_index.order(fx.idx(rig.spec.snap_min)) == .lt);
    try testing.expectEqual(@as(u32, 0), rig.sm.snapshot_calls);
    try testing.expect(rig.store.snapshot == null);
    try testing.expectEqual(Index.zero, rig.status().snapshot_index);
}

// ---- 2. restart from a snapshot -------------------------------------------------------------

test "driver snapshot: restart over a snapshot at 400 plus 20 entries replays only the 20" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    const want = try preload(&rig, restart_tail, 1);
    try rig.boot(testing.allocator);

    // Restored at init, before any step: the state is the snapshot's, nothing replayed yet.
    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls);
    try testing.expectEqual(@as(u64, restart_index), rig.sm.applied_index);
    try testing.expectEqual(want.at_snapshot, rig.sm.digest());
    try testing.expectEqual(@as(u32, 0), rig.sm.apply_calls);
    const now = rig.status();
    try testing.expectEqual(fx.idx(restart_index), now.applied_index);
    try testing.expectEqual(fx.idx(restart_index + restart_tail), now.commit_index);
    try testing.expectEqual(fx.idx(restart_index), rig.driver.node.log.base.index);
    try testing.expectEqual(@as(usize, restart_tail), rig.driver.node.entries().len);

    try rig.catch_up();
    try testing.expectEqual(@as(u32, restart_tail), rig.sm.apply_calls);
    try testing.expectEqual(@as(u64, restart_index + 1), rig.sm.first_apply_index);
    try testing.expect(!rig.sm.out_of_order);
    try testing.expectEqual(want.at_end, rig.sm.digest()); // The never-crashed replica's digest.
}

test "driver snapshot: restart with the commit lost in the crash resumes at the snapshot" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    const want = try preload(&rig, 0, 1);
    rig.store.hard_state.commit_index = .zero; // The crash lost the commit save of the install.
    try rig.boot(testing.allocator);

    const now = rig.status();
    try testing.expectEqual(fx.idx(restart_index), now.commit_index);
    try testing.expectEqual(fx.idx(restart_index), now.applied_index);
    try testing.expectEqual(@as(usize, 0), rig.driver.node.entries().len);
    for (0..3) |_| try rig.tick();
    try testing.expectEqual(@as(u32, 0), rig.sm.apply_calls); // Nothing to replay.
    try testing.expectEqual(want.at_snapshot, rig.sm.digest());
}

test "driver snapshot: uncommitted tail entries are not applied by a restart" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    const want = try preload(&rig, restart_tail, 0); // commit stays at the snapshot
    try rig.boot(testing.allocator);
    for (0..3) |_| try rig.tick();
    try testing.expectEqual(@as(u32, 0), rig.sm.apply_calls);
    try testing.expectEqual(want.at_snapshot, rig.sm.digest());
    try testing.expectEqual(@as(usize, restart_tail), rig.driver.node.entries().len);
}

test "driver snapshot: automatic snapshots then a crash restore to the never-crashed digest" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();
    var model: KvSm = .{ .trace = null };
    var buffer: [op_bytes]u8 = undefined;
    for (0..150) |i| {
        const data = op_data(&buffer, i);
        try rig.propose(data);
        model.apply_op(data);
        try rig.catch_up();
        try testing.expectEqual(model.digest(), rig.sm.digest());
    }
    try testing.expect(rig.saves >= 2);
    const snapshot_index = @intFromEnum(rig.store.base_index);
    const committed = @intFromEnum(rig.status().commit_index);
    try testing.expect(snapshot_index > 0 and snapshot_index <= committed);

    try rig.restart(testing.allocator);
    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls);
    try testing.expectEqual(snapshot_index, rig.sm.applied_index);
    try rig.catch_up();
    try testing.expectEqual(@as(u32, @intCast(committed - snapshot_index)), rig.sm.apply_calls);
    try testing.expect(rig.sm.apply_calls < rig.spec.log_entries); // Not the whole history.
    try testing.expect(!rig.sm.out_of_order);
    try testing.expectEqual(model.digest(), rig.sm.digest());

    try rig.elect(); // And the restarted node keeps working and keeps snapshotting.
    const saves_before = rig.saves;
    for (150..300) |i| {
        const data = op_data(&buffer, i);
        try rig.propose(data);
        model.apply_op(data);
    }
    try rig.catch_up();
    try testing.expect(rig.saves > saves_before);
    try testing.expectEqual(model.digest(), rig.sm.digest());
}

// ---- 3. a snapshot over the buffer is a typed, fail-stop fault -------------------------------

fn propose_until_error(rig: *Rig) anyerror {
    for (0..40) |i| {
        var data: [op_bytes]u8 = undefined;
        rig.propose(put_op(&data, @intCast(i % 12), @intCast(i))) catch |err| return err;
    }
    return error.NoCallFailed;
}

/// A rig at `spec_small` with `buffer` bytes, booted and elected.
fn start(rig: *Rig, buffer: u64) !void {
    var spec = spec_small;
    spec.buffer = buffer;
    try rig.create(testing.allocator, spec, &one_voter);
    errdefer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();
}

/// The size, in bytes, of the first snapshot that the scripted puts produce.
fn first_snapshot_size() !u64 {
    var rig: Rig = undefined;
    try start(&rig, snapshot_full_bytes);
    defer rig.destroy(testing.allocator);
    var i: u64 = 0;
    while (rig.saves == 0) : (i += 1) {
        try testing.expect(i < 10);
        try rig.put(i);
    }
    return rig.store.snapshot.?.snapshot.data.len;
}

fn expect_failed_stop(rig: *Rig) !void {
    try testing.expect(rig.driver.stopped);
    try testing.expectEqual(Index.zero, rig.status().snapshot_index); // Never confirmed.
    try testing.expectEqual(Index.zero, rig.driver.node.log.base.index); // Nothing compacted.
}

test "driver snapshot: Fault names SnapshotTooLarge" {
    var found = false;
    for (@typeInfo(Driver.Fault).error_set.?) |variant| {
        found = found or std.mem.eql(u8, variant.name, "SnapshotTooLarge");
    }
    try testing.expect(found);
}

test "driver snapshot: a snapshot one byte over the buffer is SnapshotTooLarge and fail-stop" {
    const size = try first_snapshot_size();
    try testing.expect(size > snapshot_empty_bytes);
    var rig: Rig = undefined;
    try start(&rig, size - 1);
    defer rig.destroy(testing.allocator);

    const err = propose_until_error(&rig);
    try testing.expectEqualStrings("SnapshotTooLarge", @errorName(err));
    try expect_failed_stop(&rig);
    try testing.expect(rig.store.snapshot == null); // Nothing was saved.
    try testing.expectEqual(@as(u32, 1), rig.sm.snapshot_calls);
    try testing.expectEqual(@as(u32, 0), rig.trace.count(.save_snapshot));
}

test "driver snapshot: a snapshot of exactly the buffer size is saved" {
    const size = try first_snapshot_size();
    var rig: Rig = undefined;
    try start(&rig, size);
    defer rig.destroy(testing.allocator);
    var i: u64 = 0;
    while (rig.saves == 0) : (i += 1) {
        try testing.expect(i < 10);
        try rig.put(i);
    }
    try testing.expectEqual(size, rig.store.snapshot.?.snapshot.data.len);
    try testing.expect(!rig.driver.stopped);
}

test "driver snapshot: an empty state machine snapshot fits a buffer of exactly its size" {
    var rig: Rig = undefined;
    try start(&rig, snapshot_empty_bytes);
    defer rig.destroy(testing.allocator);
    var i: u64 = 0;
    while (rig.saves == 0) : (i += 1) {
        try testing.expect(i < 10);
        var data: [op_bytes]u8 = undefined;
        try rig.propose(delete_op(&data, @intCast(i))); // Absent keys: stays empty.
    }
    try testing.expectEqual(@as(u32, 0), rig.sm.keys());
    const stored = rig.store.snapshot.?.snapshot.data;
    try testing.expectEqual(@as(usize, snapshot_empty_bytes), stored.len);
}

test "driver snapshot: even an empty snapshot is too large for a buffer one byte short" {
    var rig: Rig = undefined;
    try start(&rig, snapshot_empty_bytes - 1);
    defer rig.destroy(testing.allocator);
    var err: anyerror = error.TestUnexpectedResult;
    for (0..10) |i| {
        var data: [op_bytes]u8 = undefined;
        rig.propose(delete_op(&data, @intCast(i))) catch |caught| {
            err = caught;
            break;
        };
    }
    try testing.expectEqualStrings("SnapshotTooLarge", @errorName(err));
    try expect_failed_stop(&rig);
}

test "driver snapshot: a zero-byte buffer refuses every snapshot" {
    var rig: Rig = undefined;
    try start(&rig, 0);
    defer rig.destroy(testing.allocator);
    const err = propose_until_error(&rig);
    try testing.expectEqualStrings("SnapshotTooLarge", @errorName(err));
    try expect_failed_stop(&rig);
}

test "driver snapshot: after SnapshotTooLarge a restart with a big enough buffer recovers" {
    const size = try first_snapshot_size();
    var rig: Rig = undefined;
    try start(&rig, size - 1);
    defer rig.destroy(testing.allocator);
    const err = propose_until_error(&rig);
    try testing.expectEqualStrings("SnapshotTooLarge", @errorName(err));
    try expect_failed_stop(&rig);

    rig.spec.buffer = size; // The only recovery is a fresh init over the same store (ADR-006).
    try rig.restart(testing.allocator);
    try rig.catch_up();
    try rig.elect();
    for (0..30) |i| try rig.put(i);
    try testing.expect(rig.saves >= 1);
    try testing.expect(!rig.driver.stopped);
}

// ---- 4. the other faults of the snapshot path -----------------------------------------------

const Fault = enum { sm_snapshot_fails, save_fails, store_full, sync_fails };

fn arm(rig: *Rig, fault: Fault) void {
    switch (fault) {
        .sm_snapshot_fails => rig.sm.fail_snapshot = true,
        .save_fails => rig.rec.fail_save_snapshot = true,
        .store_full => {}, // The store was created too small for any non-empty snapshot.
        .sync_fails => rig.rec.fail_snapshot_sync = true,
    }
}

fn disarm(rig: *Rig) void {
    rig.rec.fail_save_snapshot = false;
    rig.rec.fail_snapshot_sync = false;
}

fn fault_case(fault: Fault, want: []const u8) !void {
    var spec = spec_small;
    if (fault == .store_full) spec.store_snapshot_bytes = snapshot_empty_bytes;
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();
    arm(&rig, fault);

    const err = propose_until_error(&rig);
    try testing.expectEqualStrings(want, @errorName(err));
    try expect_failed_stop(&rig); // Not confirmed: nothing compacted on a failed save or sync.

    disarm(&rig);
    rig.sm.fail_snapshot = false;
    try rig.restart(testing.allocator);
    try rig.catch_up();
    try rig.driver.node.check_invariants();
}

test "driver snapshot: StateMachine.snapshot failing is StateMachineFailed and fail-stop" {
    try fault_case(.sm_snapshot_fails, "StateMachineFailed");
}

test "driver snapshot: save_snapshot failing is StoreIoFailed and fail-stop" {
    try fault_case(.save_fails, "StoreIoFailed");
}

test "driver snapshot: a snapshot over the store's capacity is StoreFull and fail-stop" {
    try fault_case(.store_full, "StoreFull");
}

test "driver snapshot: sync failing after save_snapshot is StoreIoFailed, never confirmed" {
    try fault_case(.sync_fails, "StoreIoFailed");
}

// ---- 5. restart refuses a bad snapshot (valid becomes invalid) ------------------------------

const Mutation = enum { flip_checksum, flip_magic, short_by_three, extra_byte, empty };

fn mutate(rig: *Rig, how: Mutation) void {
    const record = &rig.store.snapshot.?;
    const data = rig.store.snapshot_data;
    const len = record.snapshot.data.len;
    switch (how) {
        .flip_checksum => data[len - 1] ^= 0x01,
        .flip_magic => data[0] ^= 0x01,
        .short_by_three => record.snapshot.data = data[0 .. len - 3],
        .extra_byte => {
            data[len] = 0;
            record.snapshot.data = data[0 .. len + 1];
        },
        .empty => record.snapshot.data = data[0..0],
    }
}

test "driver snapshot: a snapshot that was valid and is damaged is StateMachineSnapshotInvalid" {
    for (std.enums.values(Mutation)) |how| {
        var rig: Rig = undefined;
        try rig.create(testing.allocator, spec_restart, &fx.configuration);
        defer rig.destroy(testing.allocator);
        _ = try preload(&rig, restart_tail, 1);
        try rig.boot(testing.allocator); // Valid: boots.
        rig.halt(testing.allocator);

        mutate(&rig, how); // Now invalid: typed error, no leak, no half-initialized driver.
        rig.sm = .{ .trace = &rig.trace };
        expect_boot_error(&rig, error.StateMachineSnapshotInvalid) catch |err| {
            std.log.err("mutation {s}", .{@tagName(how)});
            return err;
        };
        try testing.expect(!rig.booted);
    }
}

test "driver snapshot: a state machine that cannot restore fails init with its own error" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    _ = try preload(&rig, restart_tail, 1);
    rig.sm.fail_restore = true;
    try expect_boot_error(&rig, error.StateMachineFailed);
}

test "driver snapshot: a snapshot record with index zero or term zero is StoreCorrupt" {
    inline for (.{ "index", "term" }) |field| {
        var rig: Rig = undefined;
        try rig.create(testing.allocator, spec_restart, &fx.configuration);
        defer rig.destroy(testing.allocator);
        _ = try preload(&rig, 0, 1);
        @field(rig.store.snapshot.?.snapshot, field) = @enumFromInt(0);
        try expect_boot_error(&rig, error.StoreCorrupt);
        try testing.expectEqual(@as(u32, 0), rig.sm.restore_calls); // Never restored from it.
    }
}

test "driver snapshot: load_snapshot failing is StoreIoFailed from init" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    _ = try preload(&rig, restart_tail, 1);
    rig.rec.fail_load_snapshot = true;
    try expect_boot_error(&rig, error.StoreIoFailed);
}

test "driver snapshot: a snapshot term above the hard state term is RestoreInconsistent" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    _ = try preload(&rig, 0, 1);
    rig.store.hard_state.term = fx.term(restart_snapshot_term - 1);
    try expect_boot_error(&rig, error.RestoreInconsistent);
}

/// A rig whose store holds a 420-entry history compacted to a 20-entry tail, and whose node
/// log has `node_slots` slots (`snap_min`/`trailing` kept coherent with it).
fn tail_rig(rig: *Rig, node_slots: u32) !void {
    var spec = spec_restart;
    spec.snap_min = 10;
    spec.trailing = 2;
    try rig.create(testing.allocator, spec, &fx.configuration);
    errdefer rig.destroy(testing.allocator);
    _ = try preload(rig, restart_tail, 1);
    rig.spec.log_entries = node_slots;
}

test "driver snapshot: a node log that holds the tail boots although last_index is 420" {
    var rig: Rig = undefined;
    try tail_rig(&rig, restart_tail);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try testing.expectEqual(@as(usize, restart_tail), rig.driver.node.entries().len);
    try rig.catch_up();
    try testing.expectEqual(@as(u32, restart_tail), rig.sm.apply_calls);
}

test "driver snapshot: a tail one entry longer than the node log is RestoreLogFull" {
    var rig: Rig = undefined;
    try tail_rig(&rig, restart_tail - 1);
    defer rig.destroy(testing.allocator);
    try expect_boot_error(&rig, error.RestoreLogFull);
}

// ---- 6. bytes bound ---------------------------------------------------------------------------

test "driver snapshot: init_bytes_max grows by exactly the snapshot buffer" {
    var config = config_of(spec_small);
    const base = Driver.init_bytes_max(&config);
    config.message_limits.snapshot_bytes_max += 1000;
    try testing.expectEqual(base + 1000, Driver.init_bytes_max(&config));
}

test "driver snapshot: init allocates within init_bytes_max with the buffer included" {
    var spec = spec_small;
    spec.buffer = 4096;
    const config = config_of(spec);
    const bound: usize = @intCast(Driver.init_bytes_max(&config));
    const backing = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);

    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec, &one_voter);
    defer rig.store.deinit(testing.allocator);
    try rig.boot(fixed.allocator()); // OutOfMemory here means the bound forgot the buffer.
    rig.driver.deinit(testing.io, fixed.allocator());
    rig.booted = false;
}

// ---- 7. seeded model: random proposals and crashes against a reference ------------------------

const model_steps = 150;

fn model_run(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &one_voter);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    try rig.elect();

    var ops: [model_steps][op_bytes]u8 = undefined;
    var op_index: [model_steps]u64 = undefined;
    var op_count: u32 = 0;
    for (0..model_steps) |_| {
        switch (random.uintLessThan(u32, 10)) {
            0 => try rig.restart(testing.allocator),
            1 => try rig.tick(),
            else => {
                if (rig.status().role != .leader) try rig.elect();
                try rig.propose(op_data(&ops[op_count], random.int(u64)));
                op_index[op_count] = @intFromEnum(rig.status().last_index);
                op_count += 1;
            },
        }
        try rig.catch_up();
        var reference: KvSm = .{ .trace = null }; // Replay every accepted command from scratch.
        for (ops[0..op_count], op_index[0..op_count]) |data, index| {
            if (index <= rig.sm.applied_index) reference.apply_op(&data);
        }
        try testing.expectEqual(reference.digest(), rig.sm.digest());
        try testing.expect(!rig.sm.out_of_order);
        try testing.expect(rig.store.base_index.order(rig.status().applied_index) != .gt);
    }
    try testing.expect(rig.saves > 0 or op_count < 30);
}

test "driver snapshot: seeded random proposals and crashes match a reference model" {
    for (1..13) |seed| try model_run(seed);
}

// ---- 8. fuzz: arbitrary snapshot bytes in the store ---------------------------------------------

fn fuzz_restore(_: void, smith: *testing.Smith) anyerror!void {
    var reference: KvSm = .{ .trace = null };
    var data: [op_bytes]u8 = undefined;
    for (0..smith.valueRangeAtMost(u8, 0, 6)) |_| {
        const key = smith.valueRangeAtMost(u8, 0, keys_max - 1);
        reference.apply_op(put_op(&data, key, smith.value(u32)));
    }
    reference.applied_index = 5;
    var encoded: [snapshot_full_bytes]u8 = undefined;
    var bytes: [snapshot_full_bytes + 4]u8 = undefined;
    var len = reference.encode(&encoded).len;
    @memcpy(bytes[0..len], encoded[0..len]);
    for (0..smith.valueRangeAtMost(u8, 0, 3)) |_| {
        if (smith.eos()) break;
        const at = smith.valueRangeAtMost(u8, 0, @intCast(len)); // len itself: append a byte
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => if (at < len) {
                bytes[at] ^= smith.value(u8);
            },
            1 => len = at,
            else => if (len < bytes.len) {
                bytes[len] = smith.value(u8);
                len += 1;
            },
        }
    }

    var oracle: KvSm = .{ .trace = null }; // The same bytes restored with no driver at all.
    var reader = std.Io.Reader.fixed(bytes[0..len]);
    const accepted = if (oracle.restore(&reader)) |_| true else |_| false;

    var rig: Rig = undefined;
    try rig.create(testing.allocator, spec_restart, &fx.configuration);
    defer rig.destroy(testing.allocator);
    const snapshot: types.Snapshot = .{
        .index = fx.idx(5),
        .term = fx.term(1),
        .data = bytes[0..len],
    };
    try rig.store.save_snapshot(&snapshot, &fx.configuration);
    try rig.store.save_hard_state(&fx.hard_state_of(1, 0, 5));
    if (!accepted) return expect_boot_error(&rig, error.StateMachineSnapshotInvalid);
    try rig.boot(testing.allocator);
    try testing.expectEqual(oracle.digest(), rig.sm.digest());
    try testing.expectEqual(@as(u64, 5), rig.sm.applied_index);
    try rig.driver.node.check_invariants();
}

test "driver snapshot: fuzzed snapshot bytes restore exactly when the state machine accepts them" {
    try testing.fuzz({}, fuzz_restore, .{});
}
