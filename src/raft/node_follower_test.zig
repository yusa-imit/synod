//! Tests for follower log matching (plan 003 item 2B-ii): an `append_entries` from the leader
//! of our term is checked with the consistency rule of Raft thesis §3.5 / §5.3 (`prev_log_index`
//! and `prev_log_term` must match), a mismatch is refused with the fast-backtrack hint, a match
//! walks the batch: entries already present are skipped, the first conflicting entry truncates
//! the suffix (never at or below `commit_index`) and the rest is appended into the node's own
//! byte arena. The reply `accepted(prev + entries.len)` leaves only after the persist effects.
//!
//! Expected values come from the Raft paper (Figure 7 logs, §5.3) and the plan's Verify line,
//! never from `follower.zig`. Commit advancement (`leader_commit`) is item 2B-iii and has its own
//! tests (`node_commit_test.zig`): every request here carries `leader_commit` zero, so the log
//! matching is tested alone and `commit_index` stays where it was.
//!
//! The model test drives random prefix-consistent leader/follower log pairs and compares every
//! reply, effect and the resulting log with a naive array reference.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const AppendResponse = types.AppendResponse;
const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

/// Room for the 11-entry leader log of Figure 7 and for 10-entry batches.
const cfg: Config = blk: {
    var c = fixtures.config;
    c.log_entries_max = 16;
    c.message_limits.entries_max = 10;
    break :blk c;
};

/// Entry `i`'s bytes are `{i, t}`: the same (index, term) always carries the same bytes, as in a
/// real log, and a different term at an index carries different bytes.
const data_table = blk: {
    var table: [17][9][2]u8 = undefined;
    for (&table, 0..) |*row, i| {
        for (row, 0..) |*cell, t| cell.* = .{ @intCast(i), @intCast(t) };
    }
    break :blk table;
};

fn entry_of(index: u64, entry_term: u64) Entry {
    return fixtures.entry(index, entry_term, &data_table[index][entry_term]);
}

/// Fills `buffer` with entries 1..terms.len, entry `i` in `terms[i - 1]`.
fn log_from(buffer: []Entry, terms: []const u64) []const Entry {
    for (terms, 0..) |entry_term, i| buffer[i] = entry_of(i + 1, entry_term);
    return buffer[0..terms.len];
}

fn restore_at(hard_term: u64, commit: u64, entries: []const Entry) node_module.Restore {
    return fixtures.restore_of(fixtures.hard_state_of(hard_term, 0, commit), entries);
}

fn append_msg(
    from: u64,
    at_term: u64,
    prev: u64,
    prev_term: u64,
    round: u64,
    entries: []const Entry,
) Message {
    return .{ .append_entries = .{
        .header = fixtures.header_of(from, 1, at_term),
        .prev_log_index = idx(prev),
        .prev_log_term = term(prev_term),
        .leader_commit = idx(0),
        .round = round,
        .entries = entries,
    } };
}

/// Steps `message`; effects must be ordered and every invariant (log validate included) hold.
fn recv(rig: *Rig, message: Message) !Effects {
    const effects = try rig.receive(&message);
    try fixtures.expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    try rig.node.log.validate();
    return effects;
}

fn tick_n(rig: *Rig, count: u32) !void {
    for (0..count) |_| _ = try rig.node.step(.tick);
}

/// The only `send` of `effects` as an `append_entries_response` from node 1 to `to`, echoing
/// `round`, at `at_term`; fails when there is no send, several, or another kind.
fn sole_reply(effects: Effects, to: u64, round: u64, at_term: u64) !AppendResponse {
    var found: ?AppendResponse = null;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries_response => |reply| {
                try testing.expect(found == null);
                found = reply;
            },
            else => return error.TestUnexpectedResult,
        },
        else => {},
    };
    const reply = found orelse return error.TestUnexpectedResult;
    try testing.expectEqual(node_id(1), reply.header.from);
    try testing.expectEqual(node_id(to), reply.header.to);
    try testing.expectEqual(term(at_term), reply.header.term);
    try testing.expectEqual(types.protocol_version_current, reply.header.protocol_version);
    try testing.expectEqual(round, reply.round);
    return reply;
}

fn expect_accepted(effects: Effects, round: u64, at_term: u64, matched: u64) !void {
    const reply = try sole_reply(effects, 2, round, at_term);
    try testing.expectEqual(types.AppendOutcome{ .accepted = idx(matched) }, reply.outcome);
}

fn expect_rejected(effects: Effects, round: u64, at_term: u64, at: u64, at_term_of: u64) !void {
    const reply = try sole_reply(effects, 2, round, at_term);
    const conflict: types.Conflict = .{ .index = idx(at), .term = term(at_term_of) };
    const want: types.AppendOutcome = .{ .rejected = conflict };
    try testing.expectEqual(want, reply.outcome);
}

fn truncate_of(effects: Effects) !?u64 {
    try testing.expect(fixtures.count_effects(effects, .truncate) <= 1);
    for (effects.items) |effect| switch (effect) {
        .truncate => |from| return @intFromEnum(from),
        else => {},
    };
    return null;
}

