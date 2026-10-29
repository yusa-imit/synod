//! Tests for the compaction policy in the node (plan 005 item 3, ADR-009 "Who snapshots"): at
//! the end of a step with no `snapshot_due` pending and `applied - log.base.index >=
//! snapshot_entries_min`, the node emits `snapshot_due` (`applied`, its term, the configuration
//! as of `applied`); `Input.snapshot_saved(index)` must name the pending due, emits nothing,
//! records `Status.snapshot_index` and compacts the log through `max(base, index -|
//! snapshot_trailing)`; `check_invariants` states `log.base <= snapshot_index <= applied`.
//!
//! Expected values come from that contract and from arithmetic on it, never from the node. The
//! `Harness` is the trivial reference model: it counts `apply` entries, tracks the base and
//! snapshot index the contract implies, and after every step checks the ADR-007 phase order,
//! `check_invariants()`, that a due appears exactly when the model says one is owed (and is the
//! only one, and last), and that a save leaves the log where the model puts it.
//!
//! Assumed new names: `Config.{snapshot_entries_min, snapshot_trailing}`, `Input.snapshot_saved:
//! Index`, `Effect.snapshot_due` (payload `.snapshot: log.Base`, `.configuration`),
//! `Effect.Phase.snapshot = 5`, `Status.snapshot_index`, `Node.snapshot_index` (the field a test
//! corrupts), `StepError.SnapshotUnexpected`, `InvariantError.InvariantBaseBeyondApplied`.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Effect = node_module.Effect;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

const lone_ids = [_]types.NodeId{node_id(1)};
const lone_configuration: types.Configuration = .{
    .voters = &lone_ids,
    .voters_outgoing = &.{},
    .learners = &.{},
};
const lone = fixtures.restore_with(lone_configuration, .empty, &.{});
const fresh = fixtures.restore_of(.empty, &.{});

/// `fixtures.config` with the compaction knobs and log sizes set; `message_limits.entries_max`
/// is 8 so one `append_entries` can carry a threshold-sized batch.
fn config_of(entries_max: u32, min: u32, trailing: u32) Config {
    var result = fixtures.config;
    result.log_entries_max = entries_max;
    result.log_bytes_max = 256;
    result.snapshot_entries_min = min;
    result.snapshot_trailing = trailing;
    result.message_limits.entries_max = 8;
    return result;
}

// ---- harness: the reference model ----------------------------------------------------------

