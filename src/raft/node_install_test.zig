//! Red tests for InstallSnapshot (plan 005 item 5, ADR-009 "InstallSnapshot (item 5)"). Four
//! groups: the `Progress` snapshot state (`State.snapshot`, `on_snapshot_sent`,
//! `on_snapshot_acked`); the leader sending one `send_snapshot` per round timeout to a peer whose
//! `next <= log.base.index` and resuming at `match + 1` after the matching response; the follower
//! rules (ack at or below commit without installing, else `save_snapshot`, `save_hard_state`, the
//! reply, `restore`; term rules first; `Conf*` and `MessageTooLarge` are errors, never asserts;
//! `append_entries` below the base is trimmed); and a three-node cluster in which one node is cut
//! off across several compactions and catches up by snapshot, then by entries.
//!
//! Assumed API that does not exist yet (the red reason): `Progress.State.snapshot`,
//! `Progress.on_snapshot_sent`, `Progress.on_snapshot_acked`, the `Effect` variants
//! `save_snapshot` (an `interfaces.SnapshotRecord`), `send_snapshot` (a `SnapshotSend` with
//! `header` and `snapshot: log.Base`) and `restore` (an `Index`), and node handling of
//! `install_snapshot` and `install_snapshot_response`.
//!
//! Expected values come from the ADR and arithmetic on it, never from the node. The cluster's
//! state machine is a model: an applied index that `apply` advances by one and `restore` sets.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const progress_module = @import("progress.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Index = types.Index;
const Message = types.Message;
const Progress = progress_module.Progress;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

const fresh = fixtures.restore_of(.empty, &.{});

fn config_of() Config {
    var result = fixtures.config;
    result.log_entries_max = 16;
    result.log_bytes_max = 64;
    result.message_limits.entries_max = 8;
    result.snapshot_entries_min = 7;
    result.snapshot_trailing = 3;
    return result; // snapshot_bytes_max stays 128.
}

// ---- progress ------------------------------------------------------------------------------

fn tracker(match: u64, next: u64, state: progress_module.State) Progress {
    return .{
        .match = idx(match),
        .next = idx(next),
        .state = state,
        .inflight_count = 0,
        .inflight_max = 4,
    };
}

test "progress: on_snapshot_sent enters snapshot with next past the index and one in flight" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));

    try testing.expectEqual(progress_module.State.snapshot, p.state);
    try testing.expectEqual(idx(11), p.next);
    try testing.expectEqual(idx(2), p.match);
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
    try testing.expect(!p.can_send());
    try p.check_invariants();
    try testing.expectEqual(@as(usize, 32), @sizeOf(Progress));
}

test "progress: on_snapshot_acked at exactly next - 1 sets match and returns to probe" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));

    try testing.expect(p.on_snapshot_acked(idx(10)));
    try testing.expectEqual(idx(10), p.match);
    try testing.expectEqual(idx(11), p.next);
    try testing.expectEqual(progress_module.State.probe, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expect(p.can_send());
    try p.check_invariants();
}

test "progress: on_snapshot_acked with a stale, early or zero index changes nothing" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));
    const sent = p;

    for ([_]u64{ 0, 2, 9, 11, 1000 }) |wrong| {
        try testing.expect(!p.on_snapshot_acked(idx(wrong)));
        try testing.expectEqual(sent, p);
    }
}

test "progress: a duplicate on_snapshot_acked and one outside the snapshot state change nothing" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));
    try testing.expect(p.on_snapshot_acked(idx(10)));
    const acked = p;

    try testing.expect(!p.on_snapshot_acked(idx(10)));
    try testing.expectEqual(acked, p);
    var replicating = tracker(10, 11, .replicate);
    const before = replicating;
    try testing.expect(!replicating.on_snapshot_acked(idx(10)));
    try testing.expectEqual(before, replicating);
}

test "progress: a timeout in the snapshot state probes again from match + 1" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));
    p.on_timeout();

    try testing.expectEqual(progress_module.State.probe, p.state);
    try testing.expectEqual(idx(3), p.next);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expect(p.can_send());
}

