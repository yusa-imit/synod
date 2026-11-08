//! synod.raft.reconfigure — joint-consensus membership changes in the node (thesis §4.3; plan 005
//! item 8, ADR-009), as free functions over a `*Node`. `Node` owns the state (`configuration`,
//! `configuration_index`, `base_configuration`, the peer slots); this file owns the rules.
//!
//! A configuration takes effect when its `conf_change` entry is appended (leader, follower and
//! restore: `node_init.log_append` calls `on_append`), not when it commits, and rolls back when a
//! truncate drops it (`on_truncate`, a backward rescan of the log, else the configuration as of
//! the log base). The leader proposes `enter_joint(current, target)` for `Input.conf_change`,
//! one change in flight (`ConfChangePending`); once it commits, `leave_if_due` appends
//! `leave_joint`; once that commits and the leader is outside `voters`, `step_end` steps it down.
//! Learners replicate but never vote, never count in a quorum and never campaign.
//!
//! Peer data is validated before any mutation (`entry_check`, at receive and at restore), so
//! decoding a node-held entry cannot fail. Peer slots are swap-removed and appended in place
//! (`slots_rebuild`): survivors keep their `Progress` and round records, a new peer starts
//! probing at the conf entry, and no allocation happens after `init`.
//!
//! Cost sketch: an append decodes one entry (at most `conf_bytes_max` bytes); a rescan or
//! `configuration_at` walks at most `log_entries_max` entries; a rebuild is O(peers^2) over at
//! most `peers_max` slots of stack-free in-place copies.

/// Validates the `conf_change` entry `data` of a peer or of a restore: decode, then the `Config`
/// caps. Peer data is never asserted; the node is unchanged on error.
pub fn entry_check(
    config: *const Config,
    data: []const u8,
) (membership.ConfDecodeError || ConfError)!void {
    var ids: [membership.conf_ids_max]NodeId = undefined;
    const change = try membership.decode(data, &ids);
    const configuration = configuration_of(&change);
    if (configuration.voters.len > config.voters_max) return error.ConfVotersTooMany;
    if (configuration.voters_outgoing.len > config.voters_max) return error.ConfVotersTooMany;
    if (configuration.learners.len > config.learners_max) return error.ConfLearnersTooMany;
}

/// Checks every `conf_change` entry of an `append_entries` (receive time, before any mutation).
pub fn receive_check(
    config: *const Config,
    entries: []const Entry,
) (membership.ConfDecodeError || ConfError)!void {
    for (entries) |item| {
        if (item.kind == .conf_change) try entry_check(config, item.data);
    }
}

/// The configuration just appended at the log tail takes effect. A leader also rebuilds its peer
/// slots. Precondition: the last entry is a `conf_change` that passed `entry_check`.
pub fn on_append(node: *Node) void {
    assert(node.log.count > 0);
    const tail = &node.log.entries[node.log.count - 1];
    assert(tail.kind == .conf_change);
    assert(tail.index == node.log.last_index());

    var ids: [membership.conf_ids_max]NodeId = undefined;
    // `entry_check` ran at receive or restore, and the leader encodes its own entries.
    const change = membership.decode(tail.data, &ids) catch unreachable;
    node.configuration = node_init.members_copy(current_region(node), configuration_of(&change));
    node.configuration_index = tail.index;
    if (node.role == .leader) slots_rebuild(node);
    assert(node.configuration.voters.len > 0);
}

/// A truncate cut the log back: if it dropped the entry that set the configuration, fall back to
/// the last `conf_change` still in the log, else the configuration as of the log base.
/// Precondition: the node does not lead (a leader never truncates).
pub fn on_truncate(node: *Node, from: Index) void {
    assert(node.role != .leader);
    assert(node.log.last_index().order(from) == .lt);
    if (node.configuration_index.order(from) == .lt) return;
    rescan(node);
    assert(node.configuration_index.order(from) == .lt);
}

/// Sets the current configuration to the last `conf_change` in the log, else to
/// `base_configuration`. Precondition: the node does not lead.
pub fn rescan(node: *Node) void {
    assert(node.role != .leader);
    const found = last_conf_at(node, node.log.last_index());
    if (found) |at| {
        var ids: [membership.conf_ids_max]NodeId = undefined;
        const item = &node.log.entries[at];
        // Node-held entries were validated on receive or restore.
        const change = membership.decode(item.data, &ids) catch unreachable;
        node.configuration = node_init.members_copy(current_region(node), configuration_of(&change));
        node.configuration_index = item.index;
    } else {
        node.configuration = node_init.members_copy(current_region(node), &node.base_configuration);
        node.configuration_index = node.log.base.index;
    }
    assert(node.configuration.voters.len > 0);
}

