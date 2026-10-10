//! synod.raft.node_init — the free functions `Node.init` is built from: `Config` assertions,
//! the `Restore` data check, the sizes of the node's preallocated arrays, the election-timeout
//! draw, the membership copy, membership tests, and the entry-byte-arena `log_append`. Split
//! from `node.zig` to keep both files readable.
//!
//! Invariants: nothing here allocates or keeps state; every size is a pure function of `Config`
//! (a caller bug in `Config` is asserted), and `restore_validate` returns a typed error for bad
//! data (never asserts on it), so a failed `init` leaves nothing allocated.
//!
//! Cost sketch: `restore_validate` is one pass over the restored entries; the rest is O(1) or
//! one `memcpy` of at most `2 * voters_max + learners_max` ids.

/// Effect slots beyond one per peer: truncate, append, save_hard_state, apply, leader_changed.
/// The winning step needs `save_hard_state`, `append`, one `send` per peer and `leader_changed`:
/// `peers_max + 3`.
pub const effects_fixed_count: u32 = 5;

/// Asserts the `Config` contract of ADR-007: a caller's bug, never a returned error.
pub fn assert_config(config: *const Config) void {
    assert(config.id != .none);
    assert(config.protocol_version >= types.protocol_version_min);
    assert(config.protocol_version <= types.protocol_version_current);
    assert(config.heartbeat_ticks >= 1);
    assert(config.heartbeat_ticks < config.election_ticks);
    assert(config.voters_max >= 1);
    assert(config.voters_max <= types.voters_max);
    assert(config.learners_max <= types.learners_max);
    assert(config.inflight_max > 0);
    assert(config.log_entries_max > 0);
}

/// `peers_max = 2 * voters_max + learners_max - 1`: joint-sized so Phase 4 changes no size.
pub fn effects_capacity(config: *const Config) u32 {
    const peers_max = 2 * config.voters_max + config.learners_max - 1;
    assert(peers_max >= 1);
    const result = peers_max + effects_fixed_count;
    assert(result >= peers_max + 3); // The winning step: hard state, append, sends, leader_changed.
    return result;
}

/// `Progress` slots: one per distinct voter of a joint configuration, `2 * voters_max`.
pub fn progress_capacity(config: *const Config) u32 {
    const result = 2 * config.voters_max;
    assert(result >= 2);
    return result;
}

/// Round records: `inflight_max` per progress slot (the window is the bound on live rounds).
pub fn rounds_capacity(config: *const Config) usize {
    const result = @as(usize, progress_capacity(config)) * config.inflight_max;
    assert(config.inflight_max > 0);
    assert(result >= progress_capacity(config));
    return result;
}

/// Distinct voters over both sets of a joint configuration.
pub fn votes_capacity(config: *const Config) u32 {
    const result = 2 * config.voters_max;
    assert(result >= 2);
    return result;
}

pub fn members_capacity(config: *const Config) u32 {
    const result = 2 * config.voters_max + config.learners_max;
    assert(result >= 2);
    return result;
}

/// `t + rng.uint_less_than(t)`: exactly one draw, a value in `[t, 2t)`.
pub fn election_timeout_draw(rng: Rng, election_ticks: u32) u32 {
    assert(election_ticks > 0);
    const drawn: u32 = @intCast(rng.uint_less_than(election_ticks));
    assert(drawn < election_ticks);
    return election_ticks + drawn;
}

/// Pure data check of `Restore`; allocates nothing. `RestoreLogFull` is decided at copy time.
pub fn restore_validate(config: *const Config, restore: *const Restore) InitError!void {
    const configuration = &restore.configuration;
    try configuration.validate();
    if (configuration.voters.len > config.voters_max) return error.ConfVotersTooMany;
    if (configuration.voters_outgoing.len > config.voters_max) return error.ConfVotersTooMany;
    if (configuration.learners.len > config.learners_max) return error.ConfLearnersTooMany;

    const hard_state = &restore.hard_state;
    if (hard_state.vote != .none and hard_state.term == .zero) return error.RestoreInconsistent;
    var previous_term: Term = .zero;
    for (restore.entries, 0..) |entry, i| {
        if (@intFromEnum(entry.index) != i + 1) return error.RestoreInconsistent;
        if (entry.term == .zero) return error.RestoreInconsistent;
        if (entry.term.order(previous_term) == .lt) return error.RestoreInconsistent;
        if (entry.term.order(hard_state.term) == .gt) return error.RestoreInconsistent;
        previous_term = entry.term;
    }
    if (@intFromEnum(hard_state.commit_index) > restore.entries.len) {
        return error.RestoreInconsistent;
    }
    assert(@intFromEnum(hard_state.commit_index) <= restore.entries.len);
    assert(previous_term.order(hard_state.term) != .gt);
}

