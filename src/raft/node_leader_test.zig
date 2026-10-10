//! Tests for the leader send side of `Node` (plan 003 item 2B-i-a, ADR-007): the per-peer
//! `Progress` a new leader builds, the `append_entries` it sends on election, on `propose` and on
//! heartbeat ticks, the in-flight window, the timeout of an unanswered round, and the negative
//! space (non-leaders, stepping down, a lone voter, learners, rejected proposals).
//!
//! Expected values come from the Raft thesis (§3.5 replication, §5.4.2 the new leader's empty
//! entry), `progress.zig`'s documented rules and ADR-007's effect order, never from `node.zig`.
//! The response side (accepted/rejected rounds) is item 2B-i-b: here the peers never answer, so a
//! peer reaches `.replicate` only by `replicate_all` writing the node-owned tracker directly.
//!
//! Assumed hook (the only one): `Node.progress` (capacity fixed at `init`) and `Node.progress_len`,
//! read through `fixtures.leader_progress`, slot order = voters without self (slot 0 is node 2).
//! Timing contract: the election step is leader tick 0; a heartbeat falls on every
//! `heartbeat_ticks`-th leader tick (3, 6, ...); a round unanswered for `election_ticks` (10)
//! ticks is timed out, or for `heartbeat_ticks` (3) ticks while the peer is probing, so a probing
//! peer is re-probed at every heartbeat (tick 3, 6, ...) and a replicating one at tick 12.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const progress_module = @import("progress.zig");
const types = @import("../types.zig");

const AppendRequest = types.AppendRequest;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;
const Progress = progress_module.Progress;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const config = fixtures.config;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

const low: u64 = 0; // election timeout t = 10
const window: u32 = 4; // config.inflight_max
const batch_max: usize = 4; // config.message_limits.entries_max

const fresh = fixtures.restore_of(.empty, &.{});
/// Term 3, commit 2, log terms 1, 2, 3: a winner campaigns at term 4 with `prev` (3, 3).
const logged = fixtures.restore_of(fixtures.hard_state_of(3, 0, 2), &fixtures.base_entries);
const fresh5 = fixtures.restore_with(fixtures.configuration5, .empty, &.{});
const lone_voters = [_]types.NodeId{node_id(1)};
const lone = fixtures.restore_with(
    .{ .voters = &lone_voters, .voters_outgoing = &.{}, .learners = &.{} },
    .empty,
    &.{},
);
const learner_ids = [_]types.NodeId{node_id(4)};
const with_learner = fixtures.restore_with(
    .{ .voters = &fixtures.voters, .voters_outgoing = &.{}, .learners = &learner_ids },
    .empty,
    &.{},
);

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

/// Ticks a follower to a pre-candidate, grants pre-votes then votes from nodes 2.. of a
/// `cluster`-voter set until it leads, and returns the winning step's effects.
fn elect(rig: *Rig, cluster: u64) !Effects {
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try tick(rig);
    }
    const would_be = @intFromEnum(rig.node.status().term) + 1;
    var peer: u64 = 2;
    while (rig.node.status().role == .pre_candidate) : (peer += 1) {
        try testing.expect(peer <= cluster);
        _ = try recv(rig, fixtures.pre_vote_response(peer, 1, would_be, true));
    }
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    const at = @intFromEnum(rig.node.status().term);
    var effects: Effects = .{ .items = &.{} };
    peer = 2;
    while (rig.node.status().role == .candidate) : (peer += 1) {
        try testing.expect(peer <= cluster);
        effects = try recv(rig, fixtures.vote_response(peer, 1, at, true));
    }
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

fn count_appends(effects: Effects) u32 {
    var total: u32 = 0;
    for (effects.items) |effect| switch (effect) {
        .send => |message| total += @intFromBool(message == .append_entries),
        else => {},
    };
    return total;
}

const Want = struct {
    to: u64,
    term: u64,
    prev: u64,
    prev_term: u64,
    commit: u64 = 0,
    entries: []const Entry,
};