/// The configuration in force as of `index`: the last `conf_change` at or below it, else the
/// configuration as of the base. Borrowed from the node's scratch region until the next call.
/// Preconditions: `base.index <= index <= last_index`.
pub fn configuration_at(node: *Node, index: Index) Configuration {
    assert(index.order(node.log.base.index) != .lt);
    assert(index.order(node.log.last_index()) != .gt);
    if (last_conf_at(node, index)) |at| {
        var ids: [membership.conf_ids_max]NodeId = undefined;
        // Node-held entries were validated on receive or restore.
        const change = membership.decode(node.log.entries[at].data, &ids) catch unreachable;
        return node_init.members_copy(scratch_region(node), configuration_of(&change));
    }
    return node_init.members_copy(scratch_region(node), &node.base_configuration);
}

/// The log is about to be compacted through `through`: the base configuration becomes the one
/// in force as of `through`. Call before `Log.compact`.
pub fn on_compact(node: *Node, through: Index) void {
    assert(through.order(node.log.base.index) != .lt);
    const as_of = configuration_at(node, through);
    node.base_configuration = node_init.members_copy(base_region(node), &as_of);
    assert(node.base_configuration.voters.len > 0);
}

/// Leader only: once the joint configuration's entry has committed, appends `leave_joint`. A full
/// log defers it to the next call (every leader tick). Emits `append` (persist phase), so call it
/// before any send of the step.
pub fn leave_if_due(node: *Node) void {
    assert(node.effects_len < node.effects.len);
    if (node.role != .leader) return;
    if (node.configuration.voters_outgoing.len == 0) return;
    if (node.configuration_index.order(node.commit_index) == .gt) return;

    var buffer: [membership.conf_bytes_max]u8 = undefined;
    const change = membership.leave_joint(&node.configuration);
    const used = membership.encode(&change, &buffer);
    const count_before = node.log.count;
    node_init.log_append(node, node.term, .conf_change, buffer[0..used]) catch |err| switch (err) {
        error.LogFull => return,
    };
    node.emit(.{ .append = node.log.entries[count_before..node.log.count] });
    assert(node.configuration.voters_outgoing.len == 0);
    assert(node.log.count == count_before + 1);
}

/// `Input.conf_change`: the leader appends `enter_joint(current, target)`. Refusals are typed and
/// leave the node unchanged. On success the effects are `append`, a possible `save_hard_state`
/// (a lone voter commits at once) and the sends.
pub fn step_conf_change(node: *Node, target: *const Configuration) ConfChangeError!void {
    if (node.role != .leader) return error.ConfChangeNotLeader;
    assert(node.leader == node.config.id);
    try target.validate();
    if (target.voters_outgoing.len != 0) return error.ConfJointShape;
    if (target.voters.len > node.config.voters_max) return error.ConfVotersTooMany;
    if (target.learners.len > node.config.learners_max) return error.ConfLearnersTooMany;
    if (node.configuration.voters_outgoing.len != 0) return error.ConfChangePending;
    if (node.configuration_index.order(node.commit_index) == .gt) return error.ConfChangePending;

    var buffer: [membership.conf_bytes_max]u8 = undefined;
    const change = membership.enter_joint(&node.configuration, target);
    if (membership.encoded_bytes(&change) > node.config.message_limits.entry_bytes_max) {
        return error.ConfChangeTooLarge;
    }
    const used = membership.encode(&change, &buffer);
    const count_before = node.log.count;
    node_init.log_append(node, node.term, .conf_change, buffer[0..used]) catch |err| switch (err) {
        error.LogFull => return error.ConfChangeLogFull,
    };
    node.effects_len = 0;
    node.emit(.{ .append = node.log.entries[count_before..node.log.count] });
    commit_module.advance_leader(node); // A lone voter commits at once, ahead of any send.
    leader_module.send_all(node);
    assert(node.configuration.voters_outgoing.len > 0);
    assert(node.effects_len >= 1);
}

/// End of a step, after `apply_ready`: a leader whose committed configuration no longer lists it
/// among the voters steps down (term kept, `leader_changed(.none)`).
pub fn step_end(node: *Node) void {
    assert(node.effects_len < node.effects.len);
    if (node.role != .leader) return;
    if (node.configuration.voters_outgoing.len != 0) return;
    if (election.contains(node.configuration.voters, node.config.id)) return;
    if (node.configuration_index.order(node.commit_index) == .gt) return;

    node.role = .follower;
    node.leader = .none;
    leader_module.reset(node);
    node.election_reset();
    node.emit(.{ .leader_changed = .none });
    assert(node.role == .follower);
    assert(node.progress_len == 0);
}

/// Whether this node votes in its own configuration. A non-voter never grants a vote or a
/// pre-vote and never campaigns.
pub fn self_is_voter(node: *const Node) bool {
    const sets = &node.configuration;
    return election.is_voter(sets.voters, sets.voters_outgoing, node.config.id);
}

