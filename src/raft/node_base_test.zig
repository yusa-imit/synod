//! Regression tests for the peer-reachable paths of `Node` over a compacted log (review of
//! plan 005 item 3): a follower whose log base is 4 (term 1) receives requests whose
//! `prev_log_index` lies below, at and above the base; a three-voter leader with that base sends
//! from, and below, the base and advances its commit index.
//!
//! Expected values come from Raft's log matching (entries up to the base are committed, so equal
//! to the leader's) and from arithmetic on the base, never from the node. A request that
//! contradicts the base (the leader's entry at the base carries another term) or a commit
//! (conflict at or below `commit_index`) is peer data: dropped whole, with no reply.
//!
//! Setup: `fixtures.config` (compaction due 7 applied entries past the base, 3 kept), node 1,
//! a follower of node 2 at term 1 that applied entries 1..7 (term 1) and saved the snapshot at
//! 7: base 4, live entries 5..7. `with_tail` adds uncommitted entries 8..10.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const idx = fixtures.idx;
const term = fixtures.term;

const fresh = fixtures.restore_of(.empty, &.{});

fn config_of() Config {
    var result = fixtures.config;
    result.log_entries_max = 16;
    result.log_bytes_max = 64;
    result.message_limits.entries_max = 8;
    result.snapshot_entries_min = 7; // Compaction on: the fixture default turns it off.
    result.snapshot_trailing = 3;
    return result;
}

/// Entries `first..first + count` at `term_value`, one byte each.
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

/// A follower of node 2 at term 1 with base 4 (term 1), entries 5..7, commit and applied 7.
fn compacted(rig: *Rig) !void {
    try rig.init_fixed(testing.allocator, config_of(), &fresh, 0);
    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 1, 7, 1);
    const effects = try recv(rig, fixtures.append_request(2, 1, 0, 0, 7, batch));
    try fixtures.expect_ack(effects, 2, 7);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .snapshot_due));

    const saved = try rig.node.step(.{ .snapshot_saved = idx(7) });
    try testing.expectEqual(@as(usize, 0), saved.items.len);
    try expect_shape(rig, 4, 7);
}

/// Uncommitted entries 8..10 (term 1) on top of `compacted`.
fn with_tail(rig: *Rig) !void {
    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 8, 3, 1);
    const effects = try recv(rig, fixtures.append_request(2, 1, 7, 1, 7, batch));
    try fixtures.expect_ack(effects, 2, 10);
    try expect_shape(rig, 4, 10);
}

fn expect_shape(rig: *Rig, base: u64, last: u64) !void {
    try testing.expectEqual(idx(base), rig.node.log.base.index);
    try testing.expectEqual(term(1), rig.node.log.base.term);
    try testing.expectEqual(idx(last), rig.node.log.last_index());
    try testing.expectEqual(@as(u32, @intCast(last - base)), rig.node.log.count);
    try testing.expectEqual(@as(u32, @intCast(last - base)), rig.node.bytes_used);
}

/// The request changed nothing durable and drew no reply.
fn expect_dropped(effects: Effects) !void {
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .send));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .truncate));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .append));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .apply));
}

/// A reply that stores nothing: no truncate, append or commit save.
fn expect_ack_only(effects: Effects, matched: u64) !void {
    try fixtures.expect_ack(effects, 2, matched);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .truncate));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .append));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .save_hard_state));
}

// ---- follower: prev below the base ---------------------------------------------------------

test "base follower: a batch ending below the base is accepted at its last index, untouched" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 2, 2, 1); // Indices 2, 3: skip 3 > 2 entries.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 1, 1, 10, batch));
    try expect_ack_only(effects, 3);
    try expect_shape(&rig, 4, 7);
    try testing.expectEqual(idx(7), rig.node.status().commit_index);
}

