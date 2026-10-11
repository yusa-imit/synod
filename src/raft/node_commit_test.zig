//! Tests for commit advancement and apply (plan 003 item 2B-iii, ADR-007): the leader commits the
//! highest index a quorum of every configuration matches, only when its log term is the current
//! one (Raft §5.4.2, Figure 8); a follower takes `min(leader_commit, last new entry)`; a
//! restarted node replays `(0, commit_index]` once on its first step; `apply` leaves in index
//! order, each entry exactly once, after the sends and before `leader_changed`.
//!
//! Expected values come from the Raft paper and the plan's contract, never from `leader.zig` or
//! `follower.zig`. Every step runs through a `Harness`, which checks the ADR-007 phase order,
//! `check_invariants()`, that `apply` entries are contiguous from the previous one and equal our
//! log, that `applied_index <= commit_index`, and that `commit_index` never decreases.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const AppendRequest = types.AppendRequest;
const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const HardState = types.HardState;
const Message = types.Message;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const config = fixtures.config;
const entry = fixtures.entry;
const log_restore = fixtures.log_restore;
const request_of = fixtures.append_request;
const append_to = fixtures.append_to;
const last_of = fixtures.last_of;
const index_of = fixtures.index_of;
const last_hard_state = fixtures.last_hard_state;
const expect_apply = fixtures.expect_apply;
const expect_quiet = fixtures.expect_quiet;
const reply_of = fixtures.reply_of;
const expect_ack = fixtures.expect_ack;
const expect_rejected = fixtures.expect_rejected;
const hard_state_of = fixtures.hard_state_of;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

/// One entry per `append_entries`, so a backed-up peer is caught up one entry at a time.
const config_one: Config = blk: {
    var c = config;
    c.message_limits.entries_max = 1;
    break :blk c;
};
const fresh = fixtures.restore_of(.empty, &.{});
const fresh5 = fixtures.restore_with(fixtures.configuration5, .empty, &.{});
/// Term 2 with an old-term entry at index 2: a winner campaigns at term 3 (Figure 8).
const old_entries = [_]Entry{ entry(1, 1, "a"), entry(2, 2, "b") };
const old = fixtures.restore_of(hard_state_of(2, 0, 0), &old_entries);
const lone_ids = [_]types.NodeId{node_id(1)};
const lone = fixtures.restore_with(
    .{ .voters = &lone_ids, .voters_outgoing = &.{}, .learners = &.{} },
    .empty,
    &.{},
);
const pair_ids = [_]types.NodeId{ node_id(1), node_id(2) };
const learner_ids = [_]types.NodeId{node_id(3)};
const pair_learner = fixtures.restore_with(
    .{ .voters = &pair_ids, .voters_outgoing = &.{}, .learners = &learner_ids },
    .empty,
    &.{},
);
const outgoing_ids = [_]types.NodeId{ node_id(1), node_id(2), node_id(4) };
/// Incoming {1, 2, 3}, outgoing {1, 2, 4}: node 2 is in both, 3 only incoming, 4 only outgoing.
const joint = fixtures.restore_with(
    .{ .voters = &fixtures.voters, .voters_outgoing = &outgoing_ids, .learners = &.{} },
    .empty,
    &.{},
);

// ---- harness and helpers -------------------------------------------------------------------

const Harness = struct {
    rig: Rig,
    applied_seen: u64,
    commit_seen: u64,

    fn init(h: *Harness, node_config: Config, restore: *const Restore) !void {
        h.applied_seen = 0;
        h.commit_seen = @intFromEnum(restore.hard_state.commit_index);
        try h.rig.init_fixed(testing.allocator, node_config, restore, 0); // Timeout t = 10.
    }

    fn deinit(h: *Harness) void {
        h.rig.deinit(testing.allocator);
    }

    /// The run-wide checks, after every step.
    fn observe(h: *Harness, effects: Effects) !void {
        const node = &h.rig.node;
        try fixtures.expect_effects_ordered(effects, node.config);
        try node.check_invariants();
        for (effects.items) |effect| switch (effect) {
            .apply => |batch| {
                try testing.expect(batch.len > 0);
                for (batch) |item| {
                    h.applied_seen += 1;
                    try testing.expectEqual(h.applied_seen, @intFromEnum(item.index));
                    const ours = node.entries()[@intCast(h.applied_seen - 1)];
                    try testing.expectEqual(ours.term, item.term);
                    try testing.expectEqualSlices(u8, ours.data, item.data);
                }
            },
            else => {},
        };
        const status = node.status();
        const commit = @intFromEnum(status.commit_index);
        try testing.expect(commit >= h.commit_seen);
        h.commit_seen = commit;
        try testing.expect(status.applied_index.order(status.commit_index) != .gt);
        try testing.expectEqual(h.applied_seen, @intFromEnum(status.applied_index));
    }
};

