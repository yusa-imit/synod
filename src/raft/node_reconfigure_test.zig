//! Red tests for joint consensus in the node, leader side (plan 005 item 8, ADR-009 "Joint
//! consensus"): `Input.conf_change` is leader only and builds `enter_joint(current, target)`
//! itself; a configuration takes effect when its entry is appended, not committed; the leader
//! proposes `leave_joint` once `enter_joint` commits and steps down when it is not in `voters`;
//! learners replicate but never vote or count; refusals happen before any mutation.
//!
//! Assumed API that does not exist yet (the red reason): the behavior behind `Input.conf_change`
//! (the node returns `ConfChangeNotLeader` for everything), `Status.configuration_index`, and the
//! rebuilt progress slots. Names assumed: `Input{ .conf_change = *const Configuration }`,
//! `node.ConfChangeError`, `Node.configuration_current() Configuration`.
//!
//! Expected values come from the ADR and plain arithmetic (13 + 8 bytes per id, majorities), never
//! from the node. Every step runs through `fixtures.step_checked` (phase order and
//! `check_invariants()`).

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const membership = @import("membership.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Configuration = types.Configuration;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Frozen = fixtures.Frozen;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;
const Trace = fixtures.Trace;

const accept = fixtures.accept;
const accept_each = fixtures.accept_each;
const answer = fixtures.answer;
const append_to = fixtures.append_to;
const conf_of = fixtures.conf_of;
const count_effects = fixtures.count_effects;
const drive = fixtures.drive;
const elect_checked = fixtures.elect_checked;
const expect_configuration = fixtures.expect_configuration;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const step_checked = fixtures.step_checked;

const cfg = fixtures.config_conf;
const fresh3 = fixtures.restore_of(.empty, &.{});
const fresh5 = fixtures.restore_with(fixtures.configuration5, .empty, &.{});
const ids1 = [_]NodeId{node_id(1)};
const ids3 = fixtures.voters;
const ids4 = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4) };
const ids5 = fixtures.voters5;
const ids134 = [_]NodeId{ node_id(1), node_id(3), node_id(4) };
const ids345 = [_]NodeId{ node_id(3), node_id(4), node_id(5) };
const ids6 = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4), node_id(5), node_id(6) };
const learner4 = [_]NodeId{node_id(4)};
const learners67 = [_]NodeId{ node_id(6), node_id(7) };
const learners678 = [_]NodeId{ node_id(6), node_id(7), node_id(8) };
const all_peers = [_]u64{ 2, 3, 4, 5, 6, 7, 8 };

fn start(rig: *Rig, node_config: Config, restore: *const Restore) !void {
    try rig.init_fixed(testing.allocator, node_config, restore, 0); // Timeout t = 10.
}

/// A three-voter leader at term 1 whose election entry (index 1) is committed.
fn leader3(rig: *Rig, node_config: Config) !void {
    try start(rig, node_config, &fresh3);
    const won = try elect_checked(rig, &.{2});
    _ = try accept(rig, try append_to(won, 2));
    // Peer 3's probe is still in flight; answer it so both peers replicate (nothing commits).
    _ = try accept(rig, try append_to(won, 3));
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
}

/// A five-voter leader at term 1 whose election entry (index 1) is committed.
fn leader5(rig: *Rig) !void {
    try start(rig, cfg, &fresh5);
    const won = try elect_checked(rig, &.{ 2, 3 });
    var trace: Trace = .{};
    try answer(rig, won, &.{ 2, 3, 4, 5 }, &trace);
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
}

fn propose_change(rig: *Rig, target: *const Configuration) !Effects {
    return step_checked(rig, .{ .conf_change = target });
}

/// The entries of the one `append` effect.
fn appended(effects: Effects) ![]const Entry {
    try testing.expectEqual(@as(u32, 1), count_effects(effects, .append));
    for (effects.items) |effect| switch (effect) {
        .append => |batch| return batch,
        else => {},
    };
    return error.TestUnexpectedResult;
}

