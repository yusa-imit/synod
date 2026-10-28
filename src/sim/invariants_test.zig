//! Tests for `sim/invariants.zig` (ADR-008, "Invariants"; plan 004 item 3), written before the
//! implementation. Histories are hand-built `Observation`s: one that passes and one that fails
//! with the named error for every property, plus the sub-cases of state machine safety,
//! `restarted` semantics, `TermsExhausted`, stats and the empty / one-node boundaries.
//! The seeded model-based test lives in `invariants_model_test.zig`.
//!
//! Each failing history is built to break exactly one property, so `check` can prove the
//! latch lands on the right one and on no other. `log_entries_max + 1` is a caller contract
//! (asserted, ADR-008 is silent on an error), so it is not provoked here.

const std = @import("std");
const testing = std.testing;
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const fx = @import("../raft/fixtures.zig");
const invariants = @import("invariants.zig");

const Checker = invariants.Checker;
const Entry = types.Entry;
const Observation = invariants.Observation;
const Property = invariants.Property;
const Violation = invariants.Violation;

const options3: Checker.Options = .{ .nodes_count = 3, .log_entries_max = 8, .terms_max = 16 };
const checked = [_]Property{
    .election_safety,
    .leader_append_only,
    .log_matching,
    .leader_completeness,
    .state_machine_safety,
};

fn obs(node: u8, role: raft.Role, term: u64, commit: u64, log: []const Entry) Observation {
    const status: raft.Status = .{
        .role = role,
        .term = fx.term(term),
        .vote = .none,
        .leader = .none,
        .commit_index = fx.idx(commit),
        .applied_index = fx.idx(0),
        .last_index = fx.idx(log.len),
        .snapshot_index = .zero,
    };
    return .{ .node_index = node, .status = status, .log = log };
}

/// Every property except `except` is still clean.
fn expect_only(checker: *const Checker, except: Property) !void {
    for (checked) |property| {
        if (property == except) continue;
        try checker.check(property);
    }
}

fn expect_latched(checker: *const Checker, property: Property, want: Violation) !void {
    try testing.expectError(want, checker.check(property));
    try testing.expectError(want, checker.check(property)); // Latched: asking twice is stable.
    try expect_only(checker, property);
}

const log_ab = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b") };

// ---- violation_of, fingerprint ----------------------------------------------------------

test "invariants: violation_of maps every property to its own named error" {
    const table = [_]struct { Property, Violation }{
        .{ .election_safety, error.ElectionSafety },
        .{ .leader_append_only, error.LeaderAppendOnly },
        .{ .log_matching, error.LogMatching },
        .{ .leader_completeness, error.LeaderCompleteness },
        .{ .state_machine_safety, error.StateMachineSafety },
        .{ .linearizability, error.Linearizability },
    };
    comptime std.debug.assert(table.len == @typeInfo(Property).@"enum".fields.len);
    inline for (table) |row| {
        const result: Violation!void = invariants.violation_of(row[0]);
        try testing.expectError(row[1], result);
    }
    for (table, 0..) |a, i| for (table[i + 1 ..]) |b| {
        try testing.expect(a[1] != b[1]);
    };
}

test "invariants: fingerprint is deterministic and ignores where the bytes live" {
    var copy_a = [_]u8{ 'x', 'y' };
    var copy_b = [_]u8{ 'x', 'y' };
    const a = fx.entry(1, 3, &copy_a);
    const b = fx.entry(1, 3, &copy_b);
    try testing.expectEqual(invariants.fingerprint(&a), invariants.fingerprint(&a));
    try testing.expectEqual(invariants.fingerprint(&a), invariants.fingerprint(&b));
}

test "invariants: fingerprint is sensitive to term, kind and data, not to the index" {
    const base = fx.entry(1, 3, "xy");
    const base_print = invariants.fingerprint(&base);
    const other_term = fx.entry(1, 4, "xy");
    var other_kind = base;
    other_kind.kind = .conf_change;
    const other_data = fx.entry(1, 3, "xz");
    const shorter = fx.entry(1, 3, "x");
    const empty = fx.entry(1, 3, "");
    const moved = fx.entry(9, 3, "xy");
    try testing.expect(invariants.fingerprint(&other_term) != base_print);
    try testing.expect(invariants.fingerprint(&other_kind) != base_print);
    try testing.expect(invariants.fingerprint(&other_data) != base_print);
    try testing.expect(invariants.fingerprint(&shorter) != base_print);
    try testing.expect(invariants.fingerprint(&empty) != base_print);
    try testing.expectEqual(base_print, invariants.fingerprint(&moved));
}