fn tick(h: *Harness) !Effects {
    const effects = try h.rig.node.step(.tick);
    try h.observe(effects);
    return effects;
}

fn recv(h: *Harness, message: Message) !Effects {
    const effects = try h.rig.receive(&message);
    try h.observe(effects);
    return effects;
}

fn propose(h: *Harness, data: []const u8) !Effects {
    const effects = try h.rig.node.step(.{ .propose = data });
    try h.observe(effects);
    return effects;
}

fn expect_commit(h: *const Harness, commit: u64) !void {
    const status = h.rig.node.status();
    try testing.expectEqual(idx(commit), status.commit_index);
    try testing.expectEqual(idx(commit), status.applied_index);
}

/// Ticks to a pre-candidate, then grants pre-votes and votes from `grants` (in order) until
/// the node leads; returns the winning step's effects.
fn elect(h: *Harness, grants: []const u64) !Effects {
    var guard: u32 = 0;
    while (h.rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try tick(h);
    }
    const would_be = @intFromEnum(h.rig.node.status().term) + 1;
    var used: usize = 0;
    while (h.rig.node.status().role == .pre_candidate) : (used += 1) {
        try testing.expect(used < grants.len);
        _ = try recv(h, fixtures.pre_vote_response(grants[used], 1, would_be, true));
    }
    try testing.expectEqual(Role.candidate, h.rig.node.status().role);
    const at = @intFromEnum(h.rig.node.status().term);
    var effects: Effects = .{ .items = &.{} };
    used = 0;
    while (h.rig.node.status().role == .candidate) : (used += 1) {
        try testing.expect(used < grants.len);
        effects = try recv(h, fixtures.vote_response(grants[used], 1, at, true));
    }
    try testing.expectEqual(Role.leader, h.rig.node.status().role);
    return effects;
}

fn response(from: u64, round: u64, outcome: types.AppendOutcome) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, 3),
        .round = round,
        .outcome = outcome,
    } };
}

fn accepted(from: u64, round: u64, at_term: u64, matched: u64) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, at_term),
        .round = round,
        .outcome = .{ .accepted = idx(matched) },
    } };
}

// ---- leader: quorum commit -----------------------------------------------------------------

test "leader commit: a quorum ack of the election entry persists the commit, then applies it" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    const won = try elect(&h, &.{2});
    try expect_quiet(won); // The leader alone (1 of 3) commits nothing.
    try expect_commit(&h, 0);
    const r2 = (try append_to(won, 2)).round;

    const effects = try recv(&h, accepted(2, r2, 1, 1));
    try testing.expectEqual(@as(usize, 2), effects.items.len);
    try testing.expect(effects.items[0] == .save_hard_state);
    try testing.expectEqual(hard_state_of(1, 1, 1), effects.items[0].save_hard_state);
    try expect_apply(effects, &.{entry(1, 1, "")});
    try expect_commit(&h, 1);
}

test "leader commit: the commit is persisted before the sends and the apply follows them" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round;
    for (0..3) |_| _ = try propose(&h, "x"); // Log 1..4; the probing peers have a full window.

    const effects = try recv(&h, accepted(2, r2, 1, 1));
    try testing.expectEqual(@as(usize, 3), effects.items.len);
    try testing.expect(effects.items[0] == .save_hard_state);
    try testing.expectEqual(hard_state_of(1, 1, 1), effects.items[0].save_hard_state);
    try testing.expect(effects.items[1] == .send);
    try testing.expectEqual(@as(u64, 4), last_of(try append_to(effects, 2)));
    try testing.expect(effects.items[2] == .apply);
    try expect_apply(effects, &.{entry(1, 1, "")});
}