/// Copies `source` into `members` (voters, then outgoing voters, then learners) and returns the
/// view over the copy. Precondition: `members` holds `2 * voters_max + learners_max` ids and
/// `source` fits the `Config` caps (checked by `restore_validate`).
pub fn members_copy(members: []NodeId, source: *const Configuration) Configuration {
    const voters_end = source.voters.len;
    const outgoing_end = voters_end + source.voters_outgoing.len;
    const learners_end = outgoing_end + source.learners.len;
    assert(learners_end <= members.len);
    assert(voters_end > 0);

    @memcpy(members[0..voters_end], source.voters);
    @memcpy(members[voters_end..outgoing_end], source.voters_outgoing);
    @memcpy(members[outgoing_end..learners_end], source.learners);
    return .{
        .voters = members[0..voters_end],
        .voters_outgoing = members[voters_end..outgoing_end],
        .learners = members[outgoing_end..learners_end],
    };
}

/// Whether `id` votes in either set of the node's configuration; a learner does not.
pub fn is_voter(node: *const Node, id: NodeId) bool {
    assert(id != .none);
    assert(id != node.config.id);
    const sets = &node.configuration;
    return election.is_voter(sets.voters, sets.voters_outgoing, id);
}

/// Whether `id` is in any set of the node's configuration, learners included.
pub fn is_member(node: *const Node, id: NodeId) bool {
    assert(id != .none);
    assert(id != node.config.id);
    const sets = &node.configuration;
    for (sets.voters) |voter| if (voter == id) return true;
    for (sets.voters_outgoing) |voter| if (voter == id) return true;
    for (sets.learners) |learner| if (learner == id) return true;
    return false;
}

/// Copies the restored log into the node's (empty) log and entry-byte arena. Returns
/// `error.RestoreLogFull` when `Config` leaves too few slots or bytes for it.
pub fn restore_entries(node: *Node, restore: *const Restore) error{RestoreLogFull}!void {
    assert(node.log.count == 0);
    assert(node.bytes_used == 0);
    for (restore.entries) |entry| {
        log_append(node, entry.term, entry.kind, entry.data) catch |err| switch (err) {
            error.LogFull => return error.RestoreLogFull,
        };
    }
    assert(node.log.count == restore.entries.len);
}

/// Appends an entry at `last_index + 1`, copying `data` into the entry-byte arena. Returns
/// `error.LogFull` (node unchanged) when no slot or too few bytes remain.
pub fn log_append(
    node: *Node,
    entry_term: Term,
    kind: EntryKind,
    data: []const u8,
) error{LogFull}!void {
    assert(entry_term != .zero);
    assert(node.bytes_used <= node.bytes.len);

    const used: usize = node.bytes_used;
    if (data.len > node.bytes.len - used) return error.LogFull;
    const stored = node.bytes[used..][0..data.len];
    @memcpy(stored, data);
    try node.log.append(.{
        .index = node.log.last_index().next(),
        .term = entry_term,
        .kind = kind,
        .data = stored,
    });
    node.bytes_used += @intCast(data.len);
    assert(node.bytes_used <= node.bytes.len);
    assert(node.log.entries[node.log.count - 1].data.ptr == stored.ptr);
}

pub fn check_invariants_indices(node: *const Node) InvariantError!void {
    const last_index = node.log.last_index();
    if (node.commit_index.order(last_index) == .gt) return error.InvariantCommitBeyondLog;
    if (node.applied_index.order(node.commit_index) == .gt) {
        return error.InvariantAppliedBeyondCommit;
    }
    if (node.term.order(node.log.term_at(last_index)) == .lt) {
        return error.InvariantTermBehindLog;
    }
    assert(node.commit_index.order(last_index) != .gt);
    assert(node.applied_index.order(last_index) != .gt);
}

pub fn check_invariants_election(node: *const Node) InvariantError!void {
    if (node.vote != .none and node.term == .zero) return error.InvariantVoteWithoutTerm;
    const leads = node.role == .leader;
    if (leads != (node.leader == node.config.id)) return error.InvariantLeaderRole;
    if (node.role == .pre_candidate and node.leader != .none) return error.InvariantLeaderRole;
    const ticks: u64 = node.config.election_ticks;
    if (node.election_timeout < ticks) return error.InvariantElectionTimeout;
    if (node.election_timeout >= 2 * ticks) return error.InvariantElectionTimeout;
    assert(leads == (node.leader == node.config.id));
    assert(node.election_timeout >= node.config.election_ticks);
}

pub fn check_invariants_bytes(node: *const Node) InvariantError!void {
    if (node.bytes_used > node.bytes.len) return error.InvariantEntryDataMisplaced;
    var offset: usize = 0;
    for (node.log.entries[0..node.log.count]) |entry| {
        if (entry.data.ptr != node.bytes.ptr + offset) {
            return error.InvariantEntryDataMisplaced;
        }
        offset += entry.data.len;
    }
    if (offset != node.bytes_used) return error.InvariantEntryDataMisplaced;
    assert(offset <= node.bytes.len);
    assert(offset == node.bytes_used);
}

const std = @import("std");
const assert = std.debug.assert;
const election = @import("election.zig");
const interfaces = @import("../interfaces.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Configuration = types.Configuration;
const EntryKind = types.EntryKind;
const InitError = node_module.InitError;
const InvariantError = node_module.InvariantError;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rng = interfaces.Rng;
const Term = types.Term;
