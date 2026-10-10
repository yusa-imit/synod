//! Tests for the leader response side of `Node` (plan 003 item 2B-i-b): an
//! `append_entries_response` is matched to the sender's slot and a live round record by its
//! echoed round id, `accepted` feeds `Progress.on_accepted` after a range check against our own
//! record, `rejected` backs `next` up in one round trip, and every stale, duplicate, foreign or
//! out-of-range response is dropped without touching any state.
//!
//! Expected values come from the Raft thesis (§3.5 log matching and fast backtracking), the
//! `progress.zig` contracts and the plan's Verify lines, never from `leader.zig`. Round ids are
//! read from the sent messages; the one implementation fact assumed is the documented record
//! layout of `leader.zig`: a slot's live records are the first `inflight_count` entries of its
//! `inflight_max` records, oldest first, so slot 0 (node 2) starts at `rounds.records[0]`.
//! Timing contract added by this item: a probing peer's oldest round times out after
//! `heartbeat_ticks` leader ticks, a replicating peer's after `election_ticks`.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const leader_module = @import("leader.zig");
const node_module = @import("node.zig");
const progress_module = @import("progress.zig");
const types = @import("../types.zig");

const AppendRequest = types.AppendRequest;
const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;
const Progress = progress_module.Progress;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;
const Round = leader_module.Round;

const config = fixtures.config;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

const low: u64 = 0; // election timeout t = 10
const window: u32 = 4; // config.inflight_max

const fresh = fixtures.restore_of(.empty, &.{});
/// Term 3, commit 2, log terms 1, 2, 3: a winner campaigns at term 4 with `prev` (3, 3).
const logged = fixtures.restore_of(fixtures.hard_state_of(3, 0, 2), &fixtures.base_entries);
const learner_ids = [_]types.NodeId{node_id(4)};
const with_learner = fixtures.restore_with(
    .{ .voters = &fixtures.voters, .voters_outgoing = &.{}, .learners = &learner_ids },
    .empty,
    &.{},
);
const config_two: Config = blk: {
    var c = fixtures.config;
    c.inflight_max = 2;
    break :blk c;
};

// ---- helpers -------------------------------------------------------------------------------

fn tick(rig: *Rig) !Effects {
    const effects = try rig.node.step(.tick);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

fn recv(rig: *Rig, message: Message) !Effects {
    const effects = try rig.receive(&message);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

fn propose(rig: *Rig, data: []const u8) !Effects {
    const effects = try rig.node.step(.{ .propose = data });
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

/// A response from `from` to node 1 for `round`, at `at_term`, accepting through `matched`.
fn accepted(from: u64, round: u64, at_term: u64, matched: u64) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, at_term),
        .round = round,
        .outcome = .{ .accepted = idx(matched) },
    } };
}

/// Like `accepted`, but rejecting with the follower's conflict hint (index, term).
fn rejected(from: u64, round: u64, at_term: u64, conflict_index: u64, conflict_term: u64) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, at_term),
        .round = round,
        .outcome = .{ .rejected = .{ .index = idx(conflict_index), .term = term(conflict_term) } },
    } };
}

/// Ticks a follower to a pre-candidate, grants pre-votes then votes from nodes 2.. of a
/// three-voter set until it leads, and returns the winning step's effects.
fn elect(rig: *Rig) !Effects {
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try tick(rig);
    }
    const would_be = @intFromEnum(rig.node.status().term) + 1;
    _ = try recv(rig, fixtures.pre_vote_response(2, 1, would_be, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    const at = @intFromEnum(rig.node.status().term);
    const effects = try recv(rig, fixtures.vote_response(2, 1, at, true));
    try testing.expectEqual(Role.leader, rig.node.status().role);
    return effects;
}

/// The `append_entries` sends of `effects` in order; any other kind of send fails the test.
fn appends(effects: Effects, out: []AppendRequest) ![]AppendRequest {
    var count: usize = 0;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries => |request| {
                try testing.expect(count < out.len);
                out[count] = request;
                count += 1;
            },
            else => return error.TestUnexpectedResult,
        },
        else => {},
    };
    return out[0..count];
}