test "leader commit: one ack commits a run in order, then an older ack is inert" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round;
    _ = try recv(&h, accepted(2, r2, 1, 1));
    const first = try append_to(try propose(&h, "x"), 2);
    const second = try append_to(try propose(&h, "y"), 2);
    try testing.expectEqual(@as(u64, 3), last_of(second));
    try expect_commit(&h, 1);

    const effects = try recv(&h, accepted(2, second.round, 1, 3));
    try testing.expectEqual(hard_state_of(1, 1, 3), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{ entry(2, 1, "x"), entry(3, 1, "y") });
    try expect_commit(&h, 3);

    const late = try recv(&h, accepted(2, first.round, 1, 2)); // Older round, match stays 3.
    try expect_quiet(late);
    try testing.expectEqual(@as(usize, 0), late.items.len);
}

test "leader commit: the median of matches decides, not the best or the worst peer" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    const won = try elect(&h, &.{2});
    const r2 = (try append_to(won, 2)).round;
    const r3 = (try append_to(won, 3)).round;
    _ = try recv(&h, accepted(2, r2, 1, 1));
    _ = try recv(&h, accepted(3, r3, 1, 1));
    const sent_x = try propose(&h, "x"); // Entry 2 goes to both replicating peers.
    const x3 = try append_to(sent_x, 3);
    const y2 = try append_to(try propose(&h, "y"), 2); // Entry 3.
    try testing.expectEqual(@as(u64, 3), last_of(y2));
    try expect_commit(&h, 1);

    // Matches are now leader 3, node 2 at 1, node 3 at 2: the median is 2.
    const first = try recv(&h, accepted(3, x3.round, 1, 2));
    try testing.expectEqual(hard_state_of(1, 1, 2), try fixtures.only_hard_state(first));
    try expect_apply(first, &.{entry(2, 1, "x")});
    // Node 2 jumps to 3: matches 3, 3, 2, the median is 3.
    const second = try recv(&h, accepted(2, y2.round, 1, 3));
    try testing.expectEqual(hard_state_of(1, 1, 3), try fixtures.only_hard_state(second));
    try expect_apply(second, &.{entry(3, 1, "y")});
}

test "leader commit: five voters need three, so one peer ack is not enough" {
    var h: Harness = undefined;
    try h.init(fixtures.config5, &fresh5);
    defer h.deinit();
    const won = try elect(&h, &.{ 2, 3 });
    const r2 = (try append_to(won, 2)).round;
    const r3 = (try append_to(won, 3)).round;

    try testing.expectEqual(@as(usize, 0), (try recv(&h, accepted(2, r2, 1, 1))).items.len);
    try expect_commit(&h, 0);
    const effects = try recv(&h, accepted(3, r3, 1, 1));
    try testing.expectEqual(hard_state_of(1, 1, 1), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{entry(1, 1, "")});
}

// ---- leader: Figure 8 -----------------------------------------------------------------------

/// One entry per message, so a peer needs two round trips to hold the old entry and a third for
/// ours. Elects node 1 at term 3 over the log of terms 1, 2, then drives both peers to match 2
/// (the old-term entry): a quorum that must not commit. Returns the pending requests for entry 3.
fn peers_hold_old_entry(h: *Harness) ![2]AppendRequest {
    const won = try elect(h, &.{2});
    const probes = [2]AppendRequest{ try append_to(won, 2), try append_to(won, 3) };
    var pending: [2]AppendRequest = undefined;
    for (probes, 0..) |probe, i| {
        const peer: u64 = i + 2;
        try testing.expectEqual(@as(u64, 3), last_of(probe));
        const reject: types.AppendOutcome = .{ .rejected = .{ .index = idx(0), .term = term(0) } };
        const back = try append_to(try recv(h, response(peer, probe.round, reject)), peer);
        try testing.expectEqual(@as(u64, 2), last_of(back)); // Entry 2, term 2, alone.
        const after = try recv(h, accepted(peer, back.round, 3, 2));
        try expect_quiet(after);
        pending[i] = try append_to(after, peer);
        try testing.expectEqual(@as(u64, 3), last_of(pending[i]));
    }
    try expect_commit(h, 0); // Both peers match index 2 (term 2): a quorum, not of this term.
    return pending;
}

