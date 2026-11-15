//! Shared builders for the ReadIndex tests (plan 005 item 9): leaders over the single
//! construction path `fixtures.Rig`, round bookkeeping for the heartbeats a leader sends, response
//! messages, and the effect extractors. No test lives here and nothing here allocates beyond the
//! `testing.allocator` the `Rig` takes.
//!
//! The helpers never read `Node.reads`: they see a node only through `step`, `status`, the
//! `Effects` it returns and the rounds it sent, so they hold whatever the read side looks like.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const AppendRequest = types.AppendRequest;
const AppendOutcome = types.AppendOutcome;
const Config = node_module.Config;
const Effects = node_module.Effects;
const Message = types.Message;
const Read = node_module.Read;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Trace = fixtures.Trace;

pub const fresh3 = fixtures.restore_of(.empty, &.{});
pub const fresh5 = fixtures.restore_with(fixtures.configuration5, .empty, &.{});

const one_voter_ids = [_]types.NodeId{fixtures.node_id(1)};
pub const fresh1 = fixtures.restore_with(
    fixtures.conf_of(&one_voter_ids, &.{}, &.{}),
    .empty,
    &.{},
);

const peers_cap = 9;

/// The latest `append_entries` the leader sent to each peer, across every step absorbed.
pub const Seen = struct {
    latest: [peers_cap]?AppendRequest = @splat(null),
    /// How many `append_entries` were absorbed since creation.
    count: u32 = 0,

    pub fn absorb(seen: *Seen, effects: Effects) void {
        for (effects.items) |effect| switch (effect) {
            .send => |message| switch (message) {
                .append_entries => |request| {
                    seen.latest[@intFromEnum(request.header.to)] = request;
                    seen.count += 1;
                },
                else => {},
            },
            else => {},
        };
    }

    pub fn request(seen: *const Seen, peer: u64) !AppendRequest {
        return seen.latest[peer] orelse error.TestUnexpectedResult;
    }

    /// The round of the latest request to `peer`.
    pub fn round(seen: *const Seen, peer: u64) !u64 {
        return (try seen.request(peer)).round;
    }
};

/// Starts a node from `restore`, elects it with `grants`, and answers every `append_entries` the
/// win provoked from `answered` until quiet (so the election entry commits when a quorum is in
/// `answered`). Node 1 is the one under test; the election timeout is exactly `t`.
pub fn leader_from(
    rig: *Rig,
    node_config: Config,
    restore: *const Restore,
    grants: []const u64,
    answered: []const u64,
) !void {
    try rig.init_fixed(testing.allocator, node_config, restore, 0);
    errdefer rig.deinit(testing.allocator);
    const won = try fixtures.elect_checked(rig, grants);
    var trace: Trace = .{};
    try fixtures.answer(rig, won, answered, &trace);
    if (rig.node.status().role != .leader) return error.TestUnexpectedResult;
}

/// Three voters {1,2,3}, term 1, the election entry (index 1) committed and applied.
pub fn leader3(rig: *Rig, node_config: Config) !void {
    try leader_from(rig, node_config, &fresh3, &.{2}, &.{ 2, 3 });
    errdefer rig.deinit(testing.allocator);
    try testing.expectEqual(fixtures.idx(1), rig.node.status().commit_index);
    try testing.expectEqual(fixtures.idx(1), rig.node.status().applied_index);
}

/// Five voters {1..5}, term 1, the election entry committed.
pub fn leader5(rig: *Rig, node_config: Config) !void {
    try leader_from(rig, node_config, &fresh5, &.{ 2, 3 }, &.{ 2, 3, 4, 5 });
    errdefer rig.deinit(testing.allocator);
    try testing.expectEqual(fixtures.idx(1), rig.node.status().commit_index);
}