fn expect_request(request: AppendRequest, want: Want) !void {
    try testing.expectEqual(node_id(1), request.header.from);
    try testing.expectEqual(node_id(want.to), request.header.to);
    try testing.expectEqual(term(want.term), request.header.term);
    try testing.expectEqual(config.protocol_version, request.header.protocol_version);
    try testing.expectEqual(idx(want.prev), request.prev_log_index);
    try testing.expectEqual(term(want.prev_term), request.prev_log_term);
    try testing.expectEqual(idx(want.commit), request.leader_commit);
    try fixtures.expect_entries_equal(want.entries, request.entries);
    const message: Message = .{ .append_entries = request };
    try message.validate(config.message_limits); // Within the configured batch bounds.
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

fn expect_targets(requests: []const AppendRequest, targets: []const u64) !void {
    try testing.expectEqual(targets.len, requests.len);
    for (targets) |target| _ = try request_to(requests, target);
}

/// Log entries `first..=last` of a leader log made of the term-1 empty entry and `"x"` proposals.
fn log_range(buffer: []Entry, first: u64, last: u64) []const Entry {
    for (buffer[0 .. last - first + 1], first..) |*slot, index| {
        slot.* = fixtures.entry(index, 1, if (index == 1) "" else "x");
    }
    return buffer[0 .. last - first + 1];
}

fn peers(rig: *Rig, want_len: usize) ![]Progress {
    const slots = fixtures.leader_progress(&rig.node);
    try testing.expectEqual(want_len, slots.len);
    return slots;
}

/// Puts every peer in `.replicate` with an empty window, as if each had acknowledged `match`.
fn replicate_all(rig: *Rig, count: usize, match: u64, next: u64) !void {
    for (try peers(rig, count)) |*slot| {
        slot.state = .replicate;
        slot.match = idx(match);
        slot.next = idx(next);
        slot.inflight_count = 0;
    }
    try rig.node.check_invariants();
}

const Snap = struct {
    status: node_module.Status,
    count: usize,
    slots: [4]Progress,
    live: usize,
};

fn snap(rig: *Rig) Snap {
    var result: Snap = undefined;
    const live = fixtures.leader_progress(&rig.node);
    result.status = rig.node.status();
    result.count = rig.node.entries().len;
    result.live = live.len;
    for (live, 0..) |slot, i| result.slots[i] = slot;
    return result;
}

fn expect_unchanged(rig: *Rig, before: Snap) !void {
    const after = snap(rig);
    try testing.expectEqual(before.status, after.status);
    try testing.expectEqual(before.count, after.count);
    try testing.expectEqual(before.live, after.live);
    for (before.slots[0..before.live], after.slots[0..after.live]) |was, now| {
        try testing.expectEqual(was, now);
    }
}

fn expect_rejected(rig: *Rig, data: []const u8, want: anyerror) !void {
    const before = snap(rig);
    try testing.expectError(want, rig.node.step(.{ .propose = data }));
    try rig.node.check_invariants();
    try expect_unchanged(rig, before);
}

// ---- election: progress and the first send --------------------------------------------------

test "leader: winning sends one append_entries per other voter carrying the empty term entry" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);

    const won = try elect(&rig, 3);
    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(won, &buffer);
    const want = [_]Entry{fixtures.entry(1, 1, "")};
    try expect_targets(requests, &.{ 2, 3 });
    for ([_]u64{ 2, 3 }) |peer| {
        const request = try request_to(requests, peer);
        try expect_request(request, .{
            .to = peer,
            .term = 1,
            .prev = 0,
            .prev_term = 0,
            .entries = &want,
        });
    }
    // Persist, then send, then notify (ADR-007): append first, the sends, leader_changed last.
    try testing.expectEqual(@as(usize, 4), won.items.len);
    try testing.expect(won.items[0] == .append);
    try testing.expect(won.items[3] == .leader_changed);
}

test "leader: first send sits after the restored log tail and carries its commit index" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &logged, low);
    defer rig.deinit(testing.allocator);

    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(try elect(&rig, 3), &buffer);
    const want = [_]Entry{fixtures.entry(4, 4, "")};
    try expect_targets(requests, &.{ 2, 3 });
    for ([_]u64{ 2, 3 }) |peer| {
        const request = try request_to(requests, peer);
        try expect_request(request, .{
            .to = peer,
            .term = 4,
            .prev = 3,
            .prev_term = 3,
            .commit = 2,
            .entries = &want,
        });
    }
}

