//! Red tests for ReadIndex at the node (plan 005 item 9, ADR-009 "ReadIndex"): `Input.read_index`
//! is leader only and refused until the leader committed an entry of its own term; a read records
//! the commit index and the next round id, and is ready once a joint-aware quorum of voters
//! (self included) has acknowledged a round at or after that id; ready reads are a FIFO prefix,
//! emitted after `apply`; `reads_max` bounds the pending reads.
//!
//! Assumed API that does not exist yet (the red reason): the behavior behind `Input.read_index`
//! (the scaffold refuses every read with `ReadIndexFull`), `Effect.read_ready`,
//! `Effect.read_failed` and `Status.reads_pending`. Names assumed: `Input{ .read_index = ctx }`,
//! `node.ReadIndexError`, `Config.reads_max`.
//!
//! Expected values come from the ADR and plain arithmetic (majorities, round ids as the node
//! sent them), never from the node's read bookkeeping. Every step runs through
//! `fixtures.step_checked` (phase order and `check_invariants()`). The step-down, state and
//! model-based cases live in `read_test.zig`; the shared builders in `read_fixtures.zig`.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const rf = @import("read_fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Frozen = fixtures.Frozen;
const Rig = fixtures.Rig;
const Role = node_module.Role;
const Seen = rf.Seen;

const accept = fixtures.accept;
const beat = rf.beat;
const conf_of = fixtures.conf_of;
const expect_after_apply = rf.expect_after_apply;
const expect_no_ready = rf.expect_no_ready;
const expect_ready = rf.expect_ready;
const idx = fixtures.idx;
const read = rf.read;
const reject_at = rf.reject_at;
const step_checked = fixtures.step_checked;
const term_now = rf.term_now;

const cfg = fixtures.config; // reads_max = 4
const none: Effects = .{ .items = &.{} };

fn pending(rig: *const Rig) u32 {
    return rig.node.status().reads_pending;
}

/// A refused read changes nothing: not the status, not the configuration, not the invariants.
fn expect_refused(rig: *Rig, want: anyerror) !void {
    const frozen = Frozen.take(&rig.node);
    try testing.expectError(want, rig.node.step(.{ .read_index = 99 }));
    try frozen.expect_same(&rig.node);
    try rig.node.check_invariants();
}

// ---- who may read ---------------------------------------------------------------------------

test "read_index: a follower refuses with ReadIndexNotLeader and changes nothing" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &rf.fresh3, 1);
    defer rig.deinit(testing.allocator);

    try expect_refused(&rig, error.ReadIndexNotLeader);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
}

test "read_index: a pre-candidate and a candidate refuse with ReadIndexNotLeader" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, cfg, &rf.fresh3, 0);
    defer rig.deinit(testing.allocator);
    for (0..40) |_| {
        if (rig.node.status().role == .pre_candidate) break;
        _ = try step_checked(&rig, .tick);
    }
    try testing.expectEqual(Role.pre_candidate, rig.node.status().role);
    try expect_refused(&rig, error.ReadIndexNotLeader);

    const grant = fixtures.pre_vote_response(2, 1, term_now(&rig) + 1, true);
    _ = try fixtures.receive_checked(&rig, &grant);
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    try expect_refused(&rig, error.ReadIndexNotLeader);
}

test "read_index: a leader deposed by a higher term refuses with ReadIndexNotLeader" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    _ = try read(&rig, 1); // Valid while leading.

    const higher = fixtures.heartbeat(2, 1, term_now(&rig) + 1);
    _ = try fixtures.receive_checked(&rig, &higher);

    try testing.expectEqual(Role.follower, rig.node.status().role);
    try expect_refused(&rig, error.ReadIndexNotLeader);
}

test "read_index: a leader with an uncommitted election entry refuses with ReadIndexNotReady" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, cfg, &rf.fresh3, 0);
    defer rig.deinit(testing.allocator);
    const won = try fixtures.elect_checked(&rig, &.{2});
    const to_two = try fixtures.append_to(won, 2);

    try expect_refused(&rig, error.ReadIndexNotReady);
    try testing.expectEqual(idx(0), rig.node.status().commit_index);

    _ = try accept(&rig, to_two); // The election entry commits.
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
    const registered = try read(&rig, 5);
    try expect_no_ready(registered);
    try testing.expectEqual(@as(u32, 1), pending(&rig));
}

test "read_index: a commit index of an earlier term is not ready, the new term's entry is" {
    const old = [_]Entry{fixtures.entry(1, 1, "")};
    const restore = fixtures.restore_of(fixtures.hard_state_of(1, 0, 1), &old);
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, cfg, &restore, 0);
    defer rig.deinit(testing.allocator);
    const won = try fixtures.elect_checked(&rig, &.{2});
    const to_two = try fixtures.append_to(won, 2);
    try testing.expectEqual(fixtures.term(2), rig.node.status().term);
    try testing.expectEqual(idx(1), rig.node.status().commit_index); // Term 1's entry.

    try expect_refused(&rig, error.ReadIndexNotReady);

    _ = try accept(&rig, to_two);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    _ = try read(&rig, 5);
    try testing.expectEqual(@as(u32, 1), pending(&rig));
}

