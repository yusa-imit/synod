//! Red tests for `Checker.state_digest` (plan 005 item 6, ADR-009 "Simulator"): every node that
//! has applied index `i` holds the same state machine, so equal applied indexes carry equal
//! digests. A ring of `log_entries_max` `(index, digest)` pairs remembers the first digest seen
//! at an index; an unequal one is `StateMachineSafety`, latched like every other property.
//!
//! API these tests assume (ADR-009):
//!   `Checker.state_digest(checker: *Checker, node_index: u8, applied: Index, digest: u64)
//!   Violation!void`. No new `Violation` or `Property` variant: the property is
//!   `state_machine_safety`, so `check(.state_machine_safety)` is the latch.
//!
//! Choices where ADR-009 is silent (the implementation may argue, not drift silently):
//!   - An index older than the ring (`log_entries_max` newer indexes were reported since) is
//!     forgotten: a different digest there is not compared. Indexes inside the ring are.
//!   - A node reporting twice at one index must repeat its digest (a replay of one machine is
//!     deterministic); a different digest from the same node is the same violation.
//!   - Applied index 0 is the empty machine; every node reports the same digest there, and a
//!     differing one is a violation too.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const invariants = @import("invariants.zig");

const Checker = invariants.Checker;
const Index = types.Index;
const Property = invariants.Property;

const gpa = testing.allocator;
const Prng = @import("prng.zig").Prng;
const ring: u32 = 4;
const options: Checker.Options = .{ .nodes_count = 3, .log_entries_max = ring, .terms_max = 8 };

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn expect_clean(checker: *const Checker) !void {
    const all = [_]Property{
        .election_safety,
        .leader_append_only,
        .log_matching,
        .leader_completeness,
        .state_machine_safety,
    };
    for (all) |property| try checker.check(property);
}

fn expect_only_state_machine_safety(checker: *const Checker) !void {
    try testing.expectError(error.StateMachineSafety, checker.check(.state_machine_safety));
    try checker.check(.election_safety);
    try checker.check(.leader_append_only);
    try checker.check(.log_matching);
    try checker.check(.leader_completeness);
}

test "digest: equal digests at equal applied indexes are accepted and latch nothing" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    for (0..3) |node| try checker.state_digest(@intCast(node), idx(1), 0xAAAA);
    for (0..3) |node| try checker.state_digest(@intCast(node), idx(2), 0xBBBB);
    try expect_clean(&checker);
}

test "digest: different digests at different indexes are not a conflict" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(0, idx(1), 1);
    try checker.state_digest(1, idx(2), 2);
    try checker.state_digest(2, idx(3), 1);
    try expect_clean(&checker);
}

test "digest: a differing digest at one index is StateMachineSafety, latched and alone" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(0, idx(5), 0x1111);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(1, idx(5), 0x2222));
    try expect_only_state_machine_safety(&checker);
    try expect_only_state_machine_safety(&checker); // asking twice is stable
}

test "digest: the same node repeating an index with another digest is a violation" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(2, idx(7), 5);
    try checker.state_digest(2, idx(7), 5); // a replay agrees with itself
    try expect_clean(&checker);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(2, idx(7), 6));
    try expect_only_state_machine_safety(&checker);
}

test "digest: index zero is the empty machine and every node must agree on it" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(0, Index.zero, 9);
    try checker.state_digest(1, Index.zero, 9);
    try expect_clean(&checker);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(2, Index.zero, 8));
}

test "digest: the first violation stays latched when later reports agree" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(0, idx(1), 1);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(1, idx(1), 2));
    checker.state_digest(0, idx(2), 7) catch {}; // later reports may be answered or not
    try expect_only_state_machine_safety(&checker);
}

test "digest: a restart of the node does not forget the digests others reported" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    try checker.state_digest(0, idx(3), 0xC0DE);
    checker.restarted(0);
    checker.restarted(1);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(1, idx(3), 0xBAD));
}

// ---- the ring ----------------------------------------------------------------------------------

test "digest: the ring holds log_entries_max indexes, the oldest then falls out" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    for (1..ring + 1) |at| try checker.state_digest(0, idx(at), 100 + at); // 1..4 fill the ring
    // Index 1 is still inside the ring: a conflict there is caught.
    try testing.expectError(error.StateMachineSafety, checker.state_digest(1, idx(1), 5));
}

test "digest: an index pushed out of the ring is forgotten, one inside still compares" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    for (1..ring + 2) |at| try checker.state_digest(0, idx(at), 100 + at); // 1..5: index 1 out
    try checker.state_digest(1, idx(1), 999); // too old to compare: accepted
    try expect_clean(&checker);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(2, idx(2), 999));
}

test "digest: a lagging node reporting inside the ring is compared with the leaders" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    for (1..ring + 1) |at| try checker.state_digest(0, idx(at), 7 * at);
    for (1..ring + 1) |at| try checker.state_digest(1, idx(at), 7 * at); // catches up in step
    try expect_clean(&checker);
}

test "digest: a snapshot install jumps the applied index and is compared at that index" {
    var checker: Checker = undefined;
    try checker.init(gpa, options);
    defer checker.deinit(gpa);
    for (1..4) |at| try checker.state_digest(0, idx(at), 50 + at);
    try checker.state_digest(1, idx(3), 53); // node 1 restored a snapshot at 3: no 1..2 first
    try expect_clean(&checker);
    try testing.expectError(error.StateMachineSafety, checker.state_digest(2, idx(3), 54));
}

// ---- model -------------------------------------------------------------------------------------

test "digest: seeded reports agree with a map of first-seen digests inside the ring" {
    for (1..41) |seed| {
        var prng = Prng.init(seed);
        var checker: Checker = undefined;
        try checker.init(gpa, options);
        defer checker.deinit(gpa);
        var seen = std.AutoHashMap(u64, u64).init(gpa);
        defer seen.deinit();
        var newest: u64 = 0;
        for (0..60) |_| {
            const low = if (newest >= ring) newest - ring + 1 else 0;
            const at = low + prng.uint_less_than(newest - low + 3);
            const digest: u64 = if (prng.chance(12)) prng.next_u64() else at * 31;
            const node = @as(u8, @intCast(prng.uint_less_than(options.nodes_count)));
            const known = seen.get(at);
            const conflict = known != null and known.? != digest;
            const result = checker.state_digest(node, idx(at), digest);
            if (conflict) {
                try testing.expectError(error.StateMachineSafety, result);
                try expect_only_state_machine_safety(&checker);
                break;
            }
            try result;
            if (known == null) try seen.put(at, digest);
            newest = @max(newest, at);
        } else try expect_clean(&checker);
    }
}