const Harness = struct {
    rig: Rig,
    /// Entries seen in `apply` effects, contiguous from 1.
    applied: u64,
    /// The model's log base and `Status.snapshot_index` after the saves so far.
    base: u64,
    snapshot: u64,
    /// The index of the due the node has emitted and the driver has not yet saved.
    pending: ?u64,
    /// Dues emitted over the run.
    dues: u32,
    /// Every entry in these tests carries this term.
    entry_term: u64,

    fn init(h: *Harness, node_config: Config, restore: *const Restore, entry_term: u64) !void {
        h.applied = 0;
        h.base = 0;
        h.snapshot = 0;
        h.pending = null;
        h.dues = 0;
        h.entry_term = entry_term;
        try h.rig.init_fixed(testing.allocator, node_config, restore, 0); // Timeout t = 10.
    }

    fn deinit(h: *Harness) void {
        h.rig.deinit(testing.allocator);
    }

    fn node(h: *Harness) *node_module.Node {
        return &h.rig.node;
    }

    fn min(h: *Harness) u64 {
        return h.rig.node.config.snapshot_entries_min;
    }

    fn trailing(h: *Harness) u64 {
        return h.rig.node.config.snapshot_trailing;
    }

    /// The checks after every step except `snapshot_saved`.
    fn observe(h: *Harness, effects: Effects) !void {
        try fixtures.expect_effects_ordered(effects, h.node().config);
        try h.node().check_invariants();
        for (effects.items) |effect| switch (effect) {
            .apply => |batch| {
                for (batch) |item| {
                    h.applied += 1;
                    try testing.expectEqual(h.applied, @intFromEnum(item.index));
                }
            },
            else => {},
        };
        try testing.expectEqual(idx(h.applied), h.node().status().applied_index);
        try h.expect_due(effects);
    }

    /// A due appears exactly when none is pending and `applied - base >= min`; it is the one
    /// and only, it is last, and it names the applied index, its term and the configuration.
    fn expect_due(h: *Harness, effects: Effects) !void {
        const owed = h.pending == null and h.applied - h.base >= h.min();
        const count = fixtures.count_effects(effects, .snapshot_due);
        try testing.expectEqual(@as(u32, @intFromBool(owed)), count);
        if (!owed) return;

        const last = effects.items[effects.items.len - 1];
        try testing.expect(last == .snapshot_due);
        try testing.expectEqual(Effect.Phase.snapshot, last.phase());
        const due = last.snapshot_due;
        try testing.expectEqual(idx(h.applied), due.snapshot.index);
        try testing.expectEqual(term(h.entry_term), due.snapshot.term);
        const want = h.node().configuration;
        try testing.expectEqualSlices(types.NodeId, want.voters, due.configuration.voters);
        try testing.expectEqual(@as(usize, 0), due.configuration.voters_outgoing.len);
        try testing.expectEqualSlices(types.NodeId, want.learners, due.configuration.learners);
        h.pending = h.applied;
        h.dues += 1;
    }

    fn tick(h: *Harness) !Effects {
        const effects = try h.node().step(.tick);
        try h.observe(effects);
        return effects;
    }

    fn propose(h: *Harness, number: u32) !Effects {
        var data: [4]u8 = undefined;
        std.mem.writeInt(u32, &data, number, .little);
        const effects = try h.node().step(.{ .propose = &data });
        try h.observe(effects);
        return effects;
    }

    fn recv(h: *Harness, message: Message) !Effects {
        const effects = try h.rig.receive(&message);
        try h.observe(effects);
        return effects;
    }

    /// Ticks a lone voter into leadership; its empty entry is applied in the winning step.
    fn elect(h: *Harness) !void {
        var guard: u32 = 0;
        while (h.node().status().role != .leader) : (guard += 1) {
            try testing.expect(guard < 40);
            _ = try h.tick();
        }
        try testing.expectEqual(Role.leader, h.node().status().role);
    }

    /// The driver confirms the pending due: no effects, and the log is where the model says.
    fn save(h: *Harness) !void {
        const index = h.pending orelse return error.TestUnexpectedResult;
        const last_before = h.node().log.last_index();
        const effects = try h.node().step(.{ .snapshot_saved = idx(index) });
        try testing.expectEqual(@as(usize, 0), effects.items.len);
        try h.node().check_invariants();

        h.pending = null;
        h.snapshot = index;
        h.base = @max(h.base, index -| h.trailing());
        try testing.expectEqual(idx(h.snapshot), h.node().status().snapshot_index);
        try testing.expectEqual(idx(h.base), h.node().log.base.index);
        try testing.expectEqual(last_before, h.node().log.last_index());
        const kept: u64 = @intFromEnum(last_before) - h.base;
        try testing.expectEqual(@as(u32, @intCast(kept)), h.node().log.count);
        if (h.base > 0) try testing.expectEqual(term(h.entry_term), h.node().log.base.term);
        if (h.node().log.count > 0) {
            try testing.expectEqual(idx(h.base + 1), h.node().entries()[0].index);
        }
    }

    /// One step of `effects`, then the driver's save when a due came out of it.
    fn drive(h: *Harness, effects: Effects) !void {
        if (fixtures.count_effects(effects, .snapshot_due) > 0) try h.save();
    }

    fn drive_propose(h: *Harness, number: u32) !void {
        try h.drive(try h.propose(number));
    }
};

fn append(from_prev: u64, commit: u64, batch: []const Entry) Message {
    const prev_term: u64 = if (from_prev == 0) 0 else 1;
    return fixtures.append_request(2, 1, from_prev, prev_term, commit, batch);
}

/// Follower of leader 2 at term 1 receives `count` term-1 entries after `prev`, committing
/// through `commit`; the reply must accept exactly `prev + count`.
fn follow(h: *Harness, prev: u64, count: u32, commit: u64) !Effects {
    var batch: [8]Entry = undefined;
    for (batch[0..count], 0..) |*slot, i| {
        slot.* = fixtures.entry(prev + @as(u64, i) + 1, 1, "ab");
    }
    const effects = try h.recv(append(prev, commit, batch[0..count]));
    try fixtures.expect_ack(effects, 2, prev + count);
    return effects;
}