/// The single appended entry is a `conf_change` at `index` and `at_term` that decodes to `want`.
fn expect_conf_append(effects: Effects, index: u64, want: types.ConfChange) !void {
    const batch = try appended(effects);
    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqual(idx(index), batch[0].index);
    var ids: [membership.conf_ids_max]NodeId = undefined;
    const got = try fixtures.decode_conf(batch[0], &ids);
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .enter_joint => |c| try expect_configuration(c, got.enter_joint),
        .leave_joint => |c| try expect_configuration(c, got.leave_joint),
    }
}

fn expect_refused(rig: *Rig, target: *const Configuration, want: anyerror) !void {
    const frozen = Frozen.take(&rig.node);
    const last = rig.node.log.count;
    try testing.expectError(want, rig.node.step(.{ .conf_change = target }));
    try frozen.expect_same(&rig.node);
    try testing.expectEqual(last, rig.node.log.count);
    try rig.node.check_invariants();
}

// ---- grow 3 -> 5 ---------------------------------------------------------------------------

test "reconfigure: growing 3 to 5 appends enter_joint and adopts it at append, not commit" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});

    const effects = try propose_change(&rig, &target);

    try expect_conf_append(effects, 2, .{ .enter_joint = conf_of(&ids5, &ids3, &.{}) });
    try expect_configuration(conf_of(&ids5, &ids3, &.{}), rig.node.configuration_current());
    const status = rig.node.status();
    try testing.expectEqual(idx(2), status.configuration_index);
    try testing.expectEqual(idx(1), status.commit_index); // Adopted, not committed.
    try testing.expectEqual(idx(2), status.last_index);
    try testing.expectEqual(@as(u32, 0), count_effects(effects, .save_hard_state));
    try testing.expectEqual(@as(u32, 4), count_effects(effects, .send)); // 2, 3 and the new 4, 5.
    const to_two = try append_to(effects, 2);
    try testing.expectEqual(idx(1), to_two.prev_log_index);
    try testing.expectEqual(@as(usize, 1), to_two.entries.len);
    _ = try append_to(effects, 4);
    _ = try append_to(effects, 5);
    try testing.expectEqual(@as(usize, 4), fixtures.leader_progress(&rig.node).len);
}

test "reconfigure: joint commit needs a majority of both sets, each alone loses" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});
    const effects = try propose_change(&rig, &target);
    const to_two = try append_to(effects, 2);
    var trace: Trace = .{};

    // Incoming {1..5}: self, 4, 5 are 3 of 5; outgoing {1,2,3}: self alone is 1 of 3.
    try answer(&rig, effects, &.{ 4, 5 }, &trace);
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
    try testing.expect(rig.node.status().configuration_index.order(idx(2)) == .eq);

    // Self and 2 complete the outgoing majority, and with 4 and 5 the incoming one.
    _ = try accept(&rig, to_two);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
}

test "reconfigure: an outgoing-only majority does not commit enter_joint either" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});
    const effects = try propose_change(&rig, &target);
    const to_three = try append_to(effects, 3);

    // Self and 2: outgoing {1,2,3} holds 2 of 3, incoming {1..5} only 2 of 5.
    _ = try accept_each(&rig, effects, &.{2});
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
    // Self, 2 and 3 are 3 of 5: both quorums hold.
    _ = try accept(&rig, to_three);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
}

test "reconfigure: committing enter_joint appends leave_joint at once and settles the config" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});
    const effects = try propose_change(&rig, &target);
    const to_two = try append_to(effects, 2);
    var trace: Trace = .{};
    try answer(&rig, effects, &.{ 4, 5 }, &trace);

    const committed = try accept(&rig, to_two);

    try expect_conf_append(committed, 3, .{ .leave_joint = conf_of(&ids5, &.{}, &.{}) });
    try expect_configuration(conf_of(&ids5, &.{}, &.{}), rig.node.configuration_current());
    const status = rig.node.status();
    try testing.expectEqual(idx(2), status.commit_index);
    try testing.expectEqual(idx(3), status.last_index);
    try testing.expectEqual(idx(3), status.configuration_index);
    try testing.expectEqual(Role.leader, status.role);
    try testing.expectEqual(@as(u32, 1), count_effects(committed, .apply));
}

