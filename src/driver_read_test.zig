//! Red tests for ReadIndex at the driver (plan 005 item 9, ADR-009 "Node contract"):
//! `Driver.read_index(io, ctx)` feeds `Input.read_index` to the node and runs the effects;
//! `read_ready` and `read_failed` become `ReadDone` records, available from `reads_done()` until
//! the next `receive`, `propose`, `poll` or `read_index` call, in effect order. A refused read
//! returns its typed `ReadIndexError` and writes nothing. Nothing allocates after `init`.
//!
//! Assumed API that does not exist yet (the red reason): the scaffold's `read_index` reaches a
//! node that refuses every read, and `execute` drops `read_ready`/`read_failed`, so
//! `reads_done()` is always empty. Names assumed: `Driver.ReadOutcome`, `Driver.ReadDone`,
//! `Driver.read_index`, `Driver.reads_done`, `Driver.init_bytes_max` counting the done buffer.
//!
//! One construction path: `H` owns a `MemoryStore`, a recording `Transport`, a counting state
//! machine, a manual clock and a seeded `Rng` behind one `Driver`; the other two voters of the
//! cluster are played by the test with `raft/fixtures.zig` messages built from the rounds the
//! driver actually sent. Every buffer comes from `std.testing.allocator`.

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
const LogStore = interfaces.LogStore;
const MemoryStore = store_module.MemoryStore;
const Message = types.Message;
const Rng = interfaces.Rng;
const StateMachine = interfaces.StateMachine;
const Transport = interfaces.Transport;

const tick_ms = 10;
const options: Driver.Options = .{ .tick_ms = tick_ms, .ticks_per_poll_max = 3 };

/// The last `append_entries` sent to a peer: its round and the last index it carries.
const Sent = struct { round: u64, last: u64 };

const Wire = struct {
    latest: [4]?Sent = @splat(null),
    appended: u32 = 0,

    pub fn send(self: *Wire, message: *const Message) void {
        switch (message.*) {
            .append_entries => |request| {
                const last = @intFromEnum(request.prev_log_index) + request.entries.len;
                self.latest[@intFromEnum(request.header.to)] = .{
                    .round = request.round,
                    .last = last,
                };
                self.appended += 1;
            },
            else => {},
        }
    }
};

const Sm = struct {
    applied: u32 = 0,

    pub fn apply(self: *Sm, entry: *const Entry) StateMachine.ApplyError!void {
        _ = entry;
        self.applied += 1;
    }

    pub fn snapshot(self: *Sm, writer: *std.Io.Writer) StateMachine.SnapshotError!void {
        _ = .{ self, writer };
        return error.StateMachineFailed; // Compaction is off in these tests.
    }

    pub fn restore(self: *Sm, reader: *std.Io.Reader) StateMachine.RestoreError!void {
        _ = .{ self, reader };
        return error.StateMachineFailed;
    }
};

const Manual = struct {
    now: u64,
    pub fn now_ms(self: *Manual) u64 {
        return self.now;
    }
};

fn config_of(reads_max: u32) raft.Config {
    var config = fx.config;
    config.log_entries_max = 16;
    config.log_bytes_max = 128;
    config.reads_max = reads_max;
    return config;
}

