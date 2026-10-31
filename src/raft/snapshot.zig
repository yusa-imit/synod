//! synod.raft.snapshot — the compaction policy of the node (ADR-009 "Who snapshots"; plan 005
//! item 3), as free functions over a `*Node`. `Node` owns the state (`snapshot_index`,
//! `snapshot_pending`, the log); this file owns the rules.
//!
//! Due (`emit_due`): at the end of every step, if no due is pending and `applied_index -
//! log.base.index >= snapshot_entries_min`, the node emits one `snapshot_due` naming `applied`,
//! the term of that entry and its configuration, last in the step's effects (snapshot phase).
//! At most one is pending: the next waits for `Input.snapshot_saved`.
//!
//! Saved (`saved`): the driver saved and synced the snapshot at the pending index. The node
//! records `snapshot_index`, compacts the log through `max(base, index -| snapshot_trailing)`
//! and re-packs the entry-byte arena once so the live entries start at offset zero again. It
//! emits nothing, and `Node.step` skips `emit_due` for that step (the driver asserts the
//! `Effects` of a save empty, ADR-009), so a due owed by then waits for the next step. Any other
//! index, or none pending, is `SnapshotUnexpected` with no mutation.
//!
//! Install (`step_install`, plan 005 item 5, ADR-009 "InstallSnapshot"): the follower side of an
//! `install_snapshot`. Order: a configuration over the `Config` caps is a `Conf*` error before
//! any change; a non-member is ignored; a stale term is refused with `match_index = 0`; a higher
//! term is adopted and the sender claims leadership as for `append_entries`. A snapshot at or
//! below `commit_index` is acked and changes nothing. Else the node copies the configuration,
//! emits `save_snapshot`, moves `snapshot_index`, `applied_index` and `commit_index` to the
//! snapshot, keeps the log suffix above it iff the log holds `(index, term)` (else `reset`s the
//! log to the snapshot), then one `save_hard_state`, the reply, and `restore(index)`. A pending
//! `snapshot_due` is forgotten (a later `snapshot_saved` for it is `SnapshotUnexpected`).
//!
//! Send (`send`): the leader side, called by `leader.zig` for a probing peer whose `next - 1` is
//! below the log base: one `send_snapshot` for the node's `snapshot_index` and one `Round`
//! record, so the install times out like any round.
//!
//! Invariants: `log.base.index <= snapshot_index <= applied_index`; the arena stays packed in
//! index order (`check_invariants_bytes`); compaction never grows `bytes_used` or the log.
//! Allocation: none. Cost sketch: one `copyForwards` of the kept bytes and one pass over the
//! kept entries per save; `emit_due` is O(1).

/// Emits `snapshot_due` when one is owed. Called once at the end of every successful `step`,
/// after `apply_ready`, so it is the last effect. Preconditions (asserted): applied is within
/// the log and a free effect slot exists (`effects_fixed_count` reserves it).
pub fn emit_due(node: *Node) void {
    assert(node.applied_index.order(node.log.last_index()) != .gt);
    assert(node.effects_len < node.effects.len);
    if (node.snapshot_pending != .zero) return;
    if (node.config.snapshot_entries_min == 0) return; // Compaction off (see `Config`).

    const base = @intFromEnum(node.log.base.index);
    const applied = @intFromEnum(node.applied_index);
    if (applied -| base < node.config.snapshot_entries_min) return;

    assert(applied > base); // `snapshot_entries_min >= 1`.
    const entry_term = node.log.term_at(node.applied_index) catch |err| switch (err) {
        // `base < applied` (asserted above), so the index is not below the base.
        error.LogCompacted => unreachable,
    };
    node.snapshot_pending = node.applied_index;
    node.emit(.{ .snapshot_due = .{
        .snapshot = .{ .index = node.applied_index, .term = entry_term },
        .configuration = node.configuration,
    } });
    assert(node.effects[node.effects_len - 1].phase() == .snapshot);
    assert(node.snapshot_pending == node.applied_index);
}

