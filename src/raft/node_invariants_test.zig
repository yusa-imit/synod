//! Tests for `Node.check_invariants` in the 2A-i skeleton (plan 003, ADR-007): a valid node
//! passes, and each `InvariantError` variant a follower can reach is provoked by corrupting one
//! field of an otherwise valid node, then restored so the next case starts clean.
//!
//! Not provokable yet, because they need a leader's per-peer `progress` or proposal bytes that
//! land with items 2B-i/2C: `InvariantProgressOrder`, `InvariantInflightOverflow`,
//! `InvariantEntryDataMisplaced`. They are pinned by the exhaustive switch at the bottom.
//!
//! The corrupted fields (`commit_index`, `applied_index`, `term`, `vote`, `leader`, `role`,
//! `election_timeout`, `log.entries`) are the `Node` fields the implementation must name so.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");

const Rig = fixtures.Rig;

const config = fixtures.config;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const term = fixtures.term;

fn make(rig: *Rig) !void {
    try rig.init(testing.allocator, config, &fixtures.base_restore, 1);
    try rig.node.check_invariants();
}

test "node: a freshly restored node and a freshly empty node both pass check_invariants" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    const empty = fixtures.restore_of(.empty, &.{});
    var blank: Rig = undefined;
    try blank.init(testing.allocator, config, &empty, 2);
    defer blank.deinit(testing.allocator);
    try blank.node.check_invariants();
}

test "node: commit_index past the log is InvariantCommitBeyondLog" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    rig.node.commit_index = idx(4); // The log ends at index 3.
    try testing.expectError(error.InvariantCommitBeyondLog, rig.node.check_invariants());
    rig.node.commit_index = idx(3); // Exactly the last index is fine.
    try rig.node.check_invariants();
}

test "node: applied_index past commit_index is InvariantAppliedBeyondCommit" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    rig.node.applied_index = idx(3); // Commit is 2, the log has 3 entries.
    try testing.expectError(error.InvariantAppliedBeyondCommit, rig.node.check_invariants());
    rig.node.applied_index = idx(2); // Applied may equal commit.
    try rig.node.check_invariants();
}

test "node: a term behind the last log entry is InvariantTermBehindLog" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    rig.node.term = term(2); // The last entry carries term 3.
    try testing.expectError(error.InvariantTermBehindLog, rig.node.check_invariants());
    rig.node.term = term(3);
    try rig.node.check_invariants();
}

test "node: a vote cast in term zero is InvariantVoteWithoutTerm" {
    const empty = fixtures.restore_of(.empty, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &empty, 1);
    defer rig.deinit(testing.allocator);

    rig.node.vote = node_id(2);
    try testing.expectError(error.InvariantVoteWithoutTerm, rig.node.check_invariants());
    rig.node.vote = .none;
    try rig.node.check_invariants();
}

test "node: role leader without being the known leader is InvariantLeaderRole" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    rig.node.role = .leader; // `leader` is still .none, not this node.
    try testing.expectError(error.InvariantLeaderRole, rig.node.check_invariants());
    rig.node.role = .follower;
    try rig.node.check_invariants();
}

test "node: an election timeout outside [t, 2t) is InvariantElectionTimeout" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    const t = config.election_ticks;
    rig.node.election_timeout = t - 1;
    try testing.expectError(error.InvariantElectionTimeout, rig.node.check_invariants());
    rig.node.election_timeout = 2 * t;
    try testing.expectError(error.InvariantElectionTimeout, rig.node.check_invariants());
    for ([_]u32{ t, 2 * t - 1 }) |inside| {
        rig.node.election_timeout = inside;
        try rig.node.check_invariants();
    }
}

test "node: a corrupted log is reported with the inherited log invariants" {
    var rig: Rig = undefined;
    try make(&rig);
    defer rig.deinit(testing.allocator);

    const entries = rig.node.log.entries;
    entries[1].index = idx(5);
    try testing.expectError(error.InvariantIndexNotContiguous, rig.node.check_invariants());
    entries[1].index = idx(2);
    entries[2].term = term(1); // Terms along the log are 1, 2, then 1.
    try testing.expectError(error.InvariantTermRegressed, rig.node.check_invariants());
    entries[2].term = term(3);
    entries[0].index = idx(2); // No snapshot exists, so the log must start at index 1.
    try testing.expectError(error.InvariantSnapshotGap, rig.node.check_invariants());
    entries[0].index = idx(1);
    try rig.node.check_invariants();
}

fn describe_invariant(err: node_module.InvariantError) u8 {
    return switch (err) {
        error.InvariantIndexNotContiguous,
        error.InvariantTermRegressed,
        error.InvariantSnapshotGap,
        => 0,
        error.InvariantCommitBeyondLog,
        error.InvariantAppliedBeyondCommit,
        error.InvariantTermBehindLog,
        error.InvariantVoteWithoutTerm,
        error.InvariantLeaderRole,
        error.InvariantElectionTimeout,
        => 1,
        error.InvariantEntryDataMisplaced,
        error.InvariantProgressOrder,
        error.InvariantInflightOverflow,
        => 2,
    };
}

test "node: InvariantError is exhaustively switchable" {
    try testing.expectEqual(@as(u8, 0), describe_invariant(error.InvariantSnapshotGap));
    try testing.expectEqual(@as(u8, 1), describe_invariant(error.InvariantLeaderRole));
    try testing.expectEqual(@as(u8, 2), describe_invariant(error.InvariantProgressOrder));
}