// ---- the pure checks ----------------------------------------------------------------------

test "invariants: log_matching accepts prefixes and divergent terms, rejects equal-term forks" {
    const same = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b"), fx.entry(3, 2, "c") };
    const other_data = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "x") };
    const other_prefix = [_]Entry{ fx.entry(1, 1, "z"), fx.entry(2, 2, "b") };
    const other_term = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 3, "x") };
    var other_kind = log_ab;
    other_kind[1].kind = .conf_change;
    try invariants.log_matching(&log_ab, &same);
    try invariants.log_matching(&same, &log_ab);
    try invariants.log_matching(&log_ab, &log_ab);
    try invariants.log_matching(&log_ab, &.{});
    try invariants.log_matching(&.{}, &.{});
    try invariants.log_matching(&log_ab, &other_term); // Different terms may differ.
    try testing.expectError(error.LogMatching, invariants.log_matching(&log_ab, &other_data));
    try testing.expectError(error.LogMatching, invariants.log_matching(&other_data, &log_ab));
    try testing.expectError(error.LogMatching, invariants.log_matching(&log_ab, &other_prefix));
    try testing.expectError(error.LogMatching, invariants.log_matching(&log_ab, &other_kind));
}

test "invariants: leader_append_only accepts an extension, rejects a cut or a rewrite" {
    const prints = [_]u64{ invariants.fingerprint(&log_ab[0]), invariants.fingerprint(&log_ab[1]) };
    const longer = [_]Entry{ log_ab[0], log_ab[1], fx.entry(3, 2, "c") };
    const rewritten_tail = [_]Entry{ log_ab[0], fx.entry(2, 2, "q") };
    const rewritten_head = [_]Entry{ fx.entry(1, 1, "z"), log_ab[1] };
    const retermed = [_]Entry{ log_ab[0], fx.entry(2, 3, "b") };
    try invariants.leader_append_only(&prints, &log_ab); // Unchanged.
    try invariants.leader_append_only(&prints, &longer);
    try invariants.leader_append_only(&.{}, &.{}); // Nothing remembered, nothing to break.
    try invariants.leader_append_only(&.{}, &log_ab);
    try testing.expectError(error.LeaderAppendOnly, invariants.leader_append_only(&prints, &.{}));
    try testing.expectError(
        error.LeaderAppendOnly,
        invariants.leader_append_only(&prints, log_ab[0..1]),
    );
    try testing.expectError(
        error.LeaderAppendOnly,
        invariants.leader_append_only(&prints, &rewritten_tail),
    );
    try testing.expectError(
        error.LeaderAppendOnly,
        invariants.leader_append_only(&prints, &rewritten_head),
    );
    try testing.expectError(
        error.LeaderAppendOnly,
        invariants.leader_append_only(&prints, &retermed),
    );
}

// ---- checker lifecycle, boundaries ------------------------------------------------------

fn lifecycle(gpa: std.mem.Allocator) !void {
    var checker: Checker = undefined;
    try checker.init(gpa, options3);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, .leader, 2, 2, &log_ab)});
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    checker.restarted(0);
    try checker.check(.log_matching);
}

test "invariants: no allocation failure in init leaks, and later calls allocate nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, lifecycle, .{});
}

test "invariants: a fresh checker is clean and the empty observation changes nothing" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try expect_only(&checker, .linearizability);
    try checker.observe(&.{});
    try expect_only(&checker, .linearizability);
    const stats = checker.stats();
    try testing.expectEqual(@as(u32, 0), stats.leader_terms);
    try testing.expectEqual(@as(u64, 0), stats.committed_max);
}

test "invariants: a one-node cluster observes its own leader and commits" {
    var checker: Checker = undefined;
    const small: Checker.Options = .{
        .nodes_count = 1,
        .log_entries_max = 2,
        .terms_max = 2,
    };
    try checker.init(testing.allocator, small);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 1, 1, log_ab[0..1])});
    try checker.observe(&.{obs(0, .leader, 1, 2, &log_ab)});
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    try checker.applied(0, fx.idx(2), invariants.fingerprint(&log_ab[1]));
    try expect_only(&checker, .linearizability);
    try testing.expectEqual(@as(u64, 2), checker.stats().committed_max);
    try testing.expectEqual(@as(u32, 1), checker.stats().leader_terms);
}

