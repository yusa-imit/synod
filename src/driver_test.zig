//! Red tests for `driver.zig` (plan 003 item 2D, ADR-007 "Driver"), written from the contract.
//!
//! One `Peer` is the single construction path: a `MemoryStore` behind a recording `LogStore`
//! wrapper, a recording `StateMachine`, a queue `Transport`, a manual `Clock` and a seeded
//! `Rng`, all feeding one `Trace` of call kinds. A `Cluster` hand-pumps three peers (one tick
//! per `poll`, then deliver every queued message), so a run is deterministic. After EVERY
//! driver call `Peer.settle` checks the phase order of that call's trace, `check_invariants()`
//! of node and store, and that the store mirrors the node (the trivial reference model).
//!
//! Allocation: every buffer comes from `std.testing.allocator` (leaks fail the test).

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
const Driver = driver_module.Driver;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const MemoryStore = store_module.MemoryStore;
const Message = types.Message;
const Rng = interfaces.Rng;
const StateMachine = interfaces.StateMachine;
const Transport = interfaces.Transport;

const tick_ms = 10;
const options: Driver.Options = .{ .tick_ms = tick_ms, .ticks_per_poll_max = 3 };
const entries_per = 4; // fx.config.message_limits.entries_max
const entry_bytes = 32; // fx.config.message_limits.entry_bytes_max
const queue_max = 64;
const trace_max = 256;
const applied_max = 192;
const rounds_max = 400;
const proposals = 100;

// ---- recording seams ------------------------------------------------------------------------

const Kind = enum { append, truncate, save_hard_state, sync, send, apply };