fn request_to(requests: []const AppendRequest, to: u64) !AppendRequest {
    var found: ?AppendRequest = null;
    for (requests) |request| {
        if (request.header.to != node_id(to)) continue;
        try testing.expect(found == null); // One request per peer per step.
        found = request;
    }
    return found orelse error.TestUnexpectedResult;
}

/// The round id of the `append_entries` to `to` in `effects`.
fn round_to(effects: Effects, to: u64) !u64 {
    var buffer: [4]AppendRequest = undefined;
    return (try request_to(try appends(effects, &buffer), to)).round;
}

/// The only send in `effects`, an `append_entries` to `to`.
fn sole_append(effects: Effects, to: u64) !AppendRequest {
    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(effects, &buffer);
    try testing.expectEqual(@as(usize, 1), requests.len);
    return request_to(requests, to);
}

fn expect_none(effects: Effects) !void {
    try testing.expectEqual(@as(usize, 0), effects.items.len);
}

fn expect_batch(request: AppendRequest, prev: u64, prev_term: u64, want: []const Entry) !void {
    try testing.expectEqual(idx(prev), request.prev_log_index);
    try testing.expectEqual(term(prev_term), request.prev_log_term);
    try fixtures.expect_entries_equal(want, request.entries);
}

/// Log entries `first..=last` of a leader log made of the term-1 empty entry and `"x"` proposals.
fn log_range(buffer: []Entry, first: u64, last: u64) []const Entry {
    for (buffer[0 .. last - first + 1], first..) |*slot, index| {
        slot.* = fixtures.entry(index, 1, if (index == 1) "" else "x");
    }
    return buffer[0 .. last - first + 1];
}

fn peers(rig: *Rig) []Progress {
    const slots = fixtures.leader_progress(&rig.node);
    std.debug.assert(slots.len == 2);
    return slots;
}

/// Puts both peers in `.replicate` with an empty window, as if each had acknowledged `match`.
fn replicate_all(rig: *Rig, match: u64, next: u64) !void {
    for (peers(rig)) |*slot| {
        slot.state = .replicate;
        slot.match = idx(match);
        slot.next = idx(next);
        slot.inflight_count = 0;
    }
    try rig.node.check_invariants();
}

/// Everything a dropped response must leave alone: role, term, log, trackers and round records.
const Snap = struct {
    status: node_module.Status,
    count: usize,
    live: usize,
    slots: [2]Progress,
    records: [8]Round,
    id_next: u64,
    ticks: u64,
};

fn snap(rig: *Rig) Snap {
    var result: Snap = undefined;
    const live = fixtures.leader_progress(&rig.node);
    result.status = rig.node.status();
    result.count = rig.node.entries().len;
    result.live = live.len;
    result.slots = .{ Progress.init(.zero, 1), Progress.init(.zero, 1) };
    for (live, 0..) |slot, i| result.slots[i] = slot;
    @memset(&result.records, Round.empty);
    const records = rig.node.rounds.records;
    for (records[0..@min(records.len, 8)], 0..) |record, i| result.records[i] = record;
    result.id_next = rig.node.rounds.id_next;
    result.ticks = rig.node.rounds.ticks;
    return result;
}

fn expect_unchanged(rig: *Rig, before: Snap) !void {
    try testing.expectEqual(before, snap(rig));
}

/// Delivers `message` and requires that nothing at all happened: no effect, no state change.
fn expect_dropped(rig: *Rig, message: Message) !void {
    const before = snap(rig);
    try expect_none(try recv(rig, message));
    try expect_unchanged(rig, before);
}

/// A leader of the three-voter rig after its election, both peers replicating at `match` 1 with
/// two proposals in flight to each: round `a` (prev 1, last 2) and round `b` (prev 2, last 3).
const Pipeline = struct { a2: u64, b2: u64, a3: u64, b3: u64 };

fn pipeline(rig: *Rig) !Pipeline {
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    _ = try elect(rig);
    try replicate_all(rig, 1, 2);
    // Effects are borrowed from the node and overwritten by the next step: read them at once.
    const first = try propose(rig, "x");
    const a2 = try round_to(first, 2);
    const a3 = try round_to(first, 3);
    const second = try propose(rig, "x");
    return .{
        .a2 = a2,
        .a3 = a3,
        .b2 = try round_to(second, 2),
        .b3 = try round_to(second, 3),
    };
}

