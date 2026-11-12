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
const membership = @import("membership.zig");
const progress_module = @import("progress.zig");

const AppendRequest = types.AppendRequest;
const AppendResponse = types.AppendResponse;
const Config = node_module.Config;
const ConfChange = types.ConfChange;
const Configuration = types.Configuration;
const Effect = node_module.Effect;
const Effects = node_module.Effects;
const Entry = types.Entry;
const HardState = types.HardState;
const Header = types.Header;
const Index = types.Index;
const Message = types.Message;
const Node = node_module.Node;
const Progress = progress_module.Progress;
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
/// A snapshot is due 7 applied entries past the base, keeping 3 (plan 005 item 3).
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
    .snapshot_entries_min = 0, // Compaction off: fixture state machines cannot snapshot.
    .snapshot_trailing = 0,
    .message_limits = .{ .entries_max = 4, .entry_bytes_max = 32, .snapshot_bytes_max = 128 },
};

/// Slots an `Effects` view can hold: `peers_max + 9` with `peers_max = 2 * voters_max +
/// learners_max - 1` (ADR-007), derived here from `config`, never read from the node.
pub fn effects_capacity(node_config: Config) u32 {
    const peers_max = 2 * node_config.voters_max + node_config.learners_max - 1;
    return peers_max + 9;
}

pub fn restore_of(hard_state: HardState, entries: []const Entry) Restore {
    return restore_with(configuration, hard_state, entries);
}

