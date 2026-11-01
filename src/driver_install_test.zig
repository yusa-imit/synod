//! Red tests for the driver side of InstallSnapshot (plan 005 item 5, ADR-009 "InstallSnapshot"),
//! written from the contract, not from an implementation.
//!
//! Contract under test: when the node emits `send_snapshot`, the driver builds one
//! `install_snapshot` from the stored snapshot record (`load_snapshot`); a missing record or one
//! at another index or term is `StoreCorrupt`. A follower that gets an `install_snapshot` saves
//! the snapshot and the hard state with `commit = snapshot.index`, syncs, sends the reply, then
//! restores the state machine from the snapshot (`restore(index)`); a missing or misplaced stored
//! record at that point is `StoreCorrupt`, and every fault is fail-stop.
//!
//! Fixtures: one `Rig` (a `MemoryStore` behind a recording `LogStore` with a lying `load_snapshot`
//! switch, a `KvSm` state machine with a checksummed snapshot stream, a recording `Wire`, a manual
//! clock, a seeded `Rng`). The reference model is `KvSm.apply_op` applied directly, never through
//! a driver. Every buffer comes from `std.testing.allocator`.

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
const sent_max = 32;
const keys_max = 16;
const op_bytes = 6; // op u8 (1 put, 2 delete), key u8, value u32 big endian
const snapshot_head = 14; // magic 4, applied index 8, key count 2
const snapshot_full_bytes = snapshot_head + 4 + 5 * keys_max;
const base_index = 400; // the snapshot the leader starts from
const base_tail = 20; // entries after it
const base_term = 3; // term of the snapshot
const tail_term = 4; // term of the entries after it
const leader_term = tail_term + 1; // the term a won election runs in
const install_index = 9; // the snapshot a fresh follower is sent
const install_term = 1;

// ---- recording seams ------------------------------------------------------------------------

const Kind = enum { append, truncate, save_hard_state, save_snapshot, sync, send, apply, restore };

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

    /// The position of the first `kind`, or a test failure when there is none.
    fn first(trace: *const Trace, kind: Kind) !usize {
        for (trace.kinds[0..trace.len], 0..) |seen, at| if (seen == kind) return at;
        return error.TestUnexpectedResult;
    }
};

/// What the stored snapshot looks like to the driver, whatever the store really holds.
const LoadMode = enum { real, absent, index_below, index_above, term_other };

const RecStore = struct {
    inner: *MemoryStore,
    trace: *Trace,
    load_mode: LoadMode = .real,
    fail_save_snapshot: bool = false,
    fail_snapshot_sync: bool = false,
    snapshot_unsynced: bool = false,
    /// Something was persisted since the last successful `sync`.
    unsynced: bool = false,

    pub fn append(self: *RecStore, entries: []const Entry) LogStore.WriteError!void {
        self.trace.push(.append);
        self.unsynced = true;
        return self.inner.append(entries);
    }

    pub fn truncate(self: *RecStore, from: Index) LogStore.UpdateError!void {
        self.trace.push(.truncate);
        self.unsynced = true;
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
        self.unsynced = true;
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
        self.unsynced = true;
    }

    pub fn load_snapshot(self: *RecStore) LogStore.ReadError!?interfaces.SnapshotRecord {
        var record = (try self.inner.load_snapshot()) orelse return null;
        const index = @intFromEnum(record.snapshot.index);
        switch (self.load_mode) {
            .real => {},
            .absent => return null,
            .index_below => record.snapshot.index = @enumFromInt(index - 1),
            .index_above => record.snapshot.index = @enumFromInt(index + 1),
            .term_other => {
                record.snapshot.term = @enumFromInt(@intFromEnum(record.snapshot.term) + 1);
            },
        }
        return record;
    }

    pub fn sync(self: *RecStore) LogStore.UpdateError!void {
        self.trace.push(.sync);
        if (self.fail_snapshot_sync and self.snapshot_unsynced) return error.StoreIoFailed;
        self.snapshot_unsynced = false;
        self.unsynced = false;
        return self.inner.sync();
    }
};