// ---- accepted -------------------------------------------------------------------------------

test "response: accepting the election round raises match, starts replicating, sends nothing" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig);
    const r2 = try round_to(won, 2);

    try expect_none(try recv(&rig, accepted(2, r2, 1, 1)));
    const slot = peers(&rig)[0];
    try testing.expectEqual(idx(1), slot.match);
    try testing.expectEqual(idx(2), slot.next);
    try testing.expectEqual(progress_module.State.replicate, slot.state);
    try testing.expectEqual(@as(u32, 0), slot.inflight_count);
    const other = peers(&rig)[1]; // Node 3 has not answered: still probing its one round.
    try testing.expectEqual(idx(0), other.match);
    try testing.expectEqual(progress_module.State.probe, other.state);
    try testing.expectEqual(@as(u32, 1), other.inflight_count);
}

test "response: an accepted answer frees the probe window and sends queued proposals" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2);
    for (0..3) |_| _ = try propose(&rig, "x"); // Log 1..4, every peer's window is full.

    const effects = try recv(&rig, accepted(2, r2, 1, 1));
    const request = try sole_append(effects, 2);
    var entries: [4]Entry = undefined;
    try expect_batch(request, 1, 1, log_range(&entries, 2, 4));
    try testing.expect(request.round != r2);
    try testing.expectEqual(idx(1), peers(&rig)[0].match);
    try testing.expectEqual(idx(5), peers(&rig)[0].next);
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
    try testing.expectEqual(@as(u32, 1), peers(&rig)[1].inflight_count); // Node 3 unaffected.
}

test "response: freeing one slot of a full window sends only the entries not yet sent" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config_two, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig);
    try replicate_all(&rig, 1, 2);
    const first = try round_to(try propose(&rig, "x"), 2); // prev 1, entry 2
    _ = try propose(&rig, "x"); // prev 2, entry 3: the window is full.
    const queued = try propose(&rig, "x"); // Log 1..4: only the append effect.
    try testing.expectEqual(@as(usize, 1), queued.items.len);
    try testing.expectEqual(@as(u32, 2), peers(&rig)[0].inflight_count);

    const request = try sole_append(try recv(&rig, accepted(2, first, 1, 2)), 2);
    var entries: [4]Entry = undefined;
    try expect_batch(request, 3, 1, log_range(&entries, 4, 4));
    const slot = peers(&rig)[0];
    try testing.expectEqual(idx(2), slot.match);
    try testing.expectEqual(idx(5), slot.next);
    try testing.expectEqual(@as(u32, 2), slot.inflight_count);
    try testing.expectEqual(@as(u32, 2), peers(&rig)[1].inflight_count); // Node 3 never answered.
}

fn answer_in_order(first_is_a: bool) !void {
    var rig: Rig = undefined;
    const p = try pipeline(&rig);
    defer rig.deinit(testing.allocator);
    const records = rig.node.rounds.records;

    const early = if (first_is_a) p.a2 else p.b2;
    const late = if (first_is_a) p.b2 else p.a2;
    const early_matched: u64 = if (first_is_a) 2 else 3;
    const late_matched: u64 = if (first_is_a) 3 else 2;
    try expect_none(try recv(&rig, accepted(2, early, 1, early_matched)));
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
    try testing.expectEqual(late, records[0].id); // The survivor moved to the front.
    try testing.expectEqual(idx(early_matched), peers(&rig)[0].match);

    try expect_none(try recv(&rig, accepted(2, late, 1, late_matched)));
    try testing.expectEqual(@as(u32, 0), peers(&rig)[0].inflight_count);
    try testing.expectEqual(idx(3), peers(&rig)[0].match); // Never lowered by the older answer.
    try testing.expectEqual(@as(u32, 2), peers(&rig)[1].inflight_count); // Node 3 untouched.
    try testing.expectEqual(p.a3, records[window].id);
    try testing.expectEqual(p.b3, records[window + 1].id);
}

test "response: answers in either order keep the slot's live records consistent" {
    try answer_in_order(true);
    try answer_in_order(false);
}

