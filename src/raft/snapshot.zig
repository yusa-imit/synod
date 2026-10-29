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
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Index = types.Index;
const Node = node_module.Node;
