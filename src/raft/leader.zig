//! synod.raft.leader — the send side of a Raft leader (thesis §3.5, §10.2.1; plan 003 item
//! 2B-i-a), as free functions over a `*Node`: build one `Progress` per other voter on election,
//! send `append_entries` to every peer whose window has room, heartbeat, and time out rounds.
//! `Node` owns the state (`progress`, `progress_len`, `rounds`); this file owns the rules.
//!
//! Round record design: every `append_entries` sent is one round with a unique id (`round`, the
//! id the peer echoes back, ADR-005), recorded as a `Round` (id, `prev`, `last_sent`, send tick)
//! in the sending peer's slot of `Rounds.records`. A slot's live records are exactly the first
//! `Progress.inflight_count` entries of its `inflight_max` records, oldest first, so the window
//! and the records cannot drift apart. A round times out when it has been unanswered for
//! `election_ticks` leader ticks (`heartbeat_ticks` for a probing peer, whose one lost round
//! would otherwise gate every heartbeat): the oldest live record of the slot decides, and
//! `Progress.on_timeout` then discards the whole window, so the next heartbeat (or proposal)
//! resends from `match + 1` under a fresh round id and a late response to the dead round matches
//! no record.
//!
//! Responses (2B-i-b, `step_response`): an `append_entries_response` at our term from a peer
//! with a slot is matched to a live record of that slot by its echoed round id; anything else
//! (a learner, a stranger, a dead or duplicate round) is dropped without a trace. `accepted` is
//! range-checked against our own record (`prev <= matched <= last_sent`, never the peer's
//! claim), feeds `Progress.on_accepted`, removes the record and sends the entries not yet sent.
//! `rejected` feeds `Progress.on_rejected`: a live rejection discards the window and resends
//! from the backtracked `next` at once; a stale one removes only its own record.
//!
//! Timing: the election step is leader tick 0; a heartbeat falls on every `heartbeat_ticks`-th
//! leader tick; a proposal sends at once to each peer that can send. Round ids are issued from
//! `Rounds.id_next`, which only grows (a stale id from an earlier leadership never matches).
//!
//! Invariants: `progress_len` is zero unless the node leads and then equals the number of
//! distinct voters other than the leader, in `configuration.voters` order followed by the
//! outgoing-only voters; learners get nothing. `check_invariants` states them.
//!
//! Allocation: `Storage.init` allocates the worst case once, called from `Node.init`; every
//! other function here takes no allocator. Cost sketch: a send touches one `Progress` (32
//! bytes), one `Round` (32 bytes) and the batch slice view of the log, nothing is copied; a
//! heartbeat round is O(peers), with at most `2 * voters_max` peers and `inflight_max` records.

/// One `append_entries` sent and not yet answered. A peer's response is matched to it by `id`;
/// 2B-i-b checks `prev <= matched <= last_sent` against it, never against the peer's message.
pub const Round = struct {
    id: u64,
    /// The `prev_log_index` of the request.
    prev: Index,
    /// The index of the last entry in the request; equal to `prev` for a heartbeat.
    last_sent: Index,
    /// `Rounds.ticks` when the request was sent.
    sent_tick: u64,

    /// What an unused record holds; never read as live.
    pub const empty: Round = .{ .id = 0, .prev = .zero, .last_sent = .zero, .sent_tick = 0 };
};

/// The leader's round bookkeeping. `records` holds `inflight_max` records per progress slot.
pub const Rounds = struct {
    records: []Round,
    /// The id of the next round; starts at 1 (0 is never issued) and only grows.
    id_next: u64,
    /// Leader ticks since the election step, which is tick 0.
    ticks: u64,
};