test "figure 8: an old-term entry on a quorum is not committed by counting, the empty entry does" {
    var h: Harness = undefined;
    try h.init(config_one, &old);
    defer h.deinit();
    const pending = try peers_hold_old_entry(&h);

    const effects = try recv(&h, accepted(2, pending[0].round, 3, 3));
    try testing.expectEqual(hard_state_of(3, 1, 3), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{ old_entries[0], old_entries[1], entry(3, 3, "") });
    try expect_commit(&h, 3);
}

test "figure 8: a term-3 proposal on a quorum commits the old entry beneath it, once" {
    var h: Harness = undefined;
    try h.init(config_one, &old);
    defer h.deinit();
    _ = try peers_hold_old_entry(&h);

    const sent = try propose(&h, "p");
    const to2 = try append_to(sent, 2);
    try testing.expectEqual(@as(u64, 4), last_of(to2));
    try expect_quiet(sent);
    const effects = try recv(&h, accepted(2, to2.round, 3, 4));
    try testing.expectEqual(hard_state_of(3, 1, 4), try fixtures.only_hard_state(effects));
    const log = [_]Entry{ old_entries[0], old_entries[1], entry(3, 3, ""), entry(4, 3, "p") };
    try expect_apply(effects, &log);
    try expect_commit(&h, 4);
}

// ---- leader: negative space -----------------------------------------------------------------

test "leader commit: stale rounds, strangers and old terms count for nothing, a valid ack does" {
    var h: Harness = undefined;
    try h.init(config, &old);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round; // Term 3, entry 3 is ours.

    const dropped = [_]Message{
        accepted(2, r2 + 1000, 3, 3), // A round id we never issued.
        accepted(9, r2, 3, 3), // Not in the cluster.
        accepted(3, r2, 3, 3), // Node 2's round id, sent by node 3.
        accepted(2, r2, 2, 3), // A term-2 answer to a term-3 round.
    };
    for (dropped) |message| {
        try testing.expectEqual(@as(usize, 0), (try recv(&h, message)).items.len);
    }
    try expect_commit(&h, 0);

    const effects = try recv(&h, accepted(2, r2, 3, 3));
    try testing.expectEqual(hard_state_of(3, 1, 3), try fixtures.only_hard_state(effects));
    try expect_commit(&h, 3);
}

test "leader commit: a higher-term answer deposes the leader without committing anything" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round;

    const effects = try recv(&h, accepted(2, r2, 2, 1));
    try testing.expectEqual(Role.follower, h.rig.node.status().role);
    try testing.expectEqual(idx(0), h.rig.node.status().commit_index);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .apply));
    try testing.expectEqual(hard_state_of(2, 0, 0), try fixtures.only_hard_state(effects));
}

test "leader commit: a learner's ack is not a vote, the voter's ack completes the quorum" {
    var h: Harness = undefined;
    try h.init(config, &pair_learner);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round;

    try testing.expectEqual(@as(usize, 0), (try recv(&h, accepted(3, r2, 1, 1))).items.len);
    try expect_commit(&h, 0);
    const effects = try recv(&h, accepted(2, r2, 1, 1));
    try testing.expectEqual(hard_state_of(1, 1, 1), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{entry(1, 1, "")});
}

test "leader commit: proposals alone, without acks, never commit" {
    var h: Harness = undefined;
    try h.init(config, &fresh);
    defer h.deinit();
    _ = try elect(&h, &.{2});
    for (0..4) |_| try expect_quiet(try propose(&h, "x"));
    for (0..12) |_| try expect_quiet(try tick(&h));
    try expect_commit(&h, 0);
}

// ---- leader: joint configuration ------------------------------------------------------------

test "joint commit: an incoming-only majority is not enough, the outgoing one completes it" {
    var h: Harness = undefined;
    try h.init(config, &joint);
    defer h.deinit();
    const won = try elect(&h, &.{2});
    const r3 = (try append_to(won, 3)).round;
    const r4 = (try append_to(won, 4)).round;

    // {1, 3} is a majority of {1, 2, 3} but not of {1, 2, 4}.
    try expect_quiet(try recv(&h, accepted(3, r3, 1, 1)));
    try expect_commit(&h, 0);
    const effects = try recv(&h, accepted(4, r4, 1, 1));
    try testing.expectEqual(hard_state_of(1, 1, 1), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{entry(1, 1, "")});
}