fn restore_error(err: std.Io.Reader.Error) StateMachine.RestoreError {
    return switch (err) {
        error.EndOfStream => error.StateMachineSnapshotInvalid,
        error.ReadFailed => error.ReadFailed,
    };
}

/// A key-value state machine with a self-describing, checksummed snapshot stream.
const KvSm = struct {
    trace: ?*Trace,
    values: [keys_max]u32 = @splat(0),
    present: u16 = 0,
    applied_index: u64 = 0,
    restore_calls: u32 = 0,
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
        if (index != sm.applied_index + 1) return error.StateMachineFailed;
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
        var buffer: [snapshot_full_bytes]u8 = undefined;
        try writer.writeAll(sm.encode(&buffer));
    }

    pub fn restore(sm: *KvSm, reader: *std.Io.Reader) StateMachine.RestoreError!void {
        if (sm.trace) |trace| trace.push(.restore);
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

        var fresh: KvSm = .{ .trace = sm.trace, .restore_calls = sm.restore_calls };
        var at: usize = snapshot_head;
        for (0..count) |_| {
            const key = buffer[at];
            if (key >= keys_max) return error.StateMachineSnapshotInvalid;
            fresh.present |= @as(u16, 1) << @intCast(key);
            fresh.values[key] = std.mem.readInt(u32, buffer[at + 1 ..][0..4], .big);
            at += 5;
        }
        fresh.applied_index = std.mem.readInt(u64, buffer[4..12], .big);
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
};

const Manual = struct {
    now: u64,
    pub fn now_ms(self: *Manual) u64 {
        return self.now;
    }
};

/// Records every message handed to the transport, and copies the data of an `install_snapshot`
/// (it is borrowed from the store only until the store's next mutating call).
const Wire = struct {
    trace: *Trace,
    rec: *RecStore,
    sent: [sent_max]Message = undefined,
    sent_len: u32 = 0,
    /// Sends made while something persisted was not yet synced: always zero when correct.
    unsynced_sends: u32 = 0,
    snap_copy: [snapshot_full_bytes]u8 = undefined,
    snap_len: usize = 0,

    pub fn send(self: *Wire, message: *const Message) void {
        self.trace.push(.send);
        assert(self.sent_len < sent_max);
        self.sent[self.sent_len] = message.*;
        self.sent_len += 1;
        self.unsynced_sends += @intFromBool(self.rec.unsynced);
        switch (message.*) {
            .install_snapshot => |request| {
                self.snap_len = request.snapshot.data.len;
                assert(self.snap_len <= self.snap_copy.len);
                @memcpy(self.snap_copy[0..self.snap_len], request.snapshot.data);
            },
            else => {},
        }
    }

    fn count(wire: *const Wire, kind: types.MessageKind) u32 {
        var total: u32 = 0;
        for (wire.sent[0..wire.sent_len]) |message| total += @intFromBool(message == kind);
        return total;
    }

    /// The one message of `kind` sent so far; fails when there is none or several.
    fn only(
        wire: *const Wire,
        comptime kind: types.MessageKind,
    ) !@FieldType(Message, @tagName(kind)) {
        try testing.expectEqual(@as(u32, 1), wire.count(kind));
        for (wire.sent[0..wire.sent_len]) |message| {
            if (message == kind) return @field(message, @tagName(kind));
        }
        unreachable;
    }

    /// The round of the last `append_entries` sent to `to`.
    fn append_round(wire: *const Wire, to: u64) !u64 {
        var found: ?u64 = null;
        for (wire.sent[0..wire.sent_len]) |message| switch (message) {
            .append_entries => |request| if (request.header.to == fx.node_id(to)) {
                found = request.round;
            },
            else => {},
        };
        return found orelse error.TestUnexpectedResult;
    }
};