fn appended_of(effects: Effects) ![]const Entry {
    try testing.expect(fixtures.count_effects(effects, .append) <= 1);
    for (effects.items) |effect| switch (effect) {
        .append => |batch| {
            try testing.expect(batch.len > 0);
            return batch;
        },
        else => {},
    };
    return &.{};
}

/// No durable effect and no send: what a dropped request may leave behind is `leader_changed`
/// and, on a restored node's first step, the one `apply` replaying its committed prefix.
fn expect_dropped(effects: Effects) !void {
    for (effects.items) |effect| try testing.expect(effect == .leader_changed or effect == .apply);
    try testing.expect(fixtures.count_effects(effects, .apply) <= 1);
    try testing.expect(fixtures.count_effects(effects, .leader_changed) <= 1);
}

fn expect_in_arena(rig: *const Rig, batch: []const Entry) !void {
    const low = @intFromPtr(rig.node.bytes.ptr);
    const high = low + rig.node.bytes.len;
    for (batch) |item| {
        if (item.data.len == 0) continue;
        const at = @intFromPtr(item.data.ptr);
        try testing.expect(at >= low and at + item.data.len <= high);
    }
}

// ---- Figure 7 ------------------------------------------------------------------------------

/// The leader of Figure 7 (term 8): ten entries, then a term-8 entry the leader appends later.
const leader_terms = [_]u64{ 1, 1, 1, 4, 4, 5, 5, 6, 6, 6, 8 };
const leader_old: u64 = 10;

const Figure = struct {
    follower: []const u64,
    /// The conflicts the follower must send, in order, to a leader that backs `next` up to
    /// `conflict.index` (or to 1 for a shorter log) after probing at `next = 11`.
    rejects: []const [2]u64,
    /// The truncate effect of the accepting step (0 = none) and the entries it appends.
    truncate: u64,
    appended: usize,
};

/// A leader request that sends entries `next..=last` with `prev = next - 1`.
fn leader_request(leader: []const Entry, last: usize, next: u64, round: u64) Message {
    const prev = next - 1;
    const prev_term: u64 = if (prev == 0) 0 else @intFromEnum(leader[prev - 1].term);
    return append_msg(2, 8, prev, prev_term, round, leader[prev..last]);
}

fn converge(figure: Figure) !void {
    var follower_buffer: [16]Entry = undefined;
    var leader_buffer: [11]Entry = undefined;
    const leader = log_from(&leader_buffer, &leader_terms);
    const start = log_from(&follower_buffer, figure.follower);
    const restore = restore_at(8, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    var next: u64 = leader_old + 1;
    var round: u64 = 1;
    for (figure.rejects) |want| {
        const effects = try recv(&rig, leader_request(leader, leader_old, next, round));
        try expect_rejected(effects, round, 8, want[0], want[1]);
        try testing.expectEqual(@as(?u64, null), try truncate_of(effects));
        try testing.expectEqual(@as(usize, 0), (try appended_of(effects)).len);
        try fixtures.expect_entries_equal(start, rig.node.entries());
        next = if (want[0] == 0) 1 else want[0];
        round += 1;
    }

    const effects = try recv(&rig, leader_request(leader, leader_old, next, round));
    try expect_accepted(effects, round, 8, leader_old);
    const truncated: ?u64 = if (figure.truncate == 0) null else figure.truncate;
    try testing.expectEqual(truncated, try truncate_of(effects));
    const batch = try appended_of(effects);
    try testing.expectEqual(figure.appended, batch.len);
    try fixtures.expect_entries_equal(leader[leader_old - batch.len .. leader_old], batch);
    try expect_in_arena(&rig, batch);
    try fixtures.expect_entries_equal(leader[0..leader_old], rig.node.entries()[0..leader_old]);

    // The leader appends its term-8 entry: any surplus beyond index 10 is a conflict at 11.
    const surplus = rig.node.entries().len > leader_old;
    const last = try recv(&rig, leader_request(leader, 11, 11, round + 1));
    try expect_accepted(last, round + 1, 8, 11);
    try testing.expectEqual(@as(?u64, if (surplus) 11 else null), try truncate_of(last));
    try fixtures.expect_entries_equal(leader, rig.node.entries());
    try testing.expectEqual(idx(11), rig.node.status().last_index);
    try testing.expectEqual(idx(0), rig.node.status().commit_index);
    try testing.expectEqual(@as(u32, 22), rig.node.bytes_used);
}

test "follower: figure 7 (a) missing one entry gets it appended" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 4, 4, 5, 5, 6, 6 },
        .rejects = &.{.{ 0, 0 }},
        .truncate = 0,
        .appended = 1,
    });
}

test "follower: figure 7 (b) far behind log gets the whole missing tail" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 4 },
        .rejects = &.{.{ 0, 0 }},
        .truncate = 0,
        .appended = 6,
    });
}