test "leader: five voters get four append_entries and four progress trackers" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, fixtures.config5, &fresh5, low);
    defer rig.deinit(testing.allocator);

    var buffer: [8]AppendRequest = undefined;
    const requests = try appends(try elect(&rig, 5), &buffer);
    try expect_targets(requests, &.{ 2, 3, 4, 5 });
    _ = try peers(&rig, 4);
}

fn expect_new_trackers(restore: *const Restore, leader_last: u64) !void {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, restore, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    for (try peers(&rig, 2)) |slot| {
        try testing.expectEqual(idx(0), slot.match);
        try testing.expectEqual(idx(leader_last + 1), slot.next);
        try testing.expectEqual(progress_module.State.probe, slot.state);
        try testing.expectEqual(@as(u32, 1), slot.inflight_count); // The election send.
        try testing.expectEqual(window, slot.inflight_max);
    }
}

test "leader: each peer starts probing at the entry after the pre-election log tail" {
    try expect_new_trackers(&fresh, 0);
    try expect_new_trackers(&logged, 3);
}

test "leader: a non-leader holds no progress trackers" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);

    for (0..config.election_ticks) |_| _ = try tick(&rig);
    try testing.expectEqual(Role.pre_candidate, rig.node.status().role);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);

    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 1, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
}

test "leader: followers, pre-candidates and candidates never send append_entries on tick" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);

    for (0..100) |_| try testing.expectEqual(@as(u32, 0), count_appends(try tick(&rig)));
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 1, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    for (0..100) |_| try testing.expectEqual(@as(u32, 0), count_appends(try tick(&rig)));
}

// ---- propose --------------------------------------------------------------------------------

test "leader: propose appends then sends one append_entries to each peer that can send" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);

    const effects = try propose(&rig, "a");
    try testing.expectEqual(@as(usize, 3), effects.items.len);
    try testing.expect(effects.items[0] == .append);
    const want = [_]Entry{fixtures.entry(2, 1, "a")};
    try fixtures.expect_entries_equal(&want, effects.items[0].append);
    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(effects, &buffer);
    try expect_targets(requests, &.{ 2, 3 });
    for ([_]u64{ 2, 3 }) |peer| {
        try expect_request(try request_to(requests, peer), .{
            .to = peer,
            .term = 1,
            .prev = 1,
            .prev_term = 1,
            .entries = &want,
        });
    }
    for (try peers(&rig, 2)) |slot| try testing.expectEqual(@as(u32, 1), slot.inflight_count);
}

test "leader: each peer's batch starts at its own next index" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);
    const slots = try peers(&rig, 2);
    slots[0].match = idx(0); // Node 2 is missing the empty entry too.
    slots[0].next = idx(1);

    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(try propose(&rig, "x"), &buffer);
    var entries: [4]Entry = undefined;
    try expect_request(try request_to(requests, 2), .{
        .to = 2,
        .term = 1,
        .prev = 0,
        .prev_term = 0,
        .entries = log_range(&entries, 1, 2),
    });
    try expect_request(try request_to(requests, 3), .{
        .to = 3,
        .term = 1,
        .prev = 1,
        .prev_term = 1,
        .entries = log_range(&entries, 2, 2),
    });
}

test "leader: a batch holds at most entries_max entries and the next batch resumes after it" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    for (0..5) |_| try testing.expectEqual(@as(usize, 1), (try propose(&rig, "x")).items.len);
    try replicate_all(&rig, 2, 0, 1); // Both peers hold nothing; the leader log is 1..6.

    var buffer: [4]AppendRequest = undefined;
    var entries: [8]Entry = undefined;
    const first = try appends(try propose(&rig, "x"), &buffer); // Log is now 1..7.
    for ([_]u64{ 2, 3 }) |peer| try expect_request(try request_to(first, peer), .{
        .to = peer,
        .term = 1,
        .prev = 0,
        .prev_term = 0,
        .entries = log_range(&entries, 1, batch_max),
    });
    const second = try appends(try propose(&rig, "x"), &buffer); // Log is now 1..8.
    for ([_]u64{ 2, 3 }) |peer| try expect_request(try request_to(second, peer), .{
        .to = peer,
        .term = 1,
        .prev = batch_max,
        .prev_term = 1,
        .entries = log_range(&entries, batch_max + 1, 8),
    });
}