/// The allocations of a leader, made once in `Node.init`.
pub const Storage = struct {
    progress: []Progress,
    rounds: Rounds,

    /// Allocates the worst case for `config`: a `Progress` per possible peer and
    /// `inflight_max` rounds each. Precondition: a coherent `config` (`assert_config`).
    pub fn init(gpa: Allocator, config: *const Config) Allocator.Error!Storage {
        const progress_count = node_init.progress_capacity(config);
        const records_count = node_init.rounds_capacity(config);
        assert(progress_count >= 1);
        assert(records_count >= progress_count);

        const progress = try gpa.alloc(Progress, progress_count);
        errdefer gpa.free(progress);

        const records = try gpa.alloc(Round, records_count);
        errdefer gpa.free(records);

        @memset(progress, Progress.init(.zero, config.inflight_max));
        @memset(records, Round.empty);
        return .{
            .progress = progress,
            .rounds = .{ .records = records, .id_next = 1, .ticks = 0 },
        };
    }

    /// Frees what `init` allocated, with the same `gpa`.
    pub fn deinit(storage: *const Storage, gpa: Allocator) void {
        assert(storage.progress.len > 0);
        assert(storage.rounds.records.len >= storage.progress.len);
        gpa.free(storage.rounds.records);
        gpa.free(storage.progress);
    }
};

/// A new leader's first act: one probing `Progress` per other voter, next to the entry after
/// the pre-election log tail `last_before` (the term's empty entry is its first send), then the
/// first `append_entries` to each. Preconditions: the node just became leader and has no
/// progress; the effects so far are at most `save_hard_state` (a lone voter) and the empty
/// entry's `append`.
pub fn start(node: *Node, last_before: u32) void {
    assert(node.role == .leader);
    assert(node.progress_len == 0);
    assert(node.effects_len <= 2);
    assert(last_before <= node.log.count);

    const peers = peers_count(node);
    assert(peers <= node.progress.len);
    const fresh = Progress.init(@enumFromInt(last_before), node.config.inflight_max);
    @memset(node.progress[0..peers], fresh);
    node.progress_len = peers;
    node.rounds.ticks = 0;
    send_all(node);

    // The winning step also needs one slot for `leader_changed` (ADR-007 effect capacity).
    assert(node.effects_len <= 2 + peers);
    assert(node.effects_len < node.effects.len);
}

/// Forgets the per-peer state when the node stops leading. Precondition: no longer a leader.
pub fn reset(node: *Node) void {
    assert(node.role != .leader);
    assert(node.progress_len <= node.progress.len);
    node.progress_len = 0;
    assert(node.progress_len == 0);
}

/// Sends `append_entries` to every peer whose window has room: the batch from the peer's
/// `next`, at most `entries_max` entries, empty when the peer is caught up (a heartbeat).
/// Preconditions: the node leads; effects so far are in phase order up to `persist`.
pub fn send_all(node: *Node) void {
    assert(node.role == .leader);
    assert(node.progress_len <= node.progress.len);

    var slot: u32 = 0;
    const sets = &node.configuration;
    for (sets.voters) |peer| {
        if (peer == node.config.id) continue;
        send_slot(node, slot, peer);
        slot += 1;
    }
    for (sets.voters_outgoing) |peer| {
        if (!is_outgoing_peer(node, peer)) continue;
        send_slot(node, slot, peer);
        slot += 1;
    }
    assert(slot == node.progress_len);
}

/// Handles one `append_entries_response`. Preconditions: the node leads and the response is at
/// our term (the caller applied the term rules). Peer data is only a key: the round id selects
/// our own record, and every range check and index comes from that record.
pub fn step_response(node: *Node, reply: *const AppendResponse) void {
    assert(node.role == .leader);
    assert(reply.header.term == node.term);

    const peer = reply.header.from;
    const slot = slot_of(node, peer) orelse return;
    const at = live_record(node, slot, reply.round) orelse return;
    const round = node.rounds.records[records_base(node, slot) + at];
    const p = &node.progress[slot];
    switch (reply.outcome) {
        .accepted => |matched| {
            const m = @intFromEnum(matched);
            if (m < @intFromEnum(round.prev)) return;
            if (m > @intFromEnum(round.last_sent)) return;
            assert(m < std.math.maxInt(u64)); // `last_sent` came from a `u32` log count.
            remove_record(node, slot, at);
            // Whether match advanced is consumed by commit advancement (item 2B-iii).
            _ = p.on_accepted(matched);
            if (@intFromEnum(p.next) <= node.log.count) send_slot(node, slot, peer);
        },
        .rejected => |conflict| if (p.on_rejected(conflict, round.prev)) {
            send_slot(node, slot, peer); // The window is gone, so every record is dead.
        } else {
            remove_record(node, slot, at);
            p.on_stale_rejection();
        },
    }
    assert(p.inflight_count <= p.inflight_max);
    assert(node.effects_len <= node.progress_len);
}

