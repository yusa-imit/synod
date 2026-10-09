//! Tests for PreVote in `Node` (plan 003 item 2A-iii, Raft thesis 9.6): the round an election
//! timeout starts, the `pre_vote` a node answers, and the `pre_vote_response` it counts.
//!
//! The expected values come from the thesis and the contract of plan 003, never from `node.zig`:
//! a pre-vote never adopts a term, never persists, never changes the vote or resets the timer;
//! a grant needs a higher would-be term, an up-to-date log, no leader of our own and no recent
//! word from one. Every step is followed by `check_invariants()`, an effect-order check and the
//! rule `role == pre_candidate` implies `leader == none`.
//!
//! Timing is pinned with a forced `Rng` word: `low` gives the timeout `t = 10`, `high` gives
//! `2t - 1 = 19`, the two ends of `[t, 2t)`.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Configuration = types.Configuration;
const Effects = node_module.Effects;
const Message = types.Message;
const NodeId = types.NodeId;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const config = fixtures.config;
const config5 = fixtures.config5;
const node_id = fixtures.node_id;
const term = fixtures.term;

const low: u64 = 0; // timeout t = 10
const high: u64 = std.math.maxInt(u64); // timeout 2t - 1 = 19

/// Term 3, no vote, log terms 1, 2, 3 (last position (3, 3)), commit 0.
const logged = fixtures.restore_of(fixtures.hard_state_of(3, 0, 0), &fixtures.base_entries);
/// As `logged`, but already voted for node 2 in term 3.
const voted = fixtures.restore_of(fixtures.hard_state_of(3, 2, 0), &fixtures.base_entries);
const logged5 = fixtures.restore_with(
    fixtures.configuration5,
    fixtures.hard_state_of(3, 0, 0),
    &fixtures.base_entries,
);

fn init(rig: *Rig, restore: *const node_module.Restore, forced: u64) !void {
    try rig.init_fixed(testing.allocator, config, restore, forced);
}

fn check(rig: *Rig, effects: Effects) !void {
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    if (rig.node.status().role == .pre_candidate) {
        try testing.expectEqual(NodeId.none, rig.node.status().leader);
    }
}

fn tick(rig: *Rig) !Effects {
    const effects = try rig.node.step(.tick);
    try check(rig, effects);
    return effects;
}

fn ticks_quiet(rig: *Rig, count: u32) !void {
    for (0..count) |_| try expect_quiet(try tick(rig));
}

fn recv(rig: *Rig, message: Message) !Effects {
    const effects = try rig.receive(&message);
    try check(rig, effects);
    return effects;
}

fn expect_quiet(effects: Effects) !void {
    try testing.expectEqual(@as(usize, 0), effects.items.len);
}

fn expect_state(rig: *const Rig, role: Role, term_value: u64, vote: u64, leader: u64) !void {
    const status = rig.node.status();
    try testing.expectEqual(role, status.role);
    try testing.expectEqual(term(term_value), status.term);
    try testing.expectEqual(node_id(vote), status.vote);
    try testing.expectEqual(node_id(leader), status.leader);
}

fn count_sends(effects: Effects, kind: std.meta.Tag(Message)) u32 {
    var total: u32 = 0;
    for (effects.items) |effect| switch (effect) {
        .send => |message| if (std.meta.activeTag(message) == kind) {
            total += 1;
        },
        else => {},
    };
    return total;
}

/// The real campaign: `save_hard_state{new_term, vote 1}` first, then `peers` `request_vote`s.
fn expect_campaign(effects: Effects, new_term: u64, peers: u32) !void {
    try testing.expectEqual(1 + peers, effects.items.len);
    try testing.expect(effects.items[0] == .save_hard_state);
    const saved = effects.items[0].save_hard_state;
    try testing.expectEqual(fixtures.hard_state_of(new_term, 1, 0), saved);
    try testing.expectEqual(peers, count_sends(effects, .request_vote));
    for (effects.items[1..]) |effect| {
        try testing.expectEqual(term(new_term), effect.send.header().term);
    }
}

