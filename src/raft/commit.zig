//! synod.raft.commit — commit advancement and apply (Raft §5.3, §5.4.2; plan 003 item 2B-iii),
//! as free functions over a `*Node`. `Node` owns the state (`commit_index`, `applied_index`); this
//! file owns the rules.
//!
//! Leader (`advance_leader`): the commit index moves to the highest index `N` that a quorum of
//! every voter set holds (the leader counts as matching its whole log, a peer by its
//! `Progress.match`; a joint configuration needs a majority in both sets, so `N` is the lower of
//! the two sets' quorum indexes; learners are in neither set and never count) and whose entry
//! carries the leader's current term. The term rule is the Figure 8 guard: an older-term entry
//! is never committed by counting replicas, only indirectly, beneath a current-term entry.
//! Because log terms never decrease with the index, testing the quorum index alone is enough:
//! if its term is below ours, so is every lower index.
//!
//! Follower (`advance_follower`): after an accepted append, `commit = max(commit, min(
//! leader_commit, last new entry))`, where the last new entry is `prev_log_index + entries.len`,
//! never the length of the log: a stale suffix beyond the verified prefix is not the leader's.
//!
//! Apply (`apply_ready`): one `apply` effect for the entries `(applied_index, commit_index]`, in
//! index order, each exactly once, then `applied_index = commit_index`. It runs once at the end
//! of every `step`, so a restored node replays `(0, commit_index]` on its first step, whatever
//! that step is. The effect is inserted ahead of the trailing `leader_changed` effects (apply
//! phase before notify phase) and after every send.
//!
//! Persistence: a commit advance emits `save_hard_state` through `Node.emit_hard_state`, in the
//! persist phase, so it precedes every send of the step that follows from the new commit.
//!
//! Invariants: `commit_index` never decreases and never exceeds the log; `applied_index` never
//! exceeds `commit_index`. Peer data never reaches an assertion: the leader reads only its own
//! `Progress`, and the follower clamps `leader_commit` to the entries it verified.
//!
//! Allocation: none (a stack array of at most `types.voters_max` indexes). Cost sketch: a leader
//! advance gathers and sorts at most `voters_max` indexes per voter set; apply is O(1) plus a
//! shift of at most the six effects of a step; the entries are a slice of the node's log.

/// The leader's commit rule. Preconditions (asserted): the node leads and its per-peer progress
/// is built (`leader.start` ran). Emits `save_hard_state` when the commit index moves, which is
/// before any send of the step: call it before `leader.send_slot`/`send_all`. It runs only on a
/// win, a propose, and an accepted response; a membership change (Phase 4) must call it too.
pub fn advance_leader(node: *Node) void {
    assert(node.role == .leader);
    assert(node.progress_len <= node.progress.len);
    const sets = &node.configuration;
    const commit_before = @intFromEnum(node.commit_index);
    const last = @intFromEnum(node.log.last_index());
    assert(commit_before <= last);

    var quorum = quorum_index(node, sets.voters);
    if (sets.voters_outgoing.len > 0) {
        quorum = @min(quorum, quorum_index(node, sets.voters_outgoing));
    }
    assert(quorum <= last); // No peer matches beyond the leader's log.
    if (quorum <= commit_before) return;
    assert(node.log.base.index.order(node.commit_index) != .gt); // Base <= snapshot <= applied.
    const quorum_term = node.log.term_at(@enumFromInt(quorum)) catch |err| switch (err) {
        // `quorum > commit_before >= log.base.index`: the base never passes the applied index,
        // which never passes the commit index, so `quorum` is above the base.
        error.LogCompacted => unreachable,
    };
    if (quorum_term != node.term) return; // Figure 8.

    node.commit_index = @enumFromInt(quorum);
    node.emit_hard_state();
    assert(@intFromEnum(node.commit_index) > commit_before);
    assert(@intFromEnum(node.commit_index) <= last);
}

/// The follower's commit rule after an accepted append: `last_new` is `prev_log_index +
/// entries.len`. Emits `save_hard_state` when the commit index moves. Preconditions (asserted):
/// the node follows and `last_new` is inside the log. `leader_commit` is peer data: any value.
pub fn advance_follower(node: *Node, leader_commit: Index, last_new: u64) void {
    assert(node.role == .follower);
    const last = @intFromEnum(node.log.last_index());
    assert(last_new <= last);
    const commit_before = @intFromEnum(node.commit_index);
    assert(commit_before <= last);

    const target = @min(@intFromEnum(leader_commit), last_new);
    if (target <= commit_before) return;

    node.commit_index = @enumFromInt(target);
    node.emit_hard_state();
    assert(@intFromEnum(node.commit_index) > commit_before);
    assert(@intFromEnum(node.commit_index) <= last);
}

/// Emits one `apply` for `(applied_index, commit_index]` and marks it applied; emits nothing
/// when they are equal. Called once at the end of every successful `step`. The effect goes after
/// everything but the trailing `leader_changed` effects. Precondition (asserted): applied is
/// within commit, commit within the log, and a free effect slot exists when there is work.
pub fn apply_ready(node: *Node) void {
    const applied = @intFromEnum(node.applied_index);
    const commit = @intFromEnum(node.commit_index);
    assert(applied <= commit);
    assert(commit <= @intFromEnum(node.log.last_index()));
    if (applied == commit) return;

    assert(node.effects_len < node.effects.len);
    var at: u32 = node.effects_len;
    for (0..notify_max) |_| {
        if (at == 0 or node.effects[at - 1].phase() != .notify) break;
        at -= 1;
    }
    assert(at == 0 or node.effects[at - 1].phase() != .notify);
    assert(node.effects_len - at <= notify_max);

    const last = node.effects_len;
    @memmove(node.effects[at + 1 .. last + 1], node.effects[at..last]);
    node.effects[at] = .{ .apply = node.log.range(node.applied_index, node.commit_index) };
    node.effects_len = last + 1;
    node.applied_index = node.commit_index;
    assert(node.effects[at].phase() == .apply);
    assert(node.applied_index == node.commit_index);
}

/// The most `leader_changed` effects a step emits: the deposed one and the new one.
const notify_max: u32 = 2;

/// The highest index that a majority of `set` (non-empty, within `voters_max`) matches: the
/// leader matches its whole log, a peer its `Progress.match`, a voter without progress nothing.
fn quorum_index(node: *const Node, set: []const NodeId) u64 {
    assert(set.len > 0);
    assert(set.len <= types.voters_max);
    var matches: [types.voters_max]u64 = undefined;
    for (set, 0..) |voter, i| matches[i] = match_of(node, voter);

    const sorted = matches[0..set.len];
    std.mem.sort(u64, sorted, {}, std.sort.desc(u64));
    const result = sorted[election.majority(@intCast(set.len)) - 1];
    assert(result <= sorted[0]);
    return result;
}

fn match_of(node: *const Node, voter: NodeId) u64 {
    assert(voter != .none);
    assert(node.role == .leader);
    if (voter == node.config.id) return @intFromEnum(node.log.last_index());
    // Every voter of either set other than self got a `Progress` in `leader.start`, and
    // `slot_of` searches that same set, so a miss is a broken invariant, not an input.
    const slot = leader_module.slot_of(node, voter) orelse unreachable;
    assert(slot < node.progress_len);
    return @intFromEnum(node.progress[slot].match);
}

const std = @import("std");
const assert = std.debug.assert;
const election = @import("election.zig");
const leader_module = @import("leader.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Index = types.Index;
const Node = node_module.Node;
const NodeId = types.NodeId;
