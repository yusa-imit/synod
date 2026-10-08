//! Test fixtures for `raft/node.zig` (ADR-007): the single construction path for a test `Node`,
//! a deterministic `Rng`, message builders, and the shared effect/entry assertions.
//!
//! Every node a test builds comes from `Rig.init`, which feeds `Node.init` a `Config` and a
//! `Restore` the caller spells out (no defaults hide in here beyond `config` and `restore_of`,
//! which are plain values the caller may copy and edit). Entry bytes in the `Restore` are
//! borrowed for the `init` call only, exactly as ADR-007 states.
//!
//! Allocation: none here; a `Rig` allocates only through the `gpa` its caller passes.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
const node_module = @import("node.zig");

const Config = node_module.Config;
const Configuration = types.Configuration;
const Effect = node_module.Effect;
const Effects = node_module.Effects;
const Entry = types.Entry;
const HardState = types.HardState;
const Header = types.Header;
const Index = types.Index;
const Message = types.Message;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rng = interfaces.Rng;
const Term = types.Term;

pub fn idx(value: u64) Index {
    return @enumFromInt(value);
}

pub fn term(value: u64) Term {
    return @enumFromInt(value);
}

pub fn node_id(value: u64) NodeId {
    return @enumFromInt(value);
}

pub fn entry(index: u64, term_value: u64, data: []const u8) Entry {
    return .{ .index = idx(index), .term = term(term_value), .kind = .normal, .data = data };
}

/// Fills `buffer[0..count]` with empty-data entries at indices 1..count, all in `term_value`.
pub fn fill_entries(buffer: []Entry, count: u32, term_value: u64) []const Entry {
    assert(count <= buffer.len);
    for (buffer[0..count], 0..) |*slot, i| slot.* = entry(@as(u64, i) + 1, term_value, "");
    return buffer[0..count];
}

/// Replays a SplitMix64 stream and counts draws, so a test can pin "one draw per reset".
pub const SplitMix = struct {
    state: u64,
    draws: u32 = 0,
    /// When set, every draw returns this word: `0` makes `uint_less_than(t)` yield `0` (timeout
    /// `t`), `maxInt(u64)` yields `t - 1` (timeout `2t - 1`), the two ends of `[t, 2t)`.
    forced: ?u64 = null,

    pub fn next_u64(self: *SplitMix) u64 {
        if (self.forced) |word| {
            self.draws += 1;
            return word;
        }
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        self.draws += 1;
        return z ^ (z >> 31);
    }
};

/// Three voters {1, 2, 3}, no learners, not joint. The node under test is id 1.
pub const voters = [_]NodeId{ node_id(1), node_id(2), node_id(3) };

pub const configuration: Configuration = .{
    .voters = &voters,
    .voters_outgoing = &.{},
    .learners = &.{},
};

/// Election timeout draws land in [10, 20); the log holds at most 8 entries and 64 bytes.
pub const config: Config = .{
    .id = node_id(1),
    .protocol_version = types.protocol_version_current,
    .election_ticks = 10,
    .heartbeat_ticks = 3,
    .voters_max = 3,
    .learners_max = 2,
    .inflight_max = 4,
    .log_entries_max = 8,
    .log_bytes_max = 64,
    .message_limits = .{ .entries_max = 4, .entry_bytes_max = 32, .snapshot_bytes_max = 128 },
};

/// Slots an `Effects` view can hold: `peers_max + 5` with `peers_max = 2 * voters_max +
/// learners_max - 1` (ADR-007), derived here from `config`, never read from the node.
pub fn effects_capacity(node_config: Config) u32 {
    const peers_max = 2 * node_config.voters_max + node_config.learners_max - 1;
    return peers_max + 5;
}

pub fn restore_of(hard_state: HardState, entries: []const Entry) Restore {
    return restore_with(configuration, hard_state, entries);
}

pub fn restore_with(
    cluster: Configuration,
    hard_state: HardState,
    entries: []const Entry,
) Restore {
    return .{ .hard_state = hard_state, .entries = entries, .configuration = cluster };
}

/// Five voters {1..5}, no learners, for quorum-of-three tests. The node under test is id 1.
pub const voters5 = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4), node_id(5) };

pub const configuration5: Configuration = .{
    .voters = &voters5,
    .voters_outgoing = &.{},
    .learners = &.{},
};

/// `config` with room for five voters per set.
pub const config5: Config = blk: {
    var result = config;
    result.voters_max = 5;
    break :blk result;
};

pub const base_entries = [_]Entry{ entry(1, 1, "a"), entry(2, 2, "bc"), entry(3, 3, "") };

/// Term 3, voted for node 2, commit 2, and a three-entry log (terms 1, 2, 3).
pub const base_restore = restore_of(hard_state_of(3, 2, 2), &base_entries);

