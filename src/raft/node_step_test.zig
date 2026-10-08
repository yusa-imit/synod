//! Tests for `Node.step` in the 2A-i skeleton (plan 003, ADR-007): term rules, rejection before
//! mutation, `Effect.phase` ordering, a seeded stream against a trivial term/vote model, and a
//! fuzz target over arbitrary inputs. Election, replication and apply are later items; only
//! what ADR-007 fixes today is asserted.
//!
//! Every stream is reproducible from its seed, which `std.log` reports on failure. A follower
//! receiving only responses and fewer than `election_ticks` ticks cannot time out, so no
//! election logic is reachable in these streams.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Effect = node_module.Effect;
const Entry = types.Entry;
const Message = types.Message;
const Rig = fixtures.Rig;
const Status = node_module.Status;

const config = fixtures.config;
const base_entries = fixtures.base_entries;
const base_restore = fixtures.base_restore;
const entry = fixtures.entry;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

/// A follower at term 3 that voted for node 2, commit 0 (so the first step applies nothing).
const quiet_restore = fixtures.restore_of(fixtures.hard_state_of(3, 2, 0), &base_entries);

fn quiet_status(term_value: u64, vote: u64) Status {
    return .{
        .role = .follower,
        .term = term(term_value),
        .vote = node_id(vote),
        .leader = .none,
        .commit_index = .zero,
        .applied_index = .zero,
        .last_index = idx(3),
    };
}

fn expect_unchanged(rig: *Rig, before: Status) !void {
    try testing.expectEqual(before, rig.node.status());
    try fixtures.expect_entries_equal(&base_entries, rig.node.entries());
    try rig.node.check_invariants();
}

test "node: Effect.phase maps every variant to its ADR-007 phase" {
    const one = [_]Entry{entry(1, 1, "")};
    const message = fixtures.vote_response(1, 2, 3, true);
    const cases = [_]struct { effect: Effect, phase: Effect.Phase }{
        .{ .effect = .{ .truncate = idx(2) }, .phase = .persist },
        .{ .effect = .{ .append = &one }, .phase = .persist },
        .{ .effect = .{ .save_hard_state = .empty }, .phase = .persist },
        .{ .effect = .{ .send = message }, .phase = .send },
        .{ .effect = .{ .apply = &one }, .phase = .apply },
        .{ .effect = .{ .leader_changed = node_id(2) }, .phase = .notify },
    };
    try testing.expectEqual(@typeInfo(Effect).@"union".fields.len, cases.len);
    for (cases) |case| try testing.expectEqual(case.phase, case.effect.phase());
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Effect.Phase.persist));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Effect.Phase.send));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Effect.Phase.apply));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Effect.Phase.notify));
}

test "node: a higher-term response from a peer steps down and persists exactly once" {
    const responses = [_]Message{
        fixtures.vote_response(2, 1, 5, false),
        fixtures.vote_response(3, 1, 9, true),
        fixtures.append_response(2, 1, 4),
    };
    for (responses) |message| {
        var rig: Rig = undefined;
        try rig.init(testing.allocator, config, &quiet_restore, 1);
        defer rig.deinit(testing.allocator);

        const effects = try rig.receive(&message);
        const saved = try fixtures.only_hard_state(effects);
        const new_term = message.header().term;
        try testing.expectEqual(new_term, saved.term);
        try testing.expectEqual(types.NodeId.none, saved.vote);
        try testing.expectEqual(types.Index.zero, saved.commit_index);
        try testing.expectEqual(@as(usize, 1), effects.items.len);
        try testing.expectEqual(Effect.Phase.persist, effects.items[0].phase());
        try testing.expectEqual(new_term, rig.node.status().term);
        try testing.expectEqual(types.NodeId.none, rig.node.status().vote);
        try fixtures.expect_effects_ordered(effects, config);
        try rig.node.check_invariants();
    }
}