pub fn restore_with(
    cluster: Configuration,
    hard_state: HardState,
    entries: []const Entry,
) Restore {
    return .{
        .hard_state = hard_state,
        .snapshot = .zero,
        .entries = entries,
        .configuration = cluster,
    };
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

/// A `pre_vote_response` from `from` to `to`; `term_value` is the would-be term when granted.
pub fn pre_vote_response(from: u64, to: u64, term_value: u64, granted: bool) Message {
    return .{ .pre_vote_response = .{
        .header = header_of(from, to, term_value),
        .granted = granted,
    } };
}

/// A `pre_vote` for `term_value` claiming the sender's log ends at (`last_index`, `last_term`).
pub fn pre_vote_at(
    from: u64,
    to: u64,
    term_value: u64,
    last_index: u64,
    last_term: u64,
) Message {
    return .{ .pre_vote = .{
        .header = header_of(from, to, term_value),
        .last_log_index = idx(last_index),
        .last_log_term = term(last_term),
    } };
}

/// The pre-vote round of node 1 (ADR-007, thesis 9.6): no durable effect, exactly one
/// `send .pre_vote` per id in `targets` and to nobody else, each at `would_be` term and
/// stamped with the log tail; then, when `leader_cleared`, one `leader_changed(.none)` last.
pub fn expect_pre_vote(
    effects: Effects,
    would_be: u64,
    last_index: u64,
    last_term: u64,
    targets: []const u64,
    leader_cleared: bool,
) !void {
    const extra: usize = @intFromBool(leader_cleared);
    try testing.expectEqual(targets.len + extra, effects.items.len);
    try testing.expectEqual(@as(u32, 0), count_effects(effects, .save_hard_state));
    var seen = [_]u32{0} ** 8;
    for (effects.items[0..targets.len]) |effect| {
        const request = switch (effect) {
            .send => |message| switch (message) {
                .pre_vote => |payload| payload,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(node_id(1), request.header.from);
        try testing.expectEqual(term(would_be), request.header.term);
        try testing.expectEqual(config.protocol_version, request.header.protocol_version);
        try testing.expectEqual(idx(last_index), request.last_log_index);
        try testing.expectEqual(term(last_term), request.last_log_term);
        seen[@intFromEnum(request.header.to)] += 1;
    }
    for (targets) |target| try testing.expectEqual(@as(u32, 1), seen[target]);
    if (leader_cleared) {
        const last = effects.items[effects.items.len - 1];
        try testing.expect(last == .leader_changed);
        try testing.expectEqual(NodeId.none, last.leader_changed);
    }
}

/// Exactly one `pre_vote_response` send, to `to`, at `term_value`, with `granted`; any other
/// effect is a failure (a pre-vote reply is never durable).
pub fn expect_pre_vote_reply(effects: Effects, to: u64, term_value: u64, granted: bool) !void {
    try testing.expectEqual(@as(usize, 1), effects.items.len);
    const reply = switch (effects.items[0]) {
        .send => |message| switch (message) {
            .pre_vote_response => |payload| payload,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(node_id(to), reply.header.to);
    try testing.expectEqual(node_id(1), reply.header.from);
    try testing.expectEqual(term(term_value), reply.header.term);
    try testing.expectEqual(config.protocol_version, reply.header.protocol_version);
    try testing.expectEqual(granted, reply.granted);
}

/// The leader's live per-peer trackers, slot order = `configuration.voters` without self (so
/// slot 0 is node 2 in the three-voter rig). Test-only window onto node-owned state: the leader
/// side holds them in `Node.progress` (capacity fixed at `init`) with `Node.progress_len` live,
/// zero when the node does not lead.
pub fn leader_progress(node: *Node) []Progress {
    return node.progress[0..node.progress_len];
}

// ---- commit and apply inspection (plan 003 item 2B-iii) -----------------------------------

/// The one `append_entries` to `to` in `effects`; fails when there is none or several.
pub fn append_to(effects: Effects, to: u64) !AppendRequest {
    var found: ?AppendRequest = null;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries => |request| if (request.header.to == node_id(to)) {
                try testing.expect(found == null);
                found = request;
            },
            else => {},
        },
        else => {},
    };
    return found orelse error.TestUnexpectedResult;
}

pub fn last_of(request: AppendRequest) u64 {
    return @intFromEnum(request.prev_log_index) + request.entries.len;
}

pub fn index_of(effects: Effects, tag: std.meta.Tag(Effect)) ?usize {
    for (effects.items, 0..) |effect, i| {
        if (std.meta.activeTag(effect) == tag) return i;
    }
    return null;
}

pub fn last_hard_state(effects: Effects) !HardState {
    var found: ?HardState = null;
    for (effects.items) |effect| switch (effect) {
        .save_hard_state => |hard_state| found = hard_state,
        else => {},
    };
    return found orelse error.TestUnexpectedResult;
}

/// Exactly one `apply` effect, carrying `want` in order.
pub fn expect_apply(effects: Effects, want: []const Entry) !void {
    try testing.expectEqual(@as(u32, 1), count_effects(effects, .apply));
    for (effects.items) |effect| switch (effect) {
        .apply => |batch| try expect_entries_equal(want, batch),
        else => {},
    };
}

/// Nothing durable about commit and nothing applied.
pub fn expect_quiet(effects: Effects) !void {
    try testing.expectEqual(@as(u32, 0), count_effects(effects, .save_hard_state));
    try testing.expectEqual(@as(u32, 0), count_effects(effects, .apply));
}

/// The one `append_entries_response` send in `effects`.
pub fn reply_of(effects: Effects) !AppendResponse {
    var found: ?AppendResponse = null;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries_response => |reply| {
                try testing.expect(found == null);
                found = reply;
            },
            else => {},
        },
        else => {},
    };
    return found orelse error.TestUnexpectedResult;
}

/// The one reply accepts exactly `matched` and goes to `to`.
pub fn expect_ack(effects: Effects, to: u64, matched: u64) !void {
    const reply = try reply_of(effects);
    try testing.expectEqual(node_id(to), reply.header.to);
    const want: types.AppendOutcome = .{ .accepted = idx(matched) };
    try testing.expectEqual(want, reply.outcome);
}

pub fn expect_rejected(effects: Effects) !void {
    try testing.expect((try reply_of(effects)).outcome == .rejected);
}

/// An `append_entries` from `from` to node 1.
pub fn append_request(
    from: u64,
    at_term: u64,
    prev: u64,
    prev_term: u64,
    leader_commit: u64,
    entries: []const Entry,
) Message {
    return .{ .append_entries = .{
        .header = header_of(from, 1, at_term),
        .prev_log_index = idx(prev),
        .prev_log_term = term(prev_term),
        .leader_commit = idx(leader_commit),
        .round = 7,
        .entries = entries,
    } };
}

/// A restore at `hard_term` with `count` empty term-1 entries and the given commit index.
pub fn log_restore(buffer: []Entry, count: u32, hard_term: u64, commit: u64) Restore {
    const log = fill_entries(buffer, count, 1);
    return restore_of(hard_state_of(hard_term, 0, commit), log);
}

// ---- joint consensus (plan 005 item 8) -----------------------------------------------------

/// `config` for membership changes: up to five voters and two learners per set, room for a
/// 109-byte conf entry (5 + 5 voters + 2 learners), 16 slots and 512 entry bytes.
pub const config_conf: Config = blk: {
    var result = config;
    result.voters_max = 5;
    result.log_entries_max = 16;
    result.log_bytes_max = 512;
    result.message_limits.entries_max = 8;
    result.message_limits.entry_bytes_max = 128;
    break :blk result;
};

/// Owns the bytes of one encoded `ConfChange`, so an `Entry` built from it can be borrowed.
pub const ConfBytes = struct {
    buffer: [membership.conf_bytes_max]u8 = undefined,
    len: u32 = 0,

    /// A `conf_change` entry at (`index`, `term_value`) carrying `change`, which must validate.
    pub fn entry(self: *ConfBytes, index: u64, term_value: u64, change: ConfChange) Entry {
        self.len = membership.encode(&change, &self.buffer);
        return .{
            .index = idx(index),
            .term = term(term_value),
            .kind = .conf_change,
            .data = self.buffer[0..self.len],
        };
    }
};

pub fn conf_of(
    voters_in: []const NodeId,
    outgoing: []const NodeId,
    learners: []const NodeId,
) Configuration {
    return .{ .voters = voters_in, .voters_outgoing = outgoing, .learners = learners };
}

/// Same three lists, id by id.
pub fn expect_configuration(want: Configuration, got: Configuration) !void {
    try testing.expectEqualSlices(NodeId, want.voters, got.voters);
    try testing.expectEqualSlices(NodeId, want.voters_outgoing, got.voters_outgoing);
    try testing.expectEqualSlices(NodeId, want.learners, got.learners);
}

/// Decodes the `data` of a `conf_change` entry; fails the test if it is not one that decodes.
pub fn decode_conf(entry_value: Entry, ids: *[membership.conf_ids_max]NodeId) !ConfChange {
    try testing.expectEqual(types.EntryKind.conf_change, entry_value.kind);
    return membership.decode(entry_value.data, ids);
}

/// Steps `input` and checks the ADR-007 phase order and `check_invariants()` afterwards.
pub fn step_checked(rig: *Rig, input: node_module.Input) !Effects {
    const effects = try rig.node.step(input);
    try expect_effects_ordered(effects, rig.node.config);
    try rig.node.check_invariants();
    return effects;
}

/// Like `Rig.receive`, with the checks of `step_checked`.
pub fn receive_checked(rig: *Rig, message: *const Message) !Effects {
    return step_checked(rig, .{ .message = message });
}

/// Ticks node 1 to a pre-candidate, then feeds pre-vote and vote grants from `grants` (in
/// order) until it leads; returns the winning step's effects. Needs `init_fixed(.., 0)`.
pub fn elect_checked(rig: *Rig, grants: []const u64) !Effects {
    var guard: u32 = 0;
    while (rig.node.status().role != .pre_candidate) : (guard += 1) {
        if (guard >= 40) return error.TestUnexpectedResult;
        _ = try step_checked(rig, .tick);
    }
    const would_be = @intFromEnum(rig.node.status().term) + 1;
    var used: usize = 0;
    while (rig.node.status().role == .pre_candidate) : (used += 1) {
        if (used >= grants.len) return error.TestUnexpectedResult;
        const grant = pre_vote_response(grants[used], 1, would_be, true);
        _ = try receive_checked(rig, &grant);
    }
    const at = @intFromEnum(rig.node.status().term);
    var effects: Effects = .{ .items = &.{} };
    used = 0;
    while (rig.node.status().role == .candidate) : (used += 1) {
        if (used >= grants.len) return error.TestUnexpectedResult;
        const grant = vote_response(grants[used], 1, at, true);
        effects = try receive_checked(rig, &grant);
    }
    if (rig.node.status().role != .leader) return error.TestUnexpectedResult;
    return effects;
}

/// Node 1 (leader) hears from `request.header.to` that it accepted `request` through its last
/// entry; returns the step's effects.
pub fn accept(rig: *Rig, request: AppendRequest) !Effects {
    const reply: Message = .{ .append_entries_response = .{
        .header = header_of(
            @intFromEnum(request.header.to),
            1,
            @intFromEnum(rig.node.status().term),
        ),
        .round = request.round,
        .outcome = .{ .accepted = idx(last_of(request)) },
    } };
    return receive_checked(rig, &reply);
}

/// Accepts, one step each and in the order of `peers`, the `append_entries` of `effects` to
/// those peers (all captured before the first step); follow-up sends are not answered. Returns
/// the effects of the last step.
pub fn accept_each(rig: *Rig, effects: Effects, peers: []const u64) !Effects {
    var requests: [16]AppendRequest = undefined;
    assert(peers.len <= requests.len);
    for (peers, 0..) |peer, i| requests[i] = try append_to(effects, peer);
    var last: Effects = .{ .items = &.{} };
    for (requests[0..peers.len]) |request| last = try accept(rig, request);
    return last;
}

/// What a run of steps showed the driver, beyond the final state.
pub const Trace = struct {
    /// `leader_changed(.none)` notifications seen.
    demotions: u32 = 0,

    fn observe(trace: *Trace, effects: Effects) void {
        for (effects.items) |effect| switch (effect) {
            .leader_changed => |leader| trace.demotions += @intFromBool(leader == .none),
            else => {},
        };
    }
};

/// Accepts, through its last entry, every `append_entries` in `effects` addressed to a node in
/// `peers`, and every one the answers provoke in turn, until nothing is left to answer. Peers
/// not listed stay silent.
pub fn answer(rig: *Rig, effects: Effects, peers: []const u64, trace: *Trace) !void {
    var queue: [32]AppendRequest = undefined;
    var queued = collect_appends(effects, peers, &queue, 0);
    var guard: u32 = 0;
    while (queued > 0) : (guard += 1) {
        if (guard >= 64) return error.TestUnexpectedResult;
        queued -= 1;
        const answered = try accept(rig, queue[queued]);
        trace.observe(answered);
        queued = collect_appends(answered, peers, &queue, queued);
    }
}

/// Runs `ticks` ticks, `answer`ing the sends of each.
pub fn drive(rig: *Rig, peers: []const u64, ticks: u32, trace: *Trace) !void {
    for (0..ticks) |_| {
        const effects = try step_checked(rig, .tick);
        trace.observe(effects);
        try answer(rig, effects, peers, trace);
    }
}

/// A copy of what a refused step must leave alone: the status and the three id lists.
pub const Frozen = struct {
    status: node_module.Status,
    ids: [membership.conf_ids_max]NodeId,
    counts: [3]usize,

    pub fn take(node: *const Node) Frozen {
        var frozen: Frozen = .{
            .status = node.status(),
            .ids = undefined,
            .counts = undefined,
        };
        const current = node.configuration_current();
        const lists = [3][]const NodeId{
            current.voters,
            current.voters_outgoing,
            current.learners,
        };
        var at: usize = 0;
        for (lists, 0..) |list, i| {
            @memcpy(frozen.ids[at..][0..list.len], list);
            frozen.counts[i] = list.len;
            at += list.len;
        }
        return frozen;
    }

    pub fn expect_same(frozen: *const Frozen, node: *const Node) !void {
        try testing.expectEqual(frozen.status, node.status());
        const now = Frozen.take(node);
        try testing.expectEqual(frozen.counts, now.counts);
        const total = frozen.counts[0] + frozen.counts[1] + frozen.counts[2];
        try testing.expectEqualSlices(NodeId, frozen.ids[0..total], now.ids[0..total]);
    }
};

fn collect_appends(
    effects: Effects,
    peers: []const u64,
    queue: *[32]AppendRequest,
    start: usize,
) usize {
    var queued = start;
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .append_entries => |request| {
                for (peers) |peer| if (request.header.to == node_id(peer)) {
                    assert(queued < queue.len);
                    queue[queued] = request;
                    queued += 1;
                };
            },
            else => {},
        },
        else => {},
    };
    return queued;
}