test "response: a duplicate of an answered round is dropped and does not free a second slot" {
    var rig: Rig = undefined;
    const p = try pipeline(&rig);
    defer rig.deinit(testing.allocator);

    try expect_none(try recv(&rig, accepted(2, p.a2, 1, 2)));
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
    try expect_dropped(&rig, accepted(2, p.a2, 1, 2));
    try expect_dropped(&rig, accepted(2, p.a2, 1, 3)); // Even with a different claim.
    try expect_dropped(&rig, rejected(2, p.a2, 1, 1, 1));
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
    try testing.expectEqual(idx(2), peers(&rig)[0].match);
}

test "response: unknown round ids and another peer's round id are dropped" {
    var rig: Rig = undefined;
    const p = try pipeline(&rig);
    defer rig.deinit(testing.allocator);

    try expect_dropped(&rig, accepted(2, 0, 1, 2)); // 0 is never issued.
    try expect_dropped(&rig, accepted(2, 9999, 1, 2));
    try expect_dropped(&rig, accepted(2, std.math.maxInt(u64), 1, 2));
    try expect_dropped(&rig, accepted(2, p.a3, 1, 2)); // Node 3's round, claimed by node 2.
    try expect_dropped(&rig, rejected(3, p.b2, 1, 1, 1)); // And the other way round.
}

test "response: matched outside the recorded prev..last_sent is dropped and the round stays live" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig);
    try replicate_all(&rig, 1, 2);
    const round = try round_to(try propose(&rig, "x"), 2); // prev 1, last_sent 2

    try expect_dropped(&rig, accepted(2, round, 1, 0)); // Below prev.
    try expect_dropped(&rig, accepted(2, round, 1, 3)); // Above last_sent.
    try expect_dropped(&rig, accepted(2, round, 1, std.math.maxInt(u64)));
    try expect_none(try recv(&rig, accepted(2, round, 1, 2))); // The record was untouched.
    try testing.expectEqual(idx(2), peers(&rig)[0].match);
    try testing.expectEqual(@as(u32, 0), peers(&rig)[0].inflight_count);

    const second = try round_to(try propose(&rig, "x"), 2); // prev 2, last_sent 3
    try expect_none(try recv(&rig, accepted(2, second, 1, 2))); // matched == prev is valid.
    try testing.expectEqual(idx(2), peers(&rig)[0].match);
    try testing.expectEqual(@as(u32, 0), peers(&rig)[0].inflight_count);
}

// ---- rejected -------------------------------------------------------------------------------

test "response: a rejection backs next up to the conflict run and resends in one round trip" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig); // Term 4, log 1..4, election send prev 3.
    const r2 = try round_to(won, 2);

    // Node 2's log diverges from index 2: it answers with the first index of its conflicting run.
    const request = try sole_append(try recv(&rig, rejected(2, r2, 4, 2, 1)), 2);
    const base = fixtures.base_entries;
    const want = [_]Entry{ base[1], base[2], fixtures.entry(4, 4, "") };
    try expect_batch(request, 1, 1, &want);
    try testing.expect(request.round != r2);
    try testing.expect(request.round != try round_to(won, 3));
    const slot = peers(&rig)[0];
    try testing.expectEqual(idx(2), slot.next);
    try testing.expectEqual(idx(0), slot.match);
    try testing.expectEqual(progress_module.State.probe, slot.state);
    try testing.expectEqual(@as(u32, 1), slot.inflight_count);
    try testing.expectEqual(@as(u32, 1), peers(&rig)[1].inflight_count); // Node 3 untouched.

    try expect_dropped(&rig, accepted(2, r2, 4, 3)); // The rejected round is gone for good.
    try expect_none(try recv(&rig, accepted(2, request.round, 4, 4)));
    try testing.expectEqual(idx(4), peers(&rig)[0].match);
    try testing.expectEqual(progress_module.State.replicate, peers(&rig)[0].state);
}

test "response: a shorter follower log (no conflict hint) backs next up by exactly one entry" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2); // Election send prev 3, next 4.

    const request = try sole_append(try recv(&rig, rejected(2, r2, 4, 0, 0)), 2);
    const want = [_]Entry{ fixtures.base_entries[2], fixtures.entry(4, 4, "") };
    try expect_batch(request, 2, 2, &want);
    try testing.expectEqual(idx(3), peers(&rig)[0].next);
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
}

