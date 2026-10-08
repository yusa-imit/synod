//! Tests for the election in `Node` (plan 003 item 2A-ii, ADR-007): the tick that starts a
//! campaign, the vote a node casts, the votes a candidate counts, and becoming leader.
//!
//! The expected values come from the Raft thesis (§3.4 elections, §5.4.1 up-to-date log, §5.4.2
//! the new leader's empty entry) and the ADR-007 effect order, never from `node.zig`. Every
//! step is followed by `check_invariants()` and an effect-order check (`recv`, `tick`); every
//! vote that leaves the node is preceded by its `save_hard_state` in the same view. PreVote is
//! out of scope: `pre_vote` messages stay ignored.
//!
//! Timing is pinned with a forced `Rng` word: `0` gives the timeout `t = 10`, `maxInt(u64)`
//! gives `2t - 1 = 19`, the two ends of `[t, 2t)`. Streams are reproducible from their seed,
//! which `std.log` reports on failure.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Configuration = types.Configuration;
const Effect = node_module.Effect;
const Effects = node_module.Effects;
const Entry = types.Entry;
const HardState = types.HardState;
const Message = types.Message;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const config = fixtures.config;
const config5 = fixtures.config5;
const base_entries = fixtures.base_entries;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

const low: u64 = 0; // timeout t = 10
const high: u64 = std.math.maxInt(u64); // timeout 2t - 1 = 19

/// Fresh node: term 0, empty log, voters {1, 2, 3}.
const fresh = fixtures.restore_of(.empty, &.{});
/// Term 3, no vote, log terms 1, 2, 3 (last position (3, 3)), commit 0.
const logged = fixtures.restore_of(fixtures.hard_state_of(3, 0, 0), &base_entries);
/// As `logged`, but already voted for node 2 in term 3.
const voted = fixtures.restore_of(fixtures.hard_state_of(3, 2, 0), &base_entries);
const logged5 = fixtures.restore_with(
    fixtures.configuration5,
    fixtures.hard_state_of(3, 0, 0),
    &base_entries,
);

const Position = struct { index: u64, term: u64 };
const Want = struct { role: Role, term: u64, vote: u64, leader: u64 = 0 };

fn expect_status(rig: *const Rig, want: Want) !void {
    const status = rig.node.status();
    try testing.expectEqual(want.role, status.role);
    try testing.expectEqual(term(want.term), status.term);
    try testing.expectEqual(node_id(want.vote), status.vote);
    try testing.expectEqual(node_id(want.leader), status.leader);
}

fn tick(rig: *Rig) !Effects {
    const effects = try rig.node.step(.tick);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

fn ticks_quiet(rig: *Rig, count: u32) !void {
    for (0..count) |_| try testing.expectEqual(@as(usize, 0), (try tick(rig)).items.len);
}

fn recv(rig: *Rig, message: Message) !Effects {
    const effects = try rig.receive(&message);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

/// Ticks a follower (forced `low`, timer at zero) up to and including its election tick.
fn campaign(rig: *Rig) !Effects {
    try ticks_quiet(rig, rig.node.config.election_ticks - 1);
    return tick(rig);
}

fn expect_quiet(effects: Effects) !void {
    try testing.expectEqual(@as(usize, 0), effects.items.len);
}

/// The campaign: `save_hard_state{new_term, vote 1}` first, then one `request_vote` to each of
/// `targets` and to nobody else, all stamped with this node's identity and log tail.
fn expect_election(effects: Effects, new_term: u64, last: Position, targets: []const u64) !void {
    try testing.expectEqual(1 + targets.len, effects.items.len);
    try testing.expect(effects.items[0] == .save_hard_state);
    const first = effects.items[0].save_hard_state;
    try testing.expectEqual(fixtures.hard_state_of(new_term, 1, 0), first);
    var seen = [_]u32{0} ** 8;
    for (effects.items[1..]) |effect| {
        const request = switch (effect) {
            .send => |message| switch (message) {
                .request_vote => |payload| payload,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(node_id(1), request.header.from);
        try testing.expectEqual(term(new_term), request.header.term);
        try testing.expectEqual(config.protocol_version, request.header.protocol_version);
        try testing.expectEqual(idx(last.index), request.last_log_index);
        try testing.expectEqual(term(last.term), request.last_log_term);
        seen[@intFromEnum(request.header.to)] += 1;
    }
    for (targets) |target| try testing.expectEqual(@as(u32, 1), seen[target]);
}

/// Exactly one `request_vote_response` send, to `to`, at `term_value`, with `granted`.
fn expect_reply(effects: Effects, to: u64, term_value: u64, granted: bool) !void {
    var replies: u32 = 0;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .request_vote_response => |reply| {
                replies += 1;
                try testing.expectEqual(node_id(to), reply.header.to);
                try testing.expectEqual(node_id(1), reply.header.from);
                try testing.expectEqual(term(term_value), reply.header.term);
                try testing.expectEqual(config.protocol_version, reply.header.protocol_version);
                try testing.expectEqual(granted, reply.granted);
            },
            else => return error.TestUnexpectedResult,
        },
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), replies);
}

/// A reply and nothing durable: no hard state, log or apply effect.
fn expect_reply_only(effects: Effects, to: u64, term_value: u64, granted: bool) !void {
    try expect_reply(effects, to, term_value, granted);
    try testing.expectEqual(@as(usize, 1), effects.items.len);
}

/// The ADR-007 §5.4.2 transition: one empty `.normal` entry at `term_value`, then
/// `leader_changed(self)`; `saves` hard-state writes; no new campaign.
fn expect_leader(
    rig: *Rig,
    effects: Effects,
    term_value: u64,
    previous_last: u64,
    saves: u32,
) !void {
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .append));
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .leader_changed));
    try testing.expectEqual(saves, fixtures.count_effects(effects, .save_hard_state));
    const want = [_]Entry{fixtures.entry(previous_last + 1, term_value, "")};
    var append_at: ?usize = null;
    var changed_at: ?usize = null;
    for (effects.items, 0..) |effect, i| switch (effect) {
        .append => |appended| {
            try fixtures.expect_entries_equal(&want, appended);
            try testing.expectEqual(types.EntryKind.normal, appended[0].kind);
            append_at = i;
        },
        .leader_changed => |leader| {
            try testing.expectEqual(node_id(1), leader);
            changed_at = i;
        },
        .send => |message| try testing.expect(std.meta.activeTag(message) != .request_vote),
        else => {},
    };
    try testing.expect(append_at.? < changed_at.?);
    try expect_status(rig, .{ .role = .leader, .term = term_value, .vote = 1, .leader = 1 });
    try testing.expectEqual(idx(previous_last + 1), rig.node.status().last_index);
    const stored = rig.node.entries();
    try fixtures.expect_entries_equal(&want, stored[stored.len - 1 ..]);
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

