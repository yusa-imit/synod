//! synod.raft.node — the pure Raft `Node` of ADR-007: `Config`, `Restore`, `Input`, `Effect`,
//! `Effects`, `Role`, `Status`, the error sets, and `Node` (`init`, `deinit`, `step`, `status`,
//! `entries`, `check_invariants`).
//!
//! Scope (plan 003 item 2A-i): the skeleton. A node restores from `Restore`, validates and
//! routes every received message, applies the term rules (a higher term from a known member
//! makes a follower and persists once; a stale term is dropped), counts ticks, and rejects
//! proposals unless it leads. Elections (2A-ii), replication (2B) and apply (2C) land later and
//! extend `step_message`, `step_tick` and `step_propose` without changing a signature.
//!
//! Invariants: `check_invariants` states them: commit within the log, applied within commit,
//! the term at least the last entry's term, no vote in term zero, `role == .leader` exactly
//! when `leader == config.id`, the election timeout in `[t, 2t)`, entry bytes packed in index
//! order. A `StepError` returns before any mutation and with no `Effects`.
//!
//! Allocation: `init` allocates everything the node will ever use from `gpa` (log slots, the
//! `log_bytes_max` entry-byte arena, the member list, and `peers_max + 5` effect slots). `step`
//! and every other method take no allocator and never allocate (Tiger Style §1.9). `deinit`
//! takes the same `gpa`; the node never stores it.
//!
//! Ownership: `init` copies all of `Restore` (hard state, entry bytes, configuration); the node
//! owns those copies. `Input.message` and `Input.propose` bytes are borrowed until `step`
//! returns and are copied if kept. The `Effects` view returned by `step`, every slice it
//! reaches, and `entries()` borrow node memory until the next `step()` or `deinit()`. A `Node`
//! is initialized in place and must not move afterwards: its configuration slices point into
//! node-owned heap memory, and its log entries point into the entry-byte arena.
//!
//! Cost sketch: no I/O, no syscalls. `step` touches the term, vote and role words plus at most
//! the member list (at most `2 * voters_max + learners_max` ids) to find the sender; effects
//! are written into one preallocated array, so the working set stays within a few cache lines.

/// Node configuration. Spelled out at every call site; no defaults (ADR-007).
pub const Config = struct {
    /// This node. Never `.none`.
    id: NodeId,
    /// Sent in every `Header`; within `protocol_version_min..=protocol_version_current`.
    protocol_version: u16,
    /// `t`: the election timeout is drawn from `[t, 2t)` ticks. Greater than `heartbeat_ticks`.
    election_ticks: u32,
    /// A leader heartbeats every this many ticks; in `1..t-1`.
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

    /// Execution phases: the persist phase, then send, then apply, then notify.
    pub const Phase = enum(u8) { persist = 1, send = 2, apply = 3, notify = 4 };

    /// The phase in which a driver executes `effect`. Emission order is non-decreasing in it.
    pub fn phase(effect: *const Effect) Phase {
        const result: Phase = switch (effect.*) {
            .truncate, .append, .save_hard_state => .persist,
            .send => .send,
            .apply => .apply,
            .leader_changed => .notify,
        };
        assert(@intFromEnum(result) >= @intFromEnum(Phase.persist));
        assert(@intFromEnum(result) <= @intFromEnum(Phase.notify));
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
};

pub const InitError = Allocator.Error || ConfError || error{ RestoreLogFull, RestoreInconsistent };
pub const ReceiveError = MessageError || error{StepMisrouted};
pub const ProposeError = error{ ProposeNotLeader, ProposeTooLarge, ProposeLogFull };
pub const StepError = ReceiveError || ProposeError;
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
};

/// Effect slots beyond one per peer: truncate, append, save_hard_state, apply, leader_changed.
const effects_fixed_count: u32 = 5;