fn op_data(buffer: *[op_bytes]u8, i: u64) []const u8 {
    const mixed = (i +% 1) *% 0x9e3779b97f4a7c15;
    buffer[0] = if ((mixed >> 20) % 5 == 0) 2 else 1;
    buffer[1] = @intCast((mixed >> 40) % 12);
    std.mem.writeInt(u32, buffer[2..6], @truncate(mixed >> 8), .big);
    return buffer;
}

// ---- the one construction path --------------------------------------------------------------

fn config_of() raft.Config {
    var config = fx.config;
    config.log_entries_max = 64;
    config.log_bytes_max = 64 * 8;
    config.snapshot_entries_min = 32;
    config.snapshot_trailing = 8;
    config.message_limits.snapshot_bytes_max = snapshot_full_bytes;
    return config;
}

/// Initialize in place with `create`; the caller runs `destroy`. Three voters, driver is node 1.
const Rig = struct {
    store: MemoryStore,
    rec: RecStore,
    wire: Wire,
    sm: KvSm,
    clock: Manual,
    rng: fx.SplitMix,
    trace: Trace,
    driver: Driver,
    booted: bool,

    fn create(rig: *Rig, gpa: std.mem.Allocator) !void {
        rig.* = .{
            .store = undefined,
            .rec = undefined,
            .wire = undefined,
            .sm = .{ .trace = &rig.trace },
            .clock = .{ .now = 1000 },
            .rng = .{ .state = 7919 },
            .trace = .{},
            .driver = undefined,
            .booted = false,
        };
        try rig.store.init(gpa, .{
            .entries_max = 64,
            .data_bytes_max = 64 * 8,
            .snapshot_bytes_max = 256,
        });
        rig.rec = .{ .inner = &rig.store, .trace = &rig.trace };
        rig.wire = .{ .trace = &rig.trace, .rec = &rig.rec };
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
        try rig.driver.init(testing.io, gpa, config_of(), options, &fx.configuration, deps);
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

    /// A crash and restart: same store, fresh state machine and wire, fresh driver.
    fn restart(rig: *Rig, gpa: std.mem.Allocator) !void {
        rig.halt(gpa);
        rig.sm = .{ .trace = &rig.trace };
        rig.wire.sent_len = 0;
        rig.rec.load_mode = .real;
        rig.rec.fail_save_snapshot = false;
        rig.rec.fail_snapshot_sync = false;
        rig.trace.len = 0;
        try rig.boot(gpa);
    }

    fn status(rig: *const Rig) raft.Status {
        return rig.driver.node.status();
    }

    /// One `receive` with fresh recordings. The node, the store and the driver then still agree.
    fn deliver(rig: *Rig, message: Message) !void {
        rig.trace.len = 0;
        rig.wire.sent_len = 0;
        try rig.driver.receive(testing.io, &message);
        try rig.driver.node.check_invariants();
        try rig.store.check_invariants();
        try testing.expect(!rig.driver.stopped);
    }

    /// A `receive` that must fail with exactly `want`, after which the driver is stopped.
    fn deliver_failing(rig: *Rig, message: Message, want: anyerror) !void {
        rig.trace.len = 0;
        rig.wire.sent_len = 0;
        const result = rig.driver.receive(testing.io, &message);
        try testing.expect(std.meta.isError(result));
        result catch |err| try testing.expectEqualStrings(@errorName(want), @errorName(err));
        try testing.expect(rig.driver.stopped);
    }

    /// Wins the election at `at_term`: ticks to a pre-candidate, then node 2 grants both.
    fn elect(rig: *Rig, at_term: u64) !void {
        var guard: u32 = 0;
        while (rig.status().role != .pre_candidate) : (guard += 1) {
            try testing.expect(guard < 40);
            rig.clock.now += tick_ms;
            try rig.driver.poll(testing.io);
        }
        try rig.deliver(fx.pre_vote_response(2, 1, at_term, true));
        try rig.deliver(fx.vote_response(2, 1, at_term, true));
        try testing.expectEqual(raft.Role.leader, rig.status().role);
        try testing.expectEqual(fx.term(at_term), rig.status().term);
    }
};

/// The reference state after `count` scripted commands, as of applied index `applied`.
fn reference_after(count: u64, applied: u64) KvSm {
    var reference: KvSm = .{ .trace = null };
    var buffer: [op_bytes]u8 = undefined;
    for (1..count + 1) |i| reference.apply_op(op_data(&buffer, i));
    reference.applied_index = applied;
    return reference;
}

/// What a crashed leader would have left: the snapshot at `base_index`, `base_tail` entries after
/// it, the hard state at `tail_term` with commit at the snapshot. Returns the snapshot bytes
/// (in `bytes`) and the reference digest of the state at the snapshot.
fn preload(rig: *Rig, bytes: *[snapshot_full_bytes]u8) ![]const u8 {
    const reference = reference_after(base_index, base_index);
    const data = reference.encode(bytes);
    const snapshot: types.Snapshot = .{
        .index = fx.idx(base_index),
        .term = fx.term(base_term),
        .data = data,
    };
    try rig.store.save_snapshot(&snapshot, &fx.configuration);

    var payload: [base_tail][op_bytes]u8 = undefined;
    var entries: [base_tail]Entry = undefined;
    for (0..base_tail) |k| {
        const index = base_index + 1 + k;
        entries[k] = fx.entry(index, tail_term, op_data(&payload[k], index));
    }
    try rig.store.append(&entries);
    try rig.store.save_hard_state(&fx.hard_state_of(tail_term, 0, base_index));
    return data;
}

fn rejected_from(from: u64, round: u64, at_term: u64) Message {
    const conflict: types.Conflict = .{ .index = fx.idx(1), .term = fx.term(1) };
    return .{ .append_entries_response = .{
        .header = fx.header_of(from, 1, at_term),
        .round = round,
        .outcome = .{ .rejected = conflict },
    } };
}

/// The leader with peer 2 behind its log base: booted over the preloaded snapshot, elected, and
/// ready to receive peer 2's rejection. Returns that rejection.
fn leader_with_lagging_peer(rig: *Rig, bytes: *[snapshot_full_bytes]u8) !struct {
    data: []const u8,
    rejection: Message,
} {
    try rig.create(testing.allocator);
    errdefer rig.destroy(testing.allocator);
    const data = try preload(rig, bytes);
    try rig.boot(testing.allocator);
    try testing.expectEqual(fx.idx(base_index), rig.driver.node.log.base.index);
    try rig.elect(leader_term);
    const round = try rig.wire.append_round(2);
    return .{ .data = data, .rejection = rejected_from(2, round, leader_term) };
}

// ---- 1. the leader sends the stored snapshot ------------------------------------------------

test "driver install: a peer behind the base gets one install_snapshot built from the store" {
    var rig: Rig = undefined;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const setup = try leader_with_lagging_peer(&rig, &bytes);
    defer rig.destroy(testing.allocator);

    try rig.deliver(setup.rejection);

    const request = try rig.wire.only(.install_snapshot);
    try testing.expectEqual(fx.node_id(2), request.header.to);
    try testing.expectEqual(fx.node_id(1), request.header.from);
    try testing.expectEqual(fx.term(leader_term), request.header.term);
    try testing.expectEqual(types.protocol_version_current, request.header.protocol_version);
    try testing.expectEqual(fx.idx(base_index), request.snapshot.index);
    try testing.expectEqual(fx.term(base_term), request.snapshot.term);
    try testing.expectEqualSlices(u8, setup.data, rig.wire.snap_copy[0..rig.wire.snap_len]);
    try testing.expectEqualSlices(NodeId, &fx.voters, request.configuration.voters);
    try testing.expectEqual(@as(usize, 0), request.configuration.voters_outgoing.len);
    try testing.expectEqual(@as(usize, 0), request.configuration.learners.len);
    // The snapshot replaces the append: nothing else goes to peer 2 and nothing is persisted.
    try testing.expectEqual(@as(u32, 1), rig.wire.sent_len);
    try testing.expectEqual(@as(u32, 0), rig.trace.count(.save_snapshot));
    try testing.expectEqual(@as(u32, 0), rig.wire.unsynced_sends);
}

test "driver install: the snapshot sent is valid for the follower's own validation" {
    var rig: Rig = undefined;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const setup = try leader_with_lagging_peer(&rig, &bytes);
    defer rig.destroy(testing.allocator);
    try rig.deliver(setup.rejection);

    const message = (try rig.wire.only(.install_snapshot));
    const wrapped: Message = .{ .install_snapshot = message };
    try wrapped.validate(config_of().message_limits);
    const data_restored = blk: {
        var copy: KvSm = .{ .trace = null };
        var reader = std.Io.Reader.fixed(rig.wire.snap_copy[0..rig.wire.snap_len]);
        try copy.restore(&reader);
        break :blk copy;
    };
    const reference = reference_after(base_index, base_index);
    try testing.expectEqual(reference.digest(), data_restored.digest());
    try testing.expectEqual(@as(u64, base_index), data_restored.applied_index);
}

// ---- 2. the follower installs ---------------------------------------------------------------

fn install_message(data: []const u8) Message {
    return .{ .install_snapshot = .{
        .header = fx.header_of(2, 1, install_term),
        .snapshot = .{
            .index = fx.idx(install_index),
            .term = fx.term(install_term),
            .data = data,
        },
        .configuration = fx.configuration,
    } };
}

test "driver install: a follower saves, syncs, replies, then restores the state machine" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const data = reference.encode(&bytes);

    try rig.deliver(install_message(data));

    // The store holds exactly what the leader sent.
    const record = rig.store.snapshot orelse return error.TestUnexpectedResult;
    try testing.expectEqual(fx.idx(install_index), record.snapshot.index);
    try testing.expectEqual(fx.term(install_term), record.snapshot.term);
    try testing.expectEqualSlices(u8, data, record.snapshot.data);
    try testing.expectEqualSlices(NodeId, &fx.voters, record.configuration.voters);
    // Hard state as ADR-009 says the node persists: its term, commit = snapshot.index.
    try testing.expectEqual(fx.hard_state_of(install_term, 0, install_index), rig.store.hard_state);
    // The state machine is the snapshot, once, and the node agrees.
    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls);
    try testing.expectEqual(reference.digest(), rig.sm.digest());
    try testing.expectEqual(@as(u64, install_index), rig.sm.applied_index);
    try testing.expectEqual(fx.idx(install_index), rig.status().commit_index);
    try testing.expectEqual(fx.idx(install_index), rig.status().applied_index);
    try testing.expectEqual(fx.idx(install_index), rig.status().snapshot_index);
    // The reply: one response, to the sender, at that match index.
    const reply = try rig.wire.only(.install_snapshot_response);
    try testing.expectEqual(fx.idx(install_index), reply.match_index);
    try testing.expectEqual(fx.node_id(2), reply.header.to);
    try testing.expectEqual(fx.node_id(1), reply.header.from);
    try testing.expectEqual(fx.term(install_term), reply.header.term);
    try testing.expectEqual(@as(u32, 1), rig.wire.sent_len);
}

