//! Red tests for windowed observations (plan 005 item 6): with compaction on, a node's log is a
//! window that starts at `base + 1` (`base = status.last_index - log.len`), and committed
//! indexes pass `log_entries_max`. The checker reads absolute indexes, compares only the part
//! two windows share, skips what a node already compacted, and remembers chosen entries up to
//! `Options.chosen_entries_max`; committing past it is the harness limit `ChosenExhausted`.
//!
//! API these tests assume:
//!   `Checker.Options.chosen_entries_max: u32` (>= `log_entries_max`),
//!   `invariants.ObserveError` includes `error.ChosenExhausted`,
//!   `simulation.Options.chosen_entries_max` and `simulation.LimitError.ChosenExhausted`.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io`; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const fx = @import("../raft/fixtures.zig");
const sim_fx = @import("fixtures.zig");
const invariants = @import("invariants.zig");
const simulation_module = @import("simulation.zig");
const workload_module = @import("workload.zig");

const Checker = invariants.Checker;
const Entry = types.Entry;
const Observation = invariants.Observation;
const Simulation = simulation_module.Simulation;

const gpa = testing.allocator;
const io = testing.io;
const options: Checker.Options = .{
    .nodes_count = 3,
    .log_entries_max = 4,
    .chosen_entries_max = 16,
    .terms_max = 16,
};

/// Indexes 1..8: terms 1,1,1,2,2,2,3,3; slices of it are valid windows.
const full = [_]Entry{
    fx.entry(1, 1, "a"), fx.entry(2, 1, "b"), fx.entry(3, 1, "c"), fx.entry(4, 2, "d"),
    fx.entry(5, 2, "e"), fx.entry(6, 2, "f"), fx.entry(7, 3, "g"), fx.entry(8, 3, "h"),
};

fn obs_role(node: u8, role: raft.Role, commit: u64, base: u64, log: []const Entry) Observation {
    const status: raft.Status = .{
        .role = role,
        .term = fx.term(if (role == .leader) 2 else 3),
        .vote = .none,
        .leader = .none,
        .commit_index = fx.idx(commit),
        .applied_index = fx.idx(0),
        .last_index = fx.idx(base + log.len),
        .snapshot_index = .zero,
        .configuration_index = .zero,
    };
    return .{ .node_index = node, .status = status, .log = log };
}

fn obs(node: u8, commit: u64, base: u64, log: []const Entry) Observation {
    return obs_role(node, .follower, commit, base, log);
}

/// A checker that has seen indexes 1..4 chosen, through a node that is then dropped.
fn with_four_chosen(checker: *Checker) !void {
    try checker.init(gpa, options);
    errdefer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 4, 0, full[0..4])});
    try testing.expectEqual(@as(u64, 4), checker.stats().committed_max);
}

fn expect_latched_only(checker: *const Checker, only: invariants.Property) !void {
    const all = [_]invariants.Property{
        .election_safety,     .leader_append_only,   .log_matching,
        .leader_completeness, .state_machine_safety,
    };
    for (all) |property| {
        if (property == only) {
            try testing.expect(std.meta.isError(checker.check(property)));
        } else try checker.check(property);
    }
}

test "window: a base above zero with contiguous indexes is accepted" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(1, 3, 2, full[2..6])}); // Window 3..6, commit 3.
    try checker.observe(&.{obs(1, 5, 2, full[2..6])}); // Commit 5 extends the chosen prefix.
    try testing.expectEqual(@as(u64, 5), checker.stats().committed_max);
    try checker.check(.state_machine_safety);
}

test "window: a wrong index inside the window is StateMachineSafety" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    const gap = [_]Entry{ full[4], full[5], full[7] }; // 5, 6, 8 with last_index 7.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 4, 4, &gap)}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a first index that is not base + 1 is StateMachineSafety" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    // last_index 7 and three entries say base 4, but the first entry is index 4.
    const shifted = [_]Entry{ full[3], full[4], full[5] };
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 4, 4, &shifted)}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: two windows with different bases agreeing on the overlap pass" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{ obs(0, 0, 0, full[0..4]), obs(1, 0, 2, full[2..6]) });
    try checker.check(.log_matching);
}

