//! synod.raft.contract — the declarations a driver sees of the pure Raft `Node` (ADR-007,
//! ADR-009): `Config`, `Restore`, `Input`, `SnapshotDue`, `Effect`, `Effects`, `Role`, `Status`
//! and the error sets. Split from `node.zig` to keep both under the file cap; `node.zig`
//! re-exports every name, so `node.Config` and `raft.Config` keep working.
//!
//! Invariants: none of its own; the docs on each field state the contract `Node` enforces.
//! Allocation: none. Cost sketch: types and `Effect.phase` only.

/// Node configuration. Spelled out at every call site; no defaults (ADR-007).
pub const Config = struct {
    /// This node. Never `.none`.
    id: NodeId,
    /// Sent in every `Header`; within `protocol_version_min..=protocol_version_current`.
    protocol_version: u16,
    /// `t`: the election timeout is drawn from `[t, 2t)` ticks. Greater than `heartbeat_ticks`.
    election_ticks: u32,
    /// A leader heartbeats every this many ticks; in `1..t-1`. A probing peer's round expires
    /// after this many ticks, so a peer's round trip must stay below it to ever be matched.
    heartbeat_ticks: u32,
    /// Per voter set, within `1..=types.voters_max`.
    voters_max: u32,
    /// Within `0..=types.learners_max`.
    learners_max: u32,
    /// Unacknowledged `AppendRequest`s per peer; greater than zero.
    inflight_max: u32,
    /// Slots in the node's log; greater than zero.
    log_entries_max: u32,
    /// Bytes in the node-owned entry-byte arena.
    log_bytes_max: u32,
    /// A snapshot is due once `applied - log.base.index >= this`; in `1..log_entries_max-1`.
    snapshot_entries_min: u32,
    /// Entries kept at or below a saved snapshot for slightly lagging peers; below
    /// `snapshot_entries_min`.
    snapshot_trailing: u32,
    /// Validates every received `Message` and bounds every batch.
    message_limits: Message.Limits,
};

/// State recovered from the store, borrowed for the `init` call only; `init` copies all of it.
pub const Restore = struct {
    hard_state: HardState,
    /// The whole log, contiguous from index 1.
    entries: []const Entry,
    configuration: Configuration,
};

pub const Input = union(enum) {
    /// Borrowed until `step` returns.
    message: *const Message,
    /// One logical tick; carries no time value.
    tick,
    /// Command bytes, borrowed until `step` returns. Leader only.
    propose: []const u8,
    /// The driver saved and synced the pending `snapshot_due` at this index. Emits nothing.
    snapshot_saved: Index,
};

/// A snapshot the node asks the driver to take: the state machine as of `snapshot.index`.
pub const SnapshotDue = struct {
    /// `(applied, term of the entry at applied)`.
    snapshot: log_module.Base,
    /// The configuration as of `snapshot.index`; borrowed from the node.
    configuration: Configuration,
};

pub const Effect = union(enum) {
    truncate: Index,
    /// Non-empty and contiguous.
    append: []const Entry,
    save_hard_state: HardState,
    /// The destination is `header().to` (ADR-006).
    send: Message,
    /// In index order, each exactly once.
    apply: []const Entry,
    /// `.none` means unknown. Informational.
    leader_changed: NodeId,
    /// Snapshot phase: at most one per step, always the last effect.
    snapshot_due: SnapshotDue,

    /// Execution phases: the persist phase, then send, then apply, then notify, then snapshot.
    pub const Phase = enum(u8) { persist = 1, send = 2, apply = 3, notify = 4, snapshot = 5 };

    /// The phase in which a driver executes `effect`. Emission order is non-decreasing in it.
    pub fn phase(effect: *const Effect) Phase {
        const result: Phase = switch (effect.*) {
            .truncate, .append, .save_hard_state => .persist,
            .send => .send,
            .apply => .apply,
            .leader_changed => .notify,
            .snapshot_due => .snapshot,
        };
        assert(@intFromEnum(result) >= @intFromEnum(Phase.persist));
        assert(@intFromEnum(result) <= @intFromEnum(Phase.snapshot));
        return result;
    }
};

/// Borrowed view of the effects of one `step`, valid until the next `step()`/`deinit()`.
pub const Effects = struct { items: []const Effect };

pub const Role = enum { follower, pre_candidate, candidate, leader };

pub const Status = struct {
    role: Role,
    term: Term,
    vote: NodeId,
    leader: NodeId,
    commit_index: Index,
    applied_index: Index,
    last_index: Index,
    /// The index of the last snapshot the driver confirmed; zero when none.
    snapshot_index: Index,
};

pub const InitError = Allocator.Error || ConfError || error{ RestoreLogFull, RestoreInconsistent };
pub const ReceiveError = MessageError || error{StepMisrouted};
pub const ProposeError = error{ ProposeNotLeader, ProposeTooLarge, ProposeLogFull };
pub const StepError = ReceiveError || ProposeError || error{SnapshotUnexpected};
pub const InvariantError = log_module.Log.InvariantError || error{
    InvariantCommitBeyondLog,
    InvariantAppliedBeyondCommit,
    InvariantTermBehindLog,
    InvariantVoteWithoutTerm,
    InvariantLeaderRole,
    InvariantEntryDataMisplaced,
    InvariantElectionTimeout,
    InvariantProgressOrder,
    InvariantInflightOverflow,
    InvariantBaseBeyondApplied,
};

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log_module = @import("../log.zig");
const types = @import("../types.zig");

const ConfError = types.ConfError;
const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const Message = types.Message;
const MessageError = types.MessageError;
const NodeId = types.NodeId;
const Term = types.Term;