// ---- the plan's failing test ---------------------------------------------------------------

test "snapshot policy: a 64-slot lone leader applies 500 proposals, compacting every 24 entries" {
    const node_config = config_of(64, 32, 8);
    var h: Harness = undefined;
    try h.init(node_config, &lone, 1);
    defer h.deinit();
    try h.elect(); // Entry 1; applied 1.

    for (1..501) |number| try h.drive_propose(@intCast(number));

    // The first due is owed at applied 32 (base 0); a save at S leaves base S - 8, so the next
    // is owed at S + 24: S = 32, 56, ..., 488, which is 20 snapshots. 501 entries are applied.
    try testing.expectEqual(@as(u64, 501), h.applied);
    try testing.expectEqual(@as(u32, 20), h.dues);
    const status = h.node().status();
    try testing.expectEqual(idx(501), status.applied_index);
    try testing.expectEqual(idx(501), status.last_index);
    try testing.expectEqual(idx(488), status.snapshot_index);
    try testing.expectEqual(idx(480), h.node().log.base.index);
    try testing.expectEqual(@as(u32, 21), h.node().log.count);

    // The trailing entries are still the proposals that produced them: index i holds number i-1.
    for (h.node().entries(), 0..) |kept, k| {
        const index: u32 = @intCast(481 + k);
        try testing.expectEqual(idx(index), kept.index);
        const number = std.mem.readInt(u32, kept.data[0..4], .little);
        try testing.expectEqual(index - 1, number);
    }
    try h.node().check_invariants();
}

test "snapshot policy: a follower applying 100 entries in batches of four compacts as it goes" {
    const node_config = config_of(16, 8, 2);
    var h: Harness = undefined;
    try h.init(node_config, &fresh, 1);
    defer h.deinit();

    var prev: u64 = 0;
    while (prev < 100) : (prev += 4) {
        try h.drive(try follow(&h, prev, 4, prev + 4));
    }

    try testing.expectEqual(@as(u64, 100), h.applied);
    try testing.expect(h.dues >= 10);
    const status = h.node().status();
    try testing.expectEqual(idx(100), status.last_index);
    try testing.expectEqual(idx(h.snapshot), status.snapshot_index);
    try testing.expect(h.node().log.base.index != .zero);
    try testing.expect(h.node().log.count <= 16);
    // Entries the follower still holds match what the leader sent.
    for (h.node().entries()) |kept| try testing.expectEqualSlices(u8, "ab", kept.data);
}

// ---- threshold -----------------------------------------------------------------------------

test "snapshot policy: one entry short of the threshold emits no due" {
    var h: Harness = undefined;
    try h.init(config_of(8, 5, 2), &fresh, 1);
    defer h.deinit();

    const effects = try follow(&h, 0, 4, 4); // applied 4 = min - 1
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .snapshot_due));
    try testing.expectEqual(@as(u32, 0), h.dues);
    try testing.expectEqual(idx(0), h.node().status().snapshot_index);
    try testing.expectEqual(idx(0), h.node().log.base.index);
    const more = try h.tick();
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(more, .snapshot_due));
}

test "snapshot policy: exactly the threshold emits one due naming the applied index" {
    var h: Harness = undefined;
    try h.init(config_of(8, 5, 2), &fresh, 1);
    defer h.deinit();

    const effects = try follow(&h, 0, 5, 5); // applied 5 = min
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .snapshot_due));
    try testing.expectEqual(@as(?u64, 5), h.pending);
    try testing.expectEqual(idx(0), h.node().status().snapshot_index); // Nothing saved yet.
    try testing.expectEqual(idx(0), h.node().log.base.index); // Nothing compacted yet.
}

test "snapshot policy: one entry past the threshold names applied, not the threshold" {
    var h: Harness = undefined;
    try h.init(config_of(8, 5, 2), &fresh, 1);
    defer h.deinit();

    const effects = try follow(&h, 0, 6, 6); // applied 6 = min + 1 in one step
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .snapshot_due));
    try testing.expectEqual(@as(?u64, 6), h.pending);
    try h.save();
    try testing.expectEqual(idx(4), h.node().log.base.index); // 6 - trailing 2
}