/// Node 1, built over `logged` with `low`, campaigned to term 4, then elected by node 2's grant.
fn elect_three(rig: *Rig) !void {
    _ = try campaign(rig);
    const effects = try recv(rig, fixtures.vote_response(2, 1, 4, true));
    try expect_leader(rig, effects, 4, 3, 0);
}

// ---------------------------------------------------------------------------------------
// Starting an election
// ---------------------------------------------------------------------------------------

test "election: below the timeout a tick emits nothing, at it the election starts (both ends)" {
    const bounds = [_]struct { forced: u64, timeout: u32 }{
        .{ .forced = low, .timeout = 10 },
        .{ .forced = high, .timeout = 19 },
    };
    for (bounds) |bound| {
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, &fresh, bound.forced);
        defer rig.deinit(testing.allocator);

        try ticks_quiet(&rig, bound.timeout - 1);
        try expect_status(&rig, .{ .role = .follower, .term = 0, .vote = 0 });
        const effects = try tick(&rig);
        try expect_election(effects, 1, .{ .index = 0, .term = 0 }, &.{ 2, 3 });
        try expect_status(&rig, .{ .role = .candidate, .term = 1, .vote = 1 });
        // One draw at init, exactly one more for the election timer reset.
        try testing.expectEqual(@as(u32, 2), rig.rng.draws);
    }
}

test "election: the request carries the log tail, the persisted vote and the new term" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    const effects = try campaign(&rig);
    try expect_election(effects, 4, .{ .index = 3, .term = 3 }, &.{ 2, 3 });
    try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    try testing.expectEqual(idx(3), rig.node.status().last_index);
}

test "election: a candidate whose timer expires again retries one term higher after a full wait" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    for (2..5) |next_term| {
        try ticks_quiet(&rig, config.election_ticks - 1);
        const effects = try tick(&rig);
        try expect_election(effects, next_term, .{ .index = 0, .term = 0 }, &.{ 2, 3 });
        try expect_status(&rig, .{ .role = .candidate, .term = next_term, .vote = 1 });
    }
    try testing.expectEqual(@as(u32, 5), rig.rng.draws);
}

test "election: a learner or a non-member never campaigns however long it waits" {
    const peers = [_]NodeId{ node_id(2), node_id(3) };
    const only_learner = [_]NodeId{node_id(1)};
    const as_learner: Configuration = .{
        .voters = &peers,
        .voters_outgoing = &.{},
        .learners = &only_learner,
    };
    const as_stranger: Configuration = .{
        .voters = &peers,
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    for ([_]Configuration{ as_learner, as_stranger }) |cluster| {
        const restore = fixtures.restore_with(cluster, .empty, &.{});
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, &restore, low);
        defer rig.deinit(testing.allocator);

        try ticks_quiet(&rig, 100);
        try expect_status(&rig, .{ .role = .follower, .term = 0, .vote = 0 });
    }
}

