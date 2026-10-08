//! synod.raft.node_init — the free functions `Node.init` is built from: `Config` assertions,
//! the `Restore` data check, the sizes of the node's preallocated arrays, the election-timeout
//! draw, and the membership copy. Split from `node.zig` to keep both files readable.
//!
//! Invariants: nothing here allocates or keeps state; every size is a pure function of `Config`
//! (a caller bug in `Config` is asserted), and `restore_validate` returns a typed error for bad
//! data (never asserts on it), so a failed `init` leaves nothing allocated.
//!
//! Cost sketch: `restore_validate` is one pass over the restored entries; the rest is O(1) or
//! one `memcpy` of at most `2 * voters_max + learners_max` ids.

/// Effect slots beyond one per peer: truncate, append, save_hard_state, apply, leader_changed.
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
    return peers_max + effects_fixed_count;
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

const std = @import("std");
const assert = std.debug.assert;
const interfaces = @import("../interfaces.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Configuration = types.Configuration;
const InitError = node_module.InitError;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rng = interfaces.Rng;
const Term = types.Term;
