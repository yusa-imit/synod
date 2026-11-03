//! Red tests for `Checker.installed` (plan 005 item 6, ADR-009 "Simulator"): a node that installed
//! a snapshot jumps its applied index to the snapshot's index without per-entry `applied()`
//! reports. The checker accepts the jump only forward (an install never goes back) and only to
//! an index some node committed (a snapshot covers chosen entries); the next `applied()` must
//! then be the very next index. `applied()` itself still rejects skips.
//!
//! API these tests assume:
//!   `Checker.installed(checker: *Checker, node_index: u8, applied_index: Index) Violation!void`.
//!   A violation is `StateMachineSafety`, latched like every other property.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

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

const gpa = testing.allocator;
const options: Checker.Options = .{ .nodes_count = 3, .log_entries_max = 8, .terms_max = 16 };
const log_abc = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 1, "b"), fx.entry(3, 2, "c") };

fn obs(node: u8, commit: u64, log: []const Entry) Observation {
    const status: raft.Status = .{
        .role = .follower,
        .term = fx.term(2),
        .vote = .none,
        .leader = .none,
        .commit_index = fx.idx(commit),
        .applied_index = fx.idx(0),
        .last_index = fx.idx(log.len),
        .snapshot_index = .zero,
    };
    return .{ .node_index = node, .status = status, .log = log };
}

fn expect_only_state_machine_safety(checker: *const Checker) !void {
    try testing.expectError(error.StateMachineSafety, checker.check(.state_machine_safety));
    try checker.check(.election_safety);
    try checker.check(.leader_append_only);
    try checker.check(.log_matching);
    try checker.check(.leader_completeness);
}

fn fingerprint_of(position: usize) u64 {
    return invariants.fingerprint(&log_abc[position]);
}

test "installed: after an install the next consecutive applied is accepted" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)}); // Entries 1..3 are chosen.
    try checker.installed(1, fx.idx(2)); // Node 1 jumps to 2 with no applied() reports.
    try checker.observe(&.{obs(1, 3, &log_abc)});
    try checker.applied(1, fx.idx(3), fingerprint_of(2));
    try checker.check(.state_machine_safety);
}

test "installed: an install raises the node's commit to the installed index" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(3));
    // A snapshot is committed: the node cannot later report a lower commit.
    try testing.expectError(
        error.StateMachineSafety,
        checker.observe(&.{obs(1, 2, &log_abc)}),
    );
    try expect_only_state_machine_safety(&checker);
}

test "installed: a later install further forward is accepted" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(1));
    try checker.installed(1, fx.idx(3));
    try checker.check(.state_machine_safety);
}

test "installed: an install after applying forward jumps over unapplied entries" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.applied(0, fx.idx(1), fingerprint_of(0));
    try checker.installed(0, fx.idx(3));
    try checker.check(.state_machine_safety);
}

test "installed: installing the applied index again is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(2));
    try testing.expectError(error.StateMachineSafety, checker.installed(1, fx.idx(2)));
    try expect_only_state_machine_safety(&checker);
}

test "installed: installing backwards is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(3));
    try testing.expectError(error.StateMachineSafety, checker.installed(1, fx.idx(2)));
    try expect_only_state_machine_safety(&checker);
}

test "installed: installing at or below what was applied is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.applied(0, fx.idx(1), fingerprint_of(0));
    try checker.applied(0, fx.idx(2), fingerprint_of(1));
    try testing.expectError(error.StateMachineSafety, checker.installed(0, fx.idx(2)));
    try expect_only_state_machine_safety(&checker);
}

test "installed: installing past every committed index is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 2, &log_abc)}); // Only 1..2 are chosen.
    try testing.expectError(error.StateMachineSafety, checker.installed(1, fx.idx(3)));
    try expect_only_state_machine_safety(&checker);
}

test "installed: with nothing chosen any install is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try testing.expectError(error.StateMachineSafety, checker.installed(0, fx.idx(1)));
    try expect_only_state_machine_safety(&checker);
}

test "installed: a failed install leaves the node's applied index unchanged" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(1, 2, &log_abc)});
    try testing.expectError(error.StateMachineSafety, checker.installed(1, fx.idx(3)));
    // Still at applied 0: index 1 is the next one (and the latch is already set).
    try checker.applied(1, fx.idx(1), fingerprint_of(0));
}

test "installed: skipping without an install is still a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(0, fx.idx(3), fingerprint_of(2)), // Skips 1 and 2.
    );
    try expect_only_state_machine_safety(&checker);
}

test "installed: after an install a skip past the next index is still a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(1));
    try checker.observe(&.{obs(1, 3, &log_abc)});
    try testing.expectError(
        error.StateMachineSafety,
        checker.applied(1, fx.idx(3), fingerprint_of(2)), // Next is 2.
    );
    try expect_only_state_machine_safety(&checker);
}

test "installed: a restart forgets the install" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.observe(&.{obs(0, 3, &log_abc)});
    try checker.installed(1, fx.idx(3));
    checker.restarted(1);
    try checker.installed(1, fx.idx(2)); // Applied is 0 again, so a lower install is fine.
    try checker.check(.state_machine_safety);
}
