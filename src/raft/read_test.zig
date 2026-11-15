//! Red tests for the ReadIndex state in `read.zig` (plan 005 item 9, ADR-009 "ReadIndex"): the
//! `Storage` sizes, `register`, `ack`, `emit` and `fail_all` called directly on a leader, the
//! `InvariantReadOrder` cases on a deliberately corrupted node, every way a step-down fails the
//! pending reads, a seeded model-based run against a trivial reference model, and the allocation
//! contract (everything at `init`, nothing after).
//!
//! Assumed API that does not exist yet (the red reason): the behavior of `read.register`,
//! `read.ack`, `read.emit`, `read.fail_all` and `read.check_invariants`, which the scaffold
//! leaves as refusals and no-ops. Names assumed: `read.Storage{ pending, out, acked, len }` with
//! `pending[0..len]` as `Pending{ read, round_min }`, `Node.reads`, and ack slots in the order of
//! `Node.peers` (voters, outgoing-only voters, learners).
//!
//! Expected values come from the ADR and arithmetic, never from the implementation. The
//! reference model of the seeded run knows only acks, round minimums and majorities.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const rf = @import("read_fixtures.zig");
const read_module = @import("read.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Effects = node_module.Effects;
const Message = types.Message;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Read = node_module.Read;
const Rig = fixtures.Rig;
const Role = node_module.Role;
const Seen = rf.Seen;
const Storage = read_module.Storage;

const accept = fixtures.accept;
const beat = rf.beat;
const expect_failed = rf.expect_failed;
const expect_no_ready = rf.expect_no_ready;
const expect_ready = rf.expect_ready;
const idx = fixtures.idx;
const read = rf.read;
const step_checked = fixtures.step_checked;
const term_now = rf.term_now;

const cfg = fixtures.config; // reads_max = 4

fn with_reads(max: u32) Config {
    var config = cfg;
    config.reads_max = max;
    return config;
}

/// What `emit` (and `fail_all`) left in the node's effect slots.
fn emitted(node: *const Node) Effects {
    return .{ .items = node.effects[0..node.effects_len] };
}

fn pending(rig: *const Rig) u32 {
    return rig.node.status().reads_pending;
}

// ---- Storage --------------------------------------------------------------------------------

test "read: Storage sizes follow reads_max and the progress slots, and start empty" {
    for ([_]u32{ 1, 4, 8 }) |max| {
        const config = with_reads(max);
        const storage = try Storage.init(testing.allocator, &config);
        defer storage.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, max), storage.pending.len);
        try testing.expectEqual(@as(usize, 2 * max), storage.out.len);
        // One ack slot per peer: 2 * voters_max + learners_max - 1 = 7.
        try testing.expectEqual(@as(usize, 7), storage.acked.len);
        try testing.expectEqual(@as(u32, 0), storage.len);
    }
}

test "read: Storage.init fails cleanly at every allocation and leaks nothing" {
    const config = with_reads(4);
    var failures: u32 = 0;
    for (0..8) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const storage = Storage.init(failing.allocator(), &config) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        storage.deinit(failing.allocator());
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try testing.expect(failures >= 1);
}

// ---- register -------------------------------------------------------------------------------

test "read: register records the context, the commit index and the next round id" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const next_round = rig.node.rounds.id_next;

    try read_module.register(&rig.node, 42);

    try testing.expectEqual(@as(u32, 1), rig.node.reads.len);
    const held = rig.node.reads.pending[0];
    try testing.expectEqual(@as(u64, 42), held.read.ctx);
    try testing.expectEqual(idx(1), held.read.index);
    try testing.expectEqual(next_round, held.round_min);
    try rig.node.check_invariants();
}