/// Persist = 1, sync = 2, send = 3, apply = 4: ADR-007's "persist, sync, send, apply".
fn rank(kind: Kind) u8 {
    return switch (kind) {
        .append, .truncate, .save_hard_state => 1,
        .sync => 2,
        .send => 3,
        .apply => 4,
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

    fn first(trace: *const Trace, kind: Kind) ?u32 {
        for (trace.kinds[0..trace.len], 0..) |seen, at| if (seen == kind) return @intCast(at);
        return null;
    }

    fn last(trace: *const Trace, kind: Kind) ?u32 {
        var found: ?u32 = null;
        for (trace.kinds[0..trace.len], 0..) |seen, at| if (seen == kind) {
            found = @intCast(at);
        };
        return found;
    }
};

/// One driver call is one step: its calls never go back a phase, there is at most one `sync`,
/// and a step that persisted anything synced exactly once.
fn check_trace(trace: *const Trace) !void {
    var previous: u8 = 0;
    var persists: u32 = 0;
    for (trace.kinds[0..trace.len]) |kind| {
        try testing.expect(rank(kind) >= previous);
        previous = rank(kind);
        persists += @intFromBool(rank(kind) == 1);
    }
    try testing.expect(trace.count(.sync) <= 1);
    if (persists > 0) try testing.expectEqual(@as(u32, 1), trace.count(.sync));
}

const RecStore = struct {
    inner: *MemoryStore,
    trace: *Trace,
    fail_append: ?LogStore.WriteError = null,
    fail_sync: bool = false,

    pub fn append(self: *RecStore, entries: []const Entry) LogStore.WriteError!void {
        self.trace.push(.append);
        if (self.fail_append) |err| return err;
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
        configuration: *const types.Configuration,
    ) LogStore.WriteError!void {
        return self.inner.save_snapshot(snapshot, configuration);
    }

    pub fn load_snapshot(self: *RecStore) LogStore.ReadError!?interfaces.SnapshotRecord {
        return self.inner.load_snapshot();
    }

    pub fn sync(self: *RecStore) LogStore.UpdateError!void {
        self.trace.push(.sync);
        if (self.fail_sync) return error.StoreIoFailed;
        return self.inner.sync();
    }
};

const Applied = struct { index: u64, term: u64, len: u8, data: [8]u8 };

const RecSm = struct {
    trace: *Trace,
    applied: [applied_max]Applied = undefined,
    len: u32 = 0,
    fail: bool = false,

    pub fn apply(self: *RecSm, entry: *const Entry) StateMachine.ApplyError!void {
        self.trace.push(.apply);
        if (self.fail) return error.StateMachineFailed;
        assert(self.len < applied_max and entry.data.len <= 8);
        var record: Applied = .{
            .index = @intFromEnum(entry.index),
            .term = @intFromEnum(entry.term),
            .len = @intCast(entry.data.len),
            .data = @splat(0),
        };
        @memcpy(record.data[0..entry.data.len], entry.data);
        self.applied[self.len] = record;
        self.len += 1;
    }

    pub fn snapshot(self: *RecSm, writer: *std.Io.Writer) StateMachine.SnapshotError!void {
        _ = .{ self, writer };
        return error.StateMachineFailed;
    }

    pub fn restore(self: *RecSm, reader: *std.Io.Reader) StateMachine.RestoreError!void {
        _ = .{ self, reader };
        return error.StateMachineFailed;
    }

    fn at(sm: *const RecSm, position: u32) Applied {
        return sm.applied[position];
    }

    /// Index and term sequence and every data byte agree with `other` over `0..upto`.
    fn expect_prefix_of(sm: *const RecSm, other: *const RecSm, upto: u32) !void {
        try testing.expect(sm.len >= upto and other.len >= upto);
        for (0..upto) |k| {
            const a = sm.at(@intCast(k));
            const b = other.at(@intCast(k));
            try testing.expectEqual(a.index, b.index);
            try testing.expectEqual(a.term, b.term);
            try testing.expectEqualSlices(u8, a.data[0..a.len], b.data[0..b.len]);
        }
    }

    /// Applied indices are exactly 1, 2, 3, ... with no gap, repeat or reorder.
    fn expect_contiguous(sm: *const RecSm) !void {
        for (sm.applied[0..sm.len], 1..) |record, index| {
            try testing.expectEqual(@as(u64, index), record.index);
        }
    }
};

const Manual = struct {
    now: u64,
    pub fn now_ms(self: *Manual) u64 {
        return self.now;
    }
};

/// A message in flight owned by value: the sender's entry bytes are borrowed, so copy them.
const Packet = struct {
    message: Message,
    count: u32,
    entries: [entries_per]Entry,
    lens: [entries_per]u8,
    bytes: [entries_per * entry_bytes]u8,

    fn from(message: *const Message) Packet {
        var packet: Packet = undefined;
        packet.message = message.*;
        packet.count = 0;
        if (message.* != .append_entries) return packet;
        const request = message.append_entries;
        assert(request.entries.len <= entries_per);
        packet.message.append_entries.entries = &.{};
        for (request.entries, 0..) |entry, k| {
            assert(entry.data.len <= entry_bytes);
            @memcpy(packet.bytes[k * entry_bytes ..][0..entry.data.len], entry.data);
            packet.lens[k] = @intCast(entry.data.len);
            packet.entries[k] = entry;
        }
        packet.count = @intCast(request.entries.len);
        return packet;
    }

    fn view(packet: *const Packet, out: *[entries_per]Entry) Message {
        var message = packet.message;
        if (message != .append_entries) return message;
        for (0..packet.count) |k| {
            out[k] = packet.entries[k];
            out[k].data = packet.bytes[k * entry_bytes ..][0..packet.lens[k]];
        }
        message.append_entries.entries = out[0..packet.count];
        return message;
    }
};

const Net = struct {
    queue: [queue_max]Packet = undefined,
    head: u32 = 0,
    len: u32 = 0,
    sent: u32 = 0,

    fn push(net: *Net, message: *const Message) void {
        net.sent += 1;
        if (net.len == queue_max) return; // A full bounded queue drops (interfaces.zig).
        net.queue[(net.head + net.len) % queue_max] = Packet.from(message);
        net.len += 1;
    }

    fn pop(net: *Net) ?Packet {
        if (net.len == 0) return null;
        const packet = net.queue[net.head];
        net.head = (net.head + 1) % queue_max;
        net.len -= 1;
        return packet;
    }
};

const Wire = struct {
    net: *Net,
    trace: *Trace,
    pub fn send(self: *Wire, message: *const Message) void {
        self.trace.push(.send);
        self.net.push(message);
    }
};

// ---- the one construction path --------------------------------------------------------------

fn config_of(id: u64, log_entries: u32) raft.Config {
    var config = fx.config;
    config.id = fx.node_id(id);
    config.log_entries_max = log_entries;
    config.log_bytes_max = log_entries * 8;
    return config;
}

/// Initialize in place with `create` then `boot`; it owns every implementation the driver holds.
const Peer = struct {
    id: u64,
    log_entries: u32,
    store: MemoryStore,
    rec: RecStore,
    wire: Wire,
    sm: RecSm,
    clock: Manual,
    rng: fx.SplitMix,
    trace: Trace,
    driver: Driver,
    booted: bool,

    /// `forced` pins every `Rng` draw (`0` is an election timeout of exactly `t`).
    fn create(
        peer: *Peer,
        gpa: std.mem.Allocator,
        id: u64,
        net: *Net,
        log_entries: u32,
        forced: ?u64,
    ) !void {
        peer.* = .{
            .id = id,
            .log_entries = log_entries,
            .store = undefined,
            .rec = undefined,
            .wire = .{ .net = net, .trace = &peer.trace },
            .sm = .{ .trace = &peer.trace },
            .clock = .{ .now = 1000 },
            .rng = .{ .state = id *% 7919, .forced = forced },
            .trace = .{},
            .driver = undefined,
            .booted = false,
        };
        try peer.store.init(gpa, .{
            .entries_max = log_entries,
            .data_bytes_max = log_entries * 8,
            .snapshot_bytes_max = 16,
        });
        peer.rec = .{ .inner = &peer.store, .trace = &peer.trace };
    }

    fn boot(peer: *Peer, gpa: std.mem.Allocator) !void {
        assert(!peer.booted);
        const deps: Driver.Deps = .{
            .store = LogStore.init(&peer.rec),
            .transport = Transport.init(&peer.wire),
            .state_machine = StateMachine.init(&peer.sm),
            .clock = Clock.init(&peer.clock),
            .rng = Rng.init(&peer.rng),
        };
        const config = config_of(peer.id, peer.log_entries);
        try peer.driver.init(testing.io, gpa, config, options, &fx.configuration, deps);
        peer.booted = true;
    }

    fn halt(peer: *Peer, gpa: std.mem.Allocator) void {
        if (!peer.booted) return;
        peer.driver.deinit(testing.io, gpa);
        peer.booted = false;
    }

    fn destroy(peer: *Peer, gpa: std.mem.Allocator) void {
        peer.halt(gpa);
        peer.store.deinit(gpa);
    }

    /// A crash and restart: same store, fresh state machine, fresh driver.
    fn restart(peer: *Peer, gpa: std.mem.Allocator) !void {
        peer.halt(gpa);
        peer.sm = .{ .trace = &peer.trace };
        peer.trace.len = 0;
        try peer.boot(gpa);
    }

    fn status(peer: *const Peer) raft.Status {
        return peer.driver.node.status();
    }

    fn elapsed(peer: *const Peer) u32 {
        return peer.driver.node.election_elapsed;
    }

    /// The reference model: after a call the store holds exactly what the node holds.
    fn settle(peer: *Peer) !void {
        try check_trace(&peer.trace);
        try peer.driver.node.check_invariants();
        try peer.store.check_invariants();
        const now = peer.status();
        const saved = peer.store.hard_state;
        try testing.expectEqual(now.last_index, peer.store.last_index());
        try testing.expectEqual(now.term, saved.term);
        try testing.expectEqual(now.vote, saved.vote);
        try testing.expectEqual(now.commit_index, saved.commit_index);
        try testing.expect(!peer.driver.stopped);
    }

    fn poll(peer: *Peer) !void {
        peer.trace.len = 0;
        try peer.driver.poll(testing.io);
        try peer.settle();
    }

    fn tick(peer: *Peer) !void {
        peer.clock.now += tick_ms;
        try peer.poll();
    }

    fn receive(peer: *Peer, message: *const Message) !void {
        peer.trace.len = 0;
        try peer.driver.receive(testing.io, message);
        try peer.settle();
    }

    fn propose(peer: *Peer, data: []const u8) !void {
        peer.trace.len = 0;
        try peer.driver.propose(testing.io, data);
        try peer.settle();
    }
};

const Cluster = struct {
    net: Net,
    peers: [3]Peer,
    up: u32,

    fn init(cluster: *Cluster, gpa: std.mem.Allocator, log_entries: u32) !void {
        cluster.net = .{};
        cluster.up = 0;
        errdefer cluster.deinit(gpa);
        for (&cluster.peers, 1..) |*peer, id| {
            try peer.create(gpa, @intCast(id), &cluster.net, log_entries, null);
            cluster.up += 1;
            try peer.boot(gpa);
        }
    }

    fn deinit(cluster: *Cluster, gpa: std.mem.Allocator) void {
        for (cluster.peers[0..cluster.up]) |*peer| peer.destroy(gpa);
    }

    /// Delivers one packet to the peer it is addressed to.
    fn deliver(cluster: *Cluster, packet: *const Packet) !void {
        var buffer: [entries_per]Entry = undefined;
        const message = packet.view(&buffer);
        const to = @intFromEnum(message.header().to);
        try testing.expect(to >= 1 and to <= 3);
        try cluster.peers[to - 1].receive(&message);
    }

    fn drain(cluster: *Cluster) !void {
        for (0..2000) |_| {
            const packet = cluster.net.pop() orelse return;
            try cluster.deliver(&packet);
        }
        return error.TestUnexpectedResult; // The network never went quiet.
    }

    /// One tick of every peer, then every reply.
    fn round(cluster: *Cluster) !void {
        for (&cluster.peers) |*peer| try peer.tick();
        try cluster.drain();
    }

    fn leader(cluster: *Cluster) ?*Peer {
        for (&cluster.peers) |*peer| if (peer.status().role == .leader) return peer;
        return null;
    }

    fn elect(cluster: *Cluster) !*Peer {
        for (0..rounds_max) |_| {
            try cluster.round();
            if (cluster.leader()) |found| return found;
        }
        return error.TestUnexpectedResult;
    }

    fn run_until_applied(cluster: *Cluster, want: u32) !void {
        for (0..rounds_max) |_| {
            var done = true;
            for (&cluster.peers) |*peer| done = done and peer.sm.len >= want;
            if (done) return;
            try cluster.round();
        }
        return error.TestUnexpectedResult;
    }
};

fn value_bytes(buffer: *[4]u8, value: u32) []const u8 {
    std.mem.writeInt(u32, buffer, value, .big);
    return buffer;
}

fn data_value(record: Applied) u32 {
    return std.mem.readInt(u32, record.data[0..4], .big);
}

// ---- 1. the cluster contract ----------------------------------------------------------------

test "driver: three drivers elect one leader and apply the same 100 entries in order" {
    var cluster: Cluster = undefined;
    try cluster.init(testing.allocator, 128);
    defer cluster.deinit(testing.allocator);

    const leader = try cluster.elect();
    var buffer: [4]u8 = undefined;
    for (0..proposals) |value| {
        try leader.propose(value_bytes(&buffer, @intCast(value)));
        try cluster.drain();
    }
    try testing.expectEqual(@as(u64, proposals + 1), @intFromEnum(leader.status().last_index));
    try cluster.run_until_applied(proposals + 1);

    var leaders: u32 = 0;
    for (&cluster.peers) |*peer| {
        leaders += @intFromBool(peer.status().role == .leader);
        try peer.sm.expect_contiguous();
        try peer.sm.expect_prefix_of(&leader.sm, proposals + 1);
        try testing.expectEqual(@as(u32, proposals + 1), peer.sm.len);
        try testing.expectEqual(leader.status().commit_index, peer.status().commit_index);
        try testing.expectEqual(peer.status().commit_index, peer.status().applied_index);
        try testing.expectEqual(@as(u8, 0), peer.sm.at(0).len); // Index 1 is the no-op.
        var next: u32 = 0; // The 100 commands, in proposal order.
        for (peer.sm.applied[1..peer.sm.len]) |record| {
            try testing.expectEqual(@as(u8, 4), record.len);
            try testing.expectEqual(next, data_value(record));
            next += 1;
        }
        try testing.expectEqual(@as(u32, proposals), next);
    }
    try testing.expectEqual(@as(u32, 1), leaders);
}

// ---- 2. persist, sync, send, apply ----------------------------------------------------------

test "driver: phase_ready vetoes a send or apply while the store is unsynced" {
    for (std.meta.tags(raft.Effect.Phase)) |phase| {
        try testing.expect(driver_module.phase_ready(false, phase));
        const needs_sync = phase == .send or phase == .apply;
        try testing.expectEqual(!needs_sync, driver_module.phase_ready(true, phase));
    }
}

test "driver: phase_ordered accepts a non-decreasing phase and refuses a step back" {
    for (std.meta.tags(raft.Effect.Phase)) |previous| {
        for (std.meta.tags(raft.Effect.Phase)) |next| {
            const forward = @intFromEnum(next) >= @intFromEnum(previous);
            try testing.expectEqual(forward, driver_module.phase_ordered(previous, next));
        }
    }
}

test "driver: a follower step persists, syncs once, replies, then applies" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try peer.create(testing.allocator, 1, &net, 8, null);
    defer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);

    const batch = [_]Entry{fx.entry(1, 1, "x")};
    const message = fx.append_request(2, 1, 0, 0, 1, &batch);
    try peer.receive(&message);

    const trace = &peer.trace;
    try testing.expectEqual(@as(u32, 1), trace.count(.append));
    try testing.expect(trace.count(.save_hard_state) >= 1);
    try testing.expectEqual(@as(u32, 1), trace.count(.sync));
    try testing.expectEqual(@as(u32, 1), trace.count(.send));
    try testing.expectEqual(@as(u32, 1), trace.count(.apply));
    const persisted = @max(trace.last(.append).?, trace.last(.save_hard_state).?);
    try testing.expect(persisted < trace.first(.sync).?);
    try testing.expect(trace.first(.sync).? < trace.first(.send).?);
    try testing.expect(trace.first(.send).? < trace.first(.apply).?);

    const ack = net.pop().?.message.append_entries_response;
    try testing.expectEqual(fx.node_id(2), ack.header.to);
    const want: types.AppendOutcome = .{ .accepted = fx.idx(1) };
    try testing.expectEqual(want, ack.outcome);
    try testing.expectEqual(@as(u8, 'x'), peer.sm.at(0).data[0]);
    try testing.expectEqual(@as(u64, 1), peer.sm.at(0).index);
}