test "snapshot policy: appended but uncommitted entries do not count toward the threshold" {
    var h: Harness = undefined;
    try h.init(config_of(8, 5, 2), &fresh, 1);
    defer h.deinit();

    const held = try follow(&h, 0, 6, 0); // Six entries in the log, none committed.
    try testing.expectEqual(@as(u32, 0), fixtures.count_effects(held, .snapshot_due));
    try testing.expectEqual(@as(u64, 0), h.applied);

    const commit = try follow(&h, 6, 0, 6); // The commit arrives: applied 6, a due is owed.
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(commit, .snapshot_due));
    try testing.expectEqual(@as(?u64, 6), h.pending);
}

test "snapshot policy: the threshold is counted from the base, not from zero" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect(); // applied 1
    for (1..4) |n| try h.drive_propose(@intCast(n)); // applied 4: due, saved, base 3
    try testing.expectEqual(@as(u32, 1), h.dues);
    try testing.expectEqual(idx(3), h.node().log.base.index);

    for (4..6) |n| { // applied 5, 6: both under 4 past the base
        const effects = try h.propose(@intCast(n));
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .snapshot_due));
    }
    try testing.expectEqual(@as(u32, 1), h.dues);
    try h.drive_propose(6); // applied 7 = base 3 + 4: the second due
    try testing.expectEqual(@as(u32, 2), h.dues);
    try testing.expectEqual(idx(6), h.node().log.base.index);
}

// ---- at most one pending -------------------------------------------------------------------

test "snapshot policy: no second due while one is pending, whatever the step" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect(); // applied 1
    for (1..3) |n| _ = try h.propose(@intCast(n)); // applied 3
    const first = try h.propose(3); // applied 4: the due
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(first, .snapshot_due));
    try testing.expectEqual(@as(?u64, 4), h.pending);

    // Two more applied entries and several ticks: far past the threshold, still one due.
    for (4..6) |n| {
        const effects = try h.propose(@intCast(n));
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .snapshot_due));
    }
    for (0..5) |_| {
        const effects = try h.tick();
        try testing.expectEqual(@as(u32, 0), fixtures.count_effects(effects, .snapshot_due));
    }
    try testing.expectEqual(@as(u32, 1), h.dues);
    try testing.expectEqual(@as(?u64, 4), h.pending);
    try testing.expectEqual(idx(0), h.node().log.base.index); // Nothing compacts unconfirmed.
}

test "snapshot policy: after the save the next due names the new applied index" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n)); // applied 4: due pending at 4
    _ = try h.propose(4); // applied 5, 6 while pending
    _ = try h.propose(5);
    try h.save(); // base 3; applied 6 - 3 = 3 < 4: nothing owed yet
    try testing.expectEqual(@as(?u64, null), h.pending);

    const effects = try h.propose(6); // applied 7 - 3 = 4: owed
    try testing.expectEqual(@as(u32, 1), fixtures.count_effects(effects, .snapshot_due));
    try testing.expectEqual(@as(?u64, 7), h.pending);
    try testing.expectEqual(@as(u32, 2), h.dues);
}

// ---- snapshot_saved is a typed error unless it names the pending due ------------------------

fn expect_unchanged(h: *Harness, status: node_module.Status, base: types.Index) !void {
    try testing.expectEqual(status, h.node().status());
    try testing.expectEqual(base, h.node().log.base.index);
    try h.node().check_invariants();
}

test "snapshot policy: snapshot_saved with no due pending is SnapshotUnexpected, state kept" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    _ = try h.propose(1); // applied 2: below the threshold, nothing pending
    const status = h.node().status();
    const count = h.node().log.count;

    try testing.expectError(error.SnapshotUnexpected, h.node().step(.{ .snapshot_saved = idx(2) }));
    try testing.expectError(error.SnapshotUnexpected, h.node().step(.{ .snapshot_saved = idx(0) }));
    try expect_unchanged(&h, status, idx(0));
    try testing.expectEqual(count, h.node().log.count);
}