test "progress: a rejection while a snapshot is in flight is stale and changes nothing" {
    var p = tracker(2, 3, .probe);
    p.on_snapshot_sent(idx(10));
    const sent = p;
    const conflict: types.Conflict = .{ .index = idx(4), .term = term(1) };

    try testing.expect(!p.on_rejected(conflict, idx(5)));
    try testing.expectEqual(sent, p);
}

// ---- leader --------------------------------------------------------------------------------

fn span(buffer: []Entry, first: u64, count: u32, term_value: u64) []Entry {
    for (buffer[0..count], 0..) |*slot, i| {
        slot.* = fixtures.entry(first + i, term_value, "a");
    }
    return buffer[0..count];
}

fn recv(rig: *Rig, message: Message) !Effects {
    const effects = try rig.receive(&message);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

fn snapshots_to(effects: Effects, to: u64) u32 {
    var total: u32 = 0;
    for (effects.items) |effect| switch (effect) {
        .send_snapshot => |send| if (send.header.to == node_id(to)) {
            total += 1;
        },
        else => {},
    };
    return total;
}

fn appends_to(effects: Effects, to: u64) u32 {
    var total: u32 = 0;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries => |request| if (request.header.to == node_id(to)) {
                total += 1;
            },
            else => {},
        },
        else => {},
    };
    return total;
}

/// Follower of node 2 at term 1 with entries 1..7 applied and the snapshot at 7 saved: base 4.
fn compacted(rig: *Rig) !void {
    try rig.init_fixed(testing.allocator, config_of(), &fresh, 0);
    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 1, 7, 1);
    const effects = try recv(rig, fixtures.append_request(2, 1, 0, 0, 7, batch));
    try fixtures.expect_ack(effects, 2, 7);
    const saved = try rig.node.step(.{ .snapshot_saved = idx(7) });
    try testing.expectEqual(@as(usize, 0), saved.items.len);
    try testing.expectEqual(idx(4), rig.node.log.base.index);
}

/// Wins the election at term 2; returns the effects of the winning step (appends to 2 and 3).
fn lead(rig: *Rig) !Effects {
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try rig.node.step(.tick);
    }
    _ = try recv(rig, fixtures.pre_vote_response(2, 1, 2, true));
    const effects = try recv(rig, fixtures.vote_response(2, 1, 2, true));
    try testing.expectEqual(Role.leader, rig.node.status().role);
    return effects;
}

fn rejected_from(from: u64, round: u64) Message {
    const conflict: types.Conflict = .{ .index = idx(1), .term = term(1) };
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, 2),
        .round = round,
        .outcome = .{ .rejected = conflict },
    } };
}

fn snapshot_ack(from: u64, at_term: u64, match: u64) Message {
    return .{ .install_snapshot_response = .{
        .header = fixtures.header_of(from, 1, at_term),
        .match_index = idx(match),
    } };
}

/// A compacted leader (base 4, snapshot 7, last 8) whose peer 2 was rejected back to index 1.
fn behind(rig: *Rig) !Effects {
    const won = try lead(rig);
    const round = (try fixtures.append_to(won, 2)).round;
    return recv(rig, rejected_from(2, round));
}

test "install leader: a peer rejected below the base gets one send_snapshot and no append" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);
    const won = try lead(&rig);
    const round = (try fixtures.append_to(won, 2)).round;
    const effects = try recv(&rig, rejected_from(2, round));

    try testing.expectEqual(@as(u32, 1), snapshots_to(effects, 2));
    try testing.expectEqual(@as(u32, 0), appends_to(effects, 2));
    for (effects.items) |effect| switch (effect) {
        .send_snapshot => |send| {
            try testing.expectEqual(idx(7), send.snapshot.index);
            try testing.expectEqual(term(1), send.snapshot.term);
            try testing.expectEqual(term(2), send.header.term);
            try testing.expectEqual(node_id(1), send.header.from);
        },
        else => {},
    };
    const p = fixtures.leader_progress(&rig.node)[0];
    try testing.expectEqual(progress_module.State.snapshot, p.state);
    try testing.expectEqual(idx(8), p.next);
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
}