test "driver: a conflict truncates before it appends and both precede the sync and reply" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try peer.create(testing.allocator, 1, &net, 8, null);
    defer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);

    const old = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 1, "b") };
    try peer.receive(&fx.append_request(2, 1, 0, 0, 0, &old));
    const winner = [_]Entry{fx.entry(2, 2, "c")};
    try peer.receive(&fx.append_request(3, 2, 1, 1, 0, &winner));

    const trace = &peer.trace;
    try testing.expectEqual(@as(u32, 1), trace.count(.truncate));
    try testing.expect(trace.first(.truncate).? < trace.first(.append).?);
    try testing.expect(trace.last(.append).? < trace.first(.sync).?);
    try testing.expect(trace.first(.sync).? < trace.first(.send).?);
    const kept = try peer.store.get(fx.idx(2));
    try testing.expectEqual(fx.term(2), kept.term);
    try testing.expectEqualSlices(u8, "c", kept.data);
}

// ---- 3. faults stop the driver --------------------------------------------------------------

fn fault_peer(peer: *Peer, net: *Net) !void {
    try peer.create(testing.allocator, 1, net, 8, null);
    errdefer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);
    try testing.expect(!peer.driver.stopped);
}

test "driver: a failing store append is returned, stops the driver and sends nothing" {
    const faults = [_]LogStore.WriteError{ error.StoreFull, error.StoreIoFailed };
    for (faults) |fault| {
        var net: Net = .{};
        var peer: Peer = undefined;
        try fault_peer(&peer, &net);
        defer peer.destroy(testing.allocator);
        peer.rec.fail_append = fault;

        const batch = [_]Entry{fx.entry(1, 1, "x")};
        peer.trace.len = 0;
        try testing.expectError(fault, peer.driver.receive(testing.io, &fx.append_request(
            2,
            1,
            0,
            0,
            1,
            &batch,
        )));
        try testing.expect(peer.driver.stopped);
        try testing.expectEqual(@as(u32, 0), peer.trace.count(.send));
        try testing.expectEqual(@as(u32, 0), peer.trace.count(.apply));
        try testing.expectEqual(@as(u32, 0), net.sent);
        try testing.expectEqual(Index.zero, peer.store.last_index());
    }
}