test "leader: a max-size entry is sent intact and the proposal buffer is not kept" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);

    var data = [_]u8{'y'} ** 32;
    const effects = try propose(&rig, &data);
    const want = [_]Entry{fixtures.entry(2, 1, &([_]u8{'y'} ** 32))};
    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(effects, &buffer);
    @memset(&data, '!'); // The leader copied the bytes at propose time.
    try expect_targets(requests, &.{ 2, 3 });
    for (requests) |request| try fixtures.expect_entries_equal(&want, request.entries);
    try fixtures.expect_entries_equal(&want, rig.node.entries()[1..]);
}

test "leader: a probing peer has one outstanding append and proposals queue behind it" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);

    for (0..3) |_| {
        const effects = try propose(&rig, "x");
        try testing.expectEqual(@as(usize, 1), effects.items.len);
        try testing.expect(effects.items[0] == .append);
    }
    for (try peers(&rig, 2)) |slot| {
        try testing.expectEqual(@as(u32, 1), slot.inflight_count);
        try testing.expectEqual(idx(1), slot.next); // Probing leaves next where it was.
        try testing.expectEqual(progress_module.State.probe, slot.state);
    }
}

test "leader: after inflight_max unanswered sends a peer gets nothing more but others still do" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    const slots = try peers(&rig, 2);
    slots[0].state = .replicate; // Node 2 pipelines; node 3 stays probing with one in flight.
    slots[0].match = idx(1);
    slots[0].next = idx(2);
    slots[0].inflight_count = 0;

    var buffer: [4]AppendRequest = undefined;
    var entries: [8]Entry = undefined;
    for (0..window) |k| {
        const requests = try appends(try propose(&rig, "x"), &buffer);
        try expect_targets(requests, &.{2});
        try expect_request(requests[0], .{
            .to = 2,
            .term = 1,
            .prev = k + 1,
            .prev_term = 1,
            .entries = log_range(&entries, k + 2, k + 2),
        });
    }
    try testing.expectEqual(window, slots[0].inflight_count);
    const full = try propose(&rig, "x");
    try testing.expectEqual(@as(usize, 1), full.items.len); // Only the append.
    try testing.expect(full.items[0] == .append);
    try testing.expectEqual(window, slots[0].inflight_count);
    try testing.expectEqual(@as(u32, 1), slots[1].inflight_count);
    try rig.node.check_invariants();
}

test "leader: peers with room still get a send when another peer's window is full" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);
    (try peers(&rig, 2))[0].inflight_count = window;

    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(try propose(&rig, "x"), &buffer);
    try expect_targets(requests, &.{3});
}

// ---- heartbeats and round timeout -----------------------------------------------------------

test "leader: tick heartbeats every sendable peer each heartbeat_ticks, silent between" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2); // Caught up: match 1, next 2, nothing in flight.

    var buffer: [4]AppendRequest = undefined;
    var seen_rounds: [2]u64 = undefined;
    for (1..7) |t| {
        const requests = try appends(try tick(&rig), &buffer);
        if (t % config.heartbeat_ticks != 0) {
            try testing.expectEqual(@as(usize, 0), requests.len);
            continue;
        }
        try expect_targets(requests, &.{ 2, 3 });
        for ([_]u64{ 2, 3 }) |peer| try expect_request(try request_to(requests, peer), .{
            .to = peer,
            .term = 1,
            .prev = 1,
            .prev_term = 1,
            .entries = &.{}, // Caught up: an empty heartbeat, prev = next - 1.
        });
        seen_rounds[t / 3 - 1] = (try request_to(requests, 2)).round;
    }
    try testing.expect(seen_rounds[0] != seen_rounds[1]); // Rounds are told apart by id.
    for (try peers(&rig, 2)) |slot| try testing.expectEqual(@as(u32, 2), slot.inflight_count);
}

test "leader: a heartbeat skips a peer whose window is full" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);
    (try peers(&rig, 2))[1].inflight_count = window;

    var buffer: [4]AppendRequest = undefined;
    for (0..2) |_| _ = try tick(&rig);
    const requests = try appends(try tick(&rig), &buffer);
    try expect_targets(requests, &.{2});
}