test "joint commit: an outgoing-only majority is not enough, the incoming one completes it" {
    var h: Harness = undefined;
    try h.init(config, &joint);
    defer h.deinit();
    const won = try elect(&h, &.{2});
    const r3 = (try append_to(won, 3)).round;
    const r4 = (try append_to(won, 4)).round;

    try expect_quiet(try recv(&h, accepted(4, r4, 1, 1))); // {1, 4} is not a majority of {1,2,3}.
    try expect_commit(&h, 0);
    const effects = try recv(&h, accepted(3, r3, 1, 1));
    try testing.expectEqual(hard_state_of(1, 1, 1), try fixtures.only_hard_state(effects));
    try expect_commit(&h, 1);
}

test "joint commit: a voter in both sets completes both quorums alone" {
    var h: Harness = undefined;
    try h.init(config, &joint);
    defer h.deinit();
    const r2 = (try append_to(try elect(&h, &.{2}), 2)).round;

    const effects = try recv(&h, accepted(2, r2, 1, 1));
    try testing.expectEqual(hard_state_of(1, 1, 1), try fixtures.only_hard_state(effects));
    try expect_apply(effects, &.{entry(1, 1, "")});
}

// ---- lone voter -----------------------------------------------------------------------------

test "lone voter: commits and applies the election entry and every proposal in its own step" {
    var h: Harness = undefined;
    try h.init(config, &lone);
    defer h.deinit();
    var won: Effects = .{ .items = &.{} };
    var guard: u32 = 0;
    while (h.rig.node.status().role != .leader) : (guard += 1) {
        try testing.expect(guard < config.election_ticks);
        won = try tick(&h);
    }
    try expect_apply(won, &.{entry(1, 1, "")});
    try testing.expectEqual(hard_state_of(1, 1, 1), try last_hard_state(won));
    const last = won.items.len - 1;
    try testing.expectEqual(node_id(1), won.items[last].leader_changed);
    try testing.expect(index_of(won, .apply).? < last); // Apply precedes the notify.
    try expect_commit(&h, 1);

    const first = try propose(&h, "z");
    try testing.expectEqual(@as(usize, 3), first.items.len);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(first, .append));
    try testing.expectEqual(hard_state_of(1, 1, 2), try fixtures.only_hard_state(first));
    try testing.expect(first.items[2] == .apply);
    try expect_apply(first, &.{entry(2, 1, "z")});
    try expect_commit(&h, 2);

    const second = try propose(&h, "w");
    try expect_apply(second, &.{entry(3, 1, "w")});
    try testing.expectEqual(hard_state_of(1, 1, 3), try fixtures.only_hard_state(second));
    for (0..30) |_| try testing.expectEqual(@as(usize, 0), (try tick(&h)).items.len);
    try expect_commit(&h, 3);
}

// ---- follower -------------------------------------------------------------------------------

test "follower commit: min(leader_commit, last new entry), persisted, acked, then applied" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(1, 0, 0), &.{}));
    defer h.deinit();
    var buffer: [3]Entry = undefined;
    const three = fixtures.fill_entries(&buffer, 3, 1);

    const effects = try recv(&h, request_of(2, 1, 0, 0, 2, three));
    try testing.expectEqual(hard_state_of(1, 0, 2), try fixtures.only_hard_state(effects));
    try expect_ack(effects, 2, 3);
    try expect_apply(effects, &.{ entry(1, 1, ""), entry(2, 1, "") });
    const last = effects.items.len - 1;
    try testing.expectEqual(node_id(2), effects.items[last].leader_changed);
    try testing.expect(index_of(effects, .send).? < index_of(effects, .apply).?);
    try testing.expect(index_of(effects, .apply).? < last);
    try expect_commit(&h, 2);

    const beat = try recv(&h, request_of(2, 1, 3, 1, 3, &.{})); // Heartbeat: last new is prev.
    try testing.expectEqual(hard_state_of(1, 0, 3), try fixtures.only_hard_state(beat));
    try expect_ack(beat, 2, 3);
    try expect_apply(beat, &.{entry(3, 1, "")});
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(beat, .leader_changed));
    try expect_commit(&h, 3);
}