test "read: register refuses before it mutates anything" {
    var follower: Rig = undefined;
    try follower.init(testing.allocator, cfg, &rf.fresh3, 1);
    defer follower.deinit(testing.allocator);
    try testing.expectError(error.ReadIndexNotLeader, read_module.register(&follower.node, 1));
    try testing.expectEqual(@as(u32, 0), follower.node.reads.len);

    var fresh: Rig = undefined;
    try fresh.init_fixed(testing.allocator, cfg, &rf.fresh3, 0);
    defer fresh.deinit(testing.allocator);
    _ = try fixtures.elect_checked(&fresh, &.{2}); // Leader, election entry uncommitted.
    try testing.expectError(error.ReadIndexNotReady, read_module.register(&fresh.node, 1));
    try testing.expectEqual(@as(u32, 0), fresh.node.reads.len);

    var one: Rig = undefined;
    try rf.leader3(&one, with_reads(1));
    defer one.deinit(testing.allocator);
    try read_module.register(&one.node, 7);
    try testing.expectError(error.ReadIndexFull, read_module.register(&one.node, 8));
    try testing.expectEqual(@as(u32, 1), one.node.reads.len);
    try testing.expectEqual(@as(u64, 7), one.node.reads.pending[0].read.ctx);
}

// ---- ack and emit ---------------------------------------------------------------------------

test "read: ack raises a slot's acked round and never lowers it" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const other = rig.node.reads.acked[1];

    read_module.ack(&rig.node, 0, 50);
    try testing.expectEqual(@as(u64, 50), rig.node.reads.acked[0]);
    read_module.ack(&rig.node, 0, 40); // An older round echoed late.
    try testing.expectEqual(@as(u64, 50), rig.node.reads.acked[0]);
    read_module.ack(&rig.node, 0, 60);
    try testing.expectEqual(@as(u64, 60), rig.node.reads.acked[0]);
    try testing.expectEqual(other, rig.node.reads.acked[1]); // Per slot.
}

test "read: emit reports the confirmed FIFO prefix and keeps the rest pending" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const first = rig.node.rounds.id_next;
    try read_module.register(&rig.node, 1);
    rig.node.rounds.id_next = first + 2; // Two rounds go out before the second read.
    try read_module.register(&rig.node, 2);

    read_module.ack(&rig.node, 0, first); // Peer 2 acked a round at the first read's minimum.
    rig.node.effects_len = 0;
    read_module.emit(&rig.node);
    try expect_ready(emitted(&rig.node), &.{1}, 1);
    try testing.expectEqual(@as(u32, 1), rig.node.reads.len);

    read_module.ack(&rig.node, 1, first + 2); // Peer 3 acked a round at the second's.
    rig.node.effects_len = 0;
    read_module.emit(&rig.node);
    try expect_ready(emitted(&rig.node), &.{2}, 1);
    try testing.expectEqual(@as(u32, 0), rig.node.reads.len);

    rig.node.effects_len = 0;
    read_module.emit(&rig.node); // Nothing left: nothing emitted.
    try testing.expectEqual(@as(u32, 0), rig.node.effects_len);
}

test "read: emit needs a quorum of voter acks, a minority and a learner give none" {
    var five: Rig = undefined;
    try rf.leader5(&five, fixtures.config5);
    defer five.deinit(testing.allocator);
    const round = five.node.rounds.id_next;
    try read_module.register(&five.node, 1);
    read_module.ack(&five.node, 0, round); // Self and one peer: two of five.
    five.node.effects_len = 0;
    read_module.emit(&five.node);
    try testing.expectEqual(@as(u32, 0), five.node.effects_len);
    try testing.expectEqual(@as(u32, 1), five.node.reads.len);
    read_module.ack(&five.node, 1, round); // Three of five.
    read_module.emit(&five.node);
    try expect_ready(emitted(&five.node), &.{1}, 1);

    const learner = [_]NodeId{fixtures.node_id(4)};
    const restore = fixtures.restore_with(
        fixtures.conf_of(&fixtures.voters, &.{}, &learner),
        .empty,
        &.{},
    );
    var rig: Rig = undefined;
    try rf.leader_from(&rig, cfg, &restore, &.{2}, &.{ 2, 3 });
    defer rig.deinit(testing.allocator);
    const learner_round = rig.node.rounds.id_next;
    try read_module.register(&rig.node, 1);
    read_module.ack(&rig.node, 2, learner_round + 5); // Slot 2 is the learner: no voter acked.
    rig.node.effects_len = 0;
    read_module.emit(&rig.node);
    try testing.expectEqual(@as(u32, 0), rig.node.effects_len);
    try testing.expectEqual(@as(u32, 1), rig.node.reads.len);
}

