//! synod.raft.follower — the follower side of log replication (Raft thesis §3.5, §5.3; plan 003
//! item 2B-ii), as free functions over a `*Node`: the term and leader rules for an
//! `append_entries`, the consistency check on `prev_log_index`/`prev_log_term`, the walk over the
//! batch (matching entries skipped, the first conflicting one cuts the suffix) and the reply.
//! `Node` owns the state; this file owns the rules. `leader_commit` is ignored here: commit
//! advancement and apply are item 2B-iii.
//!
//! Rules, in order. A non-member is ignored at any term. A member at a stale term is refused with
//! `rejected{0, 0}` at our term (the old leader learns the term and steps down); a member at a
//! higher term makes us a follower of that term (one `save_hard_state`). Only a voter may claim
//! leadership, and the first claim of a term stands: a leader, or a node that already follows
//! another leader of this term, drops the request in silence. An accepted claim yields a
//! candidate, restarts the election timer and runs the log check: a mismatch at `prev` replies
//! `rejected(conflict_at)` (fast backtrack, echoing the round), a match replies
//! `accepted(prev + entries.len)`.
//!
//! The walk: entry `i` of the batch is index `prev + 1 + i`. Entries equal to ours (same term at
//! the same index, so by log matching the same entry) are skipped; a replay or a reordered older
//! request therefore never shortens the log. At the first entry whose term differs, the suffix
//! from that index is truncated and the rest of the batch is appended, its bytes copied into the
//! node's arena (the request is borrowed until `step` returns). Effects leave in ADR-007 phase
//! order: `save_hard_state`, `truncate`, one `append`, then the reply, then `leader_changed`.
//!
//! Never below `commit_index`: a conflict at or below it contradicts Raft's safety argument, so
//! only a faulty or hostile peer can send it. It is peer data, not a caller bug, hence no
//! assertion: the request is dropped, with no mutation and no reply. The leader's round then
//! times out and probes again.
//!
//! Deviation from ADR-007 ("a full follower stores the prefix that fits and acks its true
//! match"): a request that would overflow the log slots or the byte arena, after the truncate it
//! implies, is dropped whole, with no truncate, no append and no reply. Reason: the leader's
//! round record (`leader.zig` `step_response`) takes any `prev <= matched <= last_sent` as
//! progress and, if `next` is still inside its log, resends the rest at once. A full follower
//! that acked its prefix would therefore be answered with the same unstorable tail on every
//! response, a loop paced only by the network, and a conflicting suffix could be cut for a
//! replacement that is then stored only in part. Dropping whole keeps the write atomic and lets
//! the leader's round timeout pace the retry. ADR-007 is amended to match.
//!
//! Invariants: after any call the log is contiguous from index 1, entry bytes are packed in
//! index order (`bytes_used` is exact), `commit_index` is unchanged, and `leader_changed` is the
//! last effect. Allocation: none; the effect array has room for the six effects of the worst
//! case (hard state, truncate, append, reply, `leader_changed(none)`, `leader_changed(id)`).
//! Cost sketch: O(batch) to compare terms, O(batch + cut suffix) bytes counted for the capacity
//! check, one `memcpy` per appended entry; `conflict_at` scans at most one term run backwards.

/// Handles one `append_entries` that passed `Message.validate` (entries contiguous from
/// `prev_log_index + 1`, terms non-decreasing). Preconditions: `effects_len == 0`, `member` is
/// whether the sender is in the configuration. Postconditions: described in the file header.
pub fn step_append(node: *Node, request: *const AppendRequest, member: bool) void {
    const head = &request.header;
    assert(head.from != node.config.id);
    assert(node.effects_len == 0);
    if (!member) return;

    const commit_before = node.commit_index;
    const leader_before = node.leader;
    const order = head.term.order(node.term);
    if (order == .lt) {
        const nothing: types.Conflict = .{ .index = .zero, .term = .zero };
        return reply(node, request, .{ .rejected = nothing });
    }

    const bumped = order == .gt;
    if (bumped) {
        _ = node.term_adopt(head.term);
        node.emit_hard_state();
    }
    if (claim_leader(node, head.from)) replicate(node, request);
    notify_leader(node, leader_before, bumped);

    assert(node.term == head.term);
    assert(node.role != .leader or !bumped); // A bump made us a follower first.
    assert(node.commit_index == commit_before); // Commit advances in item 2B-iii, not here.
    var seen_notify = false;
    for (node.effects[0..node.effects_len]) |effect| {
        // `leader_changed` is the notify phase: nothing may follow it but its own kind.
        if (seen_notify) assert(effect == .leader_changed);
        seen_notify = seen_notify or effect == .leader_changed;
    }
}

/// The sender is the leader of our term if it is a voter, we do not lead, and no other leader
/// was named this term. Then we follow it with a fresh timer. Returns whether the claim stands.
fn claim_leader(node: *Node, from: NodeId) bool {
    assert(from != node.config.id);
    assert(node.effects_len <= node.effects.len);
    if (!node_init.is_voter(node, from)) return false;
    if (node.role == .leader) return false;
    if (node.leader != .none and node.leader != from) return false;

    node.role = .follower;
    node.leader = from;
    node.election_reset();
    assert(node.role == .follower);
    assert(node.leader == from);
    return true;
}