test "leader: an unanswered round times out and the next heartbeat resends from match plus one" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    const won = try elect(&rig, 3);

    var buffer: [4]AppendRequest = undefined;
    var rounds: [9]u64 = undefined; // One round id per heartbeat: ticks 0, 3, ..., 24.
    rounds[0] = (try request_to(try appends(won, &buffer), 2)).round;
    const want = [_]Entry{fixtures.entry(1, 1, "")};
    for (1..25) |t| {
        const requests = try appends(try tick(&rig), &buffer);
        if (t % config.heartbeat_ticks != 0) { // A probe round is still live: silent.
            try testing.expectEqual(@as(usize, 0), requests.len);
            continue;
        }
        try expect_targets(requests, &.{ 2, 3 });
        for ([_]u64{ 2, 3 }) |peer| try expect_request(try request_to(requests, peer), .{
            .to = peer,
            .term = 1,
            .prev = 0,
            .prev_term = 0,
            .entries = &want,
        });
        rounds[t / config.heartbeat_ticks] = (try request_to(requests, 2)).round;
        for (try peers(&rig, 2)) |slot| {
            try testing.expectEqual(idx(1), slot.next);
            try testing.expectEqual(@as(u32, 1), slot.inflight_count);
            try testing.expectEqual(progress_module.State.probe, slot.state);
        }
    }
    for (rounds, 0..) |round, i| { // Every resend is a fresh round: a late reply matches none.
        for (rounds[i + 1 ..]) |other| try testing.expect(round != other);
    }
}

// ---- stepping down, lone voter, learners ----------------------------------------------------

test "leader: a higher term discards the progress and stops sending append_entries" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);

    _ = try recv(&rig, fixtures.vote_request(2, 1, 2));
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
    for (0..30) |_| try testing.expectEqual(@as(u32, 0), count_appends(try tick(&rig)));
}

test "leader: re-election builds fresh progress from the log tail of that moment" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    _ = try recv(&rig, fixtures.vote_request(2, 1, 2));

    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(try elect(&rig, 3), &buffer);
    const want = [_]Entry{fixtures.entry(2, 3, "")};
    try expect_targets(requests, &.{ 2, 3 });
    for ([_]u64{ 2, 3 }) |peer| try expect_request(try request_to(requests, peer), .{
        .to = peer,
        .term = 3,
        .prev = 1,
        .prev_term = 1,
        .entries = &want,
    });
    for (try peers(&rig, 2)) |slot| {
        try testing.expectEqual(idx(2), slot.next);
        try testing.expectEqual(idx(0), slot.match);
    }
}

test "leader: a single-voter cluster leads, proposes and ticks without sending anything" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &lone, low);
    defer rig.deinit(testing.allocator);

    for (0..config.election_ticks) |_| {
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(try tick(&rig), .send));
    }
    try testing.expectEqual(Role.leader, rig.node.status().role);
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);

    const effects = try propose(&rig, "z");
    try testing.expectEqual(@as(usize, 1), effects.items.len);
    try testing.expect(effects.items[0] == .append);
    try testing.expectEqual(types.Index.zero.next().next(), rig.node.status().last_index);
    for (0..30) |_| try testing.expectEqual(@as(usize, 0), (try tick(&rig)).items.len);
}

test "leader: a learner gets no progress tracker and no append_entries" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &with_learner, low);
    defer rig.deinit(testing.allocator);

    var buffer: [4]AppendRequest = undefined;
    try expect_targets(try appends(try elect(&rig, 3), &buffer), &.{ 2, 3 });
    try replicate_all(&rig, 2, 1, 2);
    try expect_targets(try appends(try propose(&rig, "x"), &buffer), &.{ 2, 3 });
    for (0..3) |_| _ = try tick(&rig);
    try testing.expectEqual(@as(usize, 2), fixtures.leader_progress(&rig.node).len);
}

// ---- proposals that fail --------------------------------------------------------------------

test "leader: propose by a follower or candidate is ProposeNotLeader and changes nothing" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    try expect_rejected(&rig, "x", error.ProposeNotLeader);
    for (0..config.election_ticks) |_| _ = try tick(&rig);
    try expect_rejected(&rig, "x", error.ProposeNotLeader); // Pre-candidate.
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 1, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    try expect_rejected(&rig, "x", error.ProposeNotLeader);
}