test "election: a node only in the outgoing set of a joint configuration still campaigns" {
    const incoming = [_]NodeId{ node_id(2), node_id(3), node_id(4) };
    const outgoing = [_]NodeId{ node_id(1), node_id(2), node_id(5) };
    const cluster: Configuration = .{
        .voters = &incoming,
        .voters_outgoing = &outgoing,
        .learners = &.{},
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    const effects = try campaign(&rig);
    // Node 2 is in both sets and is asked once; nobody is asked twice.
    try expect_election(effects, 1, .{ .index = 0, .term = 0 }, &.{ 2, 3, 4, 5 });
}

test "election: a single-voter cluster elects itself in the tick that times out" {
    const alone = [_]NodeId{node_id(1)};
    const learner = [_]NodeId{node_id(4)};
    const clusters = [_]Configuration{
        .{ .voters = &alone, .voters_outgoing = &.{}, .learners = &.{} },
        .{ .voters = &alone, .voters_outgoing = &.{}, .learners = &learner },
    };
    for (clusters) |cluster| {
        const restore = fixtures.restore_with(cluster, .empty, &.{});
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, &restore, low);
        defer rig.deinit(testing.allocator);

        const effects = try campaign(&rig);
        try expect_leader(&rig, effects, 1, 0, 1);
        const saved = try fixtures.only_hard_state(effects);
        try testing.expectEqual(fixtures.hard_state_of(1, 1, 0), saved);
        // Nobody to ask, learners included.
        try testing.expectEqual(@as(u32, 0), count_sends(effects, .request_vote));
    }
}

test "election: a leader does not campaign again however many ticks pass" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    try elect_three(&rig);

    for (0..60) |_| {
        const effects = try tick(&rig);
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
        try testing.expectEqual(@as(u32, 0), count_sends(effects, .request_vote));
        try expect_status(&rig, .{ .role = .leader, .term = 4, .vote = 1, .leader = 1 });
    }
}

// ---------------------------------------------------------------------------------------
// Counting votes and becoming leader
// ---------------------------------------------------------------------------------------

test "election: one grant makes a three-voter candidate leader and a late grant is dropped" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    try elect_three(&rig);

    const before = rig.node.status();
    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 4, true)));
    try testing.expectEqual(before, rig.node.status());
}

test "election: a five-voter candidate needs three votes, its own included" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    const effects = try campaign(&rig);
    try expect_election(effects, 4, .{ .index = 3, .term = 3 }, &.{ 2, 3, 4, 5 });
    try expect_quiet(try recv(&rig, fixtures.vote_response(2, 1, 4, true)));
    try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 4, false)));
    try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    const won = try recv(&rig, fixtures.vote_response(4, 1, 4, true));
    try expect_leader(&rig, won, 4, 3, 0);
}

test "election: a duplicate grant from one voter is counted once" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    for (0..4) |_| {
        try expect_quiet(try recv(&rig, fixtures.vote_response(2, 1, 4, true)));
        try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    }
    const won = try recv(&rig, fixtures.vote_response(5, 1, 4, true));
    try expect_leader(&rig, won, 4, 3, 0);
}

test "election: rejections never elect and the candidate retries one term higher" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    const before = rig.node.status();
    for ([_]u64{ 2, 3, 4, 5 }) |peer| {
        try expect_quiet(try recv(&rig, fixtures.vote_response(peer, 1, 4, false)));
        try testing.expectEqual(before, rig.node.status());
    }
    try ticks_quiet(&rig, config5.election_ticks - 1);
    const effects = try tick(&rig);
    try expect_election(effects, 5, .{ .index = 3, .term = 3 }, &.{ 2, 3, 4, 5 });
}

test "election: grants from a learner or a non-member are not counted" {
    const learner = [_]NodeId{node_id(4)};
    const cluster: Configuration = .{
        .voters = &fixtures.voters,
        .voters_outgoing = &.{},
        .learners = &learner,
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    // Own vote plus either of these would be 2 of 3 if they were wrongly counted.
    for ([_]u64{ 4, 9 }) |outsider| {
        try expect_quiet(try recv(&rig, fixtures.vote_response(outsider, 1, 1, true)));
        try expect_status(&rig, .{ .role = .candidate, .term = 1, .vote = 1 });
    }
    const won = try recv(&rig, fixtures.vote_response(3, 1, 1, true));
    try expect_leader(&rig, won, 1, 0, 0);
}

test "election: a response from an older term is dropped and does not count" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig); // term 4
    try ticks_quiet(&rig, config5.election_ticks - 1);
    _ = try tick(&rig); // term 5
    for ([_]u64{ 2, 3 }) |peer| {
        try expect_quiet(try recv(&rig, fixtures.vote_response(peer, 1, 4, true)));
        try expect_status(&rig, .{ .role = .candidate, .term = 5, .vote = 1 });
    }
    // Own vote plus one current grant is only 2 of 5: the stale grants added nothing.
    try expect_quiet(try recv(&rig, fixtures.vote_response(4, 1, 5, true)));
    try expect_status(&rig, .{ .role = .candidate, .term = 5, .vote = 1 });
    const won = try recv(&rig, fixtures.vote_response(5, 1, 5, true));
    try expect_leader(&rig, won, 5, 3, 0);
}