test "node: the lowest adoptable term from a fresh node is one" {
    const restore = fixtures.restore_of(.empty, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &restore, 1);
    defer rig.deinit(testing.allocator);

    const message = fixtures.vote_response(3, 1, 1, false);
    const saved = try fixtures.only_hard_state(try rig.receive(&message));
    try testing.expectEqual(fixtures.hard_state_of(1, 0, 0), saved);
    try testing.expectEqual(term(1), rig.node.status().term);
    try rig.node.check_invariants();
}

test "node: a higher term keeps the restored commit index in the saved hard state" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &base_restore, 1);
    defer rig.deinit(testing.allocator);

    const message = fixtures.append_response(3, 1, 7);
    const effects = try rig.receive(&message);
    const saved = try fixtures.only_hard_state(effects);
    try testing.expectEqual(fixtures.hard_state_of(7, 0, 2), saved);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
    try fixtures.expect_effects_ordered(effects, config);
    try rig.node.check_invariants();
}

test "node: a higher-term request makes a follower at the new term and persists once" {
    const requests = [_]Message{ fixtures.vote_request(2, 1, 5), fixtures.heartbeat(2, 1, 5) };
    for (requests) |message| {
        var rig: Rig = undefined;
        try rig.init(testing.allocator, config, &quiet_restore, 1);
        defer rig.deinit(testing.allocator);

        const effects = try rig.receive(&message);
        const saved = try fixtures.only_hard_state(effects);
        try testing.expectEqual(term(5), saved.term);
        try testing.expectEqual(term(5), rig.node.status().term);
        try testing.expectEqual(node_module.Role.follower, rig.node.status().role);
        // The old vote is gone; a grant to the candidate is the only other possibility.
        try testing.expect(saved.vote == .none or saved.vote == node_id(2));
        try testing.expectEqual(saved.vote, rig.node.status().vote);
        try fixtures.expect_effects_ordered(effects, config);
        try rig.node.check_invariants();
    }
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);
    const beat = fixtures.heartbeat(2, 1, 5);
    _ = try rig.receive(&beat);
    try testing.expectEqual(types.NodeId.none, rig.node.status().vote);
}

test "node: an equal-term response changes nothing and emits nothing" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    const messages = [_]Message{
        fixtures.vote_response(2, 1, 3, true),
        fixtures.append_response(3, 1, 3),
    };
    for (messages) |message| {
        const effects = try rig.receive(&message);
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try expect_unchanged(&rig, quiet_status(3, 2));
    }
}

test "node: a stale-term response is dropped without effects or state change" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    const messages = [_]Message{
        fixtures.vote_response(2, 1, 2, true),
        fixtures.append_response(3, 1, 1),
    };
    for (messages) |message| {
        const effects = try rig.receive(&message);
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try expect_unchanged(&rig, quiet_status(3, 2));
    }
}

test "node: a stale-term request never persists, truncates, appends or applies" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    const requests = [_]Message{ fixtures.vote_request(2, 1, 2), fixtures.heartbeat(3, 1, 1) };
    for (requests) |message| {
        const effects = try rig.receive(&message);
        // A reply (send) is allowed; no durable or applied change is.
        for ([_]std.meta.Tag(Effect){ .save_hard_state, .truncate, .append, .apply }) |tag| {
            try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, tag));
        }
        try fixtures.expect_effects_ordered(effects, config);
        try expect_unchanged(&rig, quiet_status(3, 2));
    }
}

test "node: a higher-term message from an unknown sender is not an error and not adopted" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    const message = fixtures.vote_response(9, 1, 8, false);
    const effects = try rig.receive(&message);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
    try expect_unchanged(&rig, quiet_status(3, 2));
}

test "node: a message addressed to another node is StepMisrouted and mutates nothing" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    // Higher term and valid in every other way: only the destination is wrong.
    const message = fixtures.vote_response(2, 3, 8, false);
    try testing.expectError(error.StepMisrouted, rig.receive(&message));
    try expect_unchanged(&rig, quiet_status(3, 2));
}

const Rejected = struct { message: Message, expected: anyerror };