test "snapshot policy: a wrong index is SnapshotUnexpected and the due stays pending" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n)); // applied 4: due pending at 4
    const status = h.node().status();
    const count = h.node().log.count;

    for ([_]u64{ 0, 3, 5, 99 }) |wrong| {
        const result = h.node().step(.{ .snapshot_saved = idx(wrong) });
        try testing.expectError(error.SnapshotUnexpected, result);
    }
    try expect_unchanged(&h, status, idx(0));
    try testing.expectEqual(count, h.node().log.count);
    try testing.expectEqual(idx(0), h.node().status().snapshot_index);

    try h.save(); // The right index still works afterwards, and still compacts.
    try testing.expectEqual(idx(3), h.node().log.base.index);
}

test "snapshot policy: a repeated snapshot_saved is SnapshotUnexpected, nothing compacts twice" {
    var h: Harness = undefined;
    try h.init(config_of(16, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n));
    try h.save(); // base 3, snapshot_index 4
    const status = h.node().status();

    try testing.expectError(error.SnapshotUnexpected, h.node().step(.{ .snapshot_saved = idx(4) }));
    try expect_unchanged(&h, status, idx(3));
    try testing.expectEqual(idx(4), h.node().status().snapshot_index);
}

// ---- trailing ------------------------------------------------------------------------------

test "snapshot policy: trailing 0 compacts the whole log and appends continue above it" {
    var h: Harness = undefined;
    try h.init(config_of(8, 4, 0), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n)); // applied 4: due
    try h.save();

    try testing.expectEqual(idx(4), h.node().log.base.index);
    try testing.expectEqual(term(1), h.node().log.base.term);
    try testing.expectEqual(@as(u32, 0), h.node().log.count);
    try testing.expectEqual(idx(4), h.node().status().last_index);
    try testing.expectEqual(term(1), try h.node().log.term_at(idx(4)));
    try testing.expectError(error.LogCompacted, h.node().log.term_at(idx(3)));

    for (4..8) |n| try h.drive_propose(@intCast(n)); // applied 5..8: the next due at 8
    try testing.expectEqual(@as(u32, 2), h.dues);
    try testing.expectEqual(idx(8), h.node().log.base.index);
}

test "snapshot policy: trailing min-1 keeps the most the contract allows" {
    var h: Harness = undefined;
    try h.init(config_of(8, 4, 3), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n)); // applied 4: due
    try h.save();

    try testing.expectEqual(idx(1), h.node().log.base.index);
    try testing.expectEqual(@as(u32, 3), h.node().log.count);
    try testing.expectEqual(idx(2), h.node().entries()[0].index);
    try testing.expectEqual(idx(4), h.node().status().snapshot_index);
    try testing.expectEqual(term(1), try h.node().log.term_at(idx(1))); // The base answers.
    try testing.expectError(error.LogCompacted, h.node().log.term_at(idx(0)));

    for (4..5) |n| try h.drive_propose(@intCast(n)); // applied 5 - base 1 = 4: due again
    try testing.expectEqual(@as(u32, 2), h.dues);
    try testing.expectEqual(idx(2), h.node().log.base.index);
}

test "snapshot policy: a save never moves the base backwards" {
    var h: Harness = undefined;
    try h.init(config_of(8, 2, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    var previous: u64 = 0;
    for (1..30) |n| {
        try h.drive_propose(@intCast(n));
        const base = @intFromEnum(h.node().log.base.index);
        try testing.expect(base >= previous);
        try testing.expect(base <= @intFromEnum(h.node().status().snapshot_index));
        previous = base;
    }
    try testing.expect(previous > 20);
}

// ---- effect shape --------------------------------------------------------------------------

test "snapshot policy: the snapshot phase is 5, after notify, and a due reports it" {
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Effect.Phase.snapshot));
    try testing.expect(@intFromEnum(Effect.Phase.snapshot) > @intFromEnum(Effect.Phase.notify));
    const due: Effect = .{ .snapshot_due = .{
        .snapshot = .{ .index = idx(7), .term = term(2) },
        .configuration = fixtures.configuration,
    } };
    try testing.expectEqual(Effect.Phase.snapshot, due.phase());
}