/// Initialize in place with `boot`; `deinit` frees. Node 1 is the driver, 2 and 3 are the test.
const H = struct {
    store: MemoryStore,
    wire: Wire,
    sm: Sm,
    clock: Manual,
    rng: fx.SplitMix,
    driver: Driver,

    fn boot(h: *H, gpa: std.mem.Allocator, config: raft.Config) !void {
        h.wire = .{};
        h.sm = .{};
        h.clock = .{ .now = 1000 };
        h.rng = .{ .state = 0, .forced = 0 }; // Election timeout of exactly `t` ticks.
        try h.store.init(gpa, .{
            .entries_max = 16,
            .data_bytes_max = 128,
            .snapshot_bytes_max = 16,
        });
        errdefer h.store.deinit(gpa);
        const deps: Driver.Deps = .{
            .store = LogStore.init(&h.store),
            .transport = Transport.init(&h.wire),
            .state_machine = StateMachine.init(&h.sm),
            .clock = Clock.init(&h.clock),
            .rng = Rng.init(&h.rng),
        };
        try h.driver.init(testing.io, gpa, config, options, &fx.configuration, deps);
    }

    fn deinit(h: *H, gpa: std.mem.Allocator) void {
        h.driver.deinit(testing.io, gpa);
        h.store.deinit(gpa);
    }

    fn check(h: *H) !void {
        try h.driver.node.check_invariants();
        try h.store.check_invariants();
        try testing.expect(!h.driver.stopped);
    }

    fn status(h: *const H) raft.Status {
        return h.driver.node.status();
    }

    fn tick(h: *H) !void {
        h.clock.now += tick_ms;
        try h.driver.poll(testing.io);
        try h.check();
    }

    fn receive(h: *H, message: *const Message) !void {
        try h.driver.receive(testing.io, message);
        try h.check();
    }

    fn read(h: *H, ctx: u64) !void {
        try h.driver.read_index(testing.io, ctx);
        try h.check();
    }

    /// Ticks to the election win: node 1 leads at the next term, its election entry uncommitted.
    fn win(h: *H) !void {
        for (0..40) |_| {
            if (h.status().role == .pre_candidate) break;
            try h.tick();
        }
        try testing.expectEqual(raft.Role.pre_candidate, h.status().role);
        const would_be = @intFromEnum(h.status().term) + 1;
        try h.receive(&fx.pre_vote_response(2, 1, would_be, true));
        try testing.expectEqual(raft.Role.candidate, h.status().role);
        try h.receive(&fx.vote_response(2, 1, would_be, true));
        try testing.expectEqual(raft.Role.leader, h.status().role);
    }

    /// Peer `peer` accepts the latest `append_entries` the driver sent it.
    fn answer(h: *H, peer: u64) !void {
        const sent = h.wire.latest[peer] orelse return error.TestUnexpectedResult;
        const term = @intFromEnum(h.status().term);
        const reply: Message = .{ .append_entries_response = .{
            .header = fx.header_of(peer, 1, term),
            .round = sent.round,
            .outcome = .{ .accepted = fx.idx(sent.last) },
        } };
        try h.receive(&reply);
    }

    /// A leader whose election entry (index 1) is committed and applied.
    fn lead(h: *H) !void {
        try h.win();
        try h.answer(2);
        try testing.expectEqual(fx.idx(1), h.status().commit_index);
        try testing.expectEqual(@as(u32, 1), h.sm.applied);
    }

    /// Ticks until the leader sends `append_entries` again.
    fn beat(h: *H) !void {
        const before = h.wire.appended;
        for (0..2 * options.ticks_per_poll_max + 1) |_| {
            try h.tick();
            if (h.wire.appended > before) return;
        }
        return error.TestUnexpectedResult;
    }

    fn expect_done(h: *const H, want: []const Driver.ReadDone) !void {
        try testing.expectEqualSlices(Driver.ReadDone, want, h.driver.reads_done());
    }
};

fn done(ctx: u64, index: u64, outcome: Driver.ReadOutcome) Driver.ReadDone {
    return .{ .read = .{ .ctx = ctx, .index = fx.idx(index) }, .outcome = outcome };
}

// ---- the read lifecycle ---------------------------------------------------------------------

test "driver: a read is ready after a later heartbeat is acknowledged, then reads_done clears" {
    var h: H = undefined;
    try h.boot(testing.allocator, config_of(4));
    defer h.deinit(testing.allocator);
    try h.lead();

    try h.read(77);
    try h.expect_done(&.{}); // Registered, not confirmed.
    try testing.expectEqual(@as(u32, 1), h.status().reads_pending);
    try h.beat();
    try h.expect_done(&.{}); // Sending the round confirms nothing.

    try h.answer(2);

    try h.expect_done(&.{done(77, 1, .ready)});
    try testing.expect(h.sm.applied >= 1); // The read's index is applied before it is reported.
    try testing.expectEqual(@as(u32, 0), h.status().reads_pending);
    try h.tick();
    try h.expect_done(&.{}); // This call's completions only.
}