test "driver install: the reply goes out only after a sync, and restore after the reply" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;

    try rig.deliver(install_message(reference.encode(&bytes)));

    const saved = try rig.trace.first(.save_snapshot);
    const hard = try rig.trace.first(.save_hard_state);
    const synced = try rig.trace.first(.sync);
    const sent = try rig.trace.first(.send);
    const restored = try rig.trace.first(.restore);
    try testing.expect(saved < synced and hard < synced);
    try testing.expect(synced < sent);
    try testing.expect(sent < restored);
    try testing.expectEqual(@as(u32, 1), rig.trace.count(.save_snapshot));
    try testing.expectEqual(@as(u32, 1), rig.trace.count(.restore));
    try testing.expectEqual(@as(u32, 0), rig.wire.unsynced_sends);
    try testing.expect(!rig.rec.unsynced); // Nothing is left unsynced at the end of the step.
}

test "driver install: a snapshot at or below commit is acked and stores nothing" {
    var rig: Rig = undefined;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    _ = try preload(&rig, &bytes);
    try rig.boot(testing.allocator);
    const before = rig.store.hard_state;
    const sm_digest = rig.sm.digest();

    var old_bytes: [snapshot_full_bytes]u8 = undefined;
    const old = reference_after(install_index, install_index).encode(&old_bytes);
    var message = install_message(old);
    message.install_snapshot.header = fx.header_of(2, 1, tail_term);
    try rig.deliver(message);

    const reply = try rig.wire.only(.install_snapshot_response);
    try testing.expectEqual(fx.idx(install_index), reply.match_index);
    try testing.expectEqual(@as(u32, 0), rig.trace.count(.save_snapshot));
    try testing.expectEqual(@as(u32, 0), rig.trace.count(.restore));
    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls); // Only the boot restore.
    try testing.expectEqual(sm_digest, rig.sm.digest());
    try testing.expectEqual(before, rig.store.hard_state);
    try testing.expectEqual(fx.idx(base_index), rig.store.snapshot.?.snapshot.index);
}