/// Ticks to the election tick of a follower with timeout 10 and checks it is a bare pre-vote.
fn start_pre_vote(rig: *Rig, last: [2]u64, targets: []const u64) !void {
    try ticks_quiet(rig, rig.node.config.election_ticks - 1);
    const would_be = @intFromEnum(rig.node.status().term) + 1;
    try fixtures.expect_pre_vote(try tick(rig), would_be, last[0], last[1], targets, false);
}

// ---------------------------------------------------------------------------------------
// Starting a pre-vote
// ---------------------------------------------------------------------------------------

test "prevote: an election timeout asks for pre-votes and changes neither term, vote nor storage" {
    var rig: Rig = undefined;
    try init(&rig, &voted, low);
    defer rig.deinit(testing.allocator);

    try ticks_quiet(&rig, config.election_ticks - 1);
    try testing.expectEqual(config.election_ticks - 1, rig.node.election_elapsed);
    const effects = try tick(&rig);
    // No save_hard_state is part of the check: a pre-vote is not durable.
    try fixtures.expect_pre_vote(effects, 4, 3, 3, &.{ 2, 3 }, false);
    try expect_state(&rig, .pre_candidate, 3, 2, 0);
    try testing.expectEqual(@as(u32, 0), rig.node.election_elapsed);
    // One draw at init, exactly one more for the election timer reset.
    try testing.expectEqual(@as(u32, 2), rig.rng.draws);
}

test "prevote: a follower that knew a leader forgets it after the sends" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    _ = try recv(&rig, fixtures.heartbeat(2, 1, 3));
    try expect_state(&rig, .follower, 3, 0, 2);
    try ticks_quiet(&rig, config.election_ticks - 1);
    const effects = try tick(&rig);
    try fixtures.expect_pre_vote(effects, 4, 3, 3, &.{ 2, 3 }, true);
    try expect_state(&rig, .pre_candidate, 3, 0, 0);
}

test "prevote: a joint configuration is asked in both sets once, learners never" {
    const incoming = [_]NodeId{ node_id(2), node_id(3), node_id(4) };
    const outgoing = [_]NodeId{ node_id(1), node_id(2), node_id(5) };
    const learner = [_]NodeId{node_id(6)};
    const cluster: Configuration = .{
        .voters = &incoming,
        .voters_outgoing = &outgoing,
        .learners = &learner,
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &restore, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 0, 0 }, &.{ 2, 3, 4, 5 });
    try expect_state(&rig, .pre_candidate, 0, 0, 0);
}

test "prevote: a pre-candidate whose timer expires again starts a fresh round with a fresh tally" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3, 4, 5 });
    try expect_quiet(try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true)));
    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3, 4, 5 });
    try expect_state(&rig, .pre_candidate, 3, 0, 0);
    // Node 2's old grant must be forgotten: own vote + 3 would already be a majority of 5.
    try expect_quiet(try recv(&rig, fixtures.pre_vote_response(3, 1, 4, true)));
    try expect_state(&rig, .pre_candidate, 3, 0, 0);
    try expect_campaign(try recv(&rig, fixtures.pre_vote_response(4, 1, 4, true)), 4, 4);
    try testing.expectEqual(@as(u32, 4), rig.rng.draws); // init, two rounds, the campaign
}

test "prevote: a candidate whose timer expires campaigns directly in the next term" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    try expect_campaign(try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true)), 4, 2);
    try expect_state(&rig, .candidate, 4, 1, 0);
    try ticks_quiet(&rig, config.election_ticks - 1);
    const effects = try tick(&rig);
    try expect_campaign(effects, 5, 2);
    try testing.expectEqual(@as(u32, 0), count_sends(effects, .pre_vote));
    try expect_state(&rig, .candidate, 5, 1, 0);
}