test "reconfigure: leave_joint commits on a 5-voter majority and a new change is accepted" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});
    var trace: Trace = .{};
    const effects = try propose_change(&rig, &target);
    _ = try accept_each(&rig, effects, &.{ 4, 5, 2 });
    try testing.expectEqual(idx(3), rig.node.status().last_index); // leave_joint appended.
    try testing.expectEqual(idx(2), rig.node.status().commit_index);

    try drive(&rig, &.{ 2, 3, 4, 5 }, 6, &trace);

    try testing.expectEqual(idx(3), rig.node.status().commit_index);
    try testing.expectEqual(idx(3), rig.node.status().applied_index);
    const shrink = conf_of(&ids3, &.{}, &.{});
    const again = try propose_change(&rig, &shrink);
    try expect_conf_append(again, 4, .{ .enter_joint = conf_of(&ids3, &ids5, &.{}) });
    try testing.expectEqual(idx(4), rig.node.status().configuration_index);
}

// ---- shrink 5 -> 3 with the leader removed -------------------------------------------------

test "reconfigure: shrinking 5 to 3 without the leader keeps it leading through the joint phase" {
    var rig: Rig = undefined;
    try leader5(&rig);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids345, &.{}, &.{});

    const effects = try propose_change(&rig, &target);

    try expect_conf_append(effects, 2, .{ .enter_joint = conf_of(&ids345, &ids5, &.{}) });
    try testing.expectEqual(Role.leader, rig.node.status().role);
    // The outgoing-only voter 2 still has a slot: 2, 3, 4, 5 are all sent to.
    try testing.expectEqual(@as(usize, 4), fixtures.leader_progress(&rig.node).len);
    _ = try append_to(effects, 2);
    const to_four = try append_to(effects, 4);
    // Incoming {3,4,5}: the leader is not a member, so 3 alone is 1 of 3 and loses.
    _ = try accept_each(&rig, effects, &.{3});
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
    // 4 completes incoming (2 of 3); outgoing {1..5} is self, 3, 4 = 3 of 5.
    const committed = try accept(&rig, to_four);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try expect_conf_append(committed, 3, .{ .leave_joint = conf_of(&ids345, &.{}, &.{}) });
    try testing.expectEqual(Role.leader, rig.node.status().role); // Not yet: leave_joint is open.
}

test "reconfigure: leave_joint commit steps the removed leader down, term and vote kept" {
    var rig: Rig = undefined;
    try leader5(&rig);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids345, &.{}, &.{});
    var trace: Trace = .{};
    const effects = try propose_change(&rig, &target);
    _ = try accept_each(&rig, effects, &.{ 3, 4 });
    try testing.expectEqual(idx(2), rig.node.status().commit_index);

    // The leader does not count for {3,4,5}: one ack of the leave entry commits nothing.
    try drive(&rig, &.{3}, 6, &trace);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try testing.expectEqual(Role.leader, rig.node.status().role);
    try testing.expectEqual(@as(u32, 0), trace.demotions);

    try drive(&rig, &.{4}, 6, &trace);

    const status = rig.node.status();
    try testing.expectEqual(idx(3), status.commit_index);
    try testing.expectEqual(Role.follower, status.role);
    try testing.expectEqual(NodeId.none, status.leader);
    try testing.expectEqual(fixtures.term(1), status.term); // Kept: no election, no bump.
    try testing.expectEqual(node_id(1), status.vote);
    try testing.expectEqual(@as(u32, 1), trace.demotions);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
    try expect_configuration(conf_of(&ids345, &.{}, &.{}), rig.node.configuration_current());
}

test "reconfigure: a removed leader refuses changes and never campaigns" {
    var rig: Rig = undefined;
    try leader5(&rig);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids345, &.{}, &.{});
    var trace: Trace = .{};
    const effects = try propose_change(&rig, &target);
    _ = try accept_each(&rig, effects, &.{ 3, 4 });
    try drive(&rig, &.{ 3, 4 }, 6, &trace);
    try testing.expectEqual(Role.follower, rig.node.status().role);

    try expect_refused(&rig, &target, error.ConfChangeNotLeader);
    for (0..45) |_| {
        const quiet = try step_checked(&rig, .tick);
        try testing.expectEqual(@as(usize, 0), quiet.items.len);
    }
    try testing.expectEqual(fixtures.term(1), rig.node.status().term);
    try testing.expectEqual(Role.follower, rig.node.status().role);
}