test "driver install: an installed snapshot survives a restart with the same state" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    try rig.deliver(install_message(reference.encode(&bytes)));

    try rig.restart(testing.allocator);

    try testing.expectEqual(reference.digest(), rig.sm.digest());
    try testing.expectEqual(@as(u64, install_index), rig.sm.applied_index);
    try testing.expectEqual(fx.idx(install_index), rig.status().commit_index);
    try testing.expectEqual(fx.idx(install_index), rig.driver.node.log.base.index);
}

// ---- 3. send_snapshot against a store that disagrees ----------------------------------------

fn send_corrupt_case(mode: LoadMode) !void {
    var rig: Rig = undefined;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const setup = try leader_with_lagging_peer(&rig, &bytes);
    defer rig.destroy(testing.allocator);
    rig.rec.load_mode = mode; // Between the node deciding and the driver executing.

    try rig.deliver_failing(setup.rejection, error.StoreCorrupt);

    try testing.expectEqual(@as(u32, 0), rig.wire.count(.install_snapshot));
    try testing.expectEqual(@as(u32, 0), rig.wire.sent_len);
}

test "driver install: send_snapshot with no stored snapshot is StoreCorrupt and fail-stop" {
    try send_corrupt_case(.absent);
}

test "driver install: send_snapshot with a stored snapshot one index below is StoreCorrupt" {
    try send_corrupt_case(.index_below);
}