test "driver: a failing sync stops the driver before any reply or apply leaves" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try fault_peer(&peer, &net);
    defer peer.destroy(testing.allocator);
    peer.rec.fail_sync = true;

    const batch = [_]Entry{fx.entry(1, 1, "x")};
    const message = fx.append_request(2, 1, 0, 0, 1, &batch);
    peer.trace.len = 0;
    try testing.expectError(error.StoreIoFailed, peer.driver.receive(testing.io, &message));
    try testing.expect(peer.driver.stopped);
    try testing.expectEqual(@as(u32, 1), peer.trace.count(.sync));
    try testing.expectEqual(@as(u32, 0), peer.trace.count(.send));
    try testing.expectEqual(@as(u32, 0), peer.trace.count(.apply));
    try testing.expectEqual(@as(u32, 0), net.sent);
}

test "driver: a failing apply is returned and stops the driver after the durable reply" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try fault_peer(&peer, &net);
    defer peer.destroy(testing.allocator);
    peer.sm.fail = true;

    const batch = [_]Entry{fx.entry(1, 1, "x")};
    const message = fx.append_request(2, 1, 0, 0, 1, &batch);
    peer.trace.len = 0;
    try testing.expectError(error.StateMachineFailed, peer.driver.receive(testing.io, &message));
    try testing.expect(peer.driver.stopped);
    try check_trace(&peer.trace); // Persist, sync, send, then the failed apply.
    try testing.expectEqual(@as(u32, 1), peer.trace.count(.send));
    try testing.expectEqual(@as(u32, 1), peer.trace.count(.apply));
    try testing.expectEqual(fx.idx(1), peer.store.last_index()); // The entry is durable.
    try testing.expectEqual(@as(u32, 0), peer.sm.len);
}