/// Returns the first violated configuration invariant.
pub fn check_invariants(node: *const Node) InvariantError!void {
    node.configuration.validate() catch return error.InvariantConfigurationInvalid;
    node.base_configuration.validate() catch return error.InvariantConfigurationInvalid;
    if (node.configuration_index.order(node.log.last_index()) == .gt) {
        return error.InvariantConfigurationInvalid;
    }
    if (node.configuration_index.order(node.log.base.index) == .gt) {
        const item = node.log.entry_at(node.configuration_index);
        if (item.kind != .conf_change) return error.InvariantConfigurationInvalid;
    }
    assert(node.configuration.voters.len > 0);
}

/// Leader only: makes the peer slots match the configuration after it changed. Peers that left
/// are swap-removed, new ones are appended probing at the conf entry just appended.
fn slots_rebuild(node: *Node) void {
    assert(node.role == .leader);
    var at: u32 = node.progress_len;
    for (0..node.progress_len) |_| {
        if (at == 0) break;
        at -= 1;
        if (is_peer(node, node.peers[at])) continue;
        slot_remove(node, at);
    }
    for (node.configuration.voters) |peer| slot_ensure(node, peer);
    for (node.configuration.voters_outgoing) |peer| slot_ensure(node, peer);
    for (node.configuration.learners) |peer| slot_ensure(node, peer);
    assert(node.progress_len == leader_module.peers_count(node));
}

fn slot_ensure(node: *Node, peer: NodeId) void {
    if (peer == node.config.id) return;
    if (leader_module.slot_of(node, peer) != null) return;
    const slot = node.progress_len;
    assert(slot < node.progress.len);
    assert(node.log.last_index().order(node.log.base.index) == .gt); // The conf entry is in it.
    const before_entry: Index = @enumFromInt(@intFromEnum(node.log.last_index()) - 1);
    node.progress[slot] = Progress.init(before_entry, node.config.inflight_max);
    node.peers[slot] = peer;
    const base = leader_module.records_base(node, slot);
    @memset(node.rounds.records[base..][0..node.config.inflight_max], Round.empty);
    node.progress_len = slot + 1;
}

fn slot_remove(node: *Node, slot: u32) void {
    assert(slot < node.progress_len);
    const last = node.progress_len - 1;
    if (slot != last) {
        node.progress[slot] = node.progress[last];
        node.peers[slot] = node.peers[last];
        const to = leader_module.records_base(node, slot);
        const from = leader_module.records_base(node, last);
        const width = node.config.inflight_max;
        @memcpy(node.rounds.records[to..][0..width], node.rounds.records[from..][0..width]);
    }
    const stale = leader_module.records_base(node, last);
    @memset(node.rounds.records[stale..][0..node.config.inflight_max], Round.empty);
    node.peers[last] = .none;
    node.progress_len = last;
}

/// Whether `peer` is a voter (either set) or learner of the configuration, and not this node.
fn is_peer(node: *const Node, peer: NodeId) bool {
    if (peer == node.config.id) return false;
    const sets = &node.configuration;
    return election.contains(sets.voters, peer) or election.contains(sets.voters_outgoing, peer) or
        election.contains(sets.learners, peer);
}

/// The position in the log of the last `conf_change` entry at or below `index`, or null.
fn last_conf_at(node: *const Node, index: Index) ?u32 {
    const base = @intFromEnum(node.log.base.index);
    assert(@intFromEnum(index) >= base);
    var at: u32 = @intCast(@intFromEnum(index) - base);
    assert(at <= node.log.count);
    for (0..node.log.count) |_| {
        if (at == 0) return null;
        at -= 1;
        if (node.log.entries[at].kind == .conf_change) return at;
    }
    return null;
}

fn configuration_of(change: *const ConfChange) *const Configuration {
    return switch (change.*) {
        .enter_joint => |*configuration| configuration,
        .leave_joint => |*configuration| configuration,
    };
}

fn region_size(node: *const Node) usize {
    assert(node.members.len % 3 == 0);
    return node.members.len / 3;
}

fn current_region(node: *const Node) []NodeId {
    return node.members[0..region_size(node)];
}

fn base_region(node: *const Node) []NodeId {
    const size = region_size(node);
    return node.members[size .. 2 * size];
}

fn scratch_region(node: *const Node) []NodeId {
    const size = region_size(node);
    return node.members[2 * size .. 3 * size];
}

const std = @import("std");
const assert = std.debug.assert;
const commit_module = @import("commit.zig");
const election = @import("election.zig");
const leader_module = @import("leader.zig");
const membership = @import("membership.zig");
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const ConfChange = types.ConfChange;
const ConfChangeError = node_module.ConfChangeError;
const ConfError = types.ConfError;
const Config = node_module.Config;
const Configuration = types.Configuration;
const Entry = types.Entry;
const Index = types.Index;
const InvariantError = node_module.InvariantError;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Progress = @import("progress.zig").Progress;
const Round = leader_module.Round;