test "read: fail_all then emit reports every pending read as failed, once and in order" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    for ([_]u64{ 11, 12, 13 }) |ctx| try read_module.register(&rig.node, ctx);

    rig.node.effects_len = 0;
    read_module.fail_all(&rig.node);
    read_module.emit(&rig.node);

    try expect_failed(emitted(&rig.node), &.{ 11, 12, 13 });
    try expect_no_ready(emitted(&rig.node));
    try testing.expectEqual(@as(u32, 0), rig.node.reads.len);
    rig.node.effects_len = 0;
    read_module.fail_all(&rig.node); // Nothing left to fail.
    read_module.emit(&rig.node);
    try testing.expectEqual(@as(u32, 0), rig.node.effects_len);
}

// ---- InvariantReadOrder ---------------------------------------------------------------------

test "read: check_invariants accepts reads of a leader that are ordered and within commit" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    try read_module.register(&rig.node, 1);
    try read_module.register(&rig.node, 2);

    try rig.node.check_invariants();
}

test "read: check_invariants rejects pending reads on a node that does not lead" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &rf.fresh3, 1);
    defer rig.deinit(testing.allocator);
    try rig.node.check_invariants();

    rig.node.reads.len = 1; // Corrupted: a follower holds a read.

    try testing.expectError(error.InvariantReadOrder, rig.node.check_invariants());
}

test "read: check_invariants rejects more pending reads than reads_max" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);

    rig.node.reads.len = cfg.reads_max + 1; // Corrupted: past the storage.

    try testing.expectError(error.InvariantReadOrder, rig.node.check_invariants());
}

test "read: check_invariants rejects a read index above the commit index" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    try read_module.register(&rig.node, 1);

    const commit = @intFromEnum(rig.node.status().commit_index);
    rig.node.reads.pending[0].read.index = idx(commit + 1); // Corrupted.

    try testing.expectError(error.InvariantReadOrder, rig.node.check_invariants());
}

test "read: check_invariants rejects reads whose indexes or round minimums go backwards" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    var seen: Seen = .{};
    seen.absorb(try step_checked(&rig, .{ .propose = "x" }));
    _ = try accept(&rig, try seen.request(2)); // Commit 2.
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try read_module.register(&rig.node, 1);
    try read_module.register(&rig.node, 2);
    try rig.node.check_invariants();

    rig.node.reads.pending[0].read.index = idx(2);
    rig.node.reads.pending[1].read.index = idx(1); // Corrupted: an index goes down.
    try testing.expectError(error.InvariantReadOrder, rig.node.check_invariants());

    rig.node.reads.pending[1].read.index = idx(2); // Healed.
    try rig.node.check_invariants();
    rig.node.reads.pending[0].round_min = rig.node.reads.pending[1].round_min + 1; // Corrupted.
    try testing.expectError(error.InvariantReadOrder, rig.node.check_invariants());
}

// ---- step-down fails every pending read -----------------------------------------------------

fn deposing(rig: *const Rig, which: u32) Message {
    const higher = term_now(rig) + 1;
    return switch (which) {
        0 => fixtures.heartbeat(2, 1, higher),
        1 => fixtures.vote_request(2, 1, higher),
        else => fixtures.append_response(2, 1, higher),
    };
}

fn minority_then_deposed(which: u32) !void {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    try expect_no_ready(try read(&rig, 1));
    try expect_no_ready(try read(&rig, 2));
    for (0..30) |_| { // Partitioned: heartbeats go out, nobody answers.
        const effects = try step_checked(&rig, .tick);
        try expect_no_ready(effects);
        try expect_failed(effects, &.{});
    }
    try testing.expectEqual(@as(u32, 2), pending(&rig));

    const message = deposing(&rig, which);
    const effects = try fixtures.receive_checked(&rig, &message);

    try expect_failed(effects, &.{ 1, 2 });
    try expect_no_ready(effects);
    try rf.expect_after_apply(effects);
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
    try testing.expectError(error.ReadIndexNotLeader, rig.node.step(.{ .read_index = 3 }));
}

test "read: a minority leader never confirms, a higher-term append_entries fails every read" {
    try minority_then_deposed(0);
}

test "read: a minority leader never confirms, a higher-term request_vote fails every read" {
    try minority_then_deposed(1);
}

test "read: a minority leader never confirms, a higher-term response fails every read" {
    try minority_then_deposed(2);
}