test "follower: figure 7 (c) one extra uncommitted entry survives a matching probe" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 4, 4, 5, 5, 6, 6, 6, 6 },
        .rejects = &.{},
        .truncate = 0,
        .appended = 0,
    });
}

test "follower: figure 7 (d) two extra entries of a later term are cut by the new entry" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 4, 4, 5, 5, 6, 6, 6, 7, 7 },
        .rejects = &.{},
        .truncate = 0,
        .appended = 0,
    });
}

test "follower: figure 7 (e) divergent suffix is truncated at the first conflict" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 4, 4, 4, 4 },
        .rejects = &.{.{ 0, 0 }},
        .truncate = 6,
        .appended = 5,
    });
}

test "follower: figure 7 (f) backs up through two term runs then truncates at index 4" {
    try converge(.{
        .follower = &.{ 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3 },
        .rejects = &.{ .{ 7, 3 }, .{ 4, 2 } },
        .truncate = 4,
        .appended = 7,
    });
}

// ---- rejection shapes ----------------------------------------------------------------------

test "follower: prev beyond a shorter log is refused with conflict zero and nothing changes" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 3 });
    const restore = restore_at(5, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try tick_n(&rig, 4);
    const batch = [_]Entry{entry_of(6, 5)};
    const effects = try recv(&rig, append_msg(2, 5, 5, 3, 9, &batch));
    try expect_rejected(effects, 9, 5, 0, 0);
    try testing.expectEqual(@as(usize, 2), effects.items.len); // The reply, then leader_changed.
    try testing.expect(effects.items[1] == .leader_changed);
    try fixtures.expect_entries_equal(start, rig.node.entries());
    try testing.expectEqual(@as(u32, 0), rig.node.election_elapsed); // Contact still resets.
    try testing.expectEqual(node_id(2), rig.node.status().leader);
}

test "follower: term mismatch reports the first index of the conflicting term run" {
    var buffer: [5]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 2, 2, 3 });
    const restore = restore_at(5, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const mid = try recv(&rig, append_msg(2, 5, 4, 3, 1, &.{}));
    try expect_rejected(mid, 1, 5, 2, 2); // Index 4 holds term 2, whose run starts at 2.
    const tail = try recv(&rig, append_msg(2, 5, 5, 2, 2, &.{}));
    try expect_rejected(tail, 2, 5, 5, 3); // A run of length one.
    const head = try recv(&rig, append_msg(2, 5, 1, 2, 3, &.{}));
    try expect_rejected(head, 3, 5, 1, 1); // The scan stops at index 1.
    try fixtures.expect_entries_equal(start, rig.node.entries());
}

// ---- effects -------------------------------------------------------------------------------

test "follower: conflicting entry emits truncate then append then the reply, bytes copied" {
    var buffer: [5]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 1, 2, 2, 2 });
    const restore = restore_at(4, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    var bytes = [_]u8{ 'X', 'Y' };
    const batch = [_]Entry{
        fixtures.entry(3, 3, bytes[0..1]),
        fixtures.entry(4, 3, bytes[1..2]),
    };
    const effects = try recv(&rig, append_msg(2, 4, 2, 1, 5, &batch));
    @memset(&bytes, 0); // The request buffer is borrowed until step returns only.

    try testing.expectEqual(@as(usize, 4), effects.items.len);
    try testing.expectEqual(idx(3), effects.items[0].truncate);
    try testing.expectEqual(idx(3), effects.items[1].append[0].index);
    try testing.expectEqual(@as(usize, 2), effects.items[1].append.len);
    try testing.expectEqualSlices(u8, "X", effects.items[1].append[0].data);
    try testing.expectEqualSlices(u8, "Y", effects.items[1].append[1].data);
    try testing.expectEqual(term(3), effects.items[1].append[1].term);
    try expect_in_arena(&rig, effects.items[1].append);
    try expect_accepted(effects, 5, 4, 4);
    try testing.expectEqual(node_id(2), effects.items[3].leader_changed);
    const log = rig.node.entries();
    try testing.expectEqual(@as(usize, 4), log.len);
    try testing.expectEqualSlices(u8, "X", log[2].data);
    try testing.expectEqual(term(3), log[3].term);
}

test "follower: matching prefix is skipped and only the new suffix is appended" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 1, 2 });
    const restore = restore_at(3, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{ entry_of(2, 1), entry_of(3, 2), entry_of(4, 3) };
    const effects = try recv(&rig, append_msg(2, 3, 1, 1, 2, &batch));
    try testing.expectEqual(@as(?u64, null), try truncate_of(effects));
    const appended = try appended_of(effects);
    try fixtures.expect_entries_equal(batch[2..], appended);
    try expect_accepted(effects, 2, 3, 4);
    try testing.expectEqual(@as(u32, 8), rig.node.bytes_used);
}