pub const Node = struct {
    config: Config,
    role: Role,
    term: Term,
    vote: NodeId,
    leader: NodeId,
    commit_index: Index,
    applied_index: Index,
    log: log_module.Log,
    /// Ticks without hearing from a leader before an election; drawn from `[t, 2t)`.
    election_timeout: u32,
    /// Ticks since the election timer was last reset. Saturates; never wraps.
    election_elapsed: u32,
    rng: Rng,
    /// The node's copy of the cluster membership; its slices point into `members`.
    configuration: Configuration,
    /// The hard state most recently emitted (or restored): a repeat is not emitted again.
    hard_state_saved: HardState,
    /// Entry-byte arena, `config.log_bytes_max` long; entry data is packed in index order.
    bytes: []u8,
    /// Bytes of `bytes` in use by live entries.
    bytes_used: u32,
    /// Backing store for `configuration`: `2 * voters_max + learners_max` ids.
    members: []NodeId,
    /// Effect slots, `peers_max + 5` long; `effects[0..effects_len]` is the last step's output.
    effects: []Effect,
    effects_len: u32,

    /// Initializes `node` in place from `config`, `restore` and the injected `rng`, copying all
    /// of `restore`. The node starts a follower with `applied_index == .zero`.
    /// Preconditions (asserted): a coherent `config` (see `Config`). `restore` is data:
    /// `Conf*`, `RestoreInconsistent` and `RestoreLogFull` are returned, and a failure leaves
    /// nothing allocated. The election timeout is drawn once from `rng`.
    pub fn init(
        node: *Node,
        gpa: Allocator,
        config: Config,
        restore: *const Restore,
        rng: Rng,
    ) InitError!void {
        assert_config(&config);
        assert(restore.entries.len < std.math.maxInt(u32));
        try restore_validate(&config, restore);

        var log: log_module.Log = undefined;
        try log.init(gpa, .{ .entries_max = config.log_entries_max });
        errdefer log.deinit(gpa);

        const bytes = try gpa.alloc(u8, config.log_bytes_max);
        errdefer gpa.free(bytes);

        const members = try gpa.alloc(NodeId, members_capacity(&config));
        errdefer gpa.free(members);

        const effects = try gpa.alloc(Effect, effects_capacity(&config));
        errdefer gpa.free(effects);

        @memset(log.entries, .{ .index = .zero, .term = .zero, .kind = .normal, .data = "" });
        @memset(bytes, 0);
        @memset(members, .none);
        @memset(effects, .{ .leader_changed = .none });
        node.* = .{
            .config = config,
            .role = .follower,
            .term = restore.hard_state.term,
            .vote = restore.hard_state.vote,
            .leader = .none,
            .commit_index = restore.hard_state.commit_index,
            .applied_index = .zero,
            .log = log,
            .election_timeout = election_timeout_draw(rng, config.election_ticks),
            .election_elapsed = 0,
            .rng = rng,
            .configuration = members_copy(members, &restore.configuration),
            .hard_state_saved = restore.hard_state,
            .bytes = bytes,
            .bytes_used = 0,
            .members = members,
            .effects = effects,
            .effects_len = 0,
        };
        for (restore.entries) |entry| {
            node.log_append(entry.term, entry.kind, entry.data) catch |err| switch (err) {
                error.LogFull => return error.RestoreLogFull,
            };
        }

        assert(node.role == .follower);
        assert(node.applied_index == .zero);
        assert(node.log.count == restore.entries.len);
    }

    /// Frees what `init` allocated, with the same `gpa`. Precondition: initialized, not yet
    /// deinitialized. Every borrowed `Effects` view and `entries()` slice dies here.
    pub fn deinit(node: *Node, gpa: Allocator) void {
        assert(node.effects.len > 0);
        assert(node.members.len > 0);

        gpa.free(node.effects);
        gpa.free(node.members);
        gpa.free(node.bytes);
        node.log.deinit(gpa);

        node.effects = &.{};
        node.members = &.{};
        node.bytes = &.{};
        assert(node.log.entries.len == 0);
    }

    /// Feeds one input. `.message` is validated against `config.message_limits`, then its
    /// destination against `config.id`, before any mutation. A `StepError` leaves the node
    /// unchanged and returns no effects; a tick never fails. The returned view is borrowed
    /// until the next `step()`/`deinit()`; its `phase()` never decreases.
    pub fn step(node: *Node, input: Input) StepError!Effects {
        assert(node.effects_len <= node.effects.len);
        assert(node.log.count <= node.log.entries.len);

        switch (input) {
            .message => |message| try node.step_message(message),
            .tick => node.step_tick(),
            .propose => |data| try node.step_propose(data),
        }

        assert(node.effects_len <= node.effects.len);
        return .{ .items = node.effects[0..node.effects_len] };
    }

    pub fn status(node: *const Node) Status {
        assert(node.log.count <= node.log.entries.len);
        assert(node.config.id != .none);
        return .{
            .role = node.role,
            .term = node.term,
            .vote = node.vote,
            .leader = node.leader,
            .commit_index = node.commit_index,
            .applied_index = node.applied_index,
            .last_index = node.log.last_index(),
        };
    }

    /// Borrowed until the next `step()`.
    pub fn entries(node: *const Node) []const Entry {
        assert(node.log.count <= node.log.entries.len);
        assert(node.bytes_used <= node.bytes.len);
        return node.log.entries[0..node.log.count];
    }

    /// Defense-in-depth for the simulator: returns the first violated invariant of a corrupted
    /// node. A node built by `init` and driven by `step` never fails it. The progress and
    /// inflight invariants need a leader's per-peer state (items 2B and later) and pass here.
    pub fn check_invariants(node: *const Node) InvariantError!void {
        assert(node.log.count <= node.log.entries.len);
        assert(node.effects_len <= node.effects.len);

        try node.log.validate();
        try node.check_invariants_indices();
        try node.check_invariants_election();
        try node.check_invariants_bytes();
    }

    fn check_invariants_indices(node: *const Node) InvariantError!void {
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

    fn check_invariants_election(node: *const Node) InvariantError!void {
        if (node.vote != .none and node.term == .zero) return error.InvariantVoteWithoutTerm;
        const leads = node.role == .leader;
        if (leads != (node.leader == node.config.id)) return error.InvariantLeaderRole;
        const ticks: u64 = node.config.election_ticks;
        if (node.election_timeout < ticks) return error.InvariantElectionTimeout;
        if (node.election_timeout >= 2 * ticks) return error.InvariantElectionTimeout;
        assert(leads == (node.leader == node.config.id));
        assert(node.election_timeout >= node.config.election_ticks);
    }

    fn check_invariants_bytes(node: *const Node) InvariantError!void {
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

    fn step_message(node: *Node, message: *const Message) StepError!void {
        try message.validate(node.config.message_limits);
        const head = message.header();
        if (head.to != node.config.id) return error.StepMisrouted;
        assert(head.from != node.config.id); // `validate` rejected `from == to`.
        assert(head.term != .zero);

        node.effects_len = 0;
        switch (head.term.order(node.term)) {
            // Stale: dropped without effects. Rejecting replies arrive with items 2A-ii/2B.
            .lt => {},
            // Current term: per-kind handlers arrive with items 2A-ii/2B.
            .eq => {},
            // A higher term counts only from a member of the configuration.
            .gt => if (node.is_member(head.from)) node.become_follower(head.term),
        }
        assert(node.term != .zero);
        assert(node.effects_len <= node.effects.len);
    }

    fn step_tick(node: *Node) void {
        node.effects_len = 0;
        node.election_elapsed +|= 1;
        // The election itself is item 2A-ii; until then a tick only counts.
        assert(node.effects_len == 0);
        assert(node.election_timeout >= node.config.election_ticks);
    }

    fn step_propose(node: *Node, data: []const u8) ProposeError!void {
        if (node.role != .leader) return error.ProposeNotLeader;
        assert(node.leader == node.config.id);
        if (data.len > node.config.message_limits.entry_bytes_max) return error.ProposeTooLarge;

        node.log_append(node.term, .normal, data) catch |err| switch (err) {
            error.LogFull => return error.ProposeLogFull,
        };
        node.effects_len = 0;
        const last = node.log.count;
        node.emit(.{ .append = node.log.entries[last - 1 .. last] });
        assert(node.effects_len == 1);
        assert(node.log.last_index().order(node.commit_index) == .gt);
    }

    /// Adopts a strictly higher `new_term`: follower, vote cleared, leader unknown, one
    /// `save_hard_state`, and `leader_changed(.none)` only if a leader was known.
    fn become_follower(node: *Node, new_term: Term) void {
        assert(new_term.order(node.term) == .gt);
        assert(node.effects_len == 0);

        const leader_before = node.leader;
        node.term = new_term;
        node.vote = .none;
        node.role = .follower;
        node.leader = .none;
        node.election_reset();
        node.emit_hard_state();
        if (leader_before != .none) node.emit(.{ .leader_changed = .none });

        assert(node.role == .follower);
        assert(node.vote == .none);
        assert(node.effects_len >= 1);
    }

    fn election_reset(node: *Node) void {
        node.election_elapsed = 0;
        node.election_timeout = election_timeout_draw(node.rng, node.config.election_ticks);
        assert(node.election_elapsed == 0);
        assert(node.election_timeout < 2 * @as(u64, node.config.election_ticks));
    }

    /// Emits `save_hard_state` unless it equals the last one emitted.
    fn emit_hard_state(node: *Node) void {
        const hard_state: HardState = .{
            .term = node.term,
            .vote = node.vote,
            .commit_index = node.commit_index,
        };
        assert(hard_state.term.order(node.hard_state_saved.term) != .lt);
        assert(hard_state.commit_index.order(node.hard_state_saved.commit_index) != .lt);
        if (hard_state.eql(&node.hard_state_saved)) return;

        node.emit(.{ .save_hard_state = hard_state });
        node.hard_state_saved = hard_state;
    }

    /// Appends one effect. Preconditions: a free slot, and `effect.phase()` not below the
    /// phase of the previous effect (the ADR-007 ordering).
    fn emit(node: *Node, effect: Effect) void {
        assert(node.effects_len < node.effects.len);
        if (node.effects_len > 0) {
            const previous = node.effects[node.effects_len - 1].phase();
            assert(@intFromEnum(previous) <= @intFromEnum(effect.phase()));
        }
        node.effects[node.effects_len] = effect;
        node.effects_len += 1;
        assert(node.effects_len <= node.effects.len);
    }

    /// Appends an entry at `last_index + 1`, copying `data` into the entry-byte arena. Returns
    /// `error.LogFull` (node unchanged) when no slot or too few bytes remain.
    fn log_append(
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

    fn is_member(node: *const Node, id: NodeId) bool {
        assert(id != .none);
        assert(id != node.config.id);
        const configuration = &node.configuration;
        for (configuration.voters) |voter| if (voter == id) return true;
        for (configuration.voters_outgoing) |voter| if (voter == id) return true;
        for (configuration.learners) |learner| if (learner == id) return true;
        return false;
    }
};

/// Asserts the `Config` contract of ADR-007: a caller's bug, never a returned error.
fn assert_config(config: *const Config) void {
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
fn effects_capacity(config: *const Config) u32 {
    const peers_max = 2 * config.voters_max + config.learners_max - 1;
    assert(peers_max >= 1);
    return peers_max + effects_fixed_count;
}

fn members_capacity(config: *const Config) u32 {
    const result = 2 * config.voters_max + config.learners_max;
    assert(result >= 2);
    return result;
}

/// `t + rng.uint_less_than(t)`: exactly one draw, a value in `[t, 2t)`.
fn election_timeout_draw(rng: Rng, election_ticks: u32) u32 {
    assert(election_ticks > 0);
    const drawn: u32 = @intCast(rng.uint_less_than(election_ticks));
    assert(drawn < election_ticks);
    return election_ticks + drawn;
}

/// Pure data check of `Restore`; allocates nothing. `RestoreLogFull` is decided at copy time.
fn restore_validate(config: *const Config, restore: *const Restore) InitError!void {
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
fn members_copy(members: []NodeId, source: *const Configuration) Configuration {
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

test {
    _ = @import("node_test.zig");
    _ = @import("node_step_test.zig");
    _ = @import("node_invariants_test.zig");
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const interfaces = @import("../interfaces.zig");
const log_module = @import("../log.zig");
const types = @import("../types.zig");

const ConfError = types.ConfError;
const Configuration = types.Configuration;
const Entry = types.Entry;
const EntryKind = types.EntryKind;
const HardState = types.HardState;
const Index = types.Index;
const Message = types.Message;
const MessageError = types.MessageError;
const NodeId = types.NodeId;
const Rng = interfaces.Rng;
const Term = types.Term;