test "invariants: a log of exactly log_entries_max entries is accepted and committed" {
    var buffer: [4]Entry = undefined;
    const log = fx.fill_entries(&buffer, 4, 1);
    var checker: Checker = undefined;
    const small: Checker.Options = .{
        .nodes_count = 2,
        .log_entries_max = 4,
        .terms_max = 4,
    };
    try checker.init(testing.allocator, small);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{ obs(0, .leader, 1, 4, log), obs(1, .follower, 1, 4, log) });
    try expect_only(&checker, .linearizability);
    try testing.expectEqual(@as(u64, 4), checker.stats().committed_max);
}

// ---- election safety --------------------------------------------------------------------

test "invariants: election safety allows one leader per term, across terms and repeats" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{ obs(0, .leader, 3, 0, &.{}), obs(1, .follower, 3, 0, &.{}) });
    try checker.observe(&.{obs(0, .leader, 3, 0, &.{})}); // The same leader again.
    try checker.observe(&.{obs(1, .candidate, 3, 0, &.{})}); // A candidate is not a leader.
    try checker.observe(&.{obs(1, .leader, 4, 0, &.{})});
    try checker.observe(&.{obs(2, .follower, 1000, 0, &.{})}); // Followers never use the table.
    try expect_only(&checker, .linearizability);
    try testing.expectEqual(@as(u32, 2), checker.stats().leader_terms);
}

test "invariants: two leaders in one term across observations is ElectionSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 3, 0, &.{})});
    try testing.expectError(error.ElectionSafety, checker.observe(&.{obs(1, .leader, 3, 0, &.{})}));
    try expect_latched(&checker, .election_safety, error.ElectionSafety);
}

test "invariants: two leaders in one term inside one observation is ElectionSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const both = [_]Observation{ obs(0, .leader, 5, 0, &.{}), obs(2, .leader, 5, 0, &.{}) };
    try testing.expectError(error.ElectionSafety, checker.observe(&both));
    try expect_latched(&checker, .election_safety, error.ElectionSafety);
}

test "invariants: a leader term above terms_max is TermsExhausted and not recorded" {
    var checker: Checker = undefined;
    const small: Checker.Options = .{
        .nodes_count = 3,
        .log_entries_max = 4,
        .terms_max = 3,
    };
    try checker.init(testing.allocator, small);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 3, 0, &.{})}); // Exactly terms_max is in the table.
    try testing.expectError(
        error.TermsExhausted,
        checker.observe(&.{obs(1, .leader, 4, 0, &.{})}),
    );
    try expect_only(&checker, .linearizability); // A harness limit is not a safety violation.
    try testing.expectEqual(@as(u32, 1), checker.stats().leader_terms);
}

// ---- leader append-only -----------------------------------------------------------------

test "invariants: a leader that only extends its log in a term passes" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const longer = [_]Entry{ log_ab[0], log_ab[1], fx.entry(3, 2, "c") };
    try checker.observe(&.{obs(0, .leader, 2, 0, log_ab[0..1])});
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)}); // Unchanged is still an extension.
    try checker.observe(&.{obs(0, .leader, 2, 0, &longer)});
    try expect_only(&checker, .linearizability);
}

test "invariants: a leader seen with a truncated log in the same term is LeaderAppendOnly" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    try testing.expectError(
        error.LeaderAppendOnly,
        checker.observe(&.{obs(0, .leader, 2, 0, log_ab[0..1])}),
    );
    try expect_latched(&checker, .leader_append_only, error.LeaderAppendOnly);
}

test "invariants: a leader seen with a rewritten entry in the same term is LeaderAppendOnly" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const rewritten = [_]Entry{ log_ab[0], fx.entry(2, 2, "c") }; // Same length, other bytes.
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    try testing.expectError(
        error.LeaderAppendOnly,
        checker.observe(&.{obs(0, .leader, 2, 0, &rewritten)}),
    );
    try expect_latched(&checker, .leader_append_only, error.LeaderAppendOnly);
}