test "election: a response from a newer term steps the candidate down and is not counted" {
    for ([_]bool{ true, false }) |granted| {
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, &logged, low);
        defer rig.deinit(testing.allocator);

        _ = try campaign(&rig);
        const effects = try recv(&rig, fixtures.vote_response(2, 1, 9, granted));
        const saved = try fixtures.only_hard_state(effects);
        try testing.expectEqual(fixtures.hard_state_of(9, 0, 0), saved);
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .append));
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .leader_changed));
        try expect_status(&rig, .{ .role = .follower, .term = 9, .vote = 0 });
        // Back to a follower: a further same-term grant is not a candidate's business.
        try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 9, true)));
        try expect_status(&rig, .{ .role = .follower, .term = 9, .vote = 0 });
    }
}

test "election: a grant to a follower or after stepping down changes nothing" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 3, true)));
    try expect_status(&rig, .{ .role = .follower, .term = 3, .vote = 2 });
    try testing.expectEqual(idx(3), rig.node.status().last_index);
}

// ---------------------------------------------------------------------------------------
// Casting a vote
// ---------------------------------------------------------------------------------------

test "election: a vote is granted once per term and persisted before the reply" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &fresh, 1);
    defer rig.deinit(testing.allocator);

    const first = try recv(&rig, fixtures.vote_request(2, 1, 1));
    try testing.expectEqual(fixtures.hard_state_of(1, 2, 0), try fixtures.only_hard_state(first));
    try expect_reply(first, 2, 1, true);
    try expect_status(&rig, .{ .role = .follower, .term = 1, .vote = 2 });

    const second = try recv(&rig, fixtures.vote_request(3, 1, 1));
    try expect_reply_only(second, 3, 1, false);
    try expect_status(&rig, .{ .role = .follower, .term = 1, .vote = 2 });
}

test "election: the candidate already voted for is granted again without a second write" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    for (0..3) |_| {
        const effects = try recv(&rig, fixtures.vote_request_at(2, 1, 3, 3, 3));
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
        try expect_reply_only(effects, 2, 3, true);
        try expect_status(&rig, .{ .role = .follower, .term = 3, .vote = 2 });
    }
}

test "election: a higher-term request clears the old vote before the vote is decided" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    // Same term, other candidate: the vote for node 2 stands, nothing is written.
    const same = try recv(&rig, fixtures.vote_request_at(3, 1, 3, 3, 3));
    try expect_reply_only(same, 3, 3, false);
    try expect_status(&rig, .{ .role = .follower, .term = 3, .vote = 2 });
    // Next term, the same other candidate: the old vote is void, the grant is persisted.
    const next = try recv(&rig, fixtures.vote_request_at(3, 1, 4, 3, 3));
    try testing.expectEqual(fixtures.hard_state_of(4, 3, 0), try fixtures.only_hard_state(next));
    try expect_reply(next, 3, 4, true);
    try expect_status(&rig, .{ .role = .follower, .term = 4, .vote = 3 });
}

test "election: a higher-term request with a stale log is refused but the term is adopted" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    const effects = try recv(&rig, fixtures.vote_request_at(3, 1, 6, 1, 1));
    try testing.expectEqual(fixtures.hard_state_of(6, 0, 0), try fixtures.only_hard_state(effects));
    try expect_reply(effects, 3, 6, false);
    try expect_status(&rig, .{ .role = .follower, .term = 6, .vote = 0 });
}

test "election: the up-to-date rule compares last term first, then last index" {
    // The node's log ends at (index 3, term 3); every request is at term 4.
    const Case = struct { index: u64, term: u64, grant: bool };
    const cases = [_]Case{
        .{ .index = 9, .term = 2, .grant = false }, // longer log, older last term
        .{ .index = 2, .term = 3, .grant = false }, // same last term, shorter
        .{ .index = 0, .term = 0, .grant = false }, // empty log
        .{ .index = 3, .term = 3, .grant = true }, // identical
        .{ .index = 4, .term = 3, .grant = true }, // same last term, longer
        .{ .index = 1, .term = 4, .grant = true }, // newer last term, shorter
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, &logged, low);
        defer rig.deinit(testing.allocator);

        const request = fixtures.vote_request_at(2, 1, 4, case.index, case.term);
        const effects = try recv(&rig, request);
        const vote: u64 = if (case.grant) 2 else 0;
        const saved = try fixtures.only_hard_state(effects);
        try testing.expectEqual(fixtures.hard_state_of(4, vote, 0), saved);
        try expect_reply(effects, 2, 4, case.grant);
        try expect_status(&rig, .{ .role = .follower, .term = 4, .vote = vote });
    }
}