test "reconfigure: survivors keep their progress and removed peers are never sent to again" {
    var rig: Rig = undefined;
    try leader5(&rig);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids345, &.{}, &.{});
    const effects = try propose_change(&rig, &target);
    _ = try accept_each(&rig, effects, &.{ 2, 3, 4, 5 }); // All acked entry 2; leave_joint is 3.
    try testing.expectEqual(idx(3), rig.node.status().last_index);
    try testing.expectEqual(@as(usize, 3), fixtures.leader_progress(&rig.node).len); // 3, 4, 5.

    var sends_to_removed: u32 = 0;
    var resumed = false;
    for (0..9) |_| {
        const tick = try step_checked(&rig, .tick);
        for (tick.items) |effect| switch (effect) {
            .send => |message| switch (message) {
                .append_entries => |request| {
                    sends_to_removed += @intFromBool(request.header.to == node_id(2));
                    if (request.header.to == node_id(3)) {
                        // Peer 3 had matched 2 before the swap; it resumes there, not at zero.
                        try testing.expect(@intFromEnum(request.prev_log_index) >= 2);
                        resumed = true;
                    }
                },
                else => {},
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(u32, 0), sends_to_removed);
    try testing.expect(resumed);
}

test "reconfigure: the ack that commits enter_joint may come from a peer the leave removes" {
    var rig: Rig = undefined;
    try leader5(&rig);
    defer rig.deinit(testing.allocator);
    // Voters 1, 3, 4: peers 2 and 5 are outgoing-only and sit after 3 and 4 in the slot order.
    const target = conf_of(&ids134, &.{}, &.{});
    const effects = try propose_change(&rig, &target);
    _ = try accept_each(&rig, effects, &.{3}); // Incoming has 2 of 3; outgoing only 2 of 5.
    try testing.expectEqual(idx(1), rig.node.status().commit_index);

    // Peer 2's ack completes the outgoing majority; the leave drops 2 and 5 mid-response.
    const committed = try accept_each(&rig, effects, &.{2});

    try expect_conf_append(committed, 3, .{ .leave_joint = conf_of(&ids134, &.{}, &.{}) });
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try testing.expectEqual(@as(usize, 2), fixtures.leader_progress(&rig.node).len);
    for (committed.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries => |request| {
                try testing.expect(request.header.to != node_id(2));
                try testing.expect(request.header.to != node_id(5));
            },
            else => {},
        },
        else => {},
    };
    for (0..9) |_| _ = try step_checked(&rig, .tick); // Stale progress would trip the checks.
    try testing.expectEqual(Role.leader, rig.node.status().role);
}

// ---- refusals ------------------------------------------------------------------------------

test "reconfigure: a follower and a candidate refuse a change with ConfChangeNotLeader" {
    var rig: Rig = undefined;
    try start(&rig, cfg, &fresh3);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});

    try expect_refused(&rig, &target, error.ConfChangeNotLeader);
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try step_checked(&rig, .tick);
    }
    try expect_refused(&rig, &target, error.ConfChangeNotLeader);
    // Not-leader wins over a malformed target: the role is checked first.
    const bad = conf_of(&.{}, &.{}, &.{});
    try expect_refused(&rig, &bad, error.ConfChangeNotLeader);
}

test "reconfigure: a deposed leader refuses a change it could have made a moment ago" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids5, &.{}, &.{});
    const higher = fixtures.heartbeat(3, 1, 2);
    _ = try fixtures.receive_checked(&rig, &higher);
    try testing.expectEqual(Role.follower, rig.node.status().role);

    try expect_refused(&rig, &target, error.ConfChangeNotLeader);
}