test "leader: an oversized proposal is ProposeTooLarge with no log, progress or effect change" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);

    const too_big = [_]u8{'q'} ** 33; // entry_bytes_max + 1
    try expect_rejected(&rig, &too_big, error.ProposeTooLarge);
    const exact = [_]u8{'q'} ** 32; // The boundary itself is accepted.
    try testing.expectEqual(@as(usize, 3), (try propose(&rig, &exact)).items.len);
}

test "leader: a full byte arena or slot table is ProposeLogFull with nothing sent or changed" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    try replicate_all(&rig, 2, 1, 2);
    const half = [_]u8{'b'} ** 32;
    _ = try propose(&rig, &half);
    _ = try propose(&rig, &half); // 64 of 64 bytes used.
    try expect_rejected(&rig, "x", error.ProposeLogFull);

    var slots: Rig = undefined;
    try slots.init_fixed(testing.allocator, config, &fresh, low);
    defer slots.deinit(testing.allocator);
    _ = try elect(&slots, 3);
    for (0..7) |_| _ = try propose(&slots, ""); // 8 of 8 slots, zero bytes each.
    try expect_rejected(&slots, "", error.ProposeLogFull);
}

// ---- invariants -----------------------------------------------------------------------------

test "leader: check_invariants reports InvariantProgressOrder for next not above match" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    const slots = try peers(&rig, 2);
    try rig.node.check_invariants();

    const saved = slots[1];
    slots[1].next = .zero;
    try testing.expectError(error.InvariantProgressOrder, rig.node.check_invariants());
    slots[1] = saved;
    slots[0].match = slots[0].next;
    try testing.expectError(error.InvariantProgressOrder, rig.node.check_invariants());
    slots[0].match = .zero;
    try rig.node.check_invariants();
}

test "leader: check_invariants reports InvariantInflightOverflow past the window" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    const slots = try peers(&rig, 2);

    slots[0].inflight_count = 2; // Probing allows one.
    try testing.expectError(error.InvariantInflightOverflow, rig.node.check_invariants());
    slots[0].inflight_count = 1;
    try rig.node.check_invariants();
    slots[1].state = .replicate;
    slots[1].inflight_count = window + 1;
    try testing.expectError(error.InvariantInflightOverflow, rig.node.check_invariants());
    slots[1].inflight_count = window; // A full window is legal.
    try rig.node.check_invariants();
}

test "leader: election, proposals and ticks allocate nothing after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rig: Rig = undefined;
    try rig.init_fixed(failing.allocator(), config, &fresh, low);
    defer rig.deinit(failing.allocator());
    const after_init = failing.alloc_index;
    const bytes_after_init = failing.allocated_bytes;

    _ = try elect(&rig, 3);
    for (0..40) |i| {
        if (i % 3 == 0) _ = propose(&rig, "x") catch {};
        _ = try tick(&rig);
    }
    try testing.expectEqual(after_init, failing.alloc_index);
    try testing.expectEqual(bytes_after_init, failing.allocated_bytes);
    try testing.expectEqual(@as(usize, 2), fixtures.leader_progress(&rig.node).len);
}

// ---- seeded models --------------------------------------------------------------------------

const ProbeRef = struct { last_tick: u32 = 0, resends: u32 = 0 };

/// Reference for peers that never answer: a probing peer's `next` stays `match + 1 = 1`, so every
/// send is the log prefix from index 1 (capped). A probe round lives `heartbeat_ticks` ticks
/// from its send; both peers share one schedule, and a step sends to both exactly when that
/// round is dead (and, on a tick, only on a heartbeat tick).
fn check_probe_sends(rig: *Rig, effects: Effects, ref: *ProbeRef, now: u32, beat: bool) !void {
    var buffer: [4]AppendRequest = undefined;
    const requests = try appends(effects, &buffer);
    const round_dead = now - ref.last_tick >= config.heartbeat_ticks;
    if (!(round_dead and beat)) return testing.expectEqual(@as(usize, 0), requests.len);

    const log = rig.node.entries();
    try expect_targets(requests, &.{ 2, 3 });
    for (requests) |request| {
        try testing.expectEqual(idx(0), request.prev_log_index);
        try testing.expectEqual(term(0), request.prev_log_term);
        try testing.expectEqual(idx(0), request.leader_commit);
        try fixtures.expect_entries_equal(log[0..@min(log.len, batch_max)], request.entries);
    }
    ref.last_tick = now;
    ref.resends += 1;
}