test "election: an empty candidate log is granted by an empty voter log" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &fresh, 3);
    defer rig.deinit(testing.allocator);

    const effects = try recv(&rig, fixtures.vote_request_at(3, 1, 1, 0, 0));
    try expect_reply(effects, 3, 1, true);
    try expect_status(&rig, .{ .role = .follower, .term = 1, .vote = 3 });
}

test "election: a same-term refusal for a stale log writes nothing and keeps the vote free" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    const refused = try recv(&rig, fixtures.vote_request_at(2, 1, 3, 2, 3));
    try expect_reply_only(refused, 2, 3, false);
    try expect_status(&rig, .{ .role = .follower, .term = 3, .vote = 0 });
    try testing.expectEqual(@as(u32, 1), rig.rng.draws); // a refusal does not reset the timer
    // The vote was still free: a candidate with an acceptable log gets it, durably.
    const granted = try recv(&rig, fixtures.vote_request_at(3, 1, 3, 3, 3));
    try testing.expectEqual(fixtures.hard_state_of(3, 3, 0), try fixtures.only_hard_state(granted));
    try expect_reply(granted, 3, 3, true);
}

test "election: a granted vote restarts the election timer with one draw, a refusal does not" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    try ticks_quiet(&rig, config.election_ticks - 1);
    const granted = try recv(&rig, fixtures.vote_request_at(2, 1, 3, 3, 3));
    try expect_reply(granted, 2, 3, true);
    try testing.expectEqual(@as(u32, 2), rig.rng.draws);
    // Without the reset the very next tick would fire; with it a full timeout is needed.
    try ticks_quiet(&rig, config.election_ticks - 1);
    const effects = try tick(&rig);
    try expect_election(effects, 4, .{ .index = 3, .term = 3 }, &.{ 2, 3 });
}

test "election: a refused request leaves the election timer running" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    try ticks_quiet(&rig, config.election_ticks - 1);
    const refused = try recv(&rig, fixtures.vote_request_at(3, 1, 3, 3, 3));
    try expect_reply_only(refused, 3, 3, false);
    try testing.expectEqual(@as(u32, 1), rig.rng.draws);
    const effects = try tick(&rig);
    try expect_election(effects, 4, .{ .index = 3, .term = 3 }, &.{ 2, 3 });
}

test "election: a stale-term request from a member is answered with a refusal at our term" {
    const restores = [_]*const Restore{ &voted, &logged };
    for (restores) |restore| {
        var rig: Rig = undefined;
        try rig.init_fixed(testing.allocator, config, restore, low);
        defer rig.deinit(testing.allocator);

        const before = rig.node.status();
        // Even a free vote and an acceptable log do not win a stale term.
        const effects = try recv(&rig, fixtures.vote_request_at(2, 1, 2, 2, 2));
        try expect_reply_only(effects, 2, 3, false);
        try testing.expectEqual(before, rig.node.status());
        const older = try recv(&rig, fixtures.vote_request(3, 1, 1));
        try expect_reply_only(older, 3, 3, false);
        try testing.expectEqual(before, rig.node.status());
    }
}

test "election: a request from a non-member gets no reply and changes no state" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &voted, low);
    defer rig.deinit(testing.allocator);

    const before = rig.node.status();
    for ([_]u64{ 3, 2 }) |stale_or_equal| {
        try expect_quiet(try recv(&rig, fixtures.vote_request_at(9, 1, stale_or_equal, 1, 1)));
        try testing.expectEqual(before, rig.node.status());
    }
    // A higher term from a stranger is not adopted and earns no vote.
    const higher = try recv(&rig, fixtures.vote_request_at(9, 1, 7, 3, 3));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(higher, .save_hard_state));
    for (higher.items) |effect| switch (effect) {
        .send => |message| try testing.expect(!(message == .request_vote_response and
            message.request_vote_response.granted)),
        else => {},
    };
    try testing.expectEqual(before, rig.node.status());
}

test "election: a stranger's message never panics a term-zero node, for every kind" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);

    const before = rig.node.status();
    try expect_quiet(try recv(&rig, fixtures.vote_request_at(9, 1, 1, 0, 0)));
    try expect_quiet(try recv(&rig, fixtures.vote_response(9, 1, 5, true)));
    try expect_quiet(try recv(&rig, fixtures.heartbeat(9, 1, 5)));
    try testing.expectEqual(before, rig.node.status());
    try testing.expectEqual(term(0), rig.node.status().term);
}

test "election: a node at the largest term waits instead of wrapping the term" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);

    const largest: u64 = std.math.maxInt(u64);
    _ = try recv(&rig, fixtures.heartbeat(2, 1, largest));
    try testing.expectEqual(term(largest), rig.node.status().term);
    try ticks_quiet(&rig, 3 * config.election_ticks);
    try testing.expectEqual(term(largest), rig.node.status().term);
    try testing.expectEqual(Role.follower, rig.node.status().role);
}