// ---- 4. restart -----------------------------------------------------------------------------

test "driver: a restart over the same store re-applies the whole committed log in order" {
    var cluster: Cluster = undefined;
    try cluster.init(testing.allocator, 128);
    defer cluster.deinit(testing.allocator);
    const leader = try cluster.elect();
    var buffer: [4]u8 = undefined;
    for (0..proposals) |value| {
        try leader.propose(value_bytes(&buffer, @intCast(value)));
        try cluster.drain();
    }
    try cluster.run_until_applied(proposals + 1);

    const peer = &cluster.peers[if (leader == &cluster.peers[1]) 2 else 1];
    const saved = peer.store.hard_state;
    const commit: u32 = @intCast(@intFromEnum(saved.commit_index));
    try testing.expectEqual(@as(u32, proposals + 1), commit);
    var before: RecSm = .{ .trace = &peer.trace, .len = peer.sm.len };
    before.applied = peer.sm.applied;

    try peer.restart(testing.allocator);
    const now = peer.status();
    try testing.expectEqual(raft.Role.follower, now.role);
    try testing.expectEqual(saved.term, now.term);
    try testing.expectEqual(saved.vote, now.vote);
    try testing.expectEqual(saved.commit_index, now.commit_index);
    try testing.expectEqual(peer.store.last_index(), now.last_index);

    try peer.tick(); // The first step applies (0, commit_index] into the fresh machine.
    try testing.expectEqual(commit, peer.sm.len);
    try peer.sm.expect_contiguous();
    try peer.sm.expect_prefix_of(&before, commit);
    try testing.expectEqual(@as(u32, 0), peer.trace.count(.append) + peer.trace.count(.truncate));

    try leader.propose("late"); // Rejoining: new commits reach the restarted machine in order.
    try cluster.drain();
    try cluster.run_until_applied(commit + 1);
    try peer.sm.expect_contiguous();
    try testing.expectEqualSlices(u8, "late", peer.sm.at(commit).data[0..4]);
}