/// Handles `Input.snapshot_saved(index)`: `index` must be the pending due. Emits nothing.
/// Returns `error.SnapshotUnexpected`, mutating nothing, when none is pending or `index`
/// differs: the driver's confirmation is caller data to be checked, not asserted.
pub fn saved(node: *Node, index: Index) error{SnapshotUnexpected}!void {
    assert(node.snapshot_index.order(node.applied_index) != .gt);
    assert(node.log.base.index.order(node.snapshot_index) != .gt);
    if (node.snapshot_pending == .zero) return error.SnapshotUnexpected;
    if (node.snapshot_pending != index) return error.SnapshotUnexpected;

    assert(index.order(node.applied_index) != .gt); // It was applied when it was named.
    assert(index.order(node.snapshot_index) == .gt);
    assert(index.order(node.log.base.index) == .gt); // `snapshot_index >= base`, and it grows.
    node.effects_len = 0;
    node.snapshot_pending = .zero;
    node.snapshot_index = index;
    const keep_from = @intFromEnum(index) -| node.config.snapshot_trailing;
    const through = @max(@intFromEnum(node.log.base.index), keep_from);
    compact(node, @enumFromInt(through));
    assert(node.log.base.index.order(node.snapshot_index) != .gt);
    assert(node.effects_len == 0); // ADR-009: the driver asserts this step's Effects empty.
}

/// Sends the peer in progress `slot` an `install_snapshot` for the node's last snapshot, and
/// records the round. Preconditions: the node leads, the peer is probing with nothing in flight,
/// and its `next - 1` is below `log.base.index` (so `snapshot_index >= base > match`).
pub fn send(node: *Node, slot: u32, peer: NodeId) void {
    assert(node.role == .leader);
    assert(slot < node.progress_len);
    const p = &node.progress[slot];
    assert(p.state == .probe);
    assert(p.inflight_count == 0);

    const index = node.snapshot_index;
    assert(index.order(node.log.base.index) != .lt);
    assert(index.order(node.applied_index) != .gt);
    const term = node.log.term_at(index) catch |err| switch (err) {
        // `snapshot_index >= log.base.index` (asserted above).
        error.LogCompacted => unreachable,
    };
    const round = node.rounds.id_next;
    assert(round < std.math.maxInt(u64));

    node.rounds.id_next = round + 1;
    node.rounds.records[leader_module.records_base(node, slot)] = .{
        .id = round,
        .prev = index,
        .last_sent = index,
        .sent_tick = node.rounds.ticks,
    };
    node.emit(.{ .send_snapshot = .{
        .header = node.header_to(peer),
        .snapshot = .{ .index = index, .term = term },
    } });
    p.on_snapshot_sent(index);
    assert(p.state == .snapshot);
    assert(p.inflight_count == 1);
}

/// Handles one `install_snapshot` that passed `Message.validate`. Returns a `Conf*` error,
/// changing nothing, when its configuration is over the node's `Config` caps. Preconditions:
/// `effects_len == 0`; `member` is whether the sender is in the configuration. A snapshot whose
/// index is `maxInt(u64)` cannot be a log position the node could extend: it is dropped.
pub fn step_install(
    node: *Node,
    request: *const SnapshotRequest,
    member: bool,
) ConfError!void {
    const head = &request.header;
    assert(head.from != node.config.id);
    assert(node.effects_len == 0);
    if (!member) return;

    try conf_check(node, &request.configuration);
    if (head.term.order(node.term) == .lt) return reply(node, head.from, .zero);
    if (@intFromEnum(request.snapshot.index) == std.math.maxInt(u64)) return;

    const leader_before = node.leader;
    const bumped = head.term.order(node.term) == .gt;
    if (bumped) _ = node.term_adopt(head.term);
    const claimed = follower_module.claim_leader(node, head.from);
    const installs = claimed and request.snapshot.index.order(node.commit_index) == .gt;
    if (installs) install(node, request);
    node.emit_hard_state(); // After `save_snapshot`, ahead of the reply.
    if (claimed) reply(node, head.from, request.snapshot.index);
    if (installs) node.emit(.{ .restore = request.snapshot.index });
    follower_module.notify_leader(node, leader_before, bumped);

    assert(node.term == head.term);
    assert(!installs or node.applied_index == request.snapshot.index);
}