// ---------------------------------------------------------------------------------------
// Answering a pre_vote
// ---------------------------------------------------------------------------------------

test "prevote: a grant is addressed to the sender at the would-be term and changes nothing" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    try ticks_quiet(&rig, 5);
    const before = rig.node.status();
    const effects = try recv(&rig, fixtures.pre_vote_at(2, 1, 4, 3, 3));
    try fixtures.expect_pre_vote_reply(effects, 2, 4, true);
    try testing.expectEqual(before, rig.node.status());
    try testing.expectEqual(@as(u32, 5), rig.node.election_elapsed); // timer not reset
    try testing.expectEqual(@as(u32, 1), rig.rng.draws);
}

test "prevote: a stale term, an equal term, or a stale log is refused at our own term" {
    const Case = struct { term: u64, last_index: u64, last_term: u64 };
    const cases = [_]Case{
        .{ .term = 2, .last_index = 9, .last_term = 2 }, // older term
        .{ .term = 3, .last_index = 9, .last_term = 3 }, // equal term
        .{ .term = 4, .last_index = 9, .last_term = 2 }, // lower last term, longer log
        .{ .term = 4, .last_index = 2, .last_term = 3 }, // same last term, shorter log
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try init(&rig, &logged, low);
        defer rig.deinit(testing.allocator);

        const before = rig.node.status();
        const message = fixtures.pre_vote_at(2, 1, case.term, case.last_index, case.last_term);
        try fixtures.expect_pre_vote_reply(try recv(&rig, message), 2, 3, false);
        try testing.expectEqual(before, rig.node.status());
    }
}

test "prevote: a pre_vote from a non-member or a learner gets no reply" {
    const learner = [_]NodeId{node_id(4)};
    const cluster: Configuration = .{
        .voters = &fixtures.voters,
        .voters_outgoing = &.{},
        .learners = &learner,
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try init(&rig, &restore, low);
    defer rig.deinit(testing.allocator);

    const before = rig.node.status();
    for ([_]u64{ 9, 4 }) |stranger| {
        try expect_quiet(try recv(&rig, fixtures.pre_vote_at(stranger, 1, 7, 0, 0)));
    }
    try testing.expectEqual(before, rig.node.status());
}

test "prevote: granting never consumes the real vote, for one candidate or two" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    for ([_]u64{ 2, 3, 2 }) |candidate| {
        const effects = try recv(&rig, fixtures.pre_vote_at(candidate, 1, 4, 3, 3));
        try fixtures.expect_pre_vote_reply(effects, candidate, 4, true);
        try expect_state(&rig, .follower, 3, 0, 0);
    }
    const effects = try recv(&rig, fixtures.vote_request_at(3, 1, 4, 3, 3));
    try testing.expectEqual(fixtures.hard_state_of(4, 3, 0), try fixtures.only_hard_state(effects));
    try testing.expectEqual(@as(u32, 1), count_sends(effects, .request_vote_response));
    try expect_state(&rig, .follower, 4, 3, 0);
}

test "prevote: a follower with a live leader refuses, one whose leader went silent grants" {
    var rig: Rig = undefined;
    try init(&rig, &logged, high);
    defer rig.deinit(testing.allocator);

    _ = try recv(&rig, fixtures.heartbeat(2, 1, 3));
    try ticks_quiet(&rig, config.election_ticks - 1);
    const refused = try recv(&rig, fixtures.pre_vote_at(3, 1, 4, 3, 3));
    try fixtures.expect_pre_vote_reply(refused, 3, 3, false);
    try expect_state(&rig, .follower, 3, 0, 2); // the leader is kept, the term unchanged
    try expect_quiet(try tick(&rig)); // elapsed == election_ticks: the leader's lease is over
    const granted = try recv(&rig, fixtures.pre_vote_at(3, 1, 4, 3, 3));
    try fixtures.expect_pre_vote_reply(granted, 3, 4, true);
    try expect_state(&rig, .follower, 3, 0, 2); // still no state change on a grant
}