const gap_entries = [_]Entry{entry(2, 1, "")};
const future_entries = [_]Entry{entry(1, 4, "")};
const fat_entries = [_]Entry{entry(1, 1, "z" ** 33)};
// One more entry than `message_limits.entries_max`, each contiguous and in term.
const over_count = [_]Entry{
    entry(1, 1, ""), entry(2, 1, ""), entry(3, 1, ""), entry(4, 1, ""), entry(5, 1, ""),
};

fn rej(message: Message, expected: anyerror) Rejected {
    return .{ .message = message, .expected = expected };
}

fn with_entries(term_value: u64, entries: []const Entry) Message {
    var message = fixtures.heartbeat(2, 1, term_value);
    message.append_entries.entries = entries;
    return message;
}

/// One message per `MessageError` shape `Message.validate` can name for the fixture limits.
fn rejected_messages() [12]Rejected {
    var bad_version = fixtures.vote_response(2, 1, 5, false);
    bad_version.request_vote_response.header.protocol_version = 0;
    var future_version = fixtures.vote_response(2, 1, 5, false);
    future_version.request_vote_response.header.protocol_version = 2;
    var no_position = fixtures.vote_request(2, 1, 5);
    no_position.request_vote.last_log_term = term(2);
    const no_snapshot: Message = .{ .install_snapshot = .{
        .header = fixtures.header_of(2, 1, 5),
        .snapshot = .{ .index = .zero, .term = term(1), .data = "" },
        .configuration = fixtures.configuration,
    } };
    var bad_conflict = fixtures.append_response(2, 1, 5);
    bad_conflict.append_entries_response.outcome = .{
        .rejected = .{ .index = idx(1), .term = .zero },
    };
    return .{
        rej(bad_version, error.MessageVersionUnsupported),
        rej(future_version, error.MessageVersionUnsupported),
        rej(fixtures.vote_response(2, 1, 0, false), error.MessageTermZero),
        rej(fixtures.vote_response(0, 1, 5, false), error.MessageNodeInvalid),
        rej(fixtures.vote_response(1, 1, 5, false), error.MessageNodeInvalid),
        rej(no_position, error.MessageLogPositionInvalid),
        rej(with_entries(5, &gap_entries), error.MessageEntriesNotContiguous),
        rej(with_entries(3, &future_entries), error.MessageEntryTermInvalid),
        rej(with_entries(5, &over_count), error.MessageTooLarge),
        rej(with_entries(5, &fat_entries), error.MessageTooLarge),
        rej(no_snapshot, error.MessageSnapshotInvalid),
        rej(bad_conflict, error.MessageConflictInvalid),
    };
}

test "node: a message failing validation against message_limits returns its error unchanged" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    for (rejected_messages()) |case| {
        try testing.expectError(case.expected, rig.receive(&case.message));
        try expect_unchanged(&rig, quiet_status(3, 2));
    }
}

test "node: a snapshot message with an empty voter set returns the Conf error unchanged" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    var message: Message = .{ .install_snapshot = .{
        .header = fixtures.header_of(2, 1, 5),
        .snapshot = .{ .index = idx(1), .term = term(1), .data = "" },
        .configuration = fixtures.configuration,
    } };
    message.install_snapshot.configuration.voters = &.{};
    try testing.expectError(error.ConfVotersEmpty, rig.receive(&message));
    try expect_unchanged(&rig, quiet_status(3, 2));
}

test "node: ticks before the election timeout can fire emit nothing and never fail" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    // The timeout is drawn from [t, 2t), so t - 1 ticks cannot reach it.
    for (0..config.election_ticks - 1) |_| {
        const effects = try rig.node.step(.tick);
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try expect_unchanged(&rig, quiet_status(3, 2));
    }
}

test "node: a proposal to a node that is not leader is ProposeNotLeader and mutates nothing" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, 1);
    defer rig.deinit(testing.allocator);

    try testing.expectError(error.ProposeNotLeader, rig.node.step(.{ .propose = "cmd" }));
    try expect_unchanged(&rig, quiet_status(3, 2));
    try testing.expectError(error.ProposeNotLeader, rig.node.step(.{ .propose = "" }));
    try expect_unchanged(&rig, quiet_status(3, 2));
}