test "read: reads of a deposed leader are not resurrected by a later leadership" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    _ = try read(&rig, 1);
    const higher = fixtures.heartbeat(2, 1, term_now(&rig) + 1);
    try expect_failed(try fixtures.receive_checked(&rig, &higher), &.{1});

    const won = try fixtures.elect_checked(&rig, &.{2});
    const to_two = try fixtures.append_to(won, 2);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
    // Commit 1 is of the old term: the new leader is not ready to read until its entry commits.
    try testing.expectError(error.ReadIndexNotReady, rig.node.step(.{ .read_index = 2 }));

    _ = try accept(&rig, to_two);
    const registered = try read(&rig, 2);
    try expect_no_ready(registered);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);
    try expect_ready(try accept(&rig, try seen.request(2)), &.{2}, 2);
}

test "read: a leader removed by a committed leave_joint fails its pending read in that step" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, fixtures.config_conf);
    defer rig.deinit(testing.allocator);
    const ids234 = [_]NodeId{ fixtures.node_id(2), fixtures.node_id(3), fixtures.node_id(4) };
    const target = fixtures.conf_of(&ids234, &.{}, &.{});
    var seen: Seen = .{};
    seen.absorb(try step_checked(&rig, .{ .conf_change = &target }));
    try expect_no_ready(try read(&rig, 5)); // After the rounds above: they cannot confirm it.

    try expect_no_ready(try accept(&rig, try seen.request(2)));
    const entered = try accept(&rig, try seen.request(3)); // enter_joint commits.
    try expect_no_ready(entered);
    try testing.expectEqual(idx(3), rig.node.status().last_index); // leave_joint appended.
    seen.absorb(entered);
    try expect_no_ready(try accept(&rig, try seen.request(2))); // Settled {2,3,4}: one of three.

    const left = try accept(&rig, try seen.request(3)); // leave_joint commits: 1 steps down.

    try expect_failed(left, &.{5});
    try expect_no_ready(left);
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
}

// ---- seeded model-based run -----------------------------------------------------------------

const reads_cap = 3;

/// The reference model: pending reads in order, and the highest round each voter echoed.
const Model = struct {
    ctx: [reads_cap]u64 = undefined,
    index: [reads_cap]u64 = undefined,
    round_min: [reads_cap]u64 = undefined,
    len: u32 = 0,
    acked: [2]u64 = .{ 0, 0 }, // Peers 2 and 3.

    fn ack(model: *Model, peer: u64, round: u64) void {
        model.acked[peer - 2] = @max(model.acked[peer - 2], round);
    }

    /// Reads whose round minimum a voter peer reached: with self, two of three.
    fn ready_count(model: *const Model) u32 {
        var count: u32 = 0;
        while (count < model.len) : (count += 1) {
            const need = model.round_min[count];
            if (model.acked[0] < need and model.acked[1] < need) break;
        }
        return count;
    }

    fn pop(model: *Model, count: u32) void {
        std.debug.assert(count <= model.len);
        for (0..model.len - count) |i| {
            model.ctx[i] = model.ctx[i + count];
            model.index[i] = model.index[i + count];
            model.round_min[i] = model.round_min[i + count];
        }
        model.len -= count;
    }

    fn expect_step(model: *Model, effects: Effects) !void {
        const count = model.ready_count();
        const got = try rf.ready_of(effects);
        try testing.expectEqual(@as(usize, count), got.len);
        for (got, 0..) |done, i| {
            try testing.expectEqual(model.ctx[i], done.ctx);
            try testing.expectEqual(idx(model.index[i]), done.index);
        }
        model.pop(count);
        try expect_failed(effects, &.{});
    }
};