test "response: a stale rejection removes only its record, a live one discards the window" {
    var rig: Rig = undefined;
    const p = try pipeline(&rig);
    defer rig.deinit(testing.allocator);
    const third = try round_to(try propose(&rig, "x"), 2); // Round c: prev 3, last 4.
    const records = rig.node.rounds.records;

    // Round a (prev 1) is not above match 1: stale. Only its record goes; b and c shift down.
    try expect_none(try recv(&rig, rejected(2, p.a2, 1, 1, 1)));
    var slot = peers(&rig)[0];
    try testing.expectEqual(@as(u32, 2), slot.inflight_count);
    try testing.expectEqual(progress_module.State.replicate, slot.state);
    try testing.expectEqual(idx(5), slot.next);
    try testing.expectEqual(p.b2, records[0].id);
    try testing.expectEqual(third, records[1].id);

    // Round b (prev 2) is a live rejection: the whole window goes, resend from the hint.
    const request = try sole_append(try recv(&rig, rejected(2, p.b2, 1, 2, 1)), 2);
    var entries: [4]Entry = undefined;
    try expect_batch(request, 1, 1, log_range(&entries, 2, 4));
    slot = peers(&rig)[0];
    try testing.expectEqual(idx(2), slot.next);
    try testing.expectEqual(progress_module.State.probe, slot.state);
    try testing.expectEqual(@as(u32, 1), slot.inflight_count);
    try testing.expectEqual(request.round, records[0].id);

    try expect_dropped(&rig, accepted(2, third, 1, 4)); // Round c died with its window.
    try expect_none(try recv(&rig, accepted(2, request.round, 1, 4)));
    try testing.expectEqual(idx(4), peers(&rig)[0].match);
}

// ---- joint configuration and stale probe rejections ------------------------------------------

const outgoing_ids = [_]types.NodeId{ node_id(1), node_id(2), node_id(4) };
/// Incoming {1, 2, 3}, outgoing {1, 2, 4}: node 4 is an outgoing-only voter, slot 2 (after nodes
/// 2 and 3), and nodes 1 and 2 alone form a quorum of both sets.
const joint = fixtures.restore_with(
    .{ .voters = &fixtures.voters, .voters_outgoing = &outgoing_ids, .learners = &.{} },
    .empty,
    &.{},
);

const Joint = struct {
    slots: [3]Progress,
    records: [3 * window]Round,
    id_next: u64,
    ticks: u64,
};

fn joint_snap(rig: *Rig) Joint {
    const live = fixtures.leader_progress(&rig.node);
    std.debug.assert(live.len == 3);
    var result: Joint = undefined;
    @memcpy(&result.slots, live);
    @memcpy(&result.records, rig.node.rounds.records[0 .. 3 * window]);
    result.id_next = rig.node.rounds.id_next;
    result.ticks = rig.node.rounds.ticks;
    return result;
}

/// Delivers `message` to a joint rig and requires no effect and no change to any slot or record.
fn expect_joint_dropped(rig: *Rig, message: Message) !void {
    const before = joint_snap(rig);
    try expect_none(try recv(rig, message));
    try testing.expectEqual(before, joint_snap(rig));
}

/// Slots 0 and 1 (nodes 2 and 3) and their records are exactly as in `before`.
fn expect_incoming_untouched(rig: *Rig, before: Joint) !void {
    const after = joint_snap(rig);
    try testing.expectEqualSlices(Progress, before.slots[0..2], after.slots[0..2]);
    const used = 2 * window;
    try testing.expectEqualSlices(Round, before.records[0..used], after.records[0..used]);
}