test "install leader: one send_snapshot per round timeout, none on the ticks between" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);
    const won = try lead(&rig);
    const round = (try fixtures.append_to(won, 2)).round;
    const first = try recv(&rig, rejected_from(2, round));
    try testing.expectEqual(@as(u32, 1), snapshots_to(first, 2));

    var total: u32 = 0;
    for (1..10) |_| { // election_ticks = 10: the round is younger than a timeout.
        const effects = try rig.node.step(.tick);
        total += snapshots_to(effects, 2);
        try testing.expectEqual(@as(u32, 0), appends_to(effects, 2));
        try rig.node.check_invariants();
    }
    try testing.expectEqual(@as(u32, 0), total);

    const expired = try rig.node.step(.tick); // Tick 10: the round times out, one resend.
    try testing.expectEqual(@as(u32, 1), snapshots_to(expired, 2));
    for (1..10) |_| total += snapshots_to(try rig.node.step(.tick), 2);
    try testing.expectEqual(@as(u32, 0), total);
}

test "install leader: the matching response probes from match + 1 and then commits" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);
    const won = try lead(&rig);
    const round = (try fixtures.append_to(won, 2)).round;
    _ = try recv(&rig, rejected_from(2, round));

    const effects = try recv(&rig, snapshot_ack(2, 2, 7));
    const p = fixtures.leader_progress(&rig.node)[0];
    try testing.expectEqual(idx(7), p.match);
    try testing.expectEqual(idx(8), p.next);
    try testing.expectEqual(@as(u32, 0), snapshots_to(effects, 2));
    const request = try fixtures.append_to(effects, 2);
    try testing.expectEqual(idx(7), request.prev_log_index);
    try testing.expectEqual(@as(u64, 8), fixtures.last_of(request));

    const accepted: Message = .{ .append_entries_response = .{
        .header = fixtures.header_of(2, 1, 2),
        .round = request.round,
        .outcome = .{ .accepted = idx(8) },
    } };
    _ = try recv(&rig, accepted); // Leader plus node 2 hold the term-2 entry 8.
    try testing.expectEqual(idx(8), rig.node.status().commit_index);
}

test "install leader: stale, early, duplicate and lower-term responses change nothing" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);
    _ = try behind(&rig);
    const sent = fixtures.leader_progress(&rig.node)[0];

    for ([_]u64{ 0, 6, 8, 100 }) |wrong| {
        const effects = try recv(&rig, snapshot_ack(2, 2, wrong));
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try testing.expectEqual(sent, fixtures.leader_progress(&rig.node)[0]);
    }
    const lower = try recv(&rig, snapshot_ack(2, 1, 7)); // Term 1 < 2: dropped.
    try testing.expectEqual(@as(usize, 0), lower.items.len);
    try testing.expectEqual(sent, fixtures.leader_progress(&rig.node)[0]);
    const never_sent = fixtures.leader_progress(&rig.node)[1]; // Peer 3 was never sent one.
    _ = try recv(&rig, snapshot_ack(3, 2, 7));
    try testing.expectEqual(never_sent, fixtures.leader_progress(&rig.node)[1]);

    _ = try recv(&rig, snapshot_ack(2, 2, 7)); // The real one.
    const acked = fixtures.leader_progress(&rig.node)[0];
    try testing.expectEqual(idx(7), acked.match);
    _ = try recv(&rig, snapshot_ack(2, 2, 7)); // Its duplicate.
    try testing.expectEqual(acked.match, fixtures.leader_progress(&rig.node)[0].match);
    try testing.expect(fixtures.leader_progress(&rig.node)[0].state != .snapshot);
}

// ---- follower ------------------------------------------------------------------------------

/// Follower of node 2 at term 1: entries 1..5 (term 1) held, commit and applied 3.
fn holding(rig: *Rig) !void {
    try rig.init_fixed(testing.allocator, config_of(), &fresh, 0);
    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 1, 5, 1);
    const effects = try recv(rig, fixtures.append_request(2, 1, 0, 0, 3, batch));
    try fixtures.expect_ack(effects, 2, 5);
    try testing.expectEqual(idx(3), rig.node.status().commit_index);
}

