//! Tests for `raft/node.zig` construction (plan 003 item 2A-i, ADR-007): what `Node.init`
//! accepts and keeps, every `InitError` variant provoked at its boundary, the allocation
//! contract (all memory at `init`, none afterwards), and the declared error sets.
//!
//! Step behavior lives in `node_step_test.zig`, invariants in `node_invariants_test.zig`.
//! Every node comes from `fixtures.Rig`, the single construction path.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Entry = types.Entry;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Status = node_module.Status;

const config = fixtures.config;
const entry = fixtures.entry;
const hard_state_of = fixtures.hard_state_of;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const restore_of = fixtures.restore_of;
const term = fixtures.term;

const base_entries = fixtures.base_entries;
const base_restore = fixtures.base_restore;

const InitCheckError = node_module.InitError || node_module.InvariantError;

fn init_result(node_config: Config, restore: *const Restore) InitCheckError!void {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, node_config, restore, 1);
    defer rig.deinit(testing.allocator);

    try rig.node.check_invariants();
}

test "node: a fresh restore starts a follower with zeroed status and no leader" {
    const restore = restore_of(.empty, &.{});
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &restore, 1);
    defer rig.deinit(testing.allocator);

    const expected: Status = .{
        .role = .follower,
        .term = .zero,
        .vote = .none,
        .leader = .none,
        .commit_index = .zero,
        .applied_index = .zero,
        .last_index = .zero,
    };
    try testing.expectEqual(expected, rig.node.status());
    try testing.expectEqual(@as(usize, 0), rig.node.entries().len);
    try rig.node.check_invariants();
}

test "node: restore keeps term, vote, commit and last index and applies nothing yet" {
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &base_restore, 1);
    defer rig.deinit(testing.allocator);

    const expected: Status = .{
        .role = .follower,
        .term = term(3),
        .vote = node_id(2),
        .leader = .none,
        .commit_index = idx(2),
        .applied_index = .zero, // A restarted node re-applies (0, commit_index] on its first step.
        .last_index = idx(3),
    };
    try testing.expectEqual(expected, rig.node.status());
    try fixtures.expect_entries_equal(&base_entries, rig.node.entries());
    try rig.node.check_invariants();
}

test "node: init copies the restore, so clobbering the caller's buffers changes nothing" {
    var data = [_]u8{ 'a', 'b', 'c' };
    var listed = [_]Entry{ entry(1, 1, data[0..1]), entry(2, 2, data[1..3]) };
    var members = [_]NodeId{ node_id(1), node_id(2), node_id(3) };
    var restore = restore_of(hard_state_of(2, 0, 0), &listed);
    restore.configuration.voters = &members;
    var rig: Rig = undefined;
    try rig.init(testing.allocator, config, &restore, 1);
    defer rig.deinit(testing.allocator);

    @memset(&data, 0xff);
    @memset(&listed, entry(9, 9, ""));
    @memset(&members, .none);

    const expected = [_]Entry{ entry(1, 1, "a"), entry(2, 2, "bc") };
    try fixtures.expect_entries_equal(&expected, rig.node.entries());
    try rig.node.check_invariants();
    // The copied configuration still knows peer 2: its higher term is adopted.
    const message = fixtures.vote_response(2, 1, 5, false);
    _ = try rig.receive(&message);
    try testing.expectEqual(term(5), rig.node.status().term);
}

test "node: restore log boundaries empty, one, max are accepted and max plus one is full" {
    var buffer: [config.log_entries_max + 1]Entry = undefined;
    for ([_]u32{ 0, 1, config.log_entries_max }) |count| {
        const listed = fixtures.fill_entries(&buffer, count, 1);
        try init_result(config, &restore_of(hard_state_of(1, 0, 0), listed));
    }
    const over = fixtures.fill_entries(&buffer, config.log_entries_max + 1, 1);
    const restore = restore_of(hard_state_of(1, 0, 0), over);
    try testing.expectError(error.RestoreLogFull, init_result(config, &restore));
}

test "node: restore bytes at log_bytes_max are accepted and one byte more is full" {
    const full = "x" ** 32;
    const exact = [_]Entry{ entry(1, 1, full), entry(2, 1, full) };
    const over = [_]Entry{ entry(1, 1, full), entry(2, 1, full), entry(3, 1, "y") };
    try testing.expectEqual(@as(u32, 64), config.log_bytes_max);
    // Slots are plentiful in both cases: only the byte budget differs.
    try init_result(config, &restore_of(hard_state_of(1, 0, 0), &exact));
    const over_restore = restore_of(hard_state_of(1, 0, 0), &over);
    try testing.expectError(error.RestoreLogFull, init_result(config, &over_restore));
}

test "node: restore entries must be contiguous from index one" {
    const bad_logs = [_][]const Entry{
        &.{entry(2, 1, "")}, // Starts at 2.
        &.{ entry(1, 1, ""), entry(3, 1, "") }, // Gap.
        &.{ entry(1, 1, ""), entry(1, 1, "") }, // Duplicate.
        &.{ entry(1, 1, ""), entry(3, 1, ""), entry(2, 1, "") }, // Out of order.
    };
    for (bad_logs) |entries| {
        const restore = restore_of(hard_state_of(5, 0, 0), entries);
        try testing.expectError(error.RestoreInconsistent, init_result(config, &restore));
    }
}