/// Emits the `leader_changed` effects of the step, last. Adopting a higher term forgot the
/// leader we knew (`leader_changed(.none)`); a claim then names the new one.
fn notify_leader(node: *Node, leader_before: NodeId, bumped: bool) void {
    assert(node.effects_len <= node.effects.len - 2);
    assert(!bumped or node.role != .leader);
    const known = if (bumped) NodeId.none else leader_before;
    if (bumped and leader_before != .none) node.emit(.{ .leader_changed = .none });
    if (node.leader != known) node.emit(.{ .leader_changed = node.leader });
    assert(node.effects_len <= node.effects.len);
}

/// Where the batch lands: entries from `first` on are appended after the log is cut to `keep`
/// entries (`keep == log.count` means no cut).
const Plan = struct {
    first: usize,
    keep: u32,
};

/// The consistency check, the walk and the reply for the leader of our term.
fn replicate(node: *Node, request: *const AppendRequest) void {
    assert(node.role == .follower);
    assert(node.leader == request.header.from);
    if (node.log.conflict_at(request.prev_log_index, request.prev_log_term)) |conflict| {
        return reply(node, request, .{ .rejected = conflict });
    }

    const plan = plan_walk(node, request) orelse return;
    if (plan.keep < node.log.count) cut_log(node, plan.keep);
    append_rest(node, request.entries[plan.first..]);
    const matched = @intFromEnum(request.prev_log_index) + request.entries.len;
    reply(node, request, .{ .accepted = @enumFromInt(matched) });
}

/// Walks the batch against our log. Returns null (drop the request, mutate nothing) when the
/// first conflict is at or below `commit_index`, or when the result would not fit.
/// Precondition: `prev_log_index <= last_index` and the term there matched.
fn plan_walk(node: *const Node, request: *const AppendRequest) ?Plan {
    const prev: u64 = @intFromEnum(request.prev_log_index);
    const count: u32 = node.log.count;
    assert(prev <= count);

    var plan: Plan = .{ .first = request.entries.len, .keep = count };
    for (request.entries, 0..) |item, i| {
        const index = prev + 1 + i;
        assert(@intFromEnum(item.index) == index); // `Message.validate` checked contiguity.
        if (index > count) {
            plan = .{ .first = i, .keep = count };
            break;
        }
        if (node.log.entries[@intCast(index - 1)].term == item.term) continue;
        if (index <= @intFromEnum(node.commit_index)) return null;
        plan = .{ .first = i, .keep = @intCast(index - 1) };
        break;
    }
    assert(plan.first <= request.entries.len);
    assert(plan.keep >= @intFromEnum(node.commit_index));
    if (!fits(node, plan, request.entries)) return null;
    return plan;
}

/// Whether the log, cut to `plan.keep` entries, holds `entries[plan.first..]` in both slots and
/// arena bytes.
fn fits(node: *const Node, plan: Plan, entries: []const Entry) bool {
    assert(plan.keep <= node.log.count);
    assert(plan.first <= entries.len);
    const slots = @as(u64, plan.keep) + (entries.len - plan.first);
    if (slots > node.log.entries.len) return false;

    const freed = bytes_of(node.log.entries[plan.keep..node.log.count]);
    const added = bytes_of(entries[plan.first..]);
    assert(freed <= node.bytes_used);
    return node.bytes_used - freed + added <= node.bytes.len;
}

fn bytes_of(entries: []const Entry) u64 {
    var total: u64 = 0;
    for (entries) |item| total += item.data.len;
    assert(entries.len > 0 or total == 0);
    return total;
}

/// Truncates the log to `keep` entries, freeing their bytes, and emits `truncate`.
/// Precondition: `keep < log.count`.
fn cut_log(node: *Node, keep: u32) void {
    assert(keep < node.log.count);
    assert(keep >= @intFromEnum(node.commit_index));
    const freed = bytes_of(node.log.entries[keep..node.log.count]);
    const from: Index = @enumFromInt(@as(u64, keep) + 1);
    node.log.truncate(from);
    node.bytes_used -= @intCast(freed);
    node.emit(.{ .truncate = from });
    assert(node.log.count == keep);
    assert(node.bytes_used <= node.bytes.len);
}

/// Copies `rest` onto the log tail and emits one `append` for it, if non-empty. Precondition:
/// `fits` held for it, so no `LogFull` can occur.
fn append_rest(node: *Node, rest: []const Entry) void {
    assert(rest.len == 0 or rest[0].index == node.log.last_index().next());
    const before = node.log.count;
    for (rest) |item| {
        node_init.log_append(node, item.term, item.kind, item.data) catch |err| switch (err) {
            // `fits` counted the slots and bytes of exactly these entries after the cut.
            error.LogFull => unreachable,
        };
    }
    if (rest.len > 0) node.emit(.{ .append = node.log.entries[before..node.log.count] });
    assert(node.log.count == before + rest.len);
}

/// Sends the response to `request` at our term, echoing its round.
fn reply(node: *Node, request: *const AppendRequest, outcome: types.AppendOutcome) void {
    assert(request.header.from != node.config.id);
    assert(node.effects_len < node.effects.len);
    node.emit(.{ .send = .{ .append_entries_response = .{
        .header = node.header_to(request.header.from),
        .round = request.round,
        .outcome = outcome,
    } } });
    assert(node.effects[node.effects_len - 1] == .send);
}

const std = @import("std");
const assert = std.debug.assert;
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const AppendRequest = types.AppendRequest;
const Entry = types.Entry;
const Index = types.Index;
const Node = node_module.Node;
const NodeId = types.NodeId;