fn install(from: u64, at_term: u64, index: u64, snap_term: u64, data: []const u8) Message {
    return .{ .install_snapshot = .{
        .header = fixtures.header_of(from, 1, at_term),
        .snapshot = .{ .index = idx(index), .term = term(snap_term), .data = data },
        .configuration = fixtures.configuration,
    } };
}

fn reply_match(effects: Effects, to: u64, at_term: u64) !Index {
    var found: ?types.SnapshotResponse = null;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .install_snapshot_response => |reply| {
                try testing.expect(found == null);
                found = reply;
            },
            else => {},
        },
        else => {},
    };
    const reply = found orelse return error.TestUnexpectedResult;
    try testing.expectEqual(node_id(to), reply.header.to);
    try testing.expectEqual(term(at_term), reply.header.term);
    return reply.match_index;
}

fn position(effects: Effects, tag: std.meta.Tag(node_module.Effect)) !usize {
    return fixtures.index_of(effects, tag) orelse error.TestUnexpectedResult;
}

fn expect_nothing_stored(effects: Effects) !void {
    inline for (.{ .save_snapshot, .restore, .truncate, .append, .apply }) |tag| {
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, tag));
    }
}

test "install follower: a snapshot at or below commit is acked and changes nothing" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const before = rig.node.status();

    for ([_]u64{ 3, 2, 1 }) |index| {
        const effects = try recv(&rig, install(2, 1, index, 1, "state"));
        try testing.expectEqual(idx(index), try reply_match(effects, 2, 1));
        try expect_nothing_stored(effects);
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
        try testing.expectEqual(before, rig.node.status());
        try testing.expectEqual(idx(0), rig.node.log.base.index);
    }
}

test "install follower: a newer snapshot saves, commits, replies, then restores, in order" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const effects = try recv(&rig, install(2, 1, 9, 1, "state-at-9"));

    const saved = try position(effects, .save_snapshot);
    const hard = try position(effects, .save_hard_state);
    const sent = try position(effects, .send);
    const restored = try position(effects, .restore);
    try testing.expect(saved < hard and hard < sent and sent < restored);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .save_snapshot));
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .restore));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .apply));
    try testing.expectEqual(idx(9), (try fixtures.last_hard_state(effects)).commit_index);
    try testing.expectEqual(idx(9), try reply_match(effects, 2, 1));
    switch (effects.items[saved]) {
        .save_snapshot => |record| {
            try testing.expectEqual(idx(9), record.snapshot.index);
            try testing.expectEqual(term(1), record.snapshot.term);
            try testing.expectEqualSlices(u8, "state-at-9", record.snapshot.data);
            const voters = record.configuration.voters;
            try testing.expectEqualSlices(types.NodeId, &fixtures.voters, voters);
        },
        else => unreachable,
    }
    try testing.expectEqual(idx(9), effects.items[restored].restore);

    const status = rig.node.status();
    try testing.expectEqual(idx(9), status.commit_index);
    try testing.expectEqual(idx(9), status.applied_index);
    try testing.expectEqual(idx(9), status.snapshot_index);
    try testing.expectEqual(idx(9), status.last_index); // Beyond the log: reset to the snapshot.
    try testing.expectEqual(idx(9), rig.node.log.base.index);
    try testing.expectEqual(term(1), rig.node.log.base.term);
    try testing.expectEqual(@as(u32, 0), rig.node.log.count);
    try testing.expectEqual(@as(u32, 0), rig.node.bytes_used);
}

test "install follower: a snapshot the log holds keeps the suffix above it" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const effects = try recv(&rig, install(2, 1, 4, 1, "state-at-4"));

    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .restore));
    try testing.expectEqual(idx(4), try reply_match(effects, 2, 1));
    try testing.expectEqual(idx(4), rig.node.status().commit_index);
    try testing.expectEqual(idx(5), rig.node.status().last_index);
    try testing.expectEqual(idx(4), rig.node.log.base.index);
    try testing.expectEqual(@as(u32, 1), rig.node.log.count);
    try testing.expectEqual(idx(5), rig.node.entries()[0].index);
}