test "base follower: a batch ending at the base needs its last entry to carry the base term" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 2, 3, 1); // Indices 2..4: skip 3 == 3 entries, term 1 = base.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 1, 1, 10, batch));
    try expect_ack_only(effects, 4);
    try expect_shape(&rig, 4, 7);

    // The leader of term 2 sends index 4 at term 2: it contradicts the base. Dropped whole.
    const forged = span(&buffer, 2, 3, 1);
    forged[2].term = term(2);
    const dropped = try recv(&rig, fixtures.append_request(2, 2, 1, 1, 10, forged));
    try expect_dropped(dropped);
    try expect_shape(&rig, 4, 7);
}

test "base follower: a base-term mismatch inside a longer batch drops it whole" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 2, 5, 2); // Indices 2..6, all term 2: index 4 is not term 1.
    batch[0].term = term(1);
    batch[1].term = term(1);
    const effects = try recv(&rig, fixtures.append_request(2, 2, 1, 1, 10, batch));
    try expect_dropped(effects);
    try expect_shape(&rig, 4, 7);
}

test "base follower: a request from before the base is trimmed, then replicated above it" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 2, 7, 1); // Indices 2..8; 4..7 are held, 8 is new.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 1, 1, 8, batch));
    try fixtures.expect_ack(effects, 2, 8);
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .truncate));
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .append));
    try expect_shape(&rig, 4, 8);
    try testing.expectEqual(idx(8), rig.node.status().commit_index);
}

// ---- follower: prev at the base ------------------------------------------------------------

test "base follower: prev at the base with another term is rejected at the base" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 5, 1, 2);
    const effects = try recv(&rig, fixtures.append_request(2, 2, 4, 2, 7, batch));
    const reply = try fixtures.reply_of(effects);
    const want: types.AppendOutcome = .{ .rejected = .{ .index = idx(4), .term = term(1) } };
    try testing.expectEqual(want, reply.outcome);
    try expect_shape(&rig, 4, 7);
}

test "base follower: prev at the base with the base term extends the log" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 5, 5, 1); // Indices 5..9; 5..7 are held.
    const effects = try recv(&rig, fixtures.append_request(2, 1, 4, 1, 7, batch));
    try fixtures.expect_ack(effects, 2, 9);
    try expect_shape(&rig, 4, 9);
}

// ---- follower: conflicts above the base ----------------------------------------------------

test "base follower: a conflict above the base but at the commit index is dropped" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const batch = span(&buffer, 5, 2, 1);
    batch[1].term = term(2); // Index 6, committed here at term 1.
    const effects = try recv(&rig, fixtures.append_request(2, 2, 4, 1, 7, batch));
    try expect_dropped(effects);
    try expect_shape(&rig, 4, 7);
}

test "base follower: a conflict in the uncommitted tail cuts the log above the base" {
    const cases = [_]struct { prev: u64, truncate_from: u64, last: u64 }{
        .{ .prev = 7, .truncate_from = 8, .last = 9 }, // Right above the commit index.
        .{ .prev = 8, .truncate_from = 9, .last = 10 },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try compacted(&rig);
        defer rig.deinit(testing.allocator);

        try with_tail(&rig);
        var buffer: [8]Entry = undefined;
        const batch = span(&buffer, case.prev + 1, 2, 2);
        const effects = try recv(&rig, fixtures.append_request(2, 2, case.prev, 1, 7, batch));
        try fixtures.expect_ack(effects, 2, case.last);
        try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .truncate));
        const cut = fixtures.index_of(effects, .truncate).?;
        try testing.expectEqual(idx(case.truncate_from), effects.items[cut].truncate);
        try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .append));
        try expect_shape(&rig, 4, case.last);
        try testing.expectEqual(term(2), rig.node.entries()[rig.node.log.count - 1].term);
        try testing.expectEqual(idx(7), rig.node.status().commit_index);
    }
}

// ---- leader --------------------------------------------------------------------------------

/// Ticks the compacted follower to leader of term 2 with node 2's votes; returns the winning
/// step's effects. The new leader's empty entry is index 8, sent to both peers with prev 7.
fn lead(rig: *Rig) !Effects {
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        try testing.expect(guard < 40);
        _ = try rig.node.step(.tick);
    }
    _ = try recv(rig, fixtures.pre_vote_response(2, 1, 2, true));
    try testing.expectEqual(Role.candidate, rig.node.status().role);
    const effects = try recv(rig, fixtures.vote_response(2, 1, 2, true));
    try testing.expectEqual(Role.leader, rig.node.status().role);
    try testing.expectEqual(idx(4), rig.node.log.base.index);
    try testing.expectEqual(idx(8), rig.node.log.last_index()); // The empty entry holds no bytes.
    return effects;
}