test "driver: a restart applies the committed prefix only, never the uncommitted tail" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try peer.create(testing.allocator, 1, &net, 8, null);
    defer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);
    const batch = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 1, "b"), fx.entry(3, 1, "c") };
    try peer.receive(&fx.append_request(2, 1, 0, 0, 1, &batch));
    try testing.expectEqual(@as(u32, 1), peer.sm.len);

    try peer.restart(testing.allocator);
    const now = peer.status();
    try testing.expectEqual(fx.idx(3), now.last_index); // The tail stays in the log.
    try testing.expectEqual(fx.idx(1), now.commit_index);
    try testing.expectEqual(fx.term(1), now.term);
    try testing.expectEqual(@as(usize, 3), peer.driver.node.entries().len);
    try peer.tick();
    try testing.expectEqual(@as(u32, 1), peer.sm.len);
    try testing.expectEqual(@as(u64, 1), peer.sm.at(0).index);
    try testing.expectEqual(@as(u8, 'a'), peer.sm.at(0).data[0]);
    try testing.expectEqual(@as(u32, 0), peer.trace.count(.append) + peer.trace.count(.truncate));
}

// ---- 5. poll turns the clock into whole ticks -----------------------------------------------

fn tick_peer(peer: *Peer, net: *Net) !void {
    try peer.create(testing.allocator, 1, net, 8, 0); // Every draw 0: timeout is exactly t = 10.
    errdefer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);
}