test "install follower: a snapshot at a conflicting term resets the log and adopts the term" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const effects = try recv(&rig, install(2, 2, 4, 2, "state-at-4"));

    const hard = try fixtures.last_hard_state(effects);
    try testing.expectEqual(term(2), hard.term);
    try testing.expectEqual(idx(4), hard.commit_index);
    try testing.expectEqual(idx(4), try reply_match(effects, 2, 2));
    try testing.expectEqual(idx(4), rig.node.status().last_index); // (4, 1) held, (4, 2) sent.
    try testing.expectEqual(term(2), rig.node.log.base.term);
    try testing.expectEqual(@as(u32, 0), rig.node.log.count);
}

test "install follower: a stale term is refused at our term and nothing is installed" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config_of(), &fixtures.base_restore, 0);
    defer rig.deinit(testing.allocator);
    _ = try rig.node.step(.tick); // The restored node replays its committed prefix on step one.
    const before = rig.node.status(); // Term 3, commit 2 and applied 2, three entries.

    const effects = try recv(&rig, install(2, 2, 9, 2, "state"));
    try testing.expectEqual(idx(0), try reply_match(effects, 2, 3));
    try expect_nothing_stored(effects);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
    try testing.expectEqual(before, rig.node.status());
}

test "install follower: the term rules run first even when the snapshot is at or below commit" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const effects = try recv(&rig, install(2, 2, 2, 1, "state"));

    try testing.expectEqual(term(2), (try fixtures.last_hard_state(effects)).term);
    try testing.expectEqual(idx(2), try reply_match(effects, 2, 2));
    try expect_nothing_stored(effects);
    try testing.expectEqual(idx(3), rig.node.status().commit_index);
}

test "install follower: a sender outside the configuration is ignored at any term" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const before = rig.node.status();

    const effects = try recv(&rig, install(9, 5, 9, 5, "state"));
    try testing.expectEqual(@as(usize, 0), effects.items.len);
    try testing.expectEqual(before, rig.node.status());
}

test "install follower: oversize data is MessageTooLarge and the boundary size installs" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const before = rig.node.status();
    const data = [_]u8{7} ** 129; // snapshot_bytes_max = 128.

    const message = install(2, 1, 9, 1, &data);
    try testing.expectError(error.MessageTooLarge, rig.receive(&message));
    try testing.expectEqual(before, rig.node.status());
    try rig.node.check_invariants();

    const exact = install(2, 1, 9, 1, data[0..128]);
    const effects = try recv(&rig, exact);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .restore));
}

test "install follower: a configuration over the node caps is a Conf error before any change" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    const before = rig.node.status();
    const four = [_]types.NodeId{ node_id(1), node_id(2), node_id(3), node_id(4) };
    var message = install(2, 2, 9, 2, "state"); // A higher term too: it must not be adopted.
    message.install_snapshot.configuration = .{
        .voters = &four,
        .voters_outgoing = &.{},
        .learners = &.{},
    };

    try testing.expectError(error.ConfVotersTooMany, rig.receive(&message));
    try testing.expectEqual(before, rig.node.status());
    try testing.expectEqual(idx(0), rig.node.log.base.index);
    try rig.node.check_invariants();
}

test "install follower: append_entries from below the base is trimmed and the rest accepted" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    _ = try recv(&rig, install(2, 1, 9, 1, "state-at-9"));

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 8, 4, 1); // 8, 9 at or below the base; 10, 11 new.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 7, 1, 11, batch));
    try fixtures.expect_ack(effects, 2, 11);
    try testing.expectEqual(idx(9), rig.node.log.base.index);
    try testing.expectEqual(idx(11), rig.node.status().last_index);
    try testing.expectEqual(idx(11), rig.node.status().commit_index);
    try testing.expectEqual(idx(10), rig.node.entries()[0].index);
}