test "response: an outgoing-only voter's accepted and rejected answers touch only its own slot" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &joint, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig);
    const r4 = try round_to(won, 4);
    try testing.expectEqual(@as(usize, 3), fixtures.leader_progress(&rig.node).len);

    var before = joint_snap(&rig);
    try expect_none(try recv(&rig, accepted(4, r4, 1, 1)));
    try expect_incoming_untouched(&rig, before);
    var own = fixtures.leader_progress(&rig.node)[2];
    try testing.expectEqual(idx(1), own.match);
    try testing.expectEqual(idx(2), own.next);
    try testing.expectEqual(progress_module.State.replicate, own.state);
    try testing.expectEqual(@as(u32, 0), own.inflight_count);

    // Two proposals reach only node 4: nodes 2 and 3 still probe with a full window.
    const first = try round_to(try propose(&rig, "x"), 4); // prev 1, last 2
    const second = try round_to(try propose(&rig, "x"), 4); // prev 2, last 3
    try testing.expect(first != second);
    before = joint_snap(&rig);
    try testing.expectEqual(@as(u32, 2), before.slots[2].inflight_count);

    // Node 4 lacks index 3: round `second` (prev 2 > match 1, below next 4) is a live rejection.
    const request = try sole_append(try recv(&rig, rejected(4, second, 1, 2, 1)), 4);
    var entries: [4]Entry = undefined;
    try expect_batch(request, 1, 1, log_range(&entries, 2, 3));
    try expect_incoming_untouched(&rig, before);
    own = fixtures.leader_progress(&rig.node)[2];
    try testing.expectEqual(idx(1), own.match);
    try testing.expectEqual(idx(2), own.next);
    try testing.expectEqual(progress_module.State.probe, own.state);
    try testing.expectEqual(@as(u32, 1), own.inflight_count);
    try testing.expectEqual(request.round, rig.node.rounds.records[2 * window].id);

    try expect_joint_dropped(&rig, accepted(4, first, 1, 2)); // Died with the discarded window.
    try expect_none(try recv(&rig, accepted(4, request.round, 1, 3)));
    try testing.expectEqual(idx(3), fixtures.leader_progress(&rig.node)[2].match);
    try expect_incoming_untouched(&rig, before);
}

// A rejection whose recorded `prev` is at or above `next` (or, while probing, not `next - 1`)
// is unreachable through the node: `next` only drops on a live rejection or a timeout, and both
// discard every record, a probing peer holds at most one record sent at `next - 1`, and a
// replicating peer's `next` is `last_sent + 1` of its newest record. Only direct edits of the
// tracker could build it, so no node-level test is possible.

test "response: a probe rejection at or below match is dropped from the window alone" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2);
    _ = try recv(&rig, accepted(2, r2, 1, 1)); // match 1, replicating.

    // No answers: the replicating window times out and the peer is probed again at prev == match.
    var probe: ?u64 = null;
    var ticks: u32 = 0;
    while (probe == null) : (ticks += 1) {
        try testing.expect(ticks < 2 * config.election_ticks);
        var buffer: [4]AppendRequest = undefined;
        const requests = try appends(try tick(&rig), &buffer);
        if (peers(&rig)[0].state != .probe) continue;
        for (requests) |request| {
            if (request.header.to != node_id(2)) continue;
            try testing.expectEqual(idx(1), request.prev_log_index);
            probe = request.round;
        }
    }
    var slot = peers(&rig)[0];
    try testing.expectEqual(@as(u32, 1), slot.inflight_count);
    try testing.expectEqual(idx(1), slot.match);
    try testing.expectEqual(idx(2), slot.next);
    const other = peers(&rig)[1];
    const id_next = rig.node.rounds.id_next;

    // The follower rejects the probe (prev 1 <= match 1): stale. Its record goes, nothing is sent.
    try expect_none(try recv(&rig, rejected(2, probe.?, 1, 1, 1)));
    slot = peers(&rig)[0];
    try testing.expectEqual(@as(u32, 0), slot.inflight_count);
    try testing.expectEqual(idx(2), slot.next);
    try testing.expectEqual(idx(1), slot.match);
    try testing.expectEqual(progress_module.State.probe, slot.state);
    try testing.expectEqual(id_next, rig.node.rounds.id_next);
    try testing.expectEqual(other, peers(&rig)[1]);

    // The record is gone: a repeat and a late accept are dropped, and the peer is re-probed.
    try expect_dropped(&rig, rejected(2, probe.?, 1, 1, 1));
    try expect_dropped(&rig, accepted(2, probe.?, 1, 1));
    var again: ?u64 = null;
    for (0..config.heartbeat_ticks) |_| {
        var buffer: [4]AppendRequest = undefined;
        for (try appends(try tick(&rig), &buffer)) |request| {
            if (request.header.to == node_id(2)) again = request.round;
        }
    }
    try testing.expect(again != null);
    try testing.expect(again.? != probe.?);
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
}