/// The configuration caps of `Config`, as `Conf*` errors (peer data, never asserted).
fn conf_check(node: *const Node, configuration: *const Configuration) ConfError!void {
    assert(node.config.voters_max >= 1);
    assert(node.members.len > 0);
    if (configuration.voters.len > node.config.voters_max) return error.ConfVotersTooMany;
    if (configuration.voters_outgoing.len > node.config.voters_max) {
        return error.ConfVotersTooMany;
    }
    if (configuration.learners.len > node.config.learners_max) return error.ConfLearnersTooMany;
}

/// Installs a snapshot above `commit_index` from the leader of our term: copies the
/// configuration, emits `save_snapshot`, moves the indexes and the log. Emits nothing else.
fn install(node: *Node, request: *const SnapshotRequest) void {
    const snap = request.snapshot;
    assert(snap.index.order(node.commit_index) == .gt);
    assert(snap.term.order(node.term) != .gt);
    const holds = snap.index.order(node.log.last_index()) != .gt and
        (node.log.term_at(snap.index) catch |err| switch (err) {
            // `snap.index > commit_index >= applied_index >= snapshot_index >= log.base.index`.
            error.LogCompacted => unreachable,
        }) == snap.term;

    node.configuration = node_init.members_copy(node.members, &request.configuration);
    node.emit(.{ .save_snapshot = .{ .snapshot = snap, .configuration = node.configuration } });
    node.snapshot_index = snap.index;
    node.snapshot_pending = .zero;
    node.commit_index = snap.index;
    node.applied_index = snap.index;
    if (holds) {
        compact(node, snap.index);
    } else {
        node.log.reset(.{ .index = snap.index, .term = snap.term });
        node.bytes_used = 0;
    }
    assert(node.log.base.index == snap.index);
    assert(node.log.last_index().order(snap.index) != .lt);
}

/// Sends the `install_snapshot_response` to `to` at our term.
fn reply(node: *Node, to: NodeId, match_index: Index) void {
    assert(to != node.config.id);
    assert(node.effects_len < node.effects.len);
    node.emit(.{ .send = .{ .install_snapshot_response = .{
        .header = node.header_to(to),
        .match_index = match_index,
    } } });
    assert(node.effects[node.effects_len - 1] == .send);
}

/// Drops the log through `through` and re-packs the arena. Preconditions: `base.index <=
/// through <= snapshot_index`.
fn compact(node: *Node, through: Index) void {
    assert(through.order(node.log.base.index) != .lt);
    assert(through.order(node.snapshot_index) != .gt);
    const bytes_before = node.bytes_used;
    const count_before = node.log.count;

    var dropped_bytes: u32 = 0;
    for (node.log.range(node.log.base.index, through)) |item| {
        dropped_bytes += @intCast(item.data.len);
    }
    node.log.compact(through);

    const kept_bytes = bytes_before - dropped_bytes;
    std.mem.copyForwards(u8, node.bytes[0..kept_bytes], node.bytes[dropped_bytes..bytes_before]);
    var offset: usize = 0;
    for (node.log.entries[0..node.log.count]) |*item| {
        const len = item.data.len;
        item.data = node.bytes[offset..][0..len];
        offset += len;
    }
    node.bytes_used = kept_bytes;

    assert(offset == kept_bytes);
    assert(node.bytes_used <= bytes_before);
    assert(node.log.count <= count_before);
}

const std = @import("std");
const assert = std.debug.assert;
const follower_module = @import("follower.zig");
const leader_module = @import("leader.zig");
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const ConfError = types.ConfError;
const Configuration = types.Configuration;
const Index = types.Index;
const Node = node_module.Node;
const NodeId = types.NodeId;
const SnapshotRequest = types.SnapshotRequest;