test "driver: reads confirmed by one ack are reported in registration order" {
    var h: H = undefined;
    try h.boot(testing.allocator, config_of(4));
    defer h.deinit(testing.allocator);
    try h.lead();
    try h.read(77);
    try h.read(78);
    try h.read(79);
    try h.beat();

    try h.answer(3);

    try h.expect_done(&.{ done(77, 1, .ready), done(78, 1, .ready), done(79, 1, .ready) });
}

test "driver: a higher term fails every pending read in the step that deposes the leader" {
    var h: H = undefined;
    try h.boot(testing.allocator, config_of(4));
    defer h.deinit(testing.allocator);
    try h.lead();
    try h.read(77);
    try h.read(78);
    for (0..9) |_| try h.tick(); // Partitioned: heartbeats go out and nothing comes back.
    try h.expect_done(&.{});
    try testing.expectEqual(@as(u32, 2), h.status().reads_pending);

    try h.receive(&fx.heartbeat(2, 1, @intFromEnum(h.status().term) + 1));

    try h.expect_done(&.{ done(77, 1, .failed), done(78, 1, .failed) });
    try testing.expectEqual(raft.Role.follower, h.status().role);
    try testing.expectEqual(@as(u32, 0), h.status().reads_pending);
    try h.tick();
    try h.expect_done(&.{});
}

test "driver: a read that is ready keeps its index while later proposals commit" {
    var h: H = undefined;
    try h.boot(testing.allocator, config_of(4));
    defer h.deinit(testing.allocator);
    try h.lead();
    try h.read(77); // Index 1.
    try h.driver.propose(testing.io, "x"); // Index 2, sent after the read.
    try h.check();
    try h.expect_done(&.{});

    try h.answer(2); // Commits 2, applies it and confirms the read.

    try h.expect_done(&.{done(77, 1, .ready)});
    try testing.expectEqual(@as(u32, 2), h.sm.applied); // Applied through 2 >= the read's 1.
}

// ---- refusals -------------------------------------------------------------------------------

test "driver: a refused read returns its typed error, writes nothing and does not stop" {
    var h: H = undefined;
    try h.boot(testing.allocator, config_of(2));
    defer h.deinit(testing.allocator);
    try testing.expectError(error.ReadIndexNotLeader, h.driver.read_index(testing.io, 1));
    try h.expect_done(&.{});

    try h.win(); // Leader, election entry not committed.
    const last = h.store.last_index();
    try testing.expectError(error.ReadIndexNotReady, h.driver.read_index(testing.io, 1));
    try testing.expectEqual(last, h.store.last_index());

    try h.answer(2);
    try h.read(1);
    try h.read(2);
    const before = h.status();
    try testing.expectError(error.ReadIndexFull, h.driver.read_index(testing.io, 3));

    try testing.expectEqual(before, h.status());
    try testing.expectEqual(last, h.store.last_index());
    try h.expect_done(&.{});
    try h.check();
}

// ---- allocation -----------------------------------------------------------------------------

test "driver: init_bytes_max counts the done buffer and a buffer of that size fits init" {
    const small = config_of(2);
    const large = config_of(8);
    const growth = Driver.init_bytes_max(&large) - Driver.init_bytes_max(&small);
    try testing.expect(growth >= (8 - 2) * @sizeOf(Driver.ReadDone));

    const memory = try testing.allocator.alloc(u8, Driver.init_bytes_max(&large));
    defer testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    var h: H = undefined;
    try h.boot(fixed.allocator(), large);
    h.deinit(fixed.allocator());
}

test "driver: a whole read cycle allocates nothing after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var h: H = undefined;
    try h.boot(gpa, config_of(4));
    defer h.deinit(gpa);
    failing.fail_index = failing.alloc_index; // Any further allocation fails.
    const allocations = failing.alloc_index;

    try h.lead();
    try h.read(5);
    try h.beat();
    try h.answer(2);
    try h.expect_done(&.{done(5, 1, .ready)});
    try h.receive(&fx.heartbeat(2, 1, @intFromEnum(h.status().term) + 1));

    try testing.expectEqual(allocations, failing.alloc_index);
}