test "follower: replaying a request yields only the reply and a shorter replay never truncates" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 1, 2 });
    const restore = restore_at(3, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{ entry_of(2, 1), entry_of(3, 2), entry_of(4, 3) };
    _ = try recv(&rig, append_msg(2, 3, 1, 1, 1, &batch));
    const used = rig.node.bytes_used;

    for (0..2) |i| {
        const again = try recv(&rig, append_msg(2, 3, 1, 1, 2 + i, &batch));
        try testing.expectEqual(@as(usize, 1), again.items.len); // No persist, no leader_changed.
        try expect_accepted(again, 2 + i, 3, 4);
        try testing.expectEqual(@as(usize, 4), rig.node.entries().len);
        try testing.expectEqual(used, rig.node.bytes_used);
    }
    const stale = try recv(&rig, append_msg(2, 3, 1, 1, 9, batch[0..1]));
    try expect_accepted(stale, 9, 3, 2); // Acks what the request covers, keeps the rest.
    try testing.expectEqual(@as(usize, 1), stale.items.len);
    try testing.expectEqual(@as(usize, 4), rig.node.entries().len);
}

test "follower: heartbeat is accepted at prev and a mismatching one is refused" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 3 });
    const restore = restore_at(3, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try tick_n(&rig, 4);
    const beat = try recv(&rig, append_msg(2, 3, 2, 2, 1, &.{}));
    try expect_accepted(beat, 1, 3, 2);
    try testing.expectEqual(@as(usize, 2), beat.items.len); // Reply, then leader_changed.
    try testing.expectEqual(@as(u32, 0), rig.node.election_elapsed);
    try expect_accepted(try recv(&rig, append_msg(2, 3, 3, 3, 2, &.{})), 2, 3, 3);
    try expect_accepted(try recv(&rig, append_msg(2, 3, 0, 0, 3, &.{})), 3, 3, 0);
    try expect_rejected(try recv(&rig, append_msg(2, 3, 3, 2, 4, &.{})), 4, 3, 3, 3);
    try fixtures.expect_entries_equal(start, rig.node.entries());
    try testing.expectEqual(idx(0), rig.node.status().commit_index);
}

test "follower: higher-term request persists the term before the append and the reply" {
    const restore = restore_at(5, 0, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{entry_of(1, 6)};
    const effects = try recv(&rig, append_msg(2, 6, 0, 0, 4, &batch));
    try testing.expectEqual(@as(usize, 4), effects.items.len);
    try testing.expectEqual(fixtures.hard_state_of(6, 0, 0), effects.items[0].save_hard_state);
    try testing.expectEqual(idx(1), effects.items[1].append[0].index);
    try expect_accepted(effects, 4, 6, 1);
    try testing.expectEqual(node_id(2), effects.items[3].leader_changed);
}

test "follower: a candidate of the same term yields to the leader and accepts its entries" {
    const restore = restore_at(5, 0, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try rig.node.step(.tick);
    }
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 6, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);

    const batch = [_]Entry{entry_of(1, 6)};
    const effects = try recv(&rig, append_msg(2, 6, 0, 0, 1, &batch));
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try testing.expectEqual(node_id(2), rig.node.status().leader);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
    try expect_accepted(effects, 1, 6, 1);
    try testing.expectEqual(@as(usize, 1), rig.node.entries().len);
}

// ---- negative space: who may append --------------------------------------------------------

test "follower: stale-term request is answered with rejected zero at our term, nothing else" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 3 });
    const restore = restore_at(5, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try tick_n(&rig, 3);
    const batch = [_]Entry{entry_of(1, 4)};
    for ([_]u64{ 2, 3 }) |from| {
        const effects = try recv(&rig, append_msg(from, 4, 0, 0, 7, &batch));
        try testing.expectEqual(@as(usize, 1), effects.items.len);
        const reply = effects.items[0].send.append_entries_response;
        try testing.expectEqual(node_id(from), reply.header.to);
        try testing.expectEqual(term(5), reply.header.term);
        try testing.expectEqual(@as(u64, 7), reply.round);
        const zero: types.Conflict = .{ .index = idx(0), .term = term(0) };
        try testing.expectEqual(types.AppendOutcome{ .rejected = zero }, reply.outcome);
    }
    try fixtures.expect_entries_equal(start, rig.node.entries());
    try testing.expectEqual(node_module.Role.follower, rig.node.status().role);
    try testing.expectEqual(types.NodeId.none, rig.node.status().leader);
    try testing.expectEqual(@as(u32, 3), rig.node.election_elapsed); // Stale contact: no reset.
}