test "follower commit: a leader_commit beyond the batch stops at the last new entry" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(1, 0, 0), &.{}));
    defer h.deinit();
    var buffer: [3]Entry = undefined;
    const effects = try recv(&h, request_of(2, 1, 0, 0, 9, fixtures.fill_entries(&buffer, 3, 1)));
    try expect_apply(effects, &.{ entry(1, 1, ""), entry(2, 1, ""), entry(3, 1, "") });
    try testing.expectEqual(hard_state_of(1, 0, 3), try fixtures.only_hard_state(effects));
    try expect_commit(&h, 3);
}

test "follower commit: a stale longer suffix beyond the verified prefix is not committed" {
    var buffer: [3]Entry = undefined;
    const restore = log_restore(&buffer, 3, 1, 0);
    var h: Harness = undefined;
    try h.init(config, &restore);
    defer h.deinit();

    const effects = try recv(&h, request_of(2, 1, 2, 1, 3, &.{})); // Verifies only up to 2.
    try expect_ack(effects, 2, 2);
    try expect_apply(effects, &.{ entry(1, 1, ""), entry(2, 1, "") });
    try testing.expectEqual(hard_state_of(1, 0, 2), try fixtures.only_hard_state(effects));
    try testing.expectEqual(idx(3), h.rig.node.status().last_index);
    try expect_commit(&h, 2);

    const full = try recv(&h, request_of(2, 1, 3, 1, 3, &.{}));
    try expect_apply(full, &.{entry(3, 1, "")});
    try expect_commit(&h, 3);
}

test "follower commit: a smaller or zero leader_commit never lowers it and emits nothing" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.base_restore); // Term 3, commit 2, terms 1 2 3.
    defer h.deinit();
    const restart = try tick(&h);
    try expect_apply(restart, fixtures.base_entries[0..2]);
    try expect_commit(&h, 2);

    for ([_]u64{ 1, 0 }) |lower| {
        const effects = try recv(&h, request_of(2, 3, 3, 3, lower, &.{}));
        try expect_ack(effects, 2, 3);
        try expect_quiet(effects);
        try expect_commit(&h, 2);
    }
    const raised = try recv(&h, request_of(2, 3, 3, 3, 3, &.{}));
    try expect_apply(raised, &.{base_entries_last});
    try expect_commit(&h, 3);
}

const base_entries_last = fixtures.base_entries[2];

test "follower commit: leader_commit zero on an accepting append commits and applies nothing" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(1, 0, 0), &.{}));
    defer h.deinit();
    var buffer: [3]Entry = undefined;
    const effects = try recv(&h, request_of(2, 1, 0, 0, 0, fixtures.fill_entries(&buffer, 3, 1)));
    try expect_ack(effects, 2, 3);
    try expect_quiet(effects);
    try expect_commit(&h, 0);
}

test "follower commit: rejected requests never move commit, a later accepted one does" {
    var buffer: [2]Entry = undefined;
    const restore = log_restore(&buffer, 2, 2, 0);
    var h: Harness = undefined;
    try h.init(config, &restore);
    defer h.deinit();

    const beyond = try recv(&h, request_of(2, 2, 3, 1, 9, &.{})); // prev beyond our log.
    try expect_rejected(beyond);
    try expect_quiet(beyond);
    const wrong_term = try recv(&h, request_of(2, 2, 2, 2, 9, &.{})); // prev term differs.
    try expect_rejected(wrong_term);
    try expect_quiet(wrong_term);
    try expect_commit(&h, 0);

    const effects = try recv(&h, request_of(2, 2, 2, 1, 9, &.{}));
    try expect_apply(effects, &.{ entry(1, 1, ""), entry(2, 1, "") });
    try expect_commit(&h, 2);
}