fn run_probe_model(seed: u64) !void {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var ref: ProbeRef = .{};
    var now: u32 = 0;
    for (0..120) |_| {
        if (random.boolean()) {
            now += 1;
            const beat = now % config.heartbeat_ticks == 0;
            try check_probe_sends(&rig, try tick(&rig), &ref, now, beat);
        } else if (propose(&rig, "x")) |effects| {
            try check_probe_sends(&rig, effects, &ref, now, true);
        } else |err| try testing.expectEqual(error.ProposeLogFull, err);
    }
    try testing.expect(ref.resends >= 2); // Rounds really time out and restart.
}

test "leader model: probing peers always resend the log prefix from index 1, rounds apart" {
    for ([_]u64{ 1, 2, 3, 0xdead, 0xbeef_cafe }) |seed| {
        run_probe_model(seed) catch |err| {
            std.log.err("probe model failed at seed {d}", .{seed});
            return err;
        };
    }
}

/// Reference next-index and window for node 2 in `.replicate`, no responses, no timeout yet.
const Reference = struct { next: u64 = 2, inflight: u32 = 0 };

/// Node 3 never answers and stays probing: it is re-probed with the log prefix from index 1 on
/// every heartbeat tick (its round lives `heartbeat_ticks`) and is silent on proposals.
fn check_probe_three(rig: *Rig, requests: []const AppendRequest) !void {
    const request = try request_to(requests, 3);
    const log = rig.node.entries();
    try testing.expectEqual(idx(0), request.prev_log_index);
    try testing.expectEqual(term(0), request.prev_log_term);
    try fixtures.expect_entries_equal(log[0..@min(log.len, batch_max)], request.entries);
}

fn check_replicate_sends(
    rig: *Rig,
    requests: []const AppendRequest,
    ref: *Reference,
    expect_send: bool,
    beat: bool,
) !void {
    if (beat) try check_probe_three(rig, requests);
    const want_len: usize = @as(usize, @intFromBool(expect_send)) + @intFromBool(beat);
    try testing.expectEqual(want_len, requests.len);
    if (!expect_send) return;
    const request = try request_to(requests, 2);
    const log = rig.node.entries();
    const last = log.len;
    const stop = @min(last, ref.next - 1 + batch_max);
    try testing.expectEqual(idx(ref.next - 1), request.prev_log_index);
    try testing.expectEqual(term(1), request.prev_log_term);
    try fixtures.expect_entries_equal(log[ref.next - 1 .. stop], request.entries);
    ref.next += request.entries.len; // Contiguous: the next batch begins where this one ended.
    ref.inflight += 1;
    try testing.expect(ref.inflight <= window);
}

fn run_replicate_model(seed: u64) !void {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config, &fresh, low);
    defer rig.deinit(testing.allocator);
    _ = try elect(&rig, 3);
    const slots = try peers(&rig, 2);
    slots[0].state = .replicate;
    slots[0].match = idx(1);
    slots[0].next = idx(2);
    slots[0].inflight_count = 0;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var ref: Reference = .{};
    var buffer: [4]AppendRequest = undefined;
    var ticks: u32 = 0; // Stay under election_ticks so no round times out.
    for (0..16) |_| {
        const room = ref.inflight < window;
        if (ticks < config.election_ticks - 1 and random.boolean()) {
            ticks += 1;
            const requests = try appends(try tick(&rig), &buffer);
            const beat = ticks % config.heartbeat_ticks == 0;
            try check_replicate_sends(&rig, requests, &ref, room and beat, beat);
        } else if (propose(&rig, "x")) |effects| {
            try check_replicate_sends(&rig, try appends(effects, &buffer), &ref, room, false);
        } else |err| try testing.expectEqual(error.ProposeLogFull, err);
        try testing.expectEqual(idx(ref.next), slots[0].next);
        try testing.expectEqual(ref.inflight, slots[0].inflight_count);
    }
}

test "leader model: a pipelining peer's batches are contiguous and capped by the window" {
    for ([_]u64{ 1, 2, 3, 0xdead, 0xbeef_cafe, 77 }) |seed| {
        run_replicate_model(seed) catch |err| {
            std.log.err("replicate model failed at seed {d}", .{seed});
            return err;
        };
    }
}