test "election: a higher-term pre_vote from a member adopts no term and persists nothing" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    const probe: Message = .{ .pre_vote = .{
        .header = fixtures.header_of(2, 1, 9),
        .last_log_index = idx(3),
        .last_log_term = term(3),
    } };
    const before = rig.node.status();
    try expect_quiet(try recv(&rig, probe));
    try testing.expectEqual(before, rig.node.status());
}

test "election: pre_vote messages stay ignored and never consume the vote" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    const probe: Message = .{ .pre_vote = .{
        .header = fixtures.header_of(2, 1, 3),
        .last_log_index = idx(3),
        .last_log_term = term(3),
    } };
    const before = rig.node.status();
    try expect_quiet(try recv(&rig, probe));
    try testing.expectEqual(before, rig.node.status());
    try testing.expectEqual(@as(u32, 1), rig.rng.draws);
}

// ---------------------------------------------------------------------------------------
// Contested terms and role changes
// ---------------------------------------------------------------------------------------

test "election: a split vote elects nobody and the next timeout starts a higher term" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    // Node 2 campaigned in the same term: we hold our own vote, so it is refused.
    const rival = try recv(&rig, fixtures.vote_request_at(2, 1, 4, 3, 3));
    try expect_reply_only(rival, 2, 4, false);
    try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 4, false)));
    try expect_status(&rig, .{ .role = .candidate, .term = 4, .vote = 1 });
    // The refusal did not touch the timer: the retry comes a full timeout after the campaign.
    try ticks_quiet(&rig, config.election_ticks - 1);
    const retry = try tick(&rig);
    try expect_election(retry, 5, .{ .index = 3, .term = 3 }, &.{ 2, 3 });
}

test "election: a leader refuses a same-term vote request and stays leader" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    try elect_three(&rig);

    const effects = try recv(&rig, fixtures.vote_request_at(2, 1, 4, 4, 4));
    try expect_reply_only(effects, 2, 4, false);
    try expect_status(&rig, .{ .role = .leader, .term = 4, .vote = 1, .leader = 1 });
}

test "election: a leader that sees a higher-term candidate steps down and may vote for it" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    try elect_three(&rig);

    // The leader's log ends at (4, 4); the candidate's is equal, so the vote is granted.
    const effects = try recv(&rig, fixtures.vote_request_at(3, 1, 5, 4, 4));
    try testing.expectEqual(fixtures.hard_state_of(5, 3, 0), try fixtures.only_hard_state(effects));
    try expect_reply(effects, 3, 5, true);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .leader_changed));
    for (effects.items) |effect| switch (effect) {
        .leader_changed => |leader| try testing.expectEqual(NodeId.none, leader),
        else => {},
    };
    try expect_status(&rig, .{ .role = .follower, .term = 5, .vote = 3 });
}

// ---------------------------------------------------------------------------------------
// Joint quorums
// ---------------------------------------------------------------------------------------

const joint_incoming = [_]NodeId{ node_id(1), node_id(2), node_id(3) };
const joint_outgoing = [_]NodeId{ node_id(3), node_id(4), node_id(5) };
const joint: Configuration = .{
    .voters = &joint_incoming,
    .voters_outgoing = &joint_outgoing,
    .learners = &.{},
};

test "election: a joint candidate asks every voter of both sets once, learners never" {
    const learner = [_]NodeId{node_id(6)};
    var cluster = joint;
    cluster.learners = &learner;
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    const effects = try campaign(&rig);
    try expect_election(effects, 1, .{ .index = 0, .term = 0 }, &.{ 2, 3, 4, 5 });
}

test "election: a joint candidate needs a majority of the incoming set and of the outgoing set" {
    const restore = fixtures.restore_with(joint, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    // Incoming {1,2,3}: 1 and 2 are a majority already; outgoing {3,4,5} has no vote yet.
    try expect_quiet(try recv(&rig, fixtures.vote_response(2, 1, 1, true)));
    // 3 is in both sets: outgoing now 1 of 3.
    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 1, true)));
    try expect_status(&rig, .{ .role = .candidate, .term = 1, .vote = 1 });
    const won = try recv(&rig, fixtures.vote_response(4, 1, 1, true));
    try expect_leader(&rig, won, 1, 0, 0);
}

