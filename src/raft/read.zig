//! synod.raft.read — ReadIndex (thesis §6.4; plan 005 item 9, ADR-009 "ReadIndex"), as free
//! functions over a `*Node`. `Node` owns `reads` (a `Storage`); this file owns the rules.
//!
//! A read is `{ctx, index = commit, round_min = rounds.id_next}` at registration. Every
//! `append_entries_response` at our term raises its slot's `acked` round; the read is confirmed
//! when the voters with `acked >= round_min`, plus self, form a joint-aware quorum under the
//! configuration at check time (`emit`). `round_min` never decreases, so the confirmed reads are
//! a FIFO prefix. A step-down fails every pending read (`fail_all`, from `leader.reset`).
//!
//! Layout the tests pin:
//!   - `Storage.pending[0..len]` are the reads in registration order, each `{read, round_min}`;
//!     `read.index` is the commit index at registration, `round_min` is `rounds.id_next` then.
//!   - `Storage.acked[slot]` is the highest round echoed by progress slot `slot` at our term.
//!   - `Storage.out` holds `2 * reads_max` reads: the ready prefix at `out[0..]` and the failed
//!     reads of a step at `out[reads_max..]`; the effects borrow them until the next step.
//!
//! Invariants: `len <= reads_max`; reads exist only while leading; indexes and round minimums are
//! non-decreasing, no index is above the commit index and no minimum above `rounds.id_next`.
//! `check_invariants` states them.
//!
//! Allocation: `Storage.init` allocates once, from `Node.init`; nothing here allocates later.
//! Cost sketch: `emit` is O(pending * peers) per step, both bounded by `reads_max` and
//! `2 * voters_max + learners_max`; a step with no pending read costs a compare.

/// A registered read and the first heartbeat round whose acks may confirm it.
pub const Pending = struct {
    read: Read,
    round_min: u64,
};

/// The allocations of the read side, made once in `Node.init`.
pub const Storage = struct {
    /// `reads_max` slots; `pending[0..len]` is live, oldest first.
    pending: []Pending,
    /// `2 * reads_max` slots: the emitted `read_ready` prefix and `read_failed` reads.
    out: []Read,
    /// One highest-acked round per progress slot (`node_init.progress_capacity`).
    acked: []u64,
    len: u32,
    /// Reads failed in this step and not yet emitted, at `out[reads_max..][0..failed]`.
    failed: u32,

    pub const empty: Storage = .{
        .pending = &.{},
        .out = &.{},
        .acked = &.{},
        .len = 0,
        .failed = 0,
    };

    pub fn init(gpa: Allocator, config: *const Config) Allocator.Error!Storage {
        assert(config.reads_max >= 1);
        const pending = try gpa.alloc(Pending, config.reads_max);
        errdefer gpa.free(pending);

        const out = try gpa.alloc(Read, 2 * @as(usize, config.reads_max));
        errdefer gpa.free(out);

        const acked = try gpa.alloc(u64, node_init.progress_capacity(config));
        errdefer gpa.free(acked);

        const none: Read = .{ .ctx = 0, .index = .zero };
        @memset(pending, .{ .read = none, .round_min = 0 });
        @memset(out, none);
        @memset(acked, 0);
        return .{ .pending = pending, .out = out, .acked = acked, .len = 0, .failed = 0 };
    }

    pub fn deinit(storage: *const Storage, gpa: Allocator) void {
        assert(storage.pending.len > 0);
        assert(storage.out.len == 2 * storage.pending.len);
        gpa.free(storage.acked);
        gpa.free(storage.out);
        gpa.free(storage.pending);
    }
};

/// A new leader's first act: no peer has acked anything yet. Preconditions: the node just became
/// leader and holds no read.
pub fn leader_start(node: *Node) void {
    assert(node.role == .leader);
    assert(node.reads.len == 0);
    assert(node.reads.failed == 0);
    @memset(node.reads.acked, 0);
}

/// `Input.read_index`: records `{ctx, index = commit, round_min = rounds.id_next}`.
/// Errors, before any mutation: `ReadIndexNotLeader`; `ReadIndexNotReady` until the entry at
/// the commit index has our term; `ReadIndexFull` at `reads_max`.
pub fn register(node: *Node, ctx: u64) ReadIndexError!void {
    const storage = &node.reads;
    assert(storage.len <= storage.pending.len);
    assert(node.progress_len <= storage.acked.len);

    if (node.role != .leader) return error.ReadIndexNotLeader;
    const commit_term = node.log.term_at(node.commit_index) catch |err| switch (err) {
        // The commit index is never below the log base, so this is unreachable; refusing is safe.
        error.LogCompacted => return error.ReadIndexNotReady,
    };
    if (commit_term != node.term) return error.ReadIndexNotReady;
    if (storage.len == storage.pending.len) return error.ReadIndexFull;

    node.effects_len = 0; // A step starts empty; a refused read above leaves the last one alone.
    storage.pending[storage.len] = .{
        .read = .{ .ctx = ctx, .index = node.commit_index },
        .round_min = node.rounds.id_next,
    };
    storage.len += 1;
    assert(storage.len <= storage.pending.len);
}