test "install follower: an append_entries wholly below the base is accepted at its last index" {
    var rig: Rig = undefined;
    try holding(&rig);
    defer rig.deinit(testing.allocator);
    _ = try recv(&rig, install(2, 1, 9, 1, "state-at-9"));

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 6, 4, 1); // 6..9: nothing above the base.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 5, 1, 9, batch));
    try fixtures.expect_ack(effects, 2, 9);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .append));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .truncate));
    try testing.expectEqual(idx(9), rig.node.status().last_index);
}

// ---- cluster -------------------------------------------------------------------------------

const queue_len = 64;

const Packet = struct {
    message: Message,
    entries: [8]Entry,
    bytes: [64]u8,
    snap: [8]u8,
};

/// Three nodes, synchronous delivery in FIFO order, node 3 cut on demand. Each node's state
/// machine is its applied index: `apply` adds one in order, `restore` sets it from the snapshot
/// whose eight data bytes are the index.
const Cluster = struct {
    rigs: [3]Rig,
    queue: [queue_len]Packet,
    head: u64,
    tail: u64,
    cut: [3]bool,
    applied: [3]u64,
    restores: [3]u32,
    installs: [3]u32,
    saved_index: [3]u64,
    compactions: [3]u32,

    fn init(c: *Cluster) !void {
        c.head = 0;
        c.tail = 0;
        c.cut = .{ false, false, false };
        c.applied = .{ 0, 0, 0 };
        c.restores = .{ 0, 0, 0 };
        c.installs = .{ 0, 0, 0 };
        c.saved_index = .{ 0, 0, 0 };
        c.compactions = .{ 0, 0, 0 };
        var made: usize = 0;
        errdefer for (c.rigs[0..made]) |*rig| rig.deinit(testing.allocator);
        while (made < 3) : (made += 1) {
            var node_config = config_of();
            node_config.id = node_id(made + 1);
            node_config.snapshot_entries_min = 4;
            node_config.snapshot_trailing = 1;
            node_config.message_limits.entries_max = 4;
            try c.rigs[made].init_fixed(testing.allocator, node_config, &fresh, 0);
        }
    }

    fn deinit(c: *Cluster) void {
        for (&c.rigs) |*rig| rig.deinit(testing.allocator);
    }

    fn slot(c: *Cluster, header: types.Header) !?*Packet {
        const from = @intFromEnum(header.from) - 1;
        const to = @intFromEnum(header.to) - 1;
        if (c.cut[from] or c.cut[to]) return null;
        try testing.expect(c.tail - c.head < queue_len - 4);
        defer c.tail += 1;
        return &c.queue[c.tail % queue_len];
    }

    fn enqueue(c: *Cluster, message: Message) !void {
        const packet = (try c.slot(message.header().*)) orelse return;
        packet.message = message;
        switch (message) {
            .append_entries => |request| {
                var used: usize = 0;
                for (request.entries, 0..) |item, i| {
                    @memcpy(packet.bytes[used..][0..item.data.len], item.data);
                    packet.entries[i] = item;
                    packet.entries[i].data = packet.bytes[used..][0..item.data.len];
                    used += item.data.len;
                }
                packet.message.append_entries.entries = packet.entries[0..request.entries.len];
            },
            else => {},
        }
    }

    fn enqueue_snapshot(c: *Cluster, send: node_module.SnapshotSend) !void {
        const packet = (try c.slot(send.header)) orelse return;
        std.mem.writeInt(u64, &packet.snap, @intFromEnum(send.snapshot.index), .little);
        packet.message = .{ .install_snapshot = .{
            .header = send.header,
            .snapshot = .{
                .index = send.snapshot.index,
                .term = send.snapshot.term,
                .data = &packet.snap,
            },
            .configuration = fixtures.configuration,
        } };
    }

    fn settle(c: *Cluster, n: usize, effects: Effects) !void {
        const node = &c.rigs[n].node;
        try fixtures.expect_effects_ordered(effects, node.config);
        var due: ?Index = null;
        for (effects.items) |effect| switch (effect) {
            .send => |message| try c.enqueue(message),
            .send_snapshot => |send| try c.enqueue_snapshot(send),
            .save_snapshot => |record| {
                try testing.expectEqual(@as(usize, 8), record.snapshot.data.len);
                c.saved_index[n] = std.mem.readInt(u64, record.snapshot.data[0..8], .little);
                try testing.expectEqual(@intFromEnum(record.snapshot.index), c.saved_index[n]);
            },
            .restore => |index| {
                try testing.expectEqual(@intFromEnum(index), c.saved_index[n]);
                c.applied[n] = @intFromEnum(index);
                c.restores[n] += 1;
            },
            .apply => |batch| for (batch) |item| {
                try testing.expectEqual(c.applied[n] + 1, @intFromEnum(item.index));
                c.applied[n] += 1;
            },
            .snapshot_due => |request| due = request.snapshot.index,
            else => {},
        };
        if (due) |index| { // The leader's own snapshot: data is the index, as the model defines.
            const saved = try node.step(.{ .snapshot_saved = index });
            try testing.expectEqual(@as(usize, 0), saved.items.len);
            c.compactions[n] += 1;
        }
        try node.check_invariants();
        try testing.expectEqual(idx(c.applied[n]), node.status().applied_index);
    }

    fn drain(c: *Cluster) !void {
        var guard: u32 = 0;
        while (c.head != c.tail) : (guard += 1) {
            try testing.expect(guard < 600);
            const packet = &c.queue[c.head % queue_len];
            c.head += 1;
            const to = @intFromEnum(packet.message.header().to) - 1;
            if (packet.message == .install_snapshot) c.installs[to] += 1;
            const effects = try c.rigs[to].receive(&packet.message);
            try c.settle(to, effects);
        }
    }

    fn tick(c: *Cluster, n: usize) !void {
        try c.settle(n, try c.rigs[n].node.step(.tick));
        try c.drain();
    }

    fn propose(c: *Cluster, number: u16) !void {
        var data: [2]u8 = undefined;
        std.mem.writeInt(u16, &data, number, .little);
        try c.settle(0, try c.rigs[0].node.step(.{ .propose = &data }));
        try c.drain();
    }
};