test "driver: poll yields no tick before tick_ms and carries the remainder after it" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try tick_peer(&peer, &net);
    defer peer.destroy(testing.allocator);

    try peer.poll();
    try testing.expectEqual(@as(u32, 0), peer.elapsed()); // No time has passed.
    peer.clock.now += tick_ms - 1;
    try peer.poll();
    try testing.expectEqual(@as(u32, 0), peer.elapsed()); // One ms short of a tick.
    peer.clock.now += 1;
    try peer.poll();
    try testing.expectEqual(@as(u32, 1), peer.elapsed());
    peer.clock.now += 25;
    try peer.poll();
    try testing.expectEqual(@as(u32, 3), peer.elapsed()); // Two whole ticks, 5 ms left over.
    peer.clock.now += 5;
    try peer.poll();
    try testing.expectEqual(@as(u32, 4), peer.elapsed()); // The remainder completes a tick.
    try peer.poll();
    try testing.expectEqual(@as(u32, 4), peer.elapsed()); // A repeat poll adds nothing.
}

test "driver: the tick count is what reaches the election timeout, not a poll count" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try tick_peer(&peer, &net);
    defer peer.destroy(testing.allocator);

    for ([_]u32{ 2, 4, 6, 8 }) |ticks| { // 9 ticks in, still a follower.
        peer.clock.now += 2 * tick_ms;
        try peer.poll();
        try testing.expectEqual(ticks, peer.elapsed());
    }
    try testing.expectEqual(@as(u32, 0), net.sent);
    peer.clock.now += 2 * tick_ms; // Tick 10 fires the timer: a PreVote to both peers.
    try peer.poll();
    try testing.expectEqual(raft.Role.pre_candidate, peer.status().role);
    try testing.expectEqual(@as(u32, 2), net.sent);
}

test "driver: a stall longer than ticks_per_poll_max drops the extra ticks" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try tick_peer(&peer, &net);
    defer peer.destroy(testing.allocator);

    peer.clock.now += 50 * tick_ms;
    try peer.poll();
    try testing.expectEqual(@as(u32, options.ticks_per_poll_max), peer.elapsed());
    try peer.poll();
    try testing.expectEqual(@as(u32, 3), peer.elapsed()); // The dropped ticks are not owed.
    peer.clock.now += tick_ms - 1;
    try peer.poll();
    try testing.expectEqual(@as(u32, 3), peer.elapsed());
    peer.clock.now += 1;
    try peer.poll();
    try testing.expectEqual(@as(u32, 4), peer.elapsed());
    try testing.expectEqual(@as(u32, 0), net.sent);
}

// ---- 6. rejected inputs ---------------------------------------------------------------------

test "driver: a rejected message or proposal returns its typed error and writes nothing" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try peer.create(testing.allocator, 1, &net, 8, null);
    defer peer.destroy(testing.allocator);
    try peer.boot(testing.allocator);

    var bad_version = fx.heartbeat(2, 1, 1);
    bad_version.append_entries.header.protocol_version = 0;
    var many: [5]Entry = undefined;
    const five = fx.fill_entries(&many, 5, 1);
    const cases = [_]struct { message: Message, err: anyerror }{
        .{ .message = fx.heartbeat(2, 3, 1), .err = error.StepMisrouted },
        .{ .message = bad_version, .err = error.MessageVersionUnsupported },
        .{ .message = fx.heartbeat(2, 1, 0), .err = error.MessageTermZero },
        .{ .message = fx.append_request(2, 1, 0, 0, 0, five), .err = error.MessageTooLarge },
    };
    const before = peer.status();
    for (cases) |case| {
        peer.trace.len = 0;
        try testing.expectError(case.err, peer.driver.receive(testing.io, &case.message));
        try expect_untouched(&peer, before);
    }
    peer.trace.len = 0;
    try testing.expectError(error.ProposeNotLeader, peer.driver.propose(testing.io, "x"));
    try expect_untouched(&peer, before);
    try peer.tick(); // Still a working driver afterwards.
}

fn expect_untouched(peer: *Peer, before: raft.Status) !void {
    try testing.expectEqual(@as(u32, 0), peer.trace.len);
    try testing.expect(!peer.driver.stopped);
    try testing.expectEqual(before, peer.status());
    try testing.expectEqual(Index.zero, peer.store.last_index());
    try testing.expect(peer.store.hard_state.eql(&HardState.empty));
}