test "invariants: a new term or a follower observation resets leader append-only memory" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const rival = [_]Entry{fx.entry(1, 3, "z")};
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    try checker.observe(&.{obs(0, .follower, 3, 0, log_ab[0..1])}); // Stepped down and cut.
    try checker.observe(&.{obs(0, .leader, 4, 0, &rival)}); // Leads term 4 with another log.
    try checker.observe(&.{obs(0, .leader, 4, 0, &rival)});
    try expect_only(&checker, .linearizability);
}

// ---- log matching -----------------------------------------------------------------------

test "invariants: nodes whose logs agree or differ only across terms pass log matching" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const forked = [_]Entry{ log_ab[0], fx.entry(2, 3, "x") };
    try checker.observe(&.{
        obs(0, .follower, 3, 0, &log_ab),
        obs(1, .follower, 3, 0, log_ab[0..1]),
        obs(2, .follower, 3, 0, &forked),
    });
    try expect_only(&checker, .linearizability);
}

test "invariants: equal terms with different bytes at an index is LogMatching" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const other = [_]Entry{ log_ab[0], fx.entry(2, 2, "x") };
    const both = [_]Observation{
        obs(0, .follower, 2, 0, &log_ab),
        obs(1, .follower, 2, 0, &other),
    };
    try testing.expectError(error.LogMatching, checker.observe(&both));
    try expect_latched(&checker, .log_matching, error.LogMatching);
}

test "invariants: a diverged prefix under equal terms is LogMatching" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const other = [_]Entry{ fx.entry(1, 1, "z"), log_ab[1] };
    const both = [_]Observation{
        obs(1, .follower, 2, 0, &log_ab),
        obs(2, .follower, 2, 0, &other),
    };
    try testing.expectError(error.LogMatching, checker.observe(&both));
    try expect_latched(&checker, .log_matching, error.LogMatching);
}

// ---- leader completeness ----------------------------------------------------------------

test "invariants: a leader holding every entry chosen up to its term passes completeness" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)}); // Index 2 chosen in term 2.
    try checker.observe(&.{obs(1, .leader, 3, 0, &log_ab)});
    try checker.observe(&.{obs(1, .leader, 3, 0, &log_ab)});
    try expect_only(&checker, .linearizability);
}

test "invariants: a leader of an older term need not hold an entry chosen in a newer term" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try checker.observe(&.{obs(1, .leader, 1, 0, log_ab[0..1])}); // Index 2 chosen in term 2 > 1.
    try expect_only(&checker, .linearizability);
}

test "invariants: a leader missing a chosen entry is LeaderCompleteness" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.LeaderCompleteness,
        checker.observe(&.{obs(1, .leader, 3, 0, log_ab[0..1])}),
    );
    try expect_latched(&checker, .leader_completeness, error.LeaderCompleteness);
}

test "invariants: a leader holding another entry at a chosen index is LeaderCompleteness" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const forked = [_]Entry{ log_ab[0], fx.entry(2, 2, "q") };
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.LeaderCompleteness,
        checker.observe(&.{obs(1, .leader, 3, 0, &forked)}),
    );
    try expect_latched(&checker, .leader_completeness, error.LeaderCompleteness);
}

// ---- state machine safety ---------------------------------------------------------------

test "invariants: agreeing commits, growing commit and in-order apply pass" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)});
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)}); // Same commit again.
    try checker.observe(&.{ obs(0, .follower, 2, 2, &log_ab), obs(1, .follower, 2, 2, &log_ab) });
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    try checker.applied(0, fx.idx(2), invariants.fingerprint(&log_ab[1]));
    try checker.applied(1, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    try expect_only(&checker, .linearizability);
    try testing.expectEqual(@as(u64, 2), checker.stats().committed_max);
}