test "node: restore entry term may equal hard_state.term but never exceed it" {
    const equal = [_]Entry{ entry(1, 2, ""), entry(2, 4, "") };
    try init_result(config, &restore_of(hard_state_of(4, 0, 0), &equal));
    const above = restore_of(hard_state_of(3, 0, 0), &equal);
    try testing.expectError(error.RestoreInconsistent, init_result(config, &above));
    const from_zero = restore_of(.empty, &.{entry(1, 1, "")});
    try testing.expectError(error.RestoreInconsistent, init_result(config, &from_zero));
    const zero_term = restore_of(hard_state_of(1, 0, 0), &.{entry(1, 0, "")});
    try testing.expectError(error.RestoreInconsistent, init_result(config, &zero_term));
}

test "node: restore commit_index may reach the last index but never pass it" {
    try init_result(config, &restore_of(hard_state_of(3, 0, 3), &base_entries));
    const past = restore_of(hard_state_of(3, 0, 4), &base_entries);
    try testing.expectError(error.RestoreInconsistent, init_result(config, &past));
    const empty_past = restore_of(hard_state_of(3, 0, 1), &.{});
    try testing.expectError(error.RestoreInconsistent, init_result(config, &empty_past));
    try init_result(config, &restore_of(hard_state_of(3, 0, 0), &.{}));
}

const ConfCase = struct { voters: []const NodeId, learners: []const NodeId, expected: anyerror };

const four_voters = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4) };
const unsorted = [_]NodeId{ node_id(2), node_id(1), node_id(3) };
const duplicated = [_]NodeId{ node_id(1), node_id(1), node_id(2) };
const with_none = [_]NodeId{ .none, node_id(1) };
const three_learners = [_]NodeId{ node_id(4), node_id(5), node_id(6) };
const voter_as_learner = [_]NodeId{node_id(2)};

fn conf_voters_17() [17]NodeId {
    var ids: [17]NodeId = undefined;
    for (&ids, 0..) |*id, i| id.* = node_id(@as(u64, i) + 1);
    return ids;
}

test "node: every Conf error from a configuration over the Config caps is returned" {
    const seventeen = conf_voters_17();
    const none: []const NodeId = &.{};
    const trio: []const NodeId = &fixtures.voters;
    const cases = [_]ConfCase{
        .{ .voters = none, .learners = none, .expected = error.ConfVotersEmpty },
        .{ .voters = &seventeen, .learners = none, .expected = error.ConfVotersTooMany },
        .{ .voters = &four_voters, .learners = none, .expected = error.ConfVotersTooMany },
        .{ .voters = trio, .learners = &three_learners, .expected = error.ConfLearnersTooMany },
        .{ .voters = &unsorted, .learners = none, .expected = error.ConfNodesUnsorted },
        .{ .voters = &duplicated, .learners = none, .expected = error.ConfNodesUnsorted },
        .{ .voters = &with_none, .learners = none, .expected = error.ConfNodesUnsorted },
        .{ .voters = trio, .learners = &voter_as_learner, .expected = error.ConfLearnerIsVoter },
    };
    for (cases) |case| {
        var restore = restore_of(.empty, &.{});
        restore.configuration = .{
            .voters = case.voters,
            .voters_outgoing = &.{},
            .learners = case.learners,
        };
        try testing.expectError(case.expected, init_result(config, &restore));
    }
}

test "node: a configuration exactly at the Config caps is accepted" {
    var restore = restore_of(.empty, &.{});
    restore.configuration.learners = &.{ node_id(4), node_id(5) };
    try testing.expectEqual(@as(usize, config.voters_max), restore.configuration.voters.len);
    try testing.expectEqual(@as(usize, config.learners_max), restore.configuration.learners.len);
    try init_result(config, &restore);
}

test "node: init fails cleanly at each allocation and deinit frees them all" {
    var attempts: u32 = 0;
    while (attempts < 32) : (attempts += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = attempts });
        var rig: Rig = undefined;
        rig.init(failing.allocator(), config, &base_restore, 1) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        defer rig.deinit(failing.allocator());

        try rig.node.check_invariants();
        // Log slots, entry bytes and the effects buffer are three separate allocations.
        try testing.expect(attempts >= 3);
        break;
    } else return error.TestUnexpectedResult;
}

test "node: no method takes an allocator after init" {
    inline for (.{ Node.step, Node.status, Node.entries, Node.check_invariants }) |function| {
        const info = @typeInfo(@TypeOf(function)).@"fn";
        inline for (info.params) |param| {
            try testing.expect(param.type.? != std.mem.Allocator);
        }
    }
    try testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(Node.step)).@"fn".params.len);
}

fn describe_init_error(err: node_module.InitError) u8 {
    return switch (err) {
        error.OutOfMemory => 0,
        error.ConfVotersEmpty,
        error.ConfVotersTooMany,
        error.ConfLearnersTooMany,
        error.ConfNodesUnsorted,
        error.ConfLearnerIsVoter,
        error.ConfJointShape,
        => 1,
        error.RestoreLogFull => 2,
        error.RestoreInconsistent => 3,
    };
}

test "node: InitError is exhaustively switchable" {
    try testing.expectEqual(@as(u8, 3), describe_init_error(error.RestoreInconsistent));
    try testing.expectEqual(@as(u8, 2), describe_init_error(error.RestoreLogFull));
    try testing.expectEqual(@as(u8, 1), describe_init_error(error.ConfLearnerIsVoter));
    try testing.expectEqual(@as(u8, 0), describe_init_error(error.OutOfMemory));
}