// ---- timeouts -------------------------------------------------------------------------------

test "response: an answer to a timed-out round never touches the new window" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const old = try round_to(try elect(&rig), 2);

    _ = try tick(&rig);
    _ = try tick(&rig);
    const resent = try tick(&rig); // Probe round unanswered for heartbeat_ticks: probed again.
    const fresh_round = try round_to(resent, 2);
    try testing.expect(fresh_round != old);

    try expect_dropped(&rig, accepted(2, old, 1, 1));
    try expect_dropped(&rig, rejected(2, old, 1, 0, 0));
    try testing.expectEqual(@as(u32, 1), peers(&rig)[0].inflight_count);
    try expect_none(try recv(&rig, accepted(2, fresh_round, 1, 1)));
    try testing.expectEqual(idx(1), peers(&rig)[0].match);
    try testing.expectEqual(progress_module.State.replicate, peers(&rig)[0].state);
}

test "response: a probing peer whose round was lost is re-probed within heartbeat_ticks" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig);
    const lost = try round_to(won, 3);
    // Node 2 is healthy; node 3 stays silent.
    _ = try recv(&rig, accepted(2, try round_to(won, 2), 1, 1));

    var buffer: [4]AppendRequest = undefined;
    var last = lost;
    var ticks: u32 = 0;
    while (ticks < 2 * config.heartbeat_ticks) : (ticks += 1) {
        const requests = try appends(try tick(&rig), &buffer);
        const at = ticks + 1;
        const probes = at == config.heartbeat_ticks or at == 2 * config.heartbeat_ticks;
        if (!probes) {
            for (requests) |request| try testing.expect(request.header.to != node_id(3));
            continue;
        }
        const request = try request_to(requests, 3);
        try testing.expect(request.round != last); // A new round every time, never a reused id.
        try testing.expectEqual(idx(0), request.prev_log_index);
        try testing.expectEqual(@as(usize, 1), request.entries.len);
        last = request.round;
    }
    try testing.expectEqual(Role.leader, rig.node.status().role);
    try expect_dropped(&rig, accepted(3, lost, 1, 1)); // The first round's late answer.
    try expect_none(try recv(&rig, accepted(3, last, 1, 1)));
    try testing.expectEqual(idx(1), peers(&rig)[1].match);
}

test "response: a replicating peer keeps the election_ticks timeout for its heartbeat rounds" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2);
    _ = try recv(&rig, accepted(2, r2, 1, 1));

    for (1..config.election_ticks) |t| {
        _ = try tick(&rig);
        const slot = peers(&rig)[0];
        try testing.expectEqual(progress_module.State.replicate, slot.state);
        const beats: u32 = @intCast(t / config.heartbeat_ticks);
        try testing.expectEqual(beats, slot.inflight_count);
    }
    _ = try tick(&rig); // Ticks 10-13: the round of tick 3 turns election_ticks old at tick 13.
    _ = try tick(&rig);
    _ = try tick(&rig);
    _ = try tick(&rig); // Tick 13.
    try testing.expectEqual(progress_module.State.probe, peers(&rig)[0].state);
    try testing.expectEqual(idx(1), peers(&rig)[0].match);
}

// ---- senders, terms, roles ------------------------------------------------------------------

test "response: a learner or a stranger cannot answer a round" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &with_learner, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig);
    const r2 = try round_to(won, 2);

    try expect_dropped(&rig, accepted(4, r2, 1, 1)); // Learner 4 has no slot.
    try expect_dropped(&rig, rejected(4, r2, 1, 1, 1));
    try expect_dropped(&rig, accepted(9, r2, 1, 1)); // Not in the cluster at all.
}

test "response: a lower-term answer is dropped even with a live round id" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2); // Term 4.

    try expect_dropped(&rig, accepted(2, r2, 3, 3));
    try expect_dropped(&rig, rejected(2, r2, 3, 2, 1));
    try testing.expectEqual(Role.leader, rig.node.status().role);
}