/// The progress slot of `peer`, in `send_all` order, or null for a learner or a stranger.
fn slot_of(node: *const Node, peer: NodeId) ?u32 {
    assert(peer != node.config.id);
    assert(node.progress_len <= node.progress.len);

    var slot: u32 = 0;
    for (node.configuration.voters) |voter| {
        if (voter == node.config.id) continue;
        if (voter == peer) return slot;
        slot += 1;
    }
    for (node.configuration.voters_outgoing) |voter| {
        if (!is_outgoing_peer(node, voter)) continue;
        if (voter == peer) return slot;
        slot += 1;
    }
    assert(slot == node.progress_len);
    return null;
}

/// The position among `slot`'s live records (oldest first) of the one with id `round`.
fn live_record(node: *const Node, slot: u32, round: u64) ?u32 {
    assert(slot < node.progress_len);
    const live = node.progress[slot].inflight_count;
    assert(live <= node.config.inflight_max);

    const base = records_base(node, slot);
    for (node.rounds.records[base..][0..live], 0..) |record, at| {
        if (record.id == round) return @intCast(at);
    }
    return null;
}

/// Removes live record `at` of `slot` by shifting the later ones down, keeping the order. The
/// caller then lowers `inflight_count` (`on_accepted`, `on_stale_rejection`).
fn remove_record(node: *Node, slot: u32, at: u32) void {
    const live = node.progress[slot].inflight_count;
    assert(at < live);
    assert(live <= node.config.inflight_max);

    const records = node.rounds.records[records_base(node, slot)..][0..live];
    @memmove(records[at .. live - 1], records[at + 1 .. live]);
    records[live - 1] = Round.empty;
}

/// One leader tick: time out the rounds that have been unanswered for `election_ticks`, then
/// heartbeat on every `heartbeat_ticks`-th tick. Preconditions: the node leads, `effects_len`
/// is zero.
pub fn tick(node: *Node) void {
    assert(node.role == .leader);
    assert(node.effects_len == 0);

    node.rounds.ticks += 1;
    for (0..node.progress_len) |slot| round_expire(node, @intCast(slot));
    if (@mod(node.rounds.ticks, node.config.heartbeat_ticks) == 0) send_all(node);
    assert(node.effects_len <= node.progress_len);
}

/// Returns the first violated leader invariant: progress held off the leader or not one slot
/// per peer (`InvariantLeaderRole`), a `Progress` out of order or over its window, a round
/// record never issued or sent in the future (`InvariantInflightOverflow`: a record the window
/// cannot account for), or a record whose `prev..last_sent` is not inside the leader's log
/// (`InvariantProgressOrder`).
pub fn check_invariants(node: *const Node) InvariantError!void {
    assert(node.progress_len <= node.progress.len);
    assert(node.rounds.records.len >= node.progress.len);

    if (node.role != .leader) {
        if (node.progress_len != 0) return error.InvariantLeaderRole;
        return;
    }
    if (node.progress_len != peers_count(node)) return error.InvariantLeaderRole;
    if (node.rounds.id_next == 0) return error.InvariantInflightOverflow;
    for (node.progress[0..node.progress_len], 0..) |*p, slot| {
        try p.check_invariants();
        if (p.inflight_max != node.config.inflight_max) return error.InvariantInflightOverflow;
        try check_invariants_rounds(node, @intCast(slot));
    }
}

fn check_invariants_rounds(node: *const Node, slot: u32) InvariantError!void {
    const live = node.progress[slot].inflight_count;
    assert(live <= node.config.inflight_max); // `Progress.check_invariants` passed.
    assert(slot < node.progress_len);

    const base = records_base(node, slot);
    for (node.rounds.records[base..][0..live]) |round| {
        if (round.id >= node.rounds.id_next) return error.InvariantInflightOverflow;
        if (round.sent_tick > node.rounds.ticks) return error.InvariantInflightOverflow;
        if (@intFromEnum(round.prev) > @intFromEnum(round.last_sent)) {
            return error.InvariantProgressOrder;
        }
        if (@intFromEnum(round.last_sent) > node.log.count) return error.InvariantProgressOrder;
    }
}

