//! synod.raft.election — the pure rules of a Raft election (Raft thesis §3.4, §5.4.1) as free
//! functions over plain values: the up-to-date comparison, the joint-shaped quorum, set
//! membership and the next term. `Node` owns every state change; this file owns the decisions.
//!
//! Invariants: every function is total over its documented domain, allocates nothing and reads
//! no state beyond its arguments, so the model-based election tests can state the same rules
//! independently and compare.
//!
//! Cost sketch: each function scans at most `2 * types.voters_max` ids twice; no I/O.

/// Whether a candidate whose log ends at (`theirs_index`, `theirs_term`) is at least as up to
/// date as a voter whose log ends at (`ours_index`, `ours_term`): the later last term wins, and
/// on equal last terms the longer (or equal) log wins (§5.4.1).
pub fn log_up_to_date(
    ours_index: Index,
    ours_term: Term,
    theirs_index: Index,
    theirs_term: Term,
) bool {
    assert((ours_index == .zero) == (ours_term == .zero));
    assert((theirs_index == .zero) == (theirs_term == .zero));

    switch (theirs_term.order(ours_term)) {
        .gt => return true,
        .lt => return false,
        .eq => return theirs_index.order(ours_index) != .lt,
    }
}

/// Whether `id` is in `ids`. `id` is a real node.
pub fn contains(ids: []const NodeId, id: NodeId) bool {
    assert(id != .none);
    assert(ids.len <= 2 * types.voters_max);
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

/// Whether `id` votes in either set of a joint configuration.
pub fn is_voter(voters: []const NodeId, voters_outgoing: []const NodeId, id: NodeId) bool {
    assert(id != .none);
    assert(voters.len + voters_outgoing.len <= 2 * types.voters_max);
    return contains(voters, id) or contains(voters_outgoing, id);
}

/// Thesis §9.6: whether a node grants a pre-vote. The asker's would-be term must exceed ours,
/// its log must be up to date, and we must neither lead nor have heard from a leader within
/// the election timeout (`leader_silent` is false in that case).
pub fn pre_vote_grantable(
    would_be: Term,
    term_own: Term,
    leads: bool,
    leader_silent: bool,
    log_ok: bool,
) bool {
    assert(would_be != .zero);
    if (would_be.order(term_own) != .gt) return false;
    const grant = !leads and leader_silent and log_ok;
    assert(!grant or !leads);
    return grant;
}

/// Strictly more than half of `size`: `size / 2 + 1`. A voter set is never empty.
pub fn majority(size: u32) u32 {
    assert(size > 0);
    assert(size <= types.voters_max);
    const result = @divFloor(size, 2) + 1;
    assert(result <= size);
    return result;
}

/// Whether `granted` (distinct voter ids; ids outside the sets are ignored) carries a majority of
/// `voters` and, when `voters_outgoing` is non-empty (joint configuration), also a majority of
/// `voters_outgoing`. A voter in both sets counts in both.
pub fn quorum_reached(
    voters: []const NodeId,
    voters_outgoing: []const NodeId,
    granted: []const NodeId,
) bool {
    assert(voters.len > 0);
    assert(granted.len <= 2 * types.voters_max);

    if (granted_count(voters, granted) < majority(@intCast(voters.len))) return false;
    if (voters_outgoing.len == 0) return true;
    return granted_count(voters_outgoing, granted) >= majority(@intCast(voters_outgoing.len));
}

/// How many ids of `set` appear in `granted`.
fn granted_count(set: []const NodeId, granted: []const NodeId) u32 {
    assert(set.len <= types.voters_max);
    assert(granted.len <= 2 * types.voters_max);
    var total: u32 = 0;
    for (set) |id| total += @intFromBool(contains(granted, id));
    assert(total <= set.len);
    return total;
}

/// The term after `current`. Precondition: `current` is below the largest term.
pub fn term_next(current: Term) Term {
    assert(@intFromEnum(current) < std.math.maxInt(u64));
    const result: Term = @enumFromInt(@intFromEnum(current) + 1);
    assert(result.order(current) == .gt);
    return result;
}

const std = @import("std");
const assert = std.debug.assert;
const types = @import("../types.zig");

const Index = types.Index;
const NodeId = types.NodeId;
const Term = types.Term;