const Run = struct {
    rig: Rig,
    seen: Seen = .{},
    model: Model = .{},
    random: std.Random,
    next_ctx: u64 = 1,

    /// One action chosen by `roll` (0..100); true once the leader was deposed.
    fn act(run: *Run, roll: u32) !bool {
        const rig = &run.rig;
        if (roll >= 97) return run.depose();
        if (roll < 25) return run.finish(try step_checked(rig, .tick));
        if (roll < 45) return run.register();
        if (roll < 60) {
            if (rig.node.status().last_index.order(idx(7)) == .gt) return false;
            return run.finish(try step_checked(rig, .{ .propose = "p" }));
        }
        const peer: u64 = 2 + run.random.uintLessThan(u64, 2);
        if (roll < 85) {
            const request = run.seen.latest[peer] orelse return false;
            run.model.ack(peer, request.round);
            return run.finish(try accept(rig, request));
        }
        const round = 1 + run.random.uintLessThan(u64, rig.node.rounds.id_next - 1);
        run.model.ack(peer, round);
        return run.finish(try rf.reject_at(rig, peer, round));
    }

    fn finish(run: *Run, effects: Effects) !bool {
        run.seen.absorb(effects);
        try run.model.expect_step(effects);
        try testing.expectEqual(run.model.len, run.rig.node.status().reads_pending);
        return false;
    }

    fn register(run: *Run) !bool {
        const node = &run.rig.node;
        const model = &run.model;
        if (model.len == reads_cap) {
            try testing.expectError(error.ReadIndexFull, node.step(.{ .read_index = 0 }));
            return false;
        }
        model.ctx[model.len] = run.next_ctx;
        model.index[model.len] = @intFromEnum(node.status().commit_index);
        model.round_min[model.len] = node.rounds.id_next;
        model.len += 1;
        run.next_ctx += 1;
        return run.finish(try read(&run.rig, run.next_ctx - 1));
    }

    fn depose(run: *Run) !bool {
        const message = fixtures.heartbeat(2, 1, term_now(&run.rig) + 1);
        const effects = try fixtures.receive_checked(&run.rig, &message);
        var want: [reads_cap]u64 = undefined;
        @memcpy(want[0..run.model.len], run.model.ctx[0..run.model.len]);
        try expect_failed(effects, want[0..run.model.len]);
        try expect_no_ready(effects);
        try testing.expectEqual(@as(u32, 0), run.rig.node.status().reads_pending);
        return true;
    }
};

fn run_seed(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    var run: Run = .{ .rig = undefined, .random = prng.random() };
    try rf.leader3(&run.rig, with_reads(reads_cap));
    defer run.rig.deinit(testing.allocator);
    for (0..160) |_| {
        const roll = run.random.uintLessThan(u32, 100);
        if (try run.act(roll)) return;
    }
    try testing.expectEqual(run.model.len, run.rig.node.status().reads_pending);
}

test "read: seeded runs of ticks, reads, proposals and acks agree with the reference model" {
    for (0..24) |seed| try run_seed(seed);
}

// ---- allocation -----------------------------------------------------------------------------

test "read: init_bytes_max grows by the read buffers and a buffer of that size fits init" {
    const small = with_reads(2);
    const large = with_reads(8);
    const growth = Node.init_bytes_max(&large) - Node.init_bytes_max(&small);
    try testing.expect(growth >= 2 * (8 - 2) * @sizeOf(Read)); // 2 * reads_max Reads.

    const memory = try testing.allocator.alloc(u8, Node.init_bytes_max(&large));
    defer testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    var rig: Rig = undefined;
    try rig.init_fixed(fixed.allocator(), large, &rf.fresh3, 0);
    rig.deinit(fixed.allocator());
}

test "read: init fails cleanly at every allocation and leaks nothing" {
    var failures: u32 = 0;
    for (0..32) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var rig: Rig = undefined;
        rig.init_fixed(failing.allocator(), cfg, &rf.fresh3, 0) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        rig.deinit(failing.allocator());
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try testing.expect(failures >= 8); // Node, log and read storage all allocate.
}

test "read: a whole read cycle allocates nothing after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var rig: Rig = undefined;
    try rig.init_fixed(gpa, cfg, &rf.fresh3, 0);
    defer rig.deinit(gpa);
    failing.fail_index = failing.alloc_index; // Any further allocation fails.
    const allocations = failing.alloc_index;

    const won = try fixtures.elect_checked(&rig, &.{2});
    _ = try accept(&rig, try fixtures.append_to(won, 2));
    const registered = try read(&rig, 1);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);
    try expect_ready(try accept(&rig, try seen.request(2)), &.{1}, 1);
    _ = try step_checked(&rig, .{ .propose = "x" });

    try testing.expectEqual(allocations, failing.alloc_index);
}