test "follower commit: stale-term, non-member and rival-leader requests never move commit" {
    var buffer: [2]Entry = undefined;
    const restore = log_restore(&buffer, 2, 2, 0);
    var h: Harness = undefined;
    try h.init(config, &restore);
    defer h.deinit();

    try expect_quiet(try recv(&h, request_of(2, 2, 0, 0, 0, &.{}))); // Node 2 leads term 2.
    const stale = try recv(&h, request_of(2, 1, 2, 1, 2, &.{})); // Term 1 < 2.
    try expect_rejected(stale);
    try expect_quiet(stale);
    try expect_quiet(try recv(&h, request_of(9, 2, 2, 1, 2, &.{}))); // Not a member.
    try expect_quiet(try recv(&h, request_of(3, 2, 2, 1, 2, &.{}))); // Second claim of term 2.
    try expect_commit(&h, 0);

    const effects = try recv(&h, request_of(2, 2, 2, 1, 2, &.{}));
    try expect_apply(effects, &.{ entry(1, 1, ""), entry(2, 1, "") });
    try expect_commit(&h, 2);
}

test "follower commit: a replayed request neither re-applies nor re-persists" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(1, 0, 0), &.{}));
    defer h.deinit();
    var buffer: [3]Entry = undefined;
    const three = fixtures.fill_entries(&buffer, 3, 1);
    _ = try recv(&h, request_of(2, 1, 0, 0, 3, three));
    try expect_commit(&h, 3);

    const again = try recv(&h, request_of(2, 1, 0, 0, 3, three));
    try expect_ack(again, 2, 3);
    try expect_quiet(again);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(again, .append));
    try expect_commit(&h, 3);
}

test "follower commit: applies the replacement of a truncated suffix, not the stale entries" {
    const stale = [_]Entry{ entry(1, 1, "a"), entry(2, 1, "b"), entry(3, 2, "c") };
    const restore = fixtures.restore_of(hard_state_of(2, 0, 0), &stale);
    var h: Harness = undefined;
    try h.init(config, &restore);
    defer h.deinit();
    const fresh_tail = [_]Entry{ entry(2, 3, "n2"), entry(3, 3, "n3") };

    const effects = try recv(&h, request_of(2, 3, 1, 1, 3, &fresh_tail));
    try expect_ack(effects, 2, 3);
    try testing.expectEqual(hard_state_of(3, 0, 3), try last_hard_state(effects));
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .truncate));
    try expect_apply(effects, &.{ stale[0], fresh_tail[0], fresh_tail[1] });
    try expect_commit(&h, 3);
}

// ---- restart --------------------------------------------------------------------------------

test "restart: a restored commit_index is replayed once, on the first step, even a plain tick" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.base_restore); // Commit 2, applied 0.
    defer h.deinit();
    try testing.expectEqual(idx(0), h.rig.node.status().applied_index);

    const first = try tick(&h);
    try testing.expectEqual(@as(usize, 1), first.items.len);
    try expect_apply(first, &.{ fixtures.base_entries[0], fixtures.base_entries[1] });
    try expect_commit(&h, 2);
    for (0..4) |_| try testing.expectEqual(@as(usize, 0), (try tick(&h)).items.len);
    try testing.expectEqual(idx(2), h.rig.node.status().commit_index);
}

test "restart: a fully committed log is replayed whole, with its bytes" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(3, 0, 3), &fixtures.base_entries));
    defer h.deinit();
    try expect_apply(try tick(&h), &fixtures.base_entries);
    try expect_commit(&h, 3);
    try testing.expectEqual(@as(usize, 0), (try tick(&h)).items.len);
}

test "restart: a restored commit_index of zero applies nothing" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(3, 0, 0), &fixtures.base_entries));
    defer h.deinit();
    for (0..5) |_| try expect_quiet(try tick(&h));
    try expect_commit(&h, 0);
}

test "restart: a first step that is a message replays before the leader notification" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.base_restore);
    defer h.deinit();

    const effects = try recv(&h, fixtures.heartbeat(2, 1, 3)); // leader_commit 0.
    try expect_ack(effects, 2, 0);
    try expect_apply(effects, &.{ fixtures.base_entries[0], fixtures.base_entries[1] });
    try testing.expect(index_of(effects, .send).? < index_of(effects, .apply).?);
    try testing.expect(index_of(effects, .apply).? < index_of(effects, .leader_changed).?);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
    try expect_commit(&h, 2);
}