test "follower: non-member sender gets no reply and no mutation at any term" {
    const restore = restore_at(5, 0, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try tick_n(&rig, 2);
    for ([_]u64{ 4, 5, 6 }) |at_term| {
        const batch = [_]Entry{entry_of(1, at_term)};
        const effects = try recv(&rig, append_msg(9, at_term, 0, 0, 1, &batch));
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try testing.expectEqual(@as(usize, 0), rig.node.entries().len);
        try testing.expectEqual(term(5), rig.node.status().term);
        try testing.expectEqual(types.NodeId.none, rig.node.status().leader);
        try testing.expectEqual(@as(u32, 2), rig.node.election_elapsed);
    }
    // Nothing was poisoned: the real leader is still accepted at the same round.
    const own = [_]Entry{entry_of(1, 5)};
    try expect_accepted(try recv(&rig, append_msg(2, 5, 0, 0, 1, &own)), 1, 5, 1);
}

test "follower: learner cannot claim leadership or append" {
    const learners = [_]types.NodeId{node_id(4)};
    const cluster: types.Configuration = .{
        .voters = &fixtures.voters,
        .voters_outgoing = &.{},
        .learners = &learners,
    };
    const restore = fixtures.restore_with(cluster, fixtures.hard_state_of(5, 0, 0), &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{entry_of(1, 5)};
    const effects = try recv(&rig, append_msg(4, 5, 0, 0, 1, &batch));
    try testing.expectEqual(@as(usize, 0), effects.items.len);
    try testing.expectEqual(@as(usize, 0), rig.node.entries().len);
    try testing.expectEqual(types.NodeId.none, rig.node.status().leader);
    try expect_accepted(try recv(&rig, append_msg(2, 5, 0, 0, 2, &batch)), 2, 5, 1);
    try testing.expectEqual(node_id(2), rig.node.status().leader);
}

test "follower: a leader ignores a same-term append from another node" {
    const restore = restore_at(2, 0, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try rig.node.step(.tick);
    }
    _ = try recv(&rig, fixtures.pre_vote_response(2, 1, 3, true));
    _ = try recv(&rig, fixtures.vote_response(2, 1, 3, true));
    try testing.expectEqual(Role.leader, rig.node.status().role);

    const batch = [_]Entry{entry_of(1, 3)};
    const effects = try recv(&rig, append_msg(3, 3, 0, 0, 1, &batch));
    try testing.expectEqual(@as(usize, 0), effects.items.len);
    try testing.expectEqual(Role.leader, rig.node.status().role);
    try testing.expectEqual(@as(usize, 1), rig.node.entries().len);
    try testing.expectEqual(@as(usize, 0), rig.node.entries()[0].data.len); // Its own no-op.

    // A higher-term leader still deposes it and is then accepted on top of the no-op.
    const next = [_]Entry{entry_of(2, 4)};
    const deposed = try recv(&rig, append_msg(3, 4, 1, 3, 2, &next));
    try testing.expectEqual(Role.follower, rig.node.status().role);
    const reply = try sole_reply(deposed, 3, 2, 4);
    try testing.expectEqual(types.AppendOutcome{ .accepted = idx(2) }, reply.outcome);
}

// ---- committed entries are never truncated -------------------------------------------------

test "follower: a request conflicting at or below commit_index is dropped without mutation" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 3 });
    const restore = restore_at(4, 3, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const at_two = [_]Entry{ entry_of(2, 4), entry_of(3, 4) };
    try expect_dropped(try recv(&rig, append_msg(2, 4, 1, 1, 1, &at_two)));
    try fixtures.expect_entries_equal(start, rig.node.entries());
    const at_three = [_]Entry{ entry_of(3, 4), entry_of(4, 4) };
    try expect_dropped(try recv(&rig, append_msg(2, 4, 2, 2, 2, &at_three)));
    try fixtures.expect_entries_equal(start, rig.node.entries());
    try testing.expectEqual(idx(3), rig.node.status().commit_index);
    try testing.expectEqual(@as(u32, 6), rig.node.bytes_used);
    // The node is not wedged: a request that extends the committed log is accepted.
    const extend = [_]Entry{entry_of(4, 4)};
    try expect_accepted(try recv(&rig, append_msg(2, 4, 3, 3, 3, &extend)), 3, 4, 4);
}

test "follower: a conflict just above commit_index truncates, a fully matching one is accepted" {
    var buffer: [3]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2, 3 });
    const restore = restore_at(4, 2, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const matching = try recv(&rig, append_msg(2, 4, 0, 0, 1, start[0..2]));
    try expect_accepted(matching, 1, 4, 2);
    try testing.expectEqual(@as(?u64, null), try truncate_of(matching));
    try testing.expectEqual(@as(usize, 3), rig.node.entries().len);

    const batch = [_]Entry{entry_of(3, 4)};
    const effects = try recv(&rig, append_msg(2, 4, 2, 2, 2, &batch));
    try testing.expectEqual(@as(?u64, 3), try truncate_of(effects));
    try expect_accepted(effects, 2, 4, 3);
    try testing.expectEqual(term(4), rig.node.entries()[2].term);
    try testing.expectEqual(idx(2), rig.node.status().commit_index);
}

// ---- capacity ------------------------------------------------------------------------------

const cfg_entries4: Config = blk: {
    var c = cfg;
    c.log_entries_max = 4;
    break :blk c;
};

const cfg_bytes4: Config = blk: {
    var c = cfg;
    c.log_bytes_max = 4;
    break :blk c;
};