fn response(from: u64, round: u64, outcome: types.AppendOutcome) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, 2),
        .round = round,
        .outcome = outcome,
    } };
}

fn rejected_at(from: u64, round: u64, conflict_index: u64) Message {
    const conflict: types.Conflict = .{ .index = idx(conflict_index), .term = term(1) };
    return response(from, round, .{ .rejected = conflict });
}

test "base leader: a peer backtracking to the base is sent prev = base with the base term" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    const won = try lead(&rig);
    const first = try fixtures.append_to(won, 2);
    try testing.expectEqual(idx(7), first.prev_log_index);

    const effects = try recv(&rig, rejected_at(2, first.round, 5)); // Resume at next = 5.
    const request = try fixtures.append_to(effects, 2);
    try testing.expectEqual(idx(4), request.prev_log_index);
    try testing.expectEqual(term(1), request.prev_log_term); // The base term.
    try testing.expectEqual(@as(usize, 4), request.entries.len); // Indices 5..8.
    try testing.expectEqual(idx(5), request.entries[0].index);
}

test "base leader: a peer needing entries below the base gets nothing until a snapshot" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    const won = try lead(&rig);
    const first = try fixtures.append_to(won, 2);
    const probe = try recv(&rig, rejected_at(2, first.round, 5));
    const at_base = try fixtures.append_to(probe, 2);

    const effects = try recv(&rig, rejected_at(2, at_base.round, 4)); // next = 4: first = 3 < 4.
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .send));
    try testing.expectEqual(Role.leader, rig.node.status().role);
}

test "base leader: two voters' acks above the base advance the commit index" {
    var rig: Rig = undefined;
    try compacted(&rig);
    defer rig.deinit(testing.allocator);

    const won = try lead(&rig);
    const first = try fixtures.append_to(won, 2);
    try testing.expectEqual(idx(7), rig.node.status().commit_index);

    const effects = try recv(&rig, response(2, first.round, .{ .accepted = idx(8) }));
    try testing.expectEqual(idx(8), rig.node.status().commit_index); // Self and 2 of 3.
    try testing.expectEqual(idx(8), (try fixtures.last_hard_state(effects)).commit_index);
    try fixtures.expect_apply(effects, rig.node.entries()[rig.node.log.count - 1 ..]);
    try testing.expectEqual(idx(4), rig.node.log.base.index);
}

// ---- the save step is quiet ----------------------------------------------------------------

test "snapshot save: a due owed at the save is emitted by the next step, not by the save" {
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, config_of(), &fresh, 0);
    defer rig.deinit(testing.allocator);

    var buffer: [8]Entry = undefined;
    const first = try recv(&rig, fixtures.append_request(2, 1, 0, 0, 7, span(&buffer, 1, 7, 1)));
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(first, .snapshot_due));
    // Applied moves to 11 while the due for 7 is pending: no second due.
    const more = try recv(&rig, fixtures.append_request(2, 1, 7, 1, 11, span(&buffer, 8, 4, 1)));
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(more, .snapshot_due));

    // Saving 7 leaves base 4; 11 - 4 = 7 owes a due, but the save step must stay empty.
    const saved = try rig.node.step(.{ .snapshot_saved = idx(7) });
    try testing.expectEqual(@as(usize, 0), saved.items.len);
    try testing.expectEqual(idx(4), rig.node.log.base.index);

    const next = try rig.node.step(.tick);
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(next, .snapshot_due));
    const due = next.items[next.items.len - 1].snapshot_due;
    try testing.expectEqual(idx(11), due.snapshot.index);
    try testing.expectError(error.SnapshotUnexpected, rig.node.step(.{ .snapshot_saved = idx(7) }));
}
