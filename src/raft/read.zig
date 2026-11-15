//! synod.raft.read — ReadIndex (thesis §6.4; plan 005 item 9, ADR-009 "ReadIndex"), as free
//! functions over a `*Node`. `Node` owns `reads` (a `Storage`); this file owns the rules.
//!
//! STATUS: Red scaffolding. `Storage` allocates and frees; `register` refuses every read with
//! `ReadIndexFull`; `ack`, `fail_all` and `emit` do nothing; `check_invariants` accepts every
//! state. The tests in `read_test.zig`, `node_read_test.zig` and `driver_read_test.zig` fail
//! until the developer replaces these bodies.
//!
//! Contract the tests pin (the names are the seam between tests and implementation):
//!   - `Storage.pending[0..len]` are the reads in registration order, each `{read, round_min}`;
//!     `read.index` is the commit index at registration, `round_min` is `rounds.id_next` then.
//!   - `Storage.acked[slot]` is the highest round echoed by progress slot `slot` at our term.
//!   - `Storage.out` holds `2 * reads_max` reads: the ready prefix and the failed reads of a step.
//!
//! Allocation: `Storage.init` allocates once, from `Node.init`; nothing here allocates later.

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

    pub const empty: Storage = .{ .pending = &.{}, .out = &.{}, .acked = &.{}, .len = 0 };

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
        return .{ .pending = pending, .out = out, .acked = acked, .len = 0 };
    }

    pub fn deinit(storage: *const Storage, gpa: Allocator) void {
        assert(storage.pending.len > 0);
        gpa.free(storage.acked);
        gpa.free(storage.out);
        gpa.free(storage.pending);
    }
};

/// `Input.read_index`: records `{ctx, index = commit, round_min = rounds.id_next}`.
/// Errors, before any mutation: `ReadIndexNotLeader`; `ReadIndexNotReady` until the entry at
/// the commit index has our term; `ReadIndexFull` at `reads_max`.
/// Red stub: refuses every read.
pub fn register(node: *Node, ctx: u64) ReadIndexError!void {
    _ = node;
    _ = ctx;
    return error.ReadIndexFull;
}

/// An `append_entries_response` at our term from voter slot `slot`, accepted or rejected, live
/// round or not, echoed `round`: raises `acked[slot]` (never lowers it). Red stub: nothing.
pub fn ack(node: *Node, slot: u32, round: u64) void {
    _ = node;
    _ = slot;
    _ = round;
}

/// A step-down: every pending read moves to the failed part of `out`, `len` becomes zero, and
/// the next `emit` reports them as `read_failed`. Red stub: nothing.
pub fn fail_all(node: *Node) void {
    _ = node;
}

/// Step end, after `apply_ready`: emits `read_ready` for the FIFO prefix confirmed by a
/// joint-aware quorum of `acked >= round_min` voters plus self, then `read_failed`. Red stub:
/// nothing.
pub fn emit(node: *Node) void {
    _ = node;
}

/// `InvariantReadOrder`: reads while not leading, more than `reads_max`, an index over the
/// commit index, or indexes or round minimums out of order. Red stub: accepts everything.
pub fn check_invariants(node: *const Node) InvariantError!void {
    _ = node;
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const node_init = @import("node_init.zig");
const node_module = @import("node.zig");

const Config = node_module.Config;
const InvariantError = node_module.InvariantError;
const Node = node_module.Node;
const Read = node_module.Read;
const ReadIndexError = node_module.ReadIndexError;