test "driver: a leader refuses oversized and over-capacity proposals without writing" {
    var cluster: Cluster = undefined;
    try cluster.init(testing.allocator, 8);
    defer cluster.deinit(testing.allocator);
    const leader = try cluster.elect();
    const before = leader.status();

    leader.trace.len = 0;
    const big: [entry_bytes + 1]u8 = @splat('z');
    try testing.expectError(error.ProposeTooLarge, leader.driver.propose(testing.io, &big));
    try expect_leader_untouched(leader, before);

    const room: u32 = 8 - @as(u32, @intCast(@intFromEnum(before.last_index)));
    for (0..room) |_| try leader.propose("abcd"); // Fills every slot.
    const full = leader.status();
    leader.trace.len = 0;
    try testing.expectError(error.ProposeLogFull, leader.driver.propose(testing.io, "abcd"));
    try expect_leader_untouched(leader, full);
    try testing.expectEqual(@as(u64, 8), @intFromEnum(full.last_index));
}

fn expect_leader_untouched(leader: *Peer, before: raft.Status) !void {
    try testing.expectEqual(@as(u32, 0), leader.trace.len);
    try testing.expect(!leader.driver.stopped);
    try testing.expectEqual(before, leader.status());
    try testing.expectEqual(before.last_index, leader.store.last_index());
}

// ---- 7. allocation --------------------------------------------------------------------------

test "driver: init fails cleanly at every allocation, then never allocates again" {
    var net: Net = .{};
    var peer: Peer = undefined;
    try peer.create(testing.allocator, 1, &net, 8, null);
    defer peer.destroy(testing.allocator);
    const log = [_]Entry{ fx.entry(1, 1, "ab"), fx.entry(2, 1, "cd"), fx.entry(3, 1, "ef") };
    try peer.store.append(&log);
    try peer.store.save_hard_state(&fx.hard_state_of(1, 0, 2));

    for (0..64) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const gpa = failing.allocator();
        peer.boot(gpa) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err); // Nothing is left allocated.
            try testing.expect(!peer.booted);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        const after_init = failing.alloc_index;
        const now = peer.status();
        try testing.expectEqual(fx.idx(3), now.last_index);
        try testing.expectEqual(fx.idx(2), now.commit_index);
        try testing.expectEqual(fx.term(1), now.term);
        for (0..12) |_| try peer.tick();
        try peer.receive(&fx.heartbeat(2, 1, 2));
        try testing.expectEqual(after_init, failing.alloc_index);
        peer.halt(gpa);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return;
    }
    return error.TestUnexpectedResult; // init never succeeded within 64 allocations.
}

// ---- 8. seeded model-based run with drops ---------------------------------------------------

const seeds_count = 40;
const chaos_steps = 400;

/// A random walk over ticks, proposals and deliveries (10% of packets dropped). The reference
/// model is the set of proposed values: every applied command was proposed, every machine's
/// applied log is gapless, and any two agree on their common prefix.
fn chaos(cluster: *Cluster, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [4]u8 = undefined;
    var proposed: u32 = 0;
    for (0..chaos_steps) |_| {
        const pick = random.uintLessThan(u32, 100);
        const peer = &cluster.peers[random.uintLessThan(u32, 3)];
        if (pick < 40) {
            try peer.tick();
        } else if (pick < 55) {
            peer.trace.len = 0;
            const data = value_bytes(&buffer, proposed);
            peer.propose(data) catch |err| {
                try testing.expectEqual(@as(u32, 0), peer.trace.len);
                try testing.expect(err == error.ProposeNotLeader or err == error.ProposeLogFull);
                continue;
            };
            proposed += 1;
        } else if (cluster.net.pop()) |packet| {
            if (random.uintLessThan(u32, 100) >= 10) try cluster.deliver(&packet);
        }
    }
    for (&cluster.peers) |*peer| try peer.sm.expect_contiguous();
    for (&cluster.peers) |*peer| for (&cluster.peers) |*other| {
        try peer.sm.expect_prefix_of(&other.sm, @min(peer.sm.len, other.sm.len));
        for (peer.sm.applied[0..peer.sm.len]) |record| {
            if (record.len > 0) try testing.expect(data_value(record) < proposed);
        }
    };
    for (0..rounds_max) |_| try cluster.round(); // Heal: a clean network converges.
    const want = cluster.peers[0].sm.len;
    try testing.expect(want >= 1); // Some leader was elected and committed its no-op.
    for (&cluster.peers) |*peer| try testing.expectEqual(want, peer.sm.len);
}

test "driver: seeded runs with dropped messages keep every applied log gapless and agreed" {
    for (0..seeds_count) |seed| {
        var cluster: Cluster = undefined;
        try cluster.init(testing.allocator, 128);
        defer cluster.deinit(testing.allocator);
        try chaos(&cluster, seed);
    }
}