test "node: stepping down from a corrupted candidate or leader role ends as a follower" {
    const Poke = struct { role: node_module.Role, leader: u64 };
    const pokes = [_]Poke{
        .{ .role = .candidate, .leader = 0 },
        .{ .role = .leader, .leader = 1 },
    };
    for (pokes) |poke| {
        var rig: Rig = undefined;
        try rig.init(testing.allocator, config, &quiet_restore, 1);
        defer rig.deinit(testing.allocator);

        rig.node.role = poke.role;
        rig.node.leader = node_id(poke.leader);
        const message = fixtures.vote_response(2, 1, 6, false);
        const effects = try rig.receive(&message);
        const status = rig.node.status();
        try testing.expectEqual(node_module.Role.follower, status.role);
        try testing.expectEqual(term(6), status.term);
        try testing.expectEqual(types.NodeId.none, status.vote);
        try testing.expectEqual(types.NodeId.none, status.leader);
        try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .save_hard_state));
        // `leader_changed` is emitted exactly when the leader actually changed.
        const changed: u32 = if (poke.leader == 0) 0 else 1;
        try testing.expectEqual(changed, fixtures.count_effects(effects, .leader_changed));
        for (effects.items) |effect| switch (effect) {
            .leader_changed => |leader| try testing.expectEqual(types.NodeId.none, leader),
            else => {},
        };
        try fixtures.expect_effects_ordered(effects, config);
        try rig.node.check_invariants();
    }
}

fn describe_step_error(err: node_module.StepError) u8 {
    return switch (err) {
        error.ConfVotersEmpty,
        error.ConfVotersTooMany,
        error.ConfLearnersTooMany,
        error.ConfNodesUnsorted,
        error.ConfLearnerIsVoter,
        error.ConfJointShape,
        => 0,
        error.MessageVersionUnsupported,
        error.MessageTermZero,
        error.MessageNodeInvalid,
        error.MessageLogPositionInvalid,
        error.MessageEntriesNotContiguous,
        error.MessageEntryTermInvalid,
        error.MessageTooLarge,
        error.MessageSnapshotInvalid,
        error.MessageConflictInvalid,
        => 1,
        error.StepMisrouted => 2,
        error.ProposeNotLeader, error.ProposeTooLarge, error.ProposeLogFull => 3,
    };
}

test "node: StepError is exhaustively switchable and tick is not part of it" {
    try testing.expectEqual(@as(u8, 2), describe_step_error(error.StepMisrouted));
    try testing.expectEqual(@as(u8, 3), describe_step_error(error.ProposeLogFull));
    try testing.expectEqual(@as(u8, 1), describe_step_error(error.MessageTooLarge));
    try testing.expectEqual(@as(u8, 0), describe_step_error(error.ConfJointShape));
}

/// The trivial reference: a follower's term and vote are all the skeleton can change.
const Model = struct {
    term: u64,
    vote: u64,

    fn status(model: *const Model) Status {
        return quiet_status(model.term, model.vote);
    }
};

const Draw = struct { message: Message, expected: ?anyerror, adopts: bool };

fn draw_message(random: std.Random, model: *const Model) Draw {
    const senders = [_]u64{ 2, 3, 9 };
    const from = senders[random.uintLessThan(u32, senders.len)];
    const to: u64 = if (random.uintLessThan(u32, 10) == 0) 2 else 1;
    const zero_term = random.uintLessThan(u32, 12) == 0;
    const message_term = if (zero_term) 0 else random.intRangeAtMost(u64, 1, model.term + 3);
    const granted = random.boolean();
    const message = if (random.boolean())
        fixtures.vote_response(from, to, message_term, granted)
    else
        fixtures.append_response(from, to, message_term);
    var expected: ?anyerror = null;
    if (zero_term) expected = error.MessageTermZero;
    // `validate` runs before the destination check, and it rejects `from == to` (node 2 to 2).
    if (!zero_term and to != 1) expected = if (from == to)
        error.MessageNodeInvalid
    else
        error.StepMisrouted;
    const adopts = expected == null and from != 9 and message_term > model.term;
    return .{ .message = message, .expected = expected, .adopts = adopts };
}