test "snapshot policy: the due comes after leader_changed and apply in the same step" {
    var h: Harness = undefined;
    try h.init(config_of(8, 1, 0), &lone, 1); // A due is owed as soon as one entry applies.
    defer h.deinit();
    var guard: u32 = 0;
    var winning: ?Effects = null;
    while (winning == null) : (guard += 1) {
        try testing.expect(guard < 40);
        const effects = try h.tick();
        if (h.node().status().role == .leader) winning = effects;
    }
    const items = winning.?.items;
    const apply_at = fixtures.index_of(winning.?, .apply) orelse return error.TestUnexpectedResult;
    const notify_at = fixtures.index_of(winning.?, .leader_changed) orelse
        return error.TestUnexpectedResult;
    try testing.expect(apply_at < notify_at);
    try testing.expect(notify_at < items.len - 1);
    try testing.expect(items[items.len - 1] == .snapshot_due);
    try testing.expectEqual(idx(1), items[items.len - 1].snapshot_due.snapshot.index);
}

// ---- invariants ----------------------------------------------------------------------------

test "snapshot policy: log.base <= snapshot_index <= applied, else InvariantBaseBeyondApplied" {
    var h: Harness = undefined;
    try h.init(config_of(8, 4, 1), &lone, 1);
    defer h.deinit();
    try h.elect();
    for (1..4) |n| _ = try h.propose(@intCast(n));
    try h.save(); // snapshot_index 4, base 3, applied 4
    const node = h.node();
    try node.check_invariants();

    node.snapshot_index = idx(5); // Beyond applied (4).
    try testing.expectError(error.InvariantBaseBeyondApplied, node.check_invariants());
    node.snapshot_index = idx(2); // Behind the log base (3).
    try testing.expectError(error.InvariantBaseBeyondApplied, node.check_invariants());
    node.snapshot_index = idx(3); // Equal to the base is legal.
    try node.check_invariants();
    node.snapshot_index = idx(4); // Equal to applied is legal.
    try node.check_invariants();
}

test "snapshot policy: a node that never snapshotted passes with snapshot_index zero" {
    var h: Harness = undefined;
    try h.init(config_of(8, 4, 1), &fresh, 1);
    defer h.deinit();
    try h.node().check_invariants();
    try testing.expectEqual(idx(0), h.node().status().snapshot_index);
    _ = try follow(&h, 0, 3, 3); // Below the threshold: applied 3, snapshot_index still 0.
    try h.node().check_invariants();
    h.node().snapshot_index = idx(4); // Applied is 3.
    try testing.expectError(error.InvariantBaseBeyondApplied, h.node().check_invariants());
}

// ---- seeded model --------------------------------------------------------------------------

test "snapshot policy: seeded lone leaders match the reference model over 20 seeds" {
    for (0..20) |seed| {
        var prng = std.Random.DefaultPrng.init(0x5a9_5107 + seed);
        const random = prng.random();
        // Peak log size is min + trailing <= 2 * min - 1 <= 31, within 32 slots.
        const min = random.intRangeAtMost(u32, 1, 16);
        const trailing = random.intRangeLessThan(u32, 0, min);

        var h: Harness = undefined;
        try h.init(config_of(32, min, trailing), &lone, 1);
        defer h.deinit();
        try h.elect();
        if (h.pending != null) try h.save();

        var proposals: u32 = 0;
        for (0..300) |_| {
            if (h.pending != null) {
                // The driver is slow: a few ticks pass before it saves. No proposal while a due
                // is pending (the applied index would move past the saved one).
                if (random.boolean()) {
                    try h.save();
                } else {
                    _ = try h.tick();
                }
            } else if (random.uintLessThan(u8, 8) == 0) {
                _ = try h.tick();
            } else {
                proposals += 1;
                _ = try h.propose(proposals);
            }
        }
        if (h.pending != null) try h.save();

        try testing.expectEqual(idx(h.applied), h.node().status().applied_index);
        try testing.expectEqual(idx(h.snapshot), h.node().status().snapshot_index);
        try testing.expectEqual(idx(h.base), h.node().log.base.index);
        try testing.expect(h.dues > 0);
        try h.node().check_invariants();
    }
}