test "invariants: two nodes committing different entries at one index is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    // Terms differ at index 2, so log matching has nothing to say: only the commits clash.
    const other = [_]Entry{ log_ab[0], fx.entry(2, 3, "q") };
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, .follower, 3, 2, &other)}),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: an overwritten committed entry on the same node is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const rewritten = [_]Entry{ log_ab[0], fx.entry(2, 3, "b") };
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, .follower, 3, 2, &rewritten)}),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: a log cut below the committed prefix is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, .follower, 2, 1, log_ab[0..1])}),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: a commit index regressing on a live node is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)}), // Same log, lower commit.
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: a commit index beyond the node's log is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, .follower, 2, 2, log_ab[0..1])}), // Commit 2, one entry.
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: non-contiguous entry indexes from a node are StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const gapped = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(3, 2, "b") };
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, .follower, 2, 0, &gapped)}),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: applying an index before its predecessor is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(2), invariants.fingerprint(&log_ab[1])), // Skips index 1.
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: applying an index twice is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0])),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: applying past the node's commit index is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)}); // Commit 1, log holds 2.
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(2), invariants.fingerprint(&log_ab[1])), // In order, uncommitted.
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: applying before any commit was observed is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0])),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: applying bytes that differ from the chosen entry is StateMachineSafety" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const impostor = fx.entry(1, 1, "x");
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(1), invariants.fingerprint(&impostor)),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

// ---- restarted --------------------------------------------------------------------------

test "invariants: a restart lets a node's commit and applied start over" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0]));
    checker.restarted(0);
    try checker.observe(&.{obs(0, .follower, 2, 0, &log_ab)}); // Not a regress after a restart.
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)});
    try checker.applied(0, fx.idx(1), invariants.fingerprint(&log_ab[0])); // Applied from 1 again.
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    try checker.applied(0, fx.idx(2), invariants.fingerprint(&log_ab[1]));
    try expect_only(&checker, .linearizability);
}

test "invariants: a restart does not forget a chosen entry, so a differing commit is caught" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const other = [_]Entry{ log_ab[0], fx.entry(2, 3, "q") };
    try checker.observe(&.{obs(0, .follower, 2, 2, &log_ab)});
    checker.restarted(0);
    checker.restarted(1); // A node that never committed restarts harmlessly.
    try testing.expectEqual(@as(u64, 2), checker.stats().committed_max); // Chosen survive.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, .follower, 3, 2, &other)}),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: after a restart an apply of a chosen index is still compared to it" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    const impostor = fx.entry(1, 1, "x");
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)});
    checker.restarted(0);
    try checker.observe(&.{obs(0, .follower, 2, 1, &log_ab)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(1), invariants.fingerprint(&impostor)),
    );
    try expect_latched(&checker, .state_machine_safety, error.StateMachineSafety);
}

test "invariants: a restart clears leader append-only memory but not the term's leader" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    checker.restarted(0);
    try checker.observe(&.{obs(0, .leader, 2, 0, log_ab[0..1])}); // Memory gone: no violation.
    try expect_only(&checker, .linearizability);
    // The one-leader-per-term table is not per-node memory and survives.
    try testing.expectError(error.ElectionSafety, checker.observe(&.{obs(1, .leader, 2, 0, &.{})}));
    try expect_latched(&checker, .election_safety, error.ElectionSafety);
}

test "invariants: without a restart the same cut leader log is caught" {
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options3);
    defer checker.deinit(testing.allocator);
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    checker.restarted(1); // Another node's restart must not clear node 0's memory.
    try testing.expectError(
        error.LeaderAppendOnly,
        checker.observe(&.{obs(0, .leader, 2, 0, log_ab[0..1])}),
    );
}

// ---- stats ------------------------------------------------------------------------------

test "invariants: stats counts leader terms once each and tracks the highest chosen index" {
    var checker: Checker = undefined;
    const small: Checker.Options = .{
        .nodes_count = 3,
        .log_entries_max = 8,
        .terms_max = 8,
    };
    try checker.init(testing.allocator, small);
    defer checker.deinit(testing.allocator);
    const three = [_]Entry{ log_ab[0], log_ab[1], fx.entry(3, 2, "c") };
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)});
    try checker.observe(&.{obs(0, .leader, 2, 0, &log_ab)}); // Same term: not counted twice.
    try checker.observe(&.{obs(1, .leader, 5, 0, &three)});
    try testing.expectEqual(@as(u32, 2), checker.stats().leader_terms);
    try testing.expectEqual(@as(u64, 0), checker.stats().committed_max);
    try checker.observe(&.{obs(2, .follower, 5, 3, &three)});
    try checker.observe(&.{obs(0, .follower, 5, 1, &three)}); // A lower commit never lowers it.
    checker.restarted(2);
    try testing.expectEqual(@as(u64, 3), checker.stats().committed_max);
    try testing.expectEqual(@as(u32, 2), checker.stats().leader_terms);
}