test "window: different bases disagreeing on the overlap are LogMatching" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    const other = [_]Entry{ full[2], fx.entry(4, 2, "X"), full[4], full[5] }; // 3..6, 4 differs.
    try testing.expectError(
        error.LogMatching,
        checker.observe(&.{ obs(0, 0, 0, full[0..4]), obs(1, 0, 2, &other) }),
    );
    try expect_latched_only(&checker, .log_matching);
}

test "window: different bases disagreeing on the entry before an equal term are LogMatching" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    // Window 2..5 against 3..6: index 4 differs in term (no check there), but index 5 has an
    // equal term and so demands an equal entry before it.
    const first = [_]Entry{ full[1], full[2], fx.entry(4, 1, "Y"), full[4] };
    try testing.expectError(
        error.LogMatching,
        checker.observe(&.{ obs(0, 0, 1, &first), obs(1, 0, 2, full[2..6]) }),
    );
    try expect_latched_only(&checker, .log_matching);
}

test "window: windows that share no index never match-check" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{ obs(0, 0, 0, full[0..2]), obs(1, 0, 4, full[4..8]) });
    try checker.check(.log_matching);
}

test "window: a window commit disagreeing with the chosen print is StateMachineSafety" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    const bad = [_]Entry{ full[2], fx.entry(4, 2, "Z"), full[4] }; // 3..5, 4 differs.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 4, 2, &bad)}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a new commit disagreeing at an absolute index is StateMachineSafety" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    const bad = [_]Entry{ full[2], full[3], fx.entry(5, 2, "e"), full[5] };
    try checker.observe(&.{obs(1, 5, 2, &bad)}); // Index 5 is first chosen here.
    const clash = [_]Entry{ full[2], full[3], fx.entry(5, 2, "Q"), full[5] };
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(2, 5, 2, &clash)}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a commit beyond the window is not held" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 7, 2, full[2..6])}), // Window ends at 6.
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a commit that regresses across windows is StateMachineSafety" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(1, 5, 2, full[2..6])});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 4, 3, full[3..7])}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a commit under a base that was never chosen cannot be verified" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    // Nothing is chosen, yet this node claims 1..4 compacted and committed.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, 4, 4, &.{})}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: an empty window with commit == base is accepted" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(1, 4, 4, &.{})});
    try checker.check(.state_machine_safety);
    try testing.expectEqual(@as(u64, 4), checker.stats().committed_max);
}

test "window: a window of exactly log_entries_max entries is accepted and committed" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(1, 8, 4, full[4..8])}); // 5..8, four entries.
    try testing.expectEqual(@as(u64, 8), checker.stats().committed_max);
    try checker.check(.state_machine_safety);
}

test "window: committing past chosen_entries_max is ChosenExhausted and no violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, .{
        .nodes_count = 3,
        .log_entries_max = 4,
        .chosen_entries_max = 6,
        .terms_max = 16,
    });
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 4, 0, full[0..4])});
    try checker.observe(&.{obs(0, 6, 2, full[2..6])}); // Exactly the limit: fine.
    try testing.expectEqual(@as(u64, 6), checker.stats().committed_max);
    try testing.expectError(
        error.ChosenExhausted,
        checker.observe(&.{obs(0, 7, 4, full[4..8])}),
    );
    try testing.expectEqual(@as(u64, 6), checker.stats().committed_max);
    try checker.check(.state_machine_safety); // A harness limit latches nothing.
}

test "window: a leader's log extending across a compaction is append-only" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs_role(0, .leader, 4, 0, full[0..4])});
    try checker.observe(&.{obs_role(0, .leader, 4, 2, full[2..6])}); // Compacted 1..2, grew.
    try checker.check(.leader_append_only);
    try testing.expectError(
        error.LeaderAppendOnly,
        checker.observe(&.{obs_role(0, .leader, 4, 2, full[2..5])}), // Shorter than 6.
    );
    try expect_latched_only(&checker, .leader_append_only);
}

test "window: a leader's window changing an overlapping entry is LeaderAppendOnly" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs_role(0, .leader, 0, 0, full[0..4])});
    const changed = [_]Entry{ full[2], fx.entry(4, 2, "Z"), full[4], full[5] };
    try testing.expectError(
        error.LeaderAppendOnly,
        checker.observe(&.{obs_role(0, .leader, 0, 2, &changed)}),
    );
    try expect_latched_only(&checker, .leader_append_only);
}