test "driver install: send_snapshot with a stored snapshot one index above is StoreCorrupt" {
    try send_corrupt_case(.index_above);
}

test "driver install: send_snapshot with a stored snapshot at another term is StoreCorrupt" {
    try send_corrupt_case(.term_other);
}

test "driver install: after a fail-stopped send a restart sends the snapshot again" {
    var rig: Rig = undefined;
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const setup = try leader_with_lagging_peer(&rig, &bytes);
    defer rig.destroy(testing.allocator);
    rig.rec.load_mode = .absent;
    try rig.deliver_failing(setup.rejection, error.StoreCorrupt);

    try rig.restart(testing.allocator); // The store itself was never damaged.
    try rig.elect(leader_term + 1); // The failed election persisted term 5.
    const round = try rig.wire.append_round(2);
    rig.wire.sent_len = 0;
    try rig.deliver(rejected_from(2, round, leader_term + 1));

    const request = try rig.wire.only(.install_snapshot);
    try testing.expectEqual(fx.idx(base_index), request.snapshot.index);
}

// ---- 4. restore against a store or state machine that disagrees -----------------------------

fn restore_corrupt_case(mode: LoadMode) !void {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const data = reference_after(install_index, install_index).encode(&bytes);
    rig.rec.load_mode = mode;

    try rig.deliver_failing(install_message(data), error.StoreCorrupt);

    try testing.expectEqual(@as(u32, 0), rig.sm.restore_calls); // Never fed the wrong snapshot.
    try testing.expectEqual(@as(u64, 0), rig.sm.applied_index);
}