/// One voter: leads after its election timeout, its own election entry committed at once.
pub fn leader1(rig: *Rig, node_config: Config) !void {
    try rig.init_fixed(testing.allocator, node_config, &fresh1, 0);
    errdefer rig.deinit(testing.allocator);
    for (0..40) |_| {
        if (rig.node.status().role == .leader) break;
        _ = try fixtures.step_checked(rig, .tick);
    }
    if (rig.node.status().role != .leader) return error.TestUnexpectedResult;
    try testing.expectEqual(fixtures.idx(1), rig.node.status().commit_index);
}

/// One `read_index` step with the phase and invariant checks of `step_checked`.
pub fn read(rig: *Rig, ctx: u64) !Effects {
    return fixtures.step_checked(rig, .{ .read_index = ctx });
}

/// Ticks until the leader sends `append_entries` (a heartbeat), absorbing every step into `seen`.
/// `first` is the step that preceded (a registration), absorbed too: whichever round the node
/// chose to send for a read, the latest per peer is what the tests answer.
pub fn beat(rig: *Rig, seen: *Seen, first: Effects) !void {
    seen.absorb(first);
    const before = seen.count;
    const limit = 2 * rig.node.config.heartbeat_ticks + 1;
    for (0..limit) |_| {
        const effects = try fixtures.step_checked(rig, .tick);
        seen.absorb(effects);
        if (seen.count > before) return;
    }
    return error.TestUnexpectedResult;
}

pub fn term_now(rig: *const Rig) u64 {
    return @intFromEnum(rig.node.status().term);
}

pub const rejection: AppendOutcome = .{ .rejected = .{ .index = .zero, .term = .zero } };

/// An `append_entries_response` from `from` to node 1 at `at_term` echoing `round`.
pub fn response(from: u64, at_term: u64, round: u64, outcome: AppendOutcome) Message {
    return .{ .append_entries_response = .{
        .header = fixtures.header_of(from, 1, at_term),
        .round = round,
        .outcome = outcome,
    } };
}

/// Steps a rejected response at the current term; a rejection acks the round all the same.
pub fn reject_at(rig: *Rig, from: u64, round: u64) !Effects {
    const message = response(from, term_now(rig), round, rejection);
    return fixtures.receive_checked(rig, &message);
}

/// The `read_ready` reads of a step: none, or exactly one effect's slice.
pub fn ready_of(effects: Effects) ![]const Read {
    return of_tag(effects, .read_ready);
}

/// The `read_failed` reads of a step: none, or exactly one effect's slice.
pub fn failed_of(effects: Effects) ![]const Read {
    return of_tag(effects, .read_failed);
}

fn of_tag(effects: Effects, tag: std.meta.Tag(node_module.Effect)) ![]const Read {
    try testing.expect(fixtures.count_effects(effects, tag) <= 1);
    for (effects.items) |effect| switch (effect) {
        .read_ready => |reads| if (tag == .read_ready) return reads,
        .read_failed => |reads| if (tag == .read_failed) return reads,
        else => {},
    };
    return &.{};
}

/// The step reported exactly `want` (by `ctx`, in order) as ready, each at `index`.
pub fn expect_ready(effects: Effects, want: []const u64, index: u64) !void {
    const got = try ready_of(effects);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |ctx, read_done| {
        try testing.expectEqual(ctx, read_done.ctx);
        try testing.expectEqual(fixtures.idx(index), read_done.index);
    }
}

/// The step reported no ready read.
pub fn expect_no_ready(effects: Effects) !void {
    try testing.expectEqual(@as(usize, 0), (try ready_of(effects)).len);
}

/// The step reported exactly `want` (by `ctx`, in registration order) as failed.
pub fn expect_failed(effects: Effects, want: []const u64) !void {
    const got = try failed_of(effects);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |ctx, read_done| try testing.expectEqual(ctx, read_done.ctx);
}

/// Every `read_ready` and `read_failed` follows every `apply` and `send` of the step.
pub fn expect_after_apply(effects: Effects) !void {
    var last_apply: ?usize = null;
    for (effects.items, 0..) |effect, at| switch (effect) {
        .apply, .send => last_apply = at,
        .read_ready, .read_failed => if (last_apply) |before| try testing.expect(before < at),
        else => {},
    };
}