// ---- when a read is ready -------------------------------------------------------------------

test "read_index: a lone voter is ready in its registering step at the commit index" {
    var rig: Rig = undefined;
    try rf.leader1(&rig, cfg);
    defer rig.deinit(testing.allocator);

    const first = try read(&rig, 77);
    try expect_ready(first, &.{77}, 1);
    try expect_after_apply(first);
    try testing.expectEqual(@as(u32, 0), pending(&rig));

    _ = try step_checked(&rig, .{ .propose = "x" });
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    const second = try read(&rig, 78);
    try expect_ready(second, &.{78}, 2);
}

test "read_index: a read confirms only on a quorum ack of a round sent after it" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);

    const registered = try read(&rig, 10);
    try expect_no_ready(registered);
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    var seen: Seen = .{};
    try beat(&rig, &seen, registered);
    const confirmed = try accept(&rig, try seen.request(2));
    try expect_ready(confirmed, &.{10}, 1);
    try expect_after_apply(confirmed);
    try testing.expectEqual(@as(u32, 0), pending(&rig));

    const again = try accept(&rig, try seen.request(3)); // Reported once, never again.
    try expect_no_ready(again);
}

test "read_index: five voters need two peers, and a repeated ack counts once" {
    var rig: Rig = undefined;
    try rf.leader5(&rig, fixtures.config5);
    defer rig.deinit(testing.allocator);
    const registered = try read(&rig, 10);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);

    try expect_no_ready(try accept(&rig, try seen.request(2))); // Self and 2: two of five.
    try expect_no_ready(try accept(&rig, try seen.request(2))); // The same voter again.
    try expect_no_ready(try reject_at(&rig, 2, try seen.round(2)));
    try expect_ready(try accept(&rig, try seen.request(3)), &.{10}, 1);
}

test "read_index: acks of rounds issued before the read do not count" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const before = rig.node.rounds.id_next; // Every round below this was sent before the read.
    try testing.expect(before >= 3);
    const registered = try read(&rig, 10);

    try expect_no_ready(try reject_at(&rig, 2, before - 1));
    try expect_no_ready(try reject_at(&rig, 3, before - 1));
    try expect_no_ready(try reject_at(&rig, 2, 1));
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    var seen: Seen = .{};
    try beat(&rig, &seen, registered);
    try expect_ready(try accept(&rig, try seen.request(3)), &.{10}, 1);
}

test "read_index: a rejected response at our term counts as an ack" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const registered = try read(&rig, 10);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);

    const confirmed = try reject_at(&rig, 3, try seen.round(3));

    try expect_ready(confirmed, &.{10}, 1);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
}

test "read_index: an ack of the current round from a learner or a stranger does not count" {
    const learner = [_]types.NodeId{fixtures.node_id(4)};
    const restore = fixtures.restore_with(
        conf_of(&fixtures.voters, &.{}, &learner),
        .empty,
        &.{},
    );
    var rig: Rig = undefined;
    try rf.leader_from(&rig, cfg, &restore, &.{2}, &.{ 2, 3 });
    defer rig.deinit(testing.allocator);
    const registered = try read(&rig, 10);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);

    try expect_no_ready(try accept(&rig, try seen.request(4)));
    try expect_no_ready(try reject_at(&rig, 4, try seen.round(4)));
    const stranger = rf.response(9, term_now(&rig), try seen.round(2), rf.rejection);
    try expect_no_ready(try fixtures.receive_checked(&rig, &stranger));
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    try expect_ready(try accept(&rig, try seen.request(2)), &.{10}, 1);
}

test "read_index: responses of a stale term and of a never issued round do not ack" {
    const restore = fixtures.restore_of(fixtures.hard_state_of(1, 0, 0), &.{});
    var rig: Rig = undefined;
    try rf.leader_from(&rig, cfg, &restore, &.{2}, &.{ 2, 3 });
    defer rig.deinit(testing.allocator);
    try testing.expectEqual(fixtures.term(2), rig.node.status().term);
    const registered = try read(&rig, 10);
    var seen: Seen = .{};
    try beat(&rig, &seen, registered);
    const round = try seen.round(2);

    const stale = rf.response(2, 1, round, rf.rejection); // Term 1 < our term 2.
    try expect_no_ready(try fixtures.receive_checked(&rig, &stale));
    // ADR-009 is silent: a round id the leader never issued cannot be an ack of its own.
    const issued = rig.node.rounds.id_next;
    try expect_no_ready(try reject_at(&rig, 2, issued));
    try expect_no_ready(try reject_at(&rig, 2, std.math.maxInt(u64)));
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    try expect_ready(try reject_at(&rig, 2, round), &.{10}, 1);
}

// ---- joint configurations -------------------------------------------------------------------

/// A three-voter leader with `enter_joint` to {1..5} appended (joint, uncommitted), a read
/// registered at commit 1 and a heartbeat round sent to every peer.
fn joint_read(rig: *Rig, seen: *Seen) !void {
    try rf.leader3(rig, fixtures.config_conf);
    errdefer rig.deinit(testing.allocator);
    const target = conf_of(&fixtures.voters5, &.{}, &.{});
    const changed = try step_checked(rig, .{ .conf_change = &target });
    seen.absorb(changed);
    try testing.expectEqual(@as(usize, 3), rig.node.configuration_current().voters_outgoing.len);
    const registered = try read(rig, 10);
    try expect_no_ready(registered);
    try beat(rig, seen, registered);
}