test "response: a higher-term answer deposes the leader and clears its progress" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const r2 = try round_to(try elect(&rig), 2);

    _ = try recv(&rig, accepted(2, r2, 2, 1));
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try testing.expectEqual(term(2), rig.node.status().term);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
    _ = try recv(&rig, rejected(2, r2, 3, 1, 1)); // And again from a follower: still no progress.
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
}

test "response: a follower or candidate drops an append answer without effect" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);
    const before = snap(&rig);
    try expect_none(try recv(&rig, accepted(2, 1, 3, 3))); // Follower at term 3.
    try expect_unchanged(&rig, before);

    for (0..config.election_ticks) |_| _ = try tick(&rig);
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 4, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    const as_candidate = snap(&rig);
    try expect_none(try recv(&rig, accepted(2, 1, 4, 3)));
    try expect_unchanged(&rig, as_candidate);
}

// ---- seeded model ---------------------------------------------------------------------------

const Live = struct { id: u64, prev: u64, last: u64 };

/// Reference for node 2 replicating: the oldest-first list of rounds sent and not yet answered,
/// built from observed sends, shrunk by each valid answer, and the highest match acknowledged.
const Model = struct {
    live: [window]Live = undefined,
    len: usize = 0,
    match: u64 = 1,
    answered: [64]u64 = undefined,
    answered_len: usize = 0,

    fn observe(model: *Model, effects: Effects) !void {
        var buffer: [4]AppendRequest = undefined;
        for (try appends(effects, &buffer)) |request| {
            if (request.header.to != node_id(2)) continue;
            try testing.expect(model.len < window);
            const prev = @intFromEnum(request.prev_log_index);
            const last = prev + request.entries.len;
            model.live[model.len] = .{ .id = request.round, .prev = prev, .last = last };
            model.len += 1;
        }
    }

    fn answer(model: *Model, at: usize, matched: u64) void {
        model.match = @max(model.match, matched);
        model.answered[model.answered_len] = model.live[at].id;
        model.answered_len += 1;
        const tail = model.live[at + 1 .. model.len];
        std.mem.copyForwards(Live, model.live[at .. model.len - 1], tail);
        model.len -= 1;
    }
};

fn run_model(seed: u64) !void {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig);
    try replicate_all(&rig, 1, 2);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var model: Model = .{};

    for (0..60) |_| {
        switch (random.uintLessThan(u8, 5)) {
            0 => if (propose(&rig, "x")) |effects| try model.observe(effects) else |err| {
                try testing.expectEqual(error.ProposeLogFull, err);
            },
            1, 2 => if (model.len > 0) {
                const at = random.uintLessThan(usize, model.len);
                const round = model.live[at];
                const matched = round.prev + random.uintAtMost(u64, round.last - round.prev);
                const effects = try recv(&rig, accepted(2, round.id, 1, matched));
                model.answer(at, matched);
                try model.observe(effects);
            },
            3 => if (model.len > 0) { // Out of range for a live round: dropped.
                const round = model.live[random.uintLessThan(usize, model.len)];
                try expect_dropped(&rig, accepted(2, round.id, 1, round.last + 1));
            },
            else => if (model.answered_len > 0) { // A duplicate of an answered round: dropped.
                const id = model.answered[random.uintLessThan(usize, model.answered_len)];
                try expect_dropped(&rig, accepted(2, id, 1, 2));
            },
        }
        const slot = peers(&rig)[0];
        try testing.expectEqual(@as(u32, @intCast(model.len)), slot.inflight_count);
        try testing.expectEqual(idx(model.match), slot.match);
        for (model.live[0..model.len], rig.node.rounds.records[0..model.len]) |want, got| {
            try testing.expectEqual(want.id, got.id);
            try testing.expectEqual(idx(want.prev), got.prev);
            try testing.expectEqual(idx(want.last), got.last_sent);
        }
    }
}

test "response model: answers, drops and refills match a reference list of live rounds" {
    for ([_]u64{ 1, 2, 0xdead, 0xbeef_cafe }) |seed| {
        run_model(seed) catch |err| {
            std.log.err("response model failed at seed {d}", .{seed});
            return err;
        };
    }
}