test "election: a joint outgoing majority alone is not enough without the incoming one" {
    const restore = fixtures.restore_with(joint, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    // Outgoing {3,4,5}: 4 and 5 are a majority; incoming {1,2,3} has only the candidate.
    try expect_quiet(try recv(&rig, fixtures.vote_response(4, 1, 1, true)));
    try expect_quiet(try recv(&rig, fixtures.vote_response(5, 1, 1, true)));
    try expect_status(&rig, .{ .role = .candidate, .term = 1, .vote = 1 });
    const won = try recv(&rig, fixtures.vote_response(2, 1, 1, true));
    try expect_leader(&rig, won, 1, 0, 0);
}

test "election: the own vote counts only in the sets that contain the candidate" {
    const incoming = [_]NodeId{ node_id(2), node_id(3), node_id(4) };
    const outgoing = [_]NodeId{ node_id(1), node_id(2), node_id(5) };
    const cluster: Configuration = .{
        .voters = &incoming,
        .voters_outgoing = &outgoing,
        .learners = &.{},
    };
    const restore = fixtures.restore_with(cluster, .empty, &.{});
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &restore, low);
    defer rig.deinit(testing.allocator);

    _ = try campaign(&rig);
    // Outgoing {1,2,5}: 1 and 5 are a majority. Incoming {2,3,4}: only 3, so far.
    try expect_quiet(try recv(&rig, fixtures.vote_response(5, 1, 1, true)));
    try expect_quiet(try recv(&rig, fixtures.vote_response(3, 1, 1, true)));
    try expect_status(&rig, .{ .role = .candidate, .term = 1, .vote = 1 });
    const won = try recv(&rig, fixtures.vote_response(4, 1, 1, true));
    try expect_leader(&rig, won, 1, 0, 0);
}

// ---------------------------------------------------------------------------------------
// Model-based stream: five voters, node 1 against a reference of the contract
// ---------------------------------------------------------------------------------------

/// What the reference model says one input must emit (kinds the election owns).
const Expect = struct {
    saves: u32 = 0,
    vote_requests: u32 = 0,
    reply: ?bool = null,
    appends: u32 = 0,
    leader_changed: u32 = 0,
};

const Model = struct {
    term: u64 = 3,
    vote: u64 = 0,
    role: Role = .follower,
    leader: u64 = 0,
    last_index: u64 = 3,
    last_term: u64 = 3,
    saved_term: u64 = 3,
    saved_vote: u64 = 0,
    elapsed: u32 = 0,
    /// Per peer, the response already received this term: 0 none, 1 rejected, 2 granted.
    resp: [6]u8 = [_]u8{0} ** 6,

    fn adopt(model: *Model, new_term: u64, want: *Expect) void {
        model.term = new_term;
        model.vote = 0;
        if (model.role == .leader) want.leader_changed = 1;
        model.role = .follower;
        model.leader = 0;
        model.elapsed = 0;
        model.resp = [_]u8{0} ** 6;
    }

    fn persisted(model: *Model, want: *Expect) void {
        if (model.term == model.saved_term and model.vote == model.saved_vote) return;
        want.saves = 1;
        model.saved_term = model.term;
        model.saved_vote = model.vote;
    }

    fn tick(model: *Model) Expect {
        var want: Expect = .{};
        model.elapsed += 1;
        if (model.role != .leader and model.elapsed >= config.election_ticks) {
            model.term += 1;
            model.vote = 1;
            model.role = .candidate;
            model.elapsed = 0;
            model.resp = [_]u8{0} ** 6;
            want.vote_requests = 4;
        }
        model.persisted(&want);
        return want;
    }

    fn request(model: *Model, from: u64, request_term: u64, last: Position) Expect {
        var want: Expect = .{};
        if (request_term > model.term) model.adopt(request_term, &want);
        if (request_term < model.term) {
            want.reply = false;
        } else {
            const newer = last.term > model.last_term;
            const longer = last.term == model.last_term and last.index >= model.last_index;
            const free = model.vote == 0 or model.vote == from;
            const grant = free and (newer or longer);
            if (grant) {
                model.vote = from;
                model.elapsed = 0;
            }
            want.reply = grant;
        }
        model.persisted(&want);
        return want;
    }

    fn response(model: *Model, from: u64, response_term: u64, granted: bool) Expect {
        var want: Expect = .{};
        if (from == 9) return want; // a stranger: ignored at every term
        if (response_term > model.term) model.adopt(response_term, &want);
        if (response_term == model.term and model.role == .candidate) {
            model.resp[from] = if (granted) 2 else 1;
            var votes: u32 = 1;
            for (model.resp) |kind| votes += @intFromBool(kind == 2);
            if (votes >= 3) {
                model.role = .leader;
                model.leader = 1;
                model.last_index += 1;
                model.last_term = model.term;
                want.appends = 1;
                want.leader_changed = 1;
            }
        }
        model.persisted(&want);
        return want;
    }
};

fn expect_matches(model: *const Model, rig: *Rig, effects: Effects, want: Expect) !void {
    try testing.expectEqual(want.saves, fixtures.count_effects(effects, .save_hard_state));
    try testing.expectEqual(want.appends, fixtures.count_effects(effects, .append));
    try testing.expectEqual(want.leader_changed, fixtures.count_effects(effects, .leader_changed));
    try testing.expectEqual(want.vote_requests, count_sends(effects, .request_vote));
    const replies: u32 = if (want.reply == null) 0 else 1;
    try testing.expectEqual(replies, count_sends(effects, .request_vote_response));
    if (want.reply) |granted| {
        for (effects.items) |effect| switch (effect) {
            .send => |message| if (message == .request_vote_response) {
                try testing.expectEqual(granted, message.request_vote_response.granted);
                try testing.expectEqual(term(model.term), message.header().term);
            },
            else => {},
        };
    }
    const status = rig.node.status();
    try testing.expectEqual(model.role, status.role);
    try testing.expectEqual(term(model.term), status.term);
    try testing.expectEqual(node_id(model.vote), status.vote);
    try testing.expectEqual(node_id(model.leader), status.leader);
    try testing.expectEqual(idx(model.last_index), status.last_index);
}