test "read_index: a joint configuration needs both majorities, new voters alone lose" {
    var rig: Rig = undefined;
    var seen: Seen = .{};
    try joint_read(&rig, &seen);
    defer rig.deinit(testing.allocator);

    // Incoming {1..5}: self, 4, 5 are three of five. Outgoing {1,2,3}: self alone is one of three.
    try expect_no_ready(try reject_at(&rig, 4, try seen.round(4)));
    try expect_no_ready(try reject_at(&rig, 5, try seen.round(5)));
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    // Peer 2 completes the outgoing majority (self, 2) and the incoming one stays.
    try expect_ready(try reject_at(&rig, 2, try seen.round(2)), &.{10}, 1);
}

test "read_index: a joint configuration needs both majorities, old voters alone lose" {
    var rig: Rig = undefined;
    var seen: Seen = .{};
    try joint_read(&rig, &seen);
    defer rig.deinit(testing.allocator);

    // Outgoing {1,2,3}: self and 2 are two of three. Incoming {1..5}: two of five.
    try expect_no_ready(try reject_at(&rig, 2, try seen.round(2)));
    try testing.expectEqual(@as(u32, 1), pending(&rig));

    // Self, 2 and 3 are three of five: both majorities hold.
    try expect_ready(try reject_at(&rig, 3, try seen.round(3)), &.{10}, 1);
}

// ---- reads_max ------------------------------------------------------------------------------

fn fill_then_full(max: u32) !void {
    var config = cfg;
    config.reads_max = max;
    var rig: Rig = undefined;
    try rf.leader3(&rig, config);
    defer rig.deinit(testing.allocator);
    for (0..max) |i| try expect_no_ready(try read(&rig, 100 + i));
    try testing.expectEqual(max, pending(&rig));

    try expect_refused(&rig, error.ReadIndexFull); // Read number `max + 1`.
    try testing.expectEqual(max, pending(&rig));

    var seen: Seen = .{};
    try beat(&rig, &seen, none);
    var want: [4]u64 = undefined;
    for (want[0..max], 0..) |*slot, i| slot.* = 100 + i;
    try expect_ready(try accept(&rig, try seen.request(2)), want[0..max], 1);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
    try expect_no_ready(try read(&rig, 999)); // The freed capacity is usable again.
    try testing.expectEqual(@as(u32, 1), pending(&rig));
}

test "read_index: with reads_max 1 the second read is full until the first is ready" {
    try fill_then_full(1);
}

test "read_index: with reads_max 2 the third read is full and ready reads free both slots" {
    try fill_then_full(2);
}

test "read_index: with reads_max 4 the fifth read is full and nothing changes" {
    try fill_then_full(4);
}

// ---- order ----------------------------------------------------------------------------------

test "read_index: reads registered before one round are ready together, in order" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    _ = try read(&rig, 1);
    _ = try read(&rig, 2);
    const third = try read(&rig, 3);
    var seen: Seen = .{};
    try beat(&rig, &seen, third);

    const confirmed = try accept(&rig, try seen.request(2));

    try expect_ready(confirmed, &.{ 1, 2, 3 }, 1);
    try testing.expectEqual(@as(u32, 0), pending(&rig));
}

test "read_index: a read registered after a round waits for a later one, the earlier is ready" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const first = try read(&rig, 1);
    var seen: Seen = .{};
    try beat(&rig, &seen, first);
    const old_request = try seen.request(2); // Sent before the second read registers.
    _ = try read(&rig, 2);
    try testing.expectEqual(@as(u32, 2), pending(&rig));

    const early = try accept(&rig, old_request);

    try expect_ready(early, &.{1}, 1); // The FIFO prefix; read 2 waits for a later round.
    try testing.expectEqual(@as(u32, 1), pending(&rig));
    try beat(&rig, &seen, none);
    try expect_ready(try accept(&rig, try seen.request(3)), &.{2}, 1);
}

test "read_index: a ready read is emitted after apply and its index is applied" {
    var rig: Rig = undefined;
    try rf.leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const registered = try read(&rig, 10); // At commit 1.
    var seen: Seen = .{};
    seen.absorb(registered);
    seen.absorb(try step_checked(&rig, .{ .propose = "x" })); // Index 2, a round after the read.

    const step = try accept(&rig, try seen.request(2)); // Commits 2 and confirms the read.

    try expect_ready(step, &.{10}, 1); // The read keeps the commit index it saw: 1, not 2.
    try expect_after_apply(step);
    const at_apply = fixtures.index_of(step, .apply) orelse return error.TestUnexpectedResult;
    const at_ready = fixtures.index_of(step, .read_ready) orelse return error.TestUnexpectedResult;
    try testing.expect(at_apply < at_ready);
    try testing.expectEqual(idx(2), rig.node.status().applied_index);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
}