test "install cluster: a node cut off across compactions catches up by snapshot, then entries" {
    var c: Cluster = undefined;
    try c.init();
    defer c.deinit();
    var guard: u32 = 0;
    while (c.rigs[0].node.status().role != .leader) : (guard += 1) {
        try testing.expect(guard < 40);
        try c.tick(0);
    }

    c.cut[2] = true;
    for (0..14) |number| try c.propose(@intCast(number));
    const leader = &c.rigs[0].node;
    try testing.expect(c.compactions[0] >= 2); // Several compactions while node 3 was away.
    try testing.expect(@intFromEnum(leader.log.base.index) >= 8);
    try testing.expectEqual(@as(u64, 0), c.applied[2]);
    // Node 3 holds only the leader's empty entry of its term, sent before the cut.
    try testing.expectEqual(idx(1), c.rigs[2].node.status().last_index);

    c.cut[2] = false;
    guard = 0;
    while (c.applied[2] != c.applied[0]) : (guard += 1) {
        try testing.expect(guard < 80);
        try c.tick(0);
    }
    try testing.expectEqual(@as(u32, 1), c.restores[2]); // Entries alone could not reach it.
    try testing.expect(c.installs[2] >= 1);
    try testing.expect(@intFromEnum(c.rigs[2].node.log.base.index) > 0);
    try testing.expectEqual(leader.status().commit_index, c.rigs[2].node.status().commit_index);

    const installs = c.installs[2];
    for (14..17) |number| try c.propose(@intCast(number));
    try c.tick(0);
    try testing.expectEqual(installs, c.installs[2]); // The rest came as entries.
    try testing.expectEqual(@as(u32, 1), c.restores[2]);
    try testing.expectEqual(c.applied[0], c.applied[2]);
    try testing.expectEqual(c.applied[0], c.applied[1]);
    try testing.expectEqual(leader.status().last_index, c.rigs[2].node.status().last_index);
}