test "follower: an append that overflows the entry slots is dropped whole, no truncate either" {
    var buffer: [2]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2 });
    const restore = restore_at(4, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg_entries4, &restore, 1);
    defer rig.deinit(testing.allocator);

    // After cutting at 2 the log would hold 1 + 4 entries in 4 slots.
    const batch = [_]Entry{ entry_of(2, 3), entry_of(3, 3), entry_of(4, 3), entry_of(5, 3) };
    try expect_dropped(try recv(&rig, append_msg(2, 4, 1, 1, 1, &batch)));
    try fixtures.expect_entries_equal(start, rig.node.entries());
    try testing.expectEqual(@as(u32, 4), rig.node.bytes_used);
    // Nothing was cut: a request that fits extends the untouched log.
    const fits = [_]Entry{entry_of(3, 4)};
    try expect_accepted(try recv(&rig, append_msg(2, 4, 2, 2, 2, &fits)), 2, 4, 3);
}

test "follower: an append that overflows the byte arena is dropped whole" {
    var buffer: [1]Entry = undefined;
    const start = log_from(&buffer, &.{1});
    const restore = restore_at(4, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg_bytes4, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{ entry_of(2, 2), entry_of(3, 2) }; // 2 + 4 bytes in a 4-byte arena.
    try expect_dropped(try recv(&rig, append_msg(2, 4, 1, 1, 1, &batch)));
    try fixtures.expect_entries_equal(start, rig.node.entries());
    const fits = [_]Entry{entry_of(2, 2)};
    try expect_accepted(try recv(&rig, append_msg(2, 4, 1, 1, 2, &fits)), 2, 4, 2);
}

test "follower: space freed by the truncate counts, an exact fit is accepted" {
    var buffer: [4]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 1, 2, 2 });
    const restore = restore_at(4, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg_entries4, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{ entry_of(3, 3), entry_of(4, 3) };
    const effects = try recv(&rig, append_msg(2, 4, 2, 1, 1, &batch));
    try testing.expectEqual(@as(?u64, 3), try truncate_of(effects));
    try fixtures.expect_entries_equal(&batch, try appended_of(effects));
    try expect_accepted(effects, 1, 4, 4);
    try testing.expectEqual(@as(usize, 4), rig.node.entries().len);
    try testing.expectEqual(@as(u32, 8), rig.node.bytes_used);
}

// ---- seeded model --------------------------------------------------------------------------

fn below(prng: *fixtures.SplitMix, bound: u64) u64 {
    return prng.next_u64() % bound;
}

/// The naive reference follower: a plain array of terms.
const Reference = struct {
    terms: [16]u64 = undefined,
    len: usize = 0,
    truncate: u64 = 0,
    appended: usize = 0,

    fn step(
        ref: *Reference,
        prev: u64,
        prev_term: u64,
        entries: []const Entry,
    ) types.AppendOutcome {
        ref.truncate = 0;
        ref.appended = 0;
        if (prev > ref.len) return .{ .rejected = .{ .index = idx(0), .term = term(0) } };
        if (prev > 0 and ref.terms[prev - 1] != prev_term) {
            const bad = ref.terms[prev - 1];
            var first = prev;
            while (first > 1 and ref.terms[first - 2] == bad) first -= 1;
            return .{ .rejected = .{ .index = idx(first), .term = term(bad) } };
        }
        for (entries, 0..) |item, i| {
            const index = prev + i + 1;
            if (index <= ref.len and ref.terms[index - 1] == @intFromEnum(item.term)) continue;
            if (index <= ref.len) ref.truncate = index;
            ref.len = index - 1;
            for (entries[i..]) |rest| {
                ref.terms[ref.len] = @intFromEnum(rest.term);
                ref.len += 1;
            }
            ref.appended = entries.len - i;
            break;
        }
        return .{ .accepted = idx(prev + entries.len) };
    }
};