test "reconfigure: a second change while enter_joint is uncommitted is ConfChangePending" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const first = conf_of(&ids5, &.{}, &.{});
    _ = try propose_change(&rig, &first);

    const other = conf_of(&ids4, &.{}, &.{});
    try expect_refused(&rig, &other, error.ConfChangePending);
    try expect_refused(&rig, &first, error.ConfChangePending);
    try testing.expectEqual(idx(2), rig.node.status().configuration_index);
}

test "reconfigure: leave_joint in flight keeps the next change ConfChangePending" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const first = conf_of(&ids5, &.{}, &.{});
    const effects = try propose_change(&rig, &first);
    _ = try accept_each(&rig, effects, &.{ 4, 5, 2 });
    try testing.expectEqual(idx(3), rig.node.status().configuration_index);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);

    const other = conf_of(&ids4, &.{}, &.{});
    try expect_refused(&rig, &other, error.ConfChangePending);
}

test "reconfigure: a leader elected into a joint configuration refuses a change as pending" {
    const out = [_]NodeId{ node_id(1), node_id(2), node_id(4) };
    const joint = conf_of(&ids3, &out, &.{});
    var bytes: fixtures.ConfBytes = .{};
    const log = [_]Entry{bytes.entry(1, 1, .{ .enter_joint = joint })};
    const restore = fixtures.restore_with(joint, fixtures.hard_state_of(1, 0, 1), &log);
    var rig: Rig = undefined;
    try start(&rig, cfg, &restore);
    defer rig.deinit(testing.allocator);
    try testing.expectEqual(idx(1), rig.node.status().configuration_index);
    _ = try elect_checked(&rig, &.{2}); // 2 is in both sets.

    const target = conf_of(&ids4, &.{}, &.{});
    try expect_refused(&rig, &target, error.ConfChangePending);
}

test "reconfigure: every ConfError is returned before any mutation" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const unsorted = [_]NodeId{ node_id(3), node_id(2), node_id(1) };
    const dupes = [_]NodeId{ node_id(1), node_id(2), node_id(2) };
    const zero = [_]NodeId{ .none, node_id(1) };
    const learner_voter = [_]NodeId{node_id(2)};
    const cases = [_]struct { target: Configuration, want: anyerror }{
        .{ .target = conf_of(&.{}, &.{}, &.{}), .want = error.ConfVotersEmpty },
        .{ .target = conf_of(&ids6, &.{}, &.{}), .want = error.ConfVotersTooMany },
        .{ .target = conf_of(&ids3, &.{}, &learners678), .want = error.ConfLearnersTooMany },
        .{ .target = conf_of(&unsorted, &.{}, &.{}), .want = error.ConfNodesUnsorted },
        .{ .target = conf_of(&dupes, &.{}, &.{}), .want = error.ConfNodesUnsorted },
        .{ .target = conf_of(&zero, &.{}, &.{}), .want = error.ConfNodesUnsorted },
        .{ .target = conf_of(&ids3, &.{}, &learner_voter), .want = error.ConfLearnerIsVoter },
        .{ .target = conf_of(&ids3, &ids4, &.{}), .want = error.ConfJointShape },
    };
    for (cases) |case| try expect_refused(&rig, &case.target, case.want);
}

test "reconfigure: a target at exactly voters_max and learners_max is accepted" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const edge = conf_of(&ids5, &.{}, &learners67);

    const effects = try propose_change(&rig, &edge);

    try expect_conf_append(effects, 2, .{ .enter_joint = conf_of(&ids5, &ids3, &learners67) });
    // Voters 2..5 and learners 6, 7: every other node in either set has a slot.
    try testing.expectEqual(@as(usize, 6), fixtures.leader_progress(&rig.node).len);
}

test "reconfigure: the joint entry must fit entry_bytes_max, outgoing ids included" {
    // 3 -> 5: ids = 5 incoming + 3 outgoing, so 13 + 8 * 8 = 77 bytes.
    const target = conf_of(&ids5, &.{}, &.{});
    for ([_]u32{ 60, 76 }) |too_small| { // 60 would fit the 53 bytes of voters alone.
        var small = cfg;
        small.message_limits.entry_bytes_max = too_small;
        var rig: Rig = undefined;
        try leader3(&rig, small);
        defer rig.deinit(testing.allocator);
        try expect_refused(&rig, &target, error.ConfChangeTooLarge);
    }
    var exact = cfg;
    exact.message_limits.entry_bytes_max = 77;
    var rig: Rig = undefined;
    try leader3(&rig, exact);
    defer rig.deinit(testing.allocator);
    const effects = try propose_change(&rig, &target);
    const batch = try appended(effects);
    try testing.expectEqual(@as(usize, 77), batch[0].data.len);
}