test "restart: entries committed after the replay are applied without repeating the replayed ones" {
    var h: Harness = undefined;
    try h.init(config, &fixtures.restore_of(hard_state_of(3, 0, 1), &fixtures.base_entries));
    defer h.deinit();
    try expect_apply(try tick(&h), &.{fixtures.base_entries[0]});

    const effects = try recv(&h, request_of(2, 3, 3, 3, 3, &.{}));
    try expect_apply(effects, &.{ fixtures.base_entries[1], fixtures.base_entries[2] });
    try testing.expectEqual(hard_state_of(3, 0, 3), try fixtures.only_hard_state(effects));
    try expect_commit(&h, 3);
}

// ---- model-based ----------------------------------------------------------------------------

/// A pending round of the model: who it went to and the range it carried.
const Pending = struct { peer: u8, id: u64, prev: u64, last: u64 };

/// The trivially correct reference: log terms, per-peer match, and the median rule restricted to
/// the leader's current term. Node 1 leads term 3 over the log of terms 1, 2, then 3.
const Reference = struct {
    terms: [8]u64 = .{ 1, 2, 3, 0, 0, 0, 0, 0 },
    last: u64 = 3,
    match: [2]u64 = .{ 0, 0 },
    commit: u64 = 0,
    pending: [16]Pending = undefined,
    pending_len: usize = 0,

    fn recompute(r: *Reference) void {
        var sorted = [3]u64{ r.last, r.match[0], r.match[1] };
        std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
        const median = sorted[1]; // The highest index at least two of three hold.
        if (median > r.commit and r.terms[@intCast(median - 1)] == 3) r.commit = median;
    }

    fn observe(r: *Reference, effects: Effects) !void {
        for (effects.items) |effect| switch (effect) {
            .send => |message| switch (message) {
                .append_entries => |request| {
                    try testing.expect(r.pending_len < r.pending.len);
                    const peer: u8 = if (request.header.to == node_id(2)) 0 else 1;
                    r.pending[r.pending_len] = .{
                        .peer = peer,
                        .id = request.round,
                        .prev = @intFromEnum(request.prev_log_index),
                        .last = last_of(request),
                    };
                    r.pending_len += 1;
                },
                else => {},
            },
            else => {},
        };
    }
};

fn run_model(seed: u64) !void {
    var h: Harness = undefined;
    try h.init(config, &old);
    defer h.deinit();
    var ref: Reference = .{};
    try ref.observe(try elect(&h, &.{2}));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    for (0..80) |_| {
        switch (random.uintLessThan(u8, 6)) {
            0, 1 => if (h.rig.node.step(.{ .propose = "x" })) |effects| {
                try h.observe(effects);
                ref.terms[@intCast(ref.last)] = 3;
                ref.last += 1;
                ref.recompute();
                try ref.observe(effects);
            } else |err| try testing.expectEqual(error.ProposeLogFull, err),
            2, 3, 4 => if (ref.pending_len > 0) {
                const at = random.uintLessThan(usize, ref.pending_len);
                const round = ref.pending[at];
                const low = @max(round.prev, ref.match[round.peer]);
                if (low > round.last) continue; // A newer ack already passed this round.
                const matched = low + random.uintAtMost(u64, round.last - low);
                ref.pending[at] = ref.pending[ref.pending_len - 1];
                ref.pending_len -= 1;
                const from: u64 = round.peer + 2;
                const effects = try recv(&h, accepted(from, round.id, 3, matched));
                ref.match[round.peer] = matched;
                ref.recompute();
                try ref.observe(effects);
            },
            else => {
                ref.pending_len = 0; // Ticks may time rounds out: forget them, never ack them.
                try ref.observe(try tick(&h));
            },
        }
        try testing.expectEqual(idx(ref.commit), h.rig.node.status().commit_index);
        try testing.expectEqual(ref.commit, h.applied_seen);
    }
}

test "commit model: 200 seeds of proposals, acks and ticks match the median reference" {
    for (0..200) |seed| {
        run_model(seed) catch |err| {
            std.log.err("commit model failed at seed {d}", .{seed});
            return err;
        };
    }
}