test "prevote: a leader refuses every pre_vote however high the term" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true));
    _ = try recv(&rig, fixtures.vote_response(2, 1, 4, true));
    try expect_state(&rig, .leader, 4, 1, 1);
    const effects = try recv(&rig, fixtures.pre_vote_at(3, 1, 9, 4, 4));
    try fixtures.expect_pre_vote_reply(effects, 3, 4, false);
    try expect_state(&rig, .leader, 4, 1, 1);
}

test "prevote: a leader long past election_ticks still refuses a pre_vote" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true));
    _ = try recv(&rig, fixtures.vote_response(2, 1, 4, true));
    try ticks_quiet(&rig, 3 * config.election_ticks);
    const effects = try recv(&rig, fixtures.pre_vote_at(3, 1, 5, 4, 4));
    try fixtures.expect_pre_vote_reply(effects, 3, 4, false);
    try expect_state(&rig, .leader, 4, 1, 1);
}

test "prevote: a learner's append_entries does not name a leader" {
    const learner = [_]NodeId{node_id(4)};
    const cluster: Configuration = .{
        .voters = &fixtures.voters,
        .voters_outgoing = &.{},
        .learners = &learner,
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try init(&rig, &restore, low);
    defer rig.deinit(testing.allocator);

    _ = try recv(&rig, fixtures.heartbeat(4, 1, 1)); // Term rules only.
    try expect_state(&rig, .follower, 1, 0, 0);
}

test "prevote: a second voter's append_entries cannot replace the leader of a term" {
    var rig: Rig = undefined;
    try init(&rig, &logged, high);
    defer rig.deinit(testing.allocator);

    _ = try recv(&rig, fixtures.heartbeat(2, 1, 3));
    try expect_state(&rig, .follower, 3, 0, 2);
    try expect_quiet(try recv(&rig, fixtures.heartbeat(3, 1, 3)));
    try expect_state(&rig, .follower, 3, 0, 2);
}

// ---------------------------------------------------------------------------------------
// Counting pre_vote_response
// ---------------------------------------------------------------------------------------

test "prevote: a duplicate or non-voter grant is not counted, then a real quorum campaigns" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3, 4, 5 });
    for ([_]u64{ 2, 2, 9, 8 }) |sender| {
        try expect_quiet(try recv(&rig, fixtures.pre_vote_response(sender, 1, 4, true)));
        try expect_state(&rig, .pre_candidate, 3, 0, 0);
    }
    // Save first, then the requests: own vote + 2 + 3 = 3 of 5.
    try expect_campaign(try recv(&rig, fixtures.pre_vote_response(3, 1, 4, true)), 4, 4);
    try expect_state(&rig, .candidate, 4, 1, 0);
}

test "prevote: a joint quorum needs a majority of the incoming and of the outgoing set" {
    const incoming = [_]NodeId{ node_id(2), node_id(3), node_id(4) };
    const outgoing = [_]NodeId{ node_id(1), node_id(2), node_id(5) };
    const cluster: Configuration = .{
        .voters = &incoming,
        .voters_outgoing = &outgoing,
        .learners = &.{},
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &restore, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 0, 0 }, &.{ 2, 3, 4, 5 });
    // 3 and 4 are an incoming majority, but the outgoing set has only our own vote.
    for ([_]u64{ 3, 4 }) |sender| {
        try expect_quiet(try recv(&rig, fixtures.pre_vote_response(sender, 1, 1, true)));
        try expect_state(&rig, .pre_candidate, 0, 0, 0);
    }
    try expect_campaign(try recv(&rig, fixtures.pre_vote_response(5, 1, 1, true)), 1, 4);
    try expect_state(&rig, .candidate, 1, 1, 0);
}