/// A voter 2..5, or the stranger 9 one time in twelve.
fn draw_peer(random: std.Random) u64 {
    if (random.uintLessThan(u32, 12) == 0) return 9;
    return random.intRangeAtMost(u64, 2, 5);
}

fn draw_term(random: std.Random, model: *const Model) u64 {
    return switch (random.uintLessThan(u32, 6)) {
        0 => random.intRangeAtMost(u64, 1, model.term),
        1 => model.term + 1,
        else => model.term,
    };
}

fn draw_position(random: std.Random, model: *const Model, request_term: u64) Position {
    if (model.last_term <= request_term and random.uintLessThan(u32, 3) == 0) {
        return .{ .index = model.last_index, .term = model.last_term };
    }
    const log_term = random.intRangeAtMost(u64, 0, @min(request_term, model.last_term + 1));
    if (log_term == 0) return .{ .index = 0, .term = 0 };
    return .{ .index = random.intRangeAtMost(u64, 1, model.last_index + 2), .term = log_term };
}

fn stream_step(rig: *Rig, model: *Model, random: std.Random) !void {
    const roll = random.uintLessThan(u32, 10);
    if (roll < 3 and model.role != .leader) {
        const want = model.tick();
        try expect_matches(model, rig, try tick(rig), want);
    } else if (roll < 6) {
        const from = draw_peer(random);
        var request_term = draw_term(random, model);
        if (from == 9) request_term = @min(request_term, model.term);
        const last = draw_position(random, model, request_term);
        const message = fixtures.vote_request_at(from, 1, request_term, last.index, last.term);
        var want: Expect = .{};
        if (from != 9) want = model.request(from, request_term, last);
        try expect_matches(model, rig, try recv(rig, message), want);
    } else {
        const from = draw_peer(random);
        const response_term = draw_term(random, model);
        var granted = random.boolean();
        if (from != 9 and response_term == model.term and model.resp[from] != 0) {
            granted = model.resp[from] == 2; // a repeat is an exact duplicate
        }
        const message = fixtures.vote_response(from, 1, response_term, granted);
        const want = model.response(from, response_term, granted);
        try expect_matches(model, rig, try recv(rig, message), want);
    }
}

fn stream_run(seed: u64, steps: u32) !void {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config5, &logged5, low);
    defer rig.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(seed);
    var model: Model = .{};
    for (0..steps) |step_number| {
        errdefer std.log.err("election stream failed: seed={d} step={d}", .{ seed, step_number });
        try stream_step(&rig, &model, prng.random());
    }
}

test "election: seeded streams of ticks, requests and responses match the reference model" {
    for (0..6) |seed| try stream_run(seed, 300);
}

// ---------------------------------------------------------------------------------------
// Fuzz: the one-vote-per-term safety property
// ---------------------------------------------------------------------------------------

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &fresh, smith.value(u64));
    defer rig.deinit(testing.allocator);

    var saved: HardState = .empty;
    for (0..96) |_| {
        if (smith.eos()) break;
        const from = smith.valueRangeAtMost(u64, 0, 4);
        const message_term = smith.valueRangeAtMost(u64, 0, 6);
        const message = if (smith.value(bool))
            fixtures.vote_request(from, 1, message_term)
        else
            fixtures.vote_response(from, 1, message_term, smith.value(bool));
        const input: node_module.Input = switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => .tick,
            else => .{ .message = &message },
        };
        const effects = rig.node.step(input) catch continue;
        try fixtures.expect_effects_ordered(effects, config);
        for (effects.items) |effect| switch (effect) {
            .save_hard_state => |next| {
                try testing.expect(next.term.order(saved.term) != .lt);
                if (next.term == saved.term and saved.vote != .none) {
                    try testing.expectEqual(saved.vote, next.vote);
                }
                saved = next;
            },
            .send => |sent| if (sent == .request_vote_response and
                sent.request_vote_response.granted)
            {
                const status = rig.node.status();
                try testing.expectEqual(status.term, sent.header().term);
                try testing.expectEqual(status.vote, sent.header().to);
                // The grant is durable in this view or an earlier one.
                try testing.expectEqual(saved.vote, sent.header().to);
                try testing.expectEqual(saved.term, status.term);
            },
            else => {},
        };
        try rig.node.check_invariants();
    }
}

test "election: fuzzed inputs never vote twice in one term and never grant unpersisted" {
    try testing.fuzz({}, fuzz_one, .{});
}