test "reconfigure: a full log slot or arena is ConfChangeLogFull, one more is not" {
    const target = conf_of(&ids5, &.{}, &.{});
    var slots = cfg;
    slots.log_entries_max = 2; // The election entry and one proposal fill it.
    var full: Rig = undefined;
    try leader3(&full, slots);
    defer full.deinit(testing.allocator);
    _ = try step_checked(&full, .{ .propose = "x" });
    try expect_refused(&full, &target, error.ConfChangeLogFull);

    var roomy: Rig = undefined;
    try leader3(&roomy, slots);
    defer roomy.deinit(testing.allocator);
    _ = try propose_change(&roomy, &target); // One free slot is enough.

    var arena = cfg;
    arena.log_bytes_max = 76; // 77 needed.
    var short: Rig = undefined;
    try leader3(&short, arena);
    defer short.deinit(testing.allocator);
    try expect_refused(&short, &target, error.ConfChangeLogFull);
    arena.log_bytes_max = 77;
    var exact: Rig = undefined;
    try leader3(&exact, arena);
    defer exact.deinit(testing.allocator);
    _ = try propose_change(&exact, &target);
}

// ---- learners ------------------------------------------------------------------------------

test "reconfigure: a learners-only change with unchanged voters is legal and joint-shaped" {
    var rig: Rig = undefined;
    try leader3(&rig, cfg);
    defer rig.deinit(testing.allocator);
    const target = conf_of(&ids3, &.{}, &learner4);

    const effects = try propose_change(&rig, &target);

    try expect_conf_append(effects, 2, .{ .enter_joint = conf_of(&ids3, &ids3, &learner4) });
    _ = try append_to(effects, 4); // The learner replicates.
    try testing.expectEqual(@as(usize, 3), fixtures.leader_progress(&rig.node).len);
    const to_two = try append_to(effects, 2);
    // A learner's ack never commits; a voter's does.
    _ = try accept_each(&rig, effects, &.{4});
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
    const committed = try accept(&rig, to_two);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try expect_conf_append(committed, 3, .{ .leave_joint = conf_of(&ids3, &.{}, &learner4) });
}

test "reconfigure: a learner gets append_entries but its ack and grants never count" {
    const restore = fixtures.restore_with(conf_of(&ids3, &.{}, &learner4), .empty, &.{});
    var rig: Rig = undefined;
    try start(&rig, cfg, &restore);
    defer rig.deinit(testing.allocator);
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try step_checked(&rig, .tick);
    }
    const pre = fixtures.pre_vote_response(4, 1, 1, true);
    _ = try fixtures.receive_checked(&rig, &pre);
    try testing.expectEqual(Role.pre_candidate, rig.node.status().role); // A learner's grant: no.
    const pre_two = fixtures.pre_vote_response(2, 1, 1, true);
    _ = try fixtures.receive_checked(&rig, &pre_two);
    const vote = fixtures.vote_response(4, 1, 1, true);
    _ = try fixtures.receive_checked(&rig, &vote);
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    const vote_two = fixtures.vote_response(2, 1, 1, true);
    const won = try fixtures.receive_checked(&rig, &vote_two);
    try testing.expectEqual(Role.leader, rig.node.status().role);

    _ = try append_to(won, 4);
    try testing.expectEqual(@as(usize, 3), fixtures.leader_progress(&rig.node).len);
    const to_two = try append_to(won, 2);
    _ = try accept_each(&rig, won, &.{4});
    try testing.expectEqual(idx(0), rig.node.status().commit_index);
    _ = try accept(&rig, to_two);
    try testing.expectEqual(idx(1), rig.node.status().commit_index);
}

// ---- model ---------------------------------------------------------------------------------