test "prevote: a mis-termed grant, a stale refusal, a stranger or a wrong role is ignored" {
    const Case = struct { from: u64, term: u64, granted: bool };
    const cases = [_]Case{
        .{ .from = 2, .term = 3, .granted = true }, // not the would-be term
        .{ .from = 2, .term = 5, .granted = true }, // too far ahead to be our round
        .{ .from = 2, .term = 3, .granted = false }, // refusal at our term
        .{ .from = 2, .term = 2, .granted = false }, // refusal from the past
        .{ .from = 9, .term = 4, .granted = true }, // non-member
        .{ .from = 9, .term = 8, .granted = false }, // non-member, higher term: no adoption
    };
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    // Not a pre-candidate yet: even a well-formed grant or a higher-term refusal is dropped.
    try expect_quiet(try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true)));
    try expect_quiet(try recv(&rig, fixtures.pre_vote_response(2, 1, 9, false)));
    try expect_state(&rig, .follower, 3, 0, 0);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    for (cases) |case| {
        const message = fixtures.pre_vote_response(case.from, 1, case.term, case.granted);
        try expect_quiet(try recv(&rig, message));
        try expect_state(&rig, .pre_candidate, 3, 0, 0);
    }
}

test "prevote: a refusal from a member that is ahead adopts its term and clears the vote" {
    var rig: Rig = undefined;
    try init(&rig, &voted, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    const effects = try recv(&rig, fixtures.pre_vote_response(3, 1, 7, false));
    try testing.expectEqual(fixtures.hard_state_of(7, 0, 0), try fixtures.only_hard_state(effects));
    try testing.expectEqual(@as(usize, 1), effects.items.len);
    try expect_state(&rig, .follower, 7, 0, 0);
}

test "prevote: a pre-candidate follows the normal term rules for a real request_vote" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    try start_pre_vote(&rig, .{ 3, 3 }, &.{ 2, 3 });
    // Same term, free vote, up-to-date log: granted and persisted before the reply.
    const same = try recv(&rig, fixtures.vote_request_at(3, 1, 3, 3, 3));
    try testing.expectEqual(fixtures.hard_state_of(3, 3, 0), try fixtures.only_hard_state(same));
    try testing.expectEqual(@as(u32, 1), count_sends(same, .request_vote_response));
    // A higher term wins over the pre-vote round: adopt, become follower.
    const higher = try recv(&rig, fixtures.vote_request_at(2, 1, 5, 3, 3));
    try testing.expectEqual(fixtures.hard_state_of(5, 2, 0), try fixtures.only_hard_state(higher));
    try expect_state(&rig, .follower, 5, 2, 0);
}

// ---------------------------------------------------------------------------------------
// The point of PreVote
// ---------------------------------------------------------------------------------------

test "prevote: an isolated node never inflates its term, and rejoins at the cluster term" {
    var rig: Rig = undefined;
    try init(&rig, &voted, low);
    defer rig.deinit(testing.allocator);

    var rounds: u32 = 0;
    for (0..100 * config.election_ticks) |_| {
        const effects = try tick(&rig);
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
        rounds += @intFromBool(count_sends(effects, .pre_vote) > 0);
    }
    try testing.expectEqual(@as(u32, 100), rounds);
    try expect_state(&rig, .pre_candidate, 3, 2, 0);
    // The real leader's heartbeat at the cluster term is accepted: nobody had to step down.
    _ = try recv(&rig, fixtures.heartbeat(3, 1, 3));
    try expect_state(&rig, .follower, 3, 2, 3);
}

test "prevote: a pre-candidate is never a leader holder, checked by check_invariants" {
    var rig: Rig = undefined;
    try init(&rig, &logged, low);
    defer rig.deinit(testing.allocator);

    rig.node.role = .pre_candidate;
    rig.node.leader = node_id(2);
    try testing.expectError(error.InvariantLeaderRole, rig.node.check_invariants());
    rig.node.leader = .none;
    try rig.node.check_invariants();
}