fn model_run(seed: u64) !void {
    var prng: fixtures.SplitMix = .{ .state = seed };
    // Leader terms are even, the follower's divergent suffix odd: equal (index, term) pairs
    // therefore always share their whole prefix, as the log matching property demands.
    var leader_terms_buffer: [10]u64 = undefined;
    const leader_len = below(&prng, 11);
    var leader_term: u64 = 2 * (1 + below(&prng, 2));
    for (leader_terms_buffer[0..leader_len]) |*slot| {
        if (leader_term < 6 and below(&prng, 3) == 0) leader_term += 2;
        slot.* = leader_term;
    }
    var follower_terms: [16]u64 = undefined;
    const shared = below(&prng, leader_len + 1);
    @memcpy(follower_terms[0..shared], leader_terms_buffer[0..shared]);
    var follower_len = shared;
    var odd: u64 = (if (shared == 0) 0 else leader_terms_buffer[shared - 1]) + 1;
    for (0..below(&prng, 5)) |_| {
        if (odd > 7) break;
        follower_terms[follower_len] = odd;
        follower_len += 1;
        odd += 2 * below(&prng, 2);
    }

    var leader_buffer: [10]Entry = undefined;
    var follower_buffer: [16]Entry = undefined;
    const leader = log_from(&leader_buffer, leader_terms_buffer[0..leader_len]);
    const start = log_from(&follower_buffer, follower_terms[0..follower_len]);
    const restore = restore_at(8, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, seed);
    defer rig.deinit(testing.allocator);
    var ref: Reference = .{ .len = follower_len };
    @memcpy(ref.terms[0..follower_len], follower_terms[0..follower_len]);

    for (0..24) |step| {
        const prev = below(&prng, leader_len + 1);
        const count = below(&prng, @as(u64, @min(3, leader_len - prev)) + 1);
        const batch = leader[prev .. prev + count];
        const prev_term: u64 = if (prev == 0) 0 else @intFromEnum(leader[prev - 1].term);
        const effects = try recv(&rig, append_msg(2, 8, prev, prev_term, step + 1, batch));

        const want = ref.step(prev, prev_term, batch);
        const reply = try sole_reply(effects, 2, step + 1, 8);
        try testing.expectEqual(want, reply.outcome);
        const cut: ?u64 = if (ref.truncate == 0) null else ref.truncate;
        try testing.expectEqual(cut, try truncate_of(effects));
        try testing.expectEqual(ref.appended, (try appended_of(effects)).len);

        const log = rig.node.entries();
        try testing.expectEqual(ref.len, log.len);
        for (log, ref.terms[0..ref.len], 0..) |item, want_term, i| {
            try testing.expectEqual(term(want_term), item.term);
            try testing.expectEqualSlices(u8, &data_table[i + 1][want_term], item.data);
        }
        if (want == .accepted) {
            const covered = prev + count;
            try fixtures.expect_entries_equal(leader[0..covered], log[0..covered]);
        }
        try testing.expectEqual(@as(u32, @intCast(2 * ref.len)), rig.node.bytes_used);
        try testing.expectEqual(idx(0), rig.node.status().commit_index);
    }
}

test "follower: seeded random requests match a naive reference and keep prefix consistency" {
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        errdefer std.log.err("follower model failed at seed {d}", .{seed});
        try model_run(seed);
    }
}

// ---- first claim stands, term bumps, non-voter members --------------------------------------

test "follower: a second voter claiming the same term is dropped and the first leader stays" {
    var buffer: [2]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2 });
    const restore = restore_at(5, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try expect_accepted(try recv(&rig, append_msg(2, 5, 2, 2, 1, &.{})), 1, 5, 2);
    try tick_n(&rig, 3);
    const rival = [_]Entry{entry_of(2, 5)}; // Would cut index 2 if it were honored.
    const effects = try recv(&rig, append_msg(3, 5, 1, 1, 2, &rival));
    try testing.expectEqual(@as(usize, 0), effects.items.len);
    try testing.expectEqual(node_id(2), rig.node.status().leader);
    try testing.expectEqual(@as(u32, 3), rig.node.election_elapsed);
    try fixtures.expect_entries_equal(start, rig.node.entries());
}

test "follower: a learner adopts a higher term but never claims, replies or touches the log" {
    const learners = [_]types.NodeId{node_id(4)};
    const cluster: types.Configuration = .{
        .voters = &fixtures.voters,
        .voters_outgoing = &.{},
        .learners = &learners,
    };
    var buffer: [1]Entry = undefined;
    const start = log_from(&buffer, &.{1});
    const restore = fixtures.restore_with(cluster, fixtures.hard_state_of(5, 0, 0), start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    const batch = [_]Entry{entry_of(2, 6)};
    // No leader known yet: the bump persists the term and announces nothing.
    const first = try recv(&rig, append_msg(4, 6, 1, 1, 1, &batch));
    try testing.expectEqual(@as(usize, 1), first.items.len);
    try testing.expectEqual(fixtures.hard_state_of(6, 0, 0), first.items[0].save_hard_state);
    try testing.expectEqual(term(6), rig.node.status().term);
    try testing.expectEqual(types.NodeId.none, rig.node.status().leader);

    // Leader 2 is known at term 6; a learner at term 7 forgets it, announces none, claims nothing.
    try expect_accepted(try recv(&rig, append_msg(2, 6, 1, 1, 2, &.{})), 2, 6, 1);
    const second = try recv(&rig, append_msg(4, 7, 1, 1, 3, &batch));
    try testing.expectEqual(@as(usize, 2), second.items.len);
    try testing.expectEqual(fixtures.hard_state_of(7, 0, 0), second.items[0].save_hard_state);
    try testing.expectEqual(types.NodeId.none, second.items[1].leader_changed);
    try testing.expectEqual(term(7), rig.node.status().term);
    try testing.expectEqual(types.NodeId.none, rig.node.status().leader);
    try fixtures.expect_entries_equal(start, rig.node.entries());
}

test "follower: a higher-term voter replaces the known leader with effects in phase order" {
    var buffer: [2]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 2 });
    const restore = restore_at(5, 0, start);
    var rig: Rig = undefined;
    try rig.init(testing.allocator, cfg, &restore, 1);
    defer rig.deinit(testing.allocator);

    try expect_accepted(try recv(&rig, append_msg(2, 5, 2, 2, 1, &.{})), 1, 5, 2);
    const batch = [_]Entry{entry_of(2, 6)};
    const effects = try recv(&rig, append_msg(3, 6, 1, 1, 2, &batch));
    try testing.expectEqual(@as(usize, 6), effects.items.len);
    try testing.expectEqual(fixtures.hard_state_of(6, 0, 0), effects.items[0].save_hard_state);
    try testing.expectEqual(idx(2), effects.items[1].truncate);
    try fixtures.expect_entries_equal(&batch, effects.items[2].append);
    const reply = effects.items[3].send.append_entries_response;
    try testing.expectEqual(node_id(3), reply.header.to);
    try testing.expectEqual(types.AppendOutcome{ .accepted = idx(2) }, reply.outcome);
    try testing.expectEqual(types.NodeId.none, effects.items[4].leader_changed);
    try testing.expectEqual(node_id(3), effects.items[5].leader_changed);
    try testing.expectEqual(node_id(3), rig.node.status().leader);
}