test "window: a leader whose window lacks a chosen entry is LeaderCompleteness" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    // Chosen 1..4 (terms 1,1,1,2); a term-3 leader at base 2 with only index 3 held (3..3)
    // is missing the chosen index 4.
    var leader = obs_role(1, .leader, 3, 2, full[2..3]);
    leader.status.term = fx.term(3);
    try testing.expectError(error.LeaderCompleteness, checker.observe(&.{leader}));
    try expect_latched_only(&checker, .leader_completeness);
}

test "window: a leader that compacted the chosen entries is complete" {
    var checker: Checker = undefined;
    try with_four_chosen(&checker);
    defer checker.deinit(gpa);
    var leader = obs_role(1, .leader, 4, 4, full[4..6]);
    leader.status.term = fx.term(3);
    try checker.observe(&.{leader});
    try checker.check(.leader_completeness);
}

test "window: Simulation reports ChosenExhausted when commits pass chosen_entries_max" {
    var exhausted: u32 = 0;
    for (0..8) |seed| {
        var sim_options = sim_fx.sim_quiet(seed, 3);
        sim_options.workload = .{
            .clients_count = 3,
            .keys_count = 4,
            .put_percent = 50,
            .op_interval_ms_max = 40,
            .fault = .none,
        };
        sim_options.history_ops_max = 256;
        sim_options.raft.snapshot_entries_min = 16;
        sim_options.raft.snapshot_trailing = 4;
        sim_options.raft.message_limits.snapshot_bytes_max =
            workload_module.KvStateMachine.snapshot_bytes(4);
        sim_options.chosen_entries_max = sim_options.raft.log_entries_max;
        var simulation: Simulation = undefined;
        try simulation.init(io, gpa, &sim_options);
        defer simulation.deinit(io, gpa);

        simulation.run_until(io, 5_000) catch |err| switch (err) {
            error.ChosenExhausted => {
                exhausted += 1;
                try testing.expectEqual(error.ChosenExhausted, simulation.report().violation);
                try sim_fx.check_all(&simulation); // A harness limit is not a violation.
            },
            else => return err,
        };
    }
    try testing.expect(exhausted > 0);
}

/// A fresh checker that has seen a leader of term 2 holding the window 1..4 (nothing committed).
fn with_leader_window(checker: *Checker) !void {
    try checker.init(gpa, options);
    errdefer checker.deinit(gpa);
    try checker.observe(&.{obs_role(0, .leader, 0, 0, full[0..4])});
    try testing.expectEqual(@as(u64, 0), checker.stats().committed_max);
}

test "window: a leader that commits and compacts in one event keeps its previous prints" {
    var checker: Checker = undefined;
    try with_leader_window(&checker);
    defer checker.deinit(gpa);
    // Commit jumps 0 -> 6 and the window slides to 5..8: indexes 1..4 were never seen committed.
    try checker.observe(&.{obs_role(0, .leader, 6, 4, full[4..8])});
    try testing.expectEqual(@as(u64, 6), checker.stats().committed_max);
    try expect_latched_only_none(&checker);
    // The skipped indexes were chosen with the leader's own prints: a follower holding a
    // different entry at index 2 contradicts them.
    const forged = [_]Entry{ full[0], fx.entry(2, 1, "x"), full[2], full[3] };
    try testing.expectError(error.StateMachineSafety, checker.observe(&.{obs(1, 4, 0, &forged)}));
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a follower that commits and compacts in one event stays unverifiable" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 0, 0, full[0..4])});
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(0, 6, 4, full[4..8])}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

test "window: a leader whose previous window misses a skipped index is unverifiable" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs_role(0, .leader, 0, 0, full[0..2])}); // Window 1..2 only.
    // Indexes 3 and 4 were compacted unseen: the previous window does not hold them.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs_role(0, .leader, 6, 4, full[4..8])}),
    );
    try expect_latched_only(&checker, .state_machine_safety);
}

fn expect_latched_only_none(checker: *const Checker) !void {
    const all = [_]invariants.Property{
        .election_safety,     .leader_append_only,   .log_matching,
        .leader_completeness, .state_machine_safety,
    };
    for (all) |property| try checker.check(property);
}