test "driver install: restore with no stored snapshot is StoreCorrupt and fail-stop" {
    try restore_corrupt_case(.absent);
}

test "driver install: restore with a stored snapshot one index below is StoreCorrupt" {
    try restore_corrupt_case(.index_below);
}

test "driver install: restore with a stored snapshot one index above is StoreCorrupt" {
    try restore_corrupt_case(.index_above);
}

test "driver install: a state machine that cannot restore fails stop with its own error" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    rig.sm.fail_restore = true;

    try rig.deliver_failing(install_message(reference.encode(&bytes)), error.StateMachineFailed);

    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls);
    // The snapshot was saved and synced before the restore, so a restart recovers from it.
    try testing.expectEqual(fx.idx(install_index), rig.store.snapshot.?.snapshot.index);
    try rig.restart(testing.allocator);
    try testing.expectEqual(reference.digest(), rig.sm.digest());
    try testing.expectEqual(@as(u64, install_index), rig.sm.applied_index);
}

test "driver install: snapshot bytes the state machine rejects fail stop as invalid" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const good = reference.encode(&bytes);
    bytes[good.len - 1] ^= 0x01; // Damage the checksum; the length is unchanged.

    try rig.deliver_failing(install_message(good), error.StateMachineSnapshotInvalid);

    try testing.expectEqual(@as(u32, 1), rig.sm.restore_calls);
    try testing.expectEqual(@as(u64, 0), rig.sm.applied_index); // The state machine kept its state.
}

// ---- 5. the install persist path faults -----------------------------------------------------

test "driver install: save_snapshot failing is StoreIoFailed, with no reply and no restore" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    rig.rec.fail_save_snapshot = true;

    try rig.deliver_failing(install_message(reference.encode(&bytes)), error.StoreIoFailed);

    try testing.expectEqual(@as(u32, 0), rig.wire.sent_len);
    try testing.expectEqual(@as(u32, 0), rig.sm.restore_calls);
    try testing.expect(rig.store.snapshot == null);
}

test "driver install: sync failing after the snapshot save sends no reply and restores nothing" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    rig.rec.fail_snapshot_sync = true;

    try rig.deliver_failing(install_message(reference.encode(&bytes)), error.StoreIoFailed);

    try testing.expectEqual(@as(u32, 0), rig.wire.sent_len); // An unsynced install is never acked.
    try testing.expectEqual(@as(u32, 0), rig.sm.restore_calls);
}

test "driver install: a snapshot over the store's snapshot capacity is StoreFull" {
    var rig: Rig = undefined;
    try rig.create(testing.allocator);
    defer rig.destroy(testing.allocator);
    try rig.boot(testing.allocator);
    const reference = reference_after(install_index, install_index);
    var bytes: [snapshot_full_bytes]u8 = undefined;
    const data = reference.encode(&bytes);
    // A store too small for the record: rebuild it at the exact boundary minus one byte.
    rig.halt(testing.allocator);
    rig.store.deinit(testing.allocator);
    try rig.store.init(testing.allocator, .{
        .entries_max = 64,
        .data_bytes_max = 64 * 8,
        .snapshot_bytes_max = @intCast(data.len - 1),
    });
    try rig.boot(testing.allocator);

    try rig.deliver_failing(install_message(data), error.StoreFull);

    try testing.expectEqual(@as(u32, 0), rig.wire.sent_len);
    try testing.expectEqual(@as(u32, 0), rig.sm.restore_calls);
}