test "follower: for every commit_index a conflict at or below it is dropped, above it applied" {
    const old = [_]u64{ 1, 1, 1 };
    for (0..4) |commit| {
        for (1..4) |conflict| {
            var buffer: [3]Entry = undefined;
            const start = log_from(&buffer, &old);
            const restore = restore_at(4, commit, start);
            var rig: Rig = undefined;
            try rig.init(testing.allocator, cfg, &restore, 1);
            defer rig.deinit(testing.allocator);

            var batch: [3]Entry = undefined;
            const count = 4 - conflict;
            for (batch[0..count], 0..) |*slot, i| slot.* = entry_of(conflict + i, 2);
            const prev_term: u64 = if (conflict == 1) 0 else 1;
            const message = append_msg(2, 4, conflict - 1, prev_term, 1, batch[0..count]);
            const effects = try recv(&rig, message);
            if (conflict <= commit) {
                try expect_dropped(effects);
                try fixtures.expect_entries_equal(start, rig.node.entries());
                try testing.expectEqual(@as(u32, 6), rig.node.bytes_used);
            } else {
                try expect_accepted(effects, 1, 4, 3);
                try testing.expectEqual(@as(?u64, conflict), try truncate_of(effects));
                try testing.expectEqual(term(2), rig.node.entries()[conflict - 1].term);
                for (rig.node.entries()[0 .. conflict - 1]) |kept| {
                    try testing.expectEqual(term(1), kept.term); // The prefix is untouched.
                }
            }
            try testing.expectEqual(idx(commit), rig.node.status().commit_index);
        }
    }
}

test "follower: the worst step fills every effect slot, with the commit saved after the append" {
    // One voter per set: `peers_max = 1`, the smallest effect array (`peers_max + 7` = 8 slots).
    var tight = cfg;
    tight.voters_max = 1;
    tight.learners_max = 0;
    const incoming = [_]types.NodeId{node_id(2)};
    const outgoing = [_]types.NodeId{node_id(3)};
    var buffer: [2]Entry = undefined;
    const start = log_from(&buffer, &.{ 1, 1 });
    const restore = fixtures.restore_with(
        .{ .voters = &incoming, .voters_outgoing = &outgoing, .learners = &.{} },
        fixtures.hard_state_of(1, 0, 0),
        start,
    );
    var rig: Rig = undefined;
    try rig.init(testing.allocator, tight, &restore, 1);
    defer rig.deinit(testing.allocator);
    _ = try recv(&rig, append_msg(2, 1, 2, 1, 1, &.{})); // Node 2 leads term 1.

    // Node 3 takes term 2, cuts our entry 2, appends its own and commits through it.
    const fresh_tail = [_]Entry{entry_of(2, 2)};
    var message = append_msg(3, 2, 1, 1, 2, &fresh_tail);
    message.append_entries.leader_commit = idx(2);
    const effects = try recv(&rig, message);
    try testing.expectEqual(@as(usize, fixtures.effects_capacity(tight)), effects.items.len);
    try testing.expectEqual(fixtures.hard_state_of(2, 0, 0), effects.items[0].save_hard_state);
    try testing.expectEqual(idx(2), effects.items[1].truncate);
    try fixtures.expect_entries_equal(&fresh_tail, effects.items[2].append);
    try testing.expectEqual(fixtures.hard_state_of(2, 0, 2), effects.items[3].save_hard_state);
    try expect_accepted_from(effects, 3, 2, 2, 2);
    try fixtures.expect_entries_equal(&.{ start[0], fresh_tail[0] }, effects.items[5].apply);
    try testing.expectEqual(types.NodeId.none, effects.items[6].leader_changed);
    try testing.expectEqual(node_id(3), effects.items[7].leader_changed);
}

fn expect_accepted_from(effects: Effects, to: u64, round: u64, at_term: u64, matched: u64) !void {
    const reply = try sole_reply(effects, to, round, at_term);
    try testing.expectEqual(types.AppendOutcome{ .accepted = idx(matched) }, reply.outcome);
}