/// Sends the next batch to `peer`, whose progress is `slot`, if its window has room, and
/// records the round.
fn send_slot(node: *Node, slot: u32, peer: NodeId) void {
    assert(slot < node.progress_len);
    assert(peer != node.config.id);
    const p = &node.progress[slot];
    if (!p.can_send()) return;

    assert(@intFromEnum(node.log.last_index()) == node.log.count); // No compaction offset yet.
    const prev = @intFromEnum(p.next) - 1; // `next >= 1` is a `Progress` invariant.
    assert(prev <= node.log.count); // The leader's log is the longest a peer can match.
    const first: u32 = @intCast(prev);
    const batch_count = @min(node.log.count - first, node.config.message_limits.entries_max);
    const stop = first + batch_count;
    const round = node.rounds.id_next;
    assert(round < std.math.maxInt(u64));

    node.rounds.id_next = round + 1;
    node.rounds.records[records_base(node, slot) + p.inflight_count] = .{
        .id = round,
        .prev = @enumFromInt(first),
        .last_sent = @enumFromInt(stop),
        .sent_tick = node.rounds.ticks,
    };
    node.emit(.{ .send = .{ .append_entries = .{
        .header = node.header_to(peer),
        .prev_log_index = @enumFromInt(first),
        .prev_log_term = node.log.term_at(@enumFromInt(first)),
        .leader_commit = node.commit_index,
        .round = round,
        .entries = node.log.entries[first..stop],
    } } });
    p.on_send(@enumFromInt(stop));
}

/// Times out `slot`'s window when its oldest live round is old enough: `election_ticks`, or
/// `heartbeat_ticks` while probing (a lost probe must not silence the peer for a whole timeout).
fn round_expire(node: *Node, slot: u32) void {
    assert(slot < node.progress_len);
    const p = &node.progress[slot];
    if (p.inflight_count == 0) return;

    const oldest = node.rounds.records[records_base(node, slot)];
    assert(oldest.sent_tick <= node.rounds.ticks);
    const age_max = switch (p.state) {
        .probe => node.config.heartbeat_ticks,
        .replicate => node.config.election_ticks,
    };
    if (node.rounds.ticks - oldest.sent_tick < age_max) return;

    p.on_timeout();
    assert(p.inflight_count == 0); // No live record is left: the window and records are one.
}

/// The index in `Rounds.records` of `slot`'s first record.
fn records_base(node: *const Node, slot: u32) usize {
    assert(slot < node.progress.len);
    const base = @as(usize, slot) * node.config.inflight_max;
    assert(base + node.config.inflight_max <= node.rounds.records.len);
    return base;
}

/// How many distinct voters other than this node the configuration has, in both sets.
fn peers_count(node: *const Node) u32 {
    const sets = &node.configuration;
    var count: u32 = 0;
    for (sets.voters) |peer| count += @intFromBool(peer != node.config.id);
    for (sets.voters_outgoing) |peer| count += @intFromBool(is_outgoing_peer(node, peer));
    assert(count <= sets.voters.len + sets.voters_outgoing.len);
    assert(count <= node.progress.len);
    return count;
}

/// Whether an outgoing-set voter is a peer not already counted in the incoming set.
fn is_outgoing_peer(node: *const Node, peer: NodeId) bool {
    assert(peer != .none);
    if (peer == node.config.id) return false;
    const incoming = election.contains(node.configuration.voters, peer);
    assert(node.progress.len > 0); // Every leader has slots; a counted peer lives in one.
    return !incoming;
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const election = @import("election.zig");
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");
const progress_module = @import("progress.zig");
const types = @import("../types.zig");

const AppendResponse = types.AppendResponse;
const Config = node_module.Config;
const Index = types.Index;
const InvariantError = node_module.InvariantError;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Progress = progress_module.Progress;