fn stream_step(rig: *Rig, model: *Model, random: std.Random, ticks_left: *u32) !void {
    if (ticks_left.* > 0 and random.uintLessThan(u32, 8) == 0) {
        ticks_left.* -= 1;
        const effects = try rig.node.step(.tick);
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        return;
    }
    const draw = draw_message(random, model);
    if (draw.expected) |expected| {
        try testing.expectError(expected, rig.receive(&draw.message));
        return;
    }
    const effects = try rig.receive(&draw.message);
    try fixtures.expect_effects_ordered(effects, config);
    if (!draw.adopts) return try testing.expectEqual(@as(usize, 0), effects.items.len);
    model.term = @intFromEnum(draw.message.header().term);
    model.vote = 0;
    const saved = try fixtures.only_hard_state(effects);
    try testing.expectEqual(fixtures.hard_state_of(model.term, 0, 0), saved);
    try testing.expectEqual(@as(usize, 1), effects.items.len);
}

fn stream_run(gpa: std.mem.Allocator, seed: u64, steps: u32) !void {
    var rig: Rig = undefined;
    try rig.init(gpa, config, &quiet_restore, seed);
    defer rig.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(seed);
    var model: Model = .{ .term = 3, .vote = 2 };
    var ticks_left: u32 = config.election_ticks - 1;
    for (0..steps) |step_number| {
        errdefer std.log.err("raft node stream failed: seed={d} step={d}", .{ seed, step_number });
        try stream_step(&rig, &model, prng.random(), &ticks_left);
        try expect_unchanged(&rig, model.status());
    }
}

test "node: seeded input streams match the term/vote reference after every step" {
    for (0..24) |seed| try stream_run(testing.allocator, seed, 200);
}

test "node: step never allocates, so a stream runs under an allocator that fails after init" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    try stream_run(counting.allocator(), 7, 0);
    const init_allocations = counting.alloc_index;
    try testing.expect(init_allocations >= 3);

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = init_allocations,
    });
    try stream_run(failing.allocator(), 7, 400);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(init_allocations, failing.alloc_index);
}

fn fuzz_message(smith: *testing.Smith, entries: []Entry) Message {
    const from = smith.valueRangeAtMost(u64, 0, 4);
    const to = smith.valueRangeAtMost(u64, 0, 4);
    const message_term = smith.valueRangeAtMost(u64, 0, 9);
    switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => return fixtures.vote_response(from, to, message_term, smith.value(bool)),
        1 => return fixtures.append_response(from, to, message_term),
        2 => return fixtures.vote_request(from, to, message_term),
        else => {
            var message = fixtures.heartbeat(from, to, message_term);
            const count = smith.valueRangeAtMost(u32, 0, 5);
            const first = smith.valueRangeAtMost(u64, 0, 3);
            for (entries[0..count], 0..) |*slot, i| {
                slot.* = entry(first + @as(u64, i) + 1, smith.valueRangeAtMost(u64, 0, 9), "ab");
            }
            message.append_entries.entries = entries[0..count];
            message.append_entries.prev_log_index = idx(first);
            message.append_entries.prev_log_term = term(if (first == 0) 0 else 1);
            return message;
        },
    }
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &quiet_restore, smith.value(u64));
    defer rig.deinit(testing.allocator);

    for (0..64) |_| {
        if (smith.eos()) break;
        const before = rig.node.status();
        var entries: [5]Entry = undefined;
        const message = fuzz_message(smith, &entries);
        const input: node_module.Input = switch (smith.valueRangeAtMost(u8, 0, 5)) {
            0 => .tick,
            1 => .{ .propose = "ab" },
            else => .{ .message = &message },
        };
        if (rig.node.step(input)) |effects| {
            try fixtures.expect_effects_ordered(effects, config);
        } else |err| {
            _ = describe_step_error(err); // Exhaustive: any new variant is handled above.
            try testing.expectEqual(before, rig.node.status());
        }
        try rig.node.check_invariants();
    }
}

test "node: fuzzed inputs keep every invariant and leave errors without mutation" {
    try testing.fuzz({}, fuzz_one, .{});
}