pub fn hard_state_of(term_value: u64, vote: u64, commit: u64) HardState {
    return .{ .term = term(term_value), .vote = node_id(vote), .commit_index = idx(commit) };
}

/// The one construction path for a test `Node`: owns the `Rng` implementation the node holds.
/// Initialize in place; the caller runs `deinit(gpa)` with the same `gpa`.
pub const Rig = struct {
    node: Node,
    rng: SplitMix,

    pub fn init(
        rig: *Rig,
        gpa: std.mem.Allocator,
        node_config: Config,
        restore: *const Restore,
        seed: u64,
    ) node_module.InitError!void {
        rig.rng = .{ .state = seed };
        try rig.node.init(gpa, node_config, restore, Rng.init(&rig.rng));
    }

    /// Like `init`, but every `Rng` draw returns `forced` (see `SplitMix.forced`): the election
    /// timeout is exactly `t` for `0` and `2t - 1` for `maxInt(u64)`.
    pub fn init_fixed(
        rig: *Rig,
        gpa: std.mem.Allocator,
        node_config: Config,
        restore: *const Restore,
        forced: u64,
    ) node_module.InitError!void {
        rig.rng = .{ .state = 0, .forced = forced };
        try rig.node.init(gpa, node_config, restore, Rng.init(&rig.rng));
    }

    pub fn deinit(rig: *Rig, gpa: std.mem.Allocator) void {
        rig.node.deinit(gpa);
    }

    /// Steps `message` into the node. The returned view is borrowed until the next step.
    pub fn receive(rig: *Rig, message: *const Message) node_module.StepError!Effects {
        return rig.node.step(.{ .message = message });
    }
};

pub fn header_of(from: u64, to: u64, term_value: u64) Header {
    return .{
        .protocol_version = types.protocol_version_current,
        .term = term(term_value),
        .from = node_id(from),
        .to = node_id(to),
    };
}

pub fn vote_response(from: u64, to: u64, term_value: u64, granted: bool) Message {
    return .{ .request_vote_response = .{
        .header = header_of(from, to, term_value),
        .granted = granted,
    } };
}

pub fn append_response(from: u64, to: u64, term_value: u64) Message {
    return .{ .append_entries_response = .{
        .header = header_of(from, to, term_value),
        .round = 0,
        .outcome = .{ .accepted = .zero },
    } };
}

/// A heartbeat-shaped `append_entries`: empty batch, `prev_log_index == 0`.
pub fn heartbeat(from: u64, to: u64, term_value: u64) Message {
    return .{ .append_entries = .{
        .header = header_of(from, to, term_value),
        .prev_log_index = .zero,
        .prev_log_term = .zero,
        .leader_commit = .zero,
        .round = 1,
        .entries = &.{},
    } };
}

pub fn vote_request(from: u64, to: u64, term_value: u64) Message {
    return .{ .request_vote = .{
        .header = header_of(from, to, term_value),
        .last_log_index = .zero,
        .last_log_term = .zero,
    } };
}

/// A `request_vote` claiming the candidate's log ends at (`last_index`, `last_term`).
pub fn vote_request_at(
    from: u64,
    to: u64,
    term_value: u64,
    last_index: u64,
    last_term: u64,
) Message {
    return .{ .request_vote = .{
        .header = header_of(from, to, term_value),
        .last_log_index = idx(last_index),
        .last_log_term = term(last_term),
    } };
}

/// Asserts the ADR-007 emission contract on one `Effects` view: `phase()` never decreases and
/// the count fits the capacity computed from `node_config`.
pub fn expect_effects_ordered(effects: Effects, node_config: Config) !void {
    try testing.expect(effects.items.len <= effects_capacity(node_config));
    var previous: u8 = 0;
    for (effects.items) |*effect| {
        const phase: u8 = @intFromEnum(effect.phase());
        try testing.expect(phase >= previous);
        previous = phase;
    }
}

/// Counts effects of one variant in a view.
pub fn count_effects(effects: Effects, tag: std.meta.Tag(Effect)) u32 {
    var total: u32 = 0;
    for (effects.items) |effect| {
        if (std.meta.activeTag(effect) == tag) total += 1;
    }
    return total;
}

/// The single `save_hard_state` payload in `effects`; fails unless there is exactly one.
pub fn only_hard_state(effects: Effects) !HardState {
    try testing.expectEqual(@as(u32, 1), count_effects(effects, .save_hard_state));
    for (effects.items) |effect| {
        switch (effect) {
            .save_hard_state => |hard_state| return hard_state,
            else => {},
        }
    }
    return error.TestUnexpectedResult;
}

/// Field-by-field equality including entry bytes (not slice identity).
pub fn expect_entries_equal(expected: []const Entry, actual: []const Entry) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try testing.expectEqual(want.index, got.index);
        try testing.expectEqual(want.term, got.term);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqualSlices(u8, want.data, got.data);
    }
}