fn id_less(_: void, a: NodeId, b: NodeId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// A seeded random target over node ids 1..8: 1..5 voters (node 1 in with probability 3/4) and
/// 0..2 learners, disjoint and sorted; the lists live in the caller's buffers.
fn random_target(random: std.Random, voters: *[5]NodeId, learners: *[2]NodeId) Configuration {
    var pool = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4) } ++
        [_]NodeId{ node_id(5), node_id(6), node_id(7), node_id(8) };
    random.shuffle(NodeId, &pool);
    if (random.uintLessThan(u32, 4) != 0) {
        const at = std.mem.findScalar(NodeId, &pool, node_id(1)).?;
        std.mem.swap(NodeId, &pool[0], &pool[at]);
    }
    const voters_count = 1 + random.uintLessThan(usize, 5);
    const learners_count = random.uintLessThan(usize, 3);
    @memcpy(voters[0..voters_count], pool[0..voters_count]);
    @memcpy(learners[0..learners_count], pool[voters_count..][0..learners_count]);
    std.mem.sort(NodeId, voters[0..voters_count], {}, id_less);
    std.mem.sort(NodeId, learners[0..learners_count], {}, id_less);
    return conf_of(voters[0..voters_count], &.{}, learners[0..learners_count]);
}

fn run_model(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var rig: Rig = undefined;
    var big = cfg;
    big.log_entries_max = 32;
    big.log_bytes_max = 2048;
    try start(&rig, big, &fresh3);
    defer rig.deinit(testing.allocator);
    var trace: Trace = .{};
    try answer(&rig, try elect_checked(&rig, &.{2}), &all_peers, &trace);

    // The reference: the settled voters, and the entry count a change adds (enter + leave).
    var model_voters: [5]NodeId = undefined;
    @memcpy(model_voters[0..3], &ids3);
    var model_len: usize = 3;
    for (0..1 + random.uintLessThan(u32, 5)) |_| {
        var voters: [5]NodeId = undefined;
        var learners: [2]NodeId = undefined;
        const target = random_target(random, &voters, &learners);
        const last = @intFromEnum(rig.node.status().last_index);

        const live = try propose_change(&rig, &target);
        var saved: [32]node_module.Effect = undefined;
        @memcpy(saved[0..live.items.len], live.items);
        const effects: Effects = .{ .items = saved[0..live.items.len] };
        // A lone voter changing to itself alone is both quorums: `enter_joint` commits at once
        // and `leave_joint` follows in the same step (ADR-007: a lone voter commits at once).
        const lone = model_len == 1 and target.voters.len == 1 and target.voters[0] == node_id(1);
        const outgoing: []const NodeId = if (lone) &.{} else model_voters[0..model_len];
        try expect_configuration(
            conf_of(target.voters, outgoing, target.learners),
            rig.node.configuration_current(),
        );
        const adopted = last + if (lone) @as(u64, 2) else 1;
        try testing.expectEqual(idx(adopted), rig.node.status().configuration_index);
        if (!lone) try expect_refused(&rig, &target, error.ConfChangePending);

        try answer(&rig, effects, &all_peers, &trace);
        try drive(&rig, &all_peers, 6, &trace);
        const demoted = std.mem.findScalar(NodeId, target.voters, node_id(1)) == null;
        if (demoted) {
            try testing.expectEqual(Role.follower, rig.node.status().role);
            try testing.expectEqual(@as(u32, 1), trace.demotions);
            return;
        }
        try expect_configuration(
            conf_of(target.voters, &.{}, target.learners),
            rig.node.configuration_current(),
        );
        const status = rig.node.status();
        try testing.expectEqual(idx(last + 2), status.configuration_index);
        try testing.expectEqual(idx(last + 2), status.commit_index);
        try testing.expectEqual(Role.leader, status.role);
        @memcpy(model_voters[0..target.voters.len], target.voters);
        model_len = target.voters.len;
    }
}

test "reconfigure model: 60 seeds of random changes match the settled-target reference" {
    for (0..60) |seed| run_model(seed) catch |err| {
        std.log.err("reconfigure model failed at seed {d}", .{seed});
        return err;
    };
}
