//! synod.sim.sim_snapshots — the simulator's snapshot bookkeeping, split out of `simulation.zig`
//! (plan 005 item 6, ADR-009 "Simulator" and "Sim snapshot sizing"): when compaction is on, how
//! big the snapshot buffers must be, and a `Tracker` that notices after each event which nodes
//! saved a snapshot or installed one and tells the `Checker`.
//!
//! Compaction is on when `Config.snapshot_entries_min > 0` and
//! `message_limits.snapshot_bytes_max > 0`. The nodes take and install snapshots by themselves
//! (the `Driver` runs `snapshot_due` and the install effects); the simulator only watches. A
//! node saved a snapshot when its `snapshot_index` rose without its state machine restoring;
//! it installed one when it restored as well. A restart restores from the store too, which is
//! neither: `restarted` re-bases the tracker and tells the checker the applied index jumped.
//!
//! Allocation: none.

const std = @import("std");
const assert = std.debug.assert;
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const invariants = @import("invariants.zig");
const workload_module = @import("workload.zig");

const Checker = invariants.Checker;
const Index = types.Index;
const KvStateMachine = workload_module.KvStateMachine;

/// The most nodes tracked; equal to `Simulation`'s `nodes_max`.
const nodes_max: u8 = 7;

/// True when `config` has the simulator's nodes compact their logs.
pub fn compaction_on(config: *const raft.Config) bool {
    const entries_on = config.snapshot_entries_min > 0;
    const bytes_on = config.message_limits.snapshot_bytes_max > 0;
    return entries_on and bytes_on;
}

/// True when the buffers of a compacting simulation hold one whole KV snapshot of `keys_count`
/// registers. Off means nothing to size: always true.
pub fn buffers_fit(config: *const raft.Config, keys_count: u16) bool {
    assert(keys_count > 0);
    if (!compaction_on(config)) return true;

    const need = KvStateMachine.snapshot_bytes(keys_count);
    return config.message_limits.snapshot_bytes_max >= need;
}

/// Bytes a store keeps for its snapshot: the message limit when compaction is on, else 0.
pub fn store_bytes_max(config: *const raft.Config) u32 {
    if (!compaction_on(config)) return 0;

    assert(config.message_limits.snapshot_bytes_max > 0);
    assert(config.message_limits.snapshot_bytes_max <= std.math.maxInt(u32));
    return @intCast(config.message_limits.snapshot_bytes_max);
}

/// Bytes of a `CrashStore` journal: the entry bytes the log holds plus, when compaction is on,
/// one whole journalled snapshot (at most one is unsynced: the driver syncs right after it).
pub fn journal_bytes_max(config: *const raft.Config) u32 {
    const total = config.log_bytes_max + store_bytes_max(config);
    assert(total >= config.log_bytes_max);
    if (compaction_on(config)) assert(total > config.log_bytes_max);
    return total;
}

/// What happened to one node's snapshot in one event.
pub const Change = enum { none, saved, installed };

/// Per-node memory of the last observed `snapshot_index` and `restores`, plus the totals.
pub const Tracker = struct {
    snapshot_seen: [nodes_max]u64,
    restores_seen: [nodes_max]u64,
    /// Snapshots saved and confirmed, and snapshots followers installed (`Stats`).
    saved: u64,
    installs: u64,

    pub const empty: Tracker = .{
        .snapshot_seen = @splat(0),
        .restores_seen = @splat(0),
        .saved = 0,
        .installs = 0,
    };

    /// Classifies what changed at node `slot` since the last call and updates the totals.
    /// Precondition: the snapshot index never goes down while the node is up.
    pub fn classify(
        tracker: *Tracker,
        slot: u8,
        snapshot_index: Index,
        kv: *const KvStateMachine,
    ) Change {
        assert(slot < nodes_max);
        const seen = tracker.snapshot_seen[slot];
        assert(@intFromEnum(snapshot_index) >= seen);
        const restored = kv.restores != tracker.restores_seen[slot];
        tracker.restores_seen[slot] = kv.restores;
        tracker.snapshot_seen[slot] = @intFromEnum(snapshot_index);
        if (@intFromEnum(snapshot_index) == seen) {
            assert(!restored); // A restore of a stale or equal snapshot is not an install.
            return .none;
        }
        if (!restored) {
            tracker.saved += 1;
            return .saved;
        }
        tracker.installs += 1;
        return .installed;
    }

    /// Reports node `slot`'s change after an event to `checker`: an install moves its applied
    /// index first, then the state digest at the snapshot index is compared with every other
    /// node's. Precondition: `applied_index` is where the state machine stands.
    pub fn report(
        tracker: *Tracker,
        checker: *Checker,
        slot: u8,
        status: *const raft.Status,
        kv: *const KvStateMachine,
    ) invariants.Violation!void {
        const change = tracker.classify(slot, status.snapshot_index, kv);
        if (change == .none) return;

        assert(status.snapshot_index != .zero);
        assert(status.applied_index == status.snapshot_index); // Nothing applies after it.
        if (change == .installed) try checker.installed(slot, status.snapshot_index);
        try checker.state_digest(slot, status.applied_index, kv.digest());
    }

    /// Node `slot` was rebuilt from its store: re-bases the tracker (a restart restores from the
    /// stored snapshot without that being an install) and, if the store held a snapshot, moves
    /// the checker's applied index to it and compares its digest.
    pub fn restarted(
        tracker: *Tracker,
        checker: *Checker,
        slot: u8,
        status: *const raft.Status,
        kv: *const KvStateMachine,
    ) invariants.Violation!void {
        assert(slot < nodes_max);
        tracker.snapshot_seen[slot] = @intFromEnum(status.snapshot_index);
        tracker.restores_seen[slot] = kv.restores;
        if (status.snapshot_index == .zero) return;

        assert(status.applied_index == status.snapshot_index); // Replay waits for the commit.
        try checker.installed(slot, status.snapshot_index);
        try checker.state_digest(slot, status.snapshot_index, kv.digest());
    }
};