/// An `append_entries_response` at our term from voter slot `slot`, accepted or rejected, live
/// round or not, echoed `round`: raises `acked[slot]` (never lowers it).
pub fn ack(node: *Node, slot: u32, round: u64) void {
    assert(node.role == .leader);
    assert(slot < node.progress_len);
    assert(slot < node.reads.acked.len);

    const held = &node.reads.acked[slot];
    held.* = @max(held.*, round);
    assert(held.* >= round);
}

/// A step-down: every pending read moves to the failed part of `out`, `len` becomes zero, and
/// the next `emit` reports them as `read_failed`.
pub fn fail_all(node: *Node) void {
    const storage = &node.reads;
    const reads_max: u32 = @intCast(storage.pending.len);
    assert(storage.len + storage.failed <= reads_max);

    const failed = storage.out[reads_max..][storage.failed..];
    for (storage.pending[0..storage.len], 0..) |held, at| failed[at] = held.read;
    storage.failed += storage.len;
    storage.len = 0;
    assert(storage.failed <= reads_max);
}

/// Step end, after `apply_ready`: emits `read_ready` for the FIFO prefix confirmed by a
/// joint-aware quorum of `acked >= round_min` voters plus self, then `read_failed`.
pub fn emit(node: *Node) void {
    const storage = &node.reads;
    assert(storage.len <= storage.pending.len);
    assert(storage.len == 0 or node.role == .leader);

    const reads_max: u32 = @intCast(storage.pending.len);
    var ready: u32 = 0;
    while (ready < storage.len) : (ready += 1) {
        if (!confirmed(node, storage.pending[ready].round_min)) break;
        storage.out[ready] = storage.pending[ready].read;
    }
    if (ready > 0) {
        @memmove(storage.pending[0 .. storage.len - ready], storage.pending[ready..storage.len]);
        storage.len -= ready;
        node.emit(.{ .read_ready = storage.out[0..ready] });
    }
    if (storage.failed > 0) {
        node.emit(.{ .read_failed = storage.out[reads_max..][0..storage.failed] });
        storage.failed = 0;
    }
    assert(storage.failed == 0);
}

/// Whether the voters that acked a round at or after `round_min`, plus self, are a quorum.
fn confirmed(node: *const Node, round_min: u64) bool {
    assert(round_min >= 1);
    assert(node.progress_len < membership.conf_ids_max);

    var ids: [membership.conf_ids_max]NodeId = undefined;
    ids[0] = node.config.id;
    var count: u32 = 1;
    for (node.peers[0..node.progress_len], node.reads.acked[0..node.progress_len]) |peer, round| {
        if (round < round_min) continue;
        ids[count] = peer;
        count += 1;
    }
    assert(count <= node.progress_len + 1);
    return membership.quorum_reached(&node.configuration, ids[0..count]);
}

/// `InvariantReadOrder`: reads while not leading, more than `reads_max`, an index over the
/// commit index, or indexes or round minimums out of order.
pub fn check_invariants(node: *const Node) InvariantError!void {
    const storage = &node.reads;
    assert(storage.pending.len > 0);
    assert(storage.failed == 0); // Emitted at the end of every step.

    if (storage.len > storage.pending.len) return error.InvariantReadOrder;
    if (storage.len > 0 and node.role != .leader) return error.InvariantReadOrder;
    var index_before: Index = .zero;
    var round_before: u64 = 0;
    for (storage.pending[0..storage.len]) |held| {
        if (held.read.index.order(index_before) == .lt) return error.InvariantReadOrder;
        if (held.read.index.order(node.commit_index) == .gt) return error.InvariantReadOrder;
        if (held.round_min < round_before) return error.InvariantReadOrder;
        if (held.round_min > node.rounds.id_next) return error.InvariantReadOrder;
        index_before = held.read.index;
        round_before = held.round_min;
    }
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const membership = @import("membership.zig");
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const Config = node_module.Config;
const Index = types.Index;
const InvariantError = node_module.InvariantError;
const Node = node_module.Node;
const NodeId = types.NodeId;
const Read = node_module.Read;
const ReadIndexError = node_module.ReadIndexError;
