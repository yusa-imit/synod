//! Red tests for `sim/crash_store.zig` (plan 004 item 5, ADR-008 "Crash store"), written from
//! the contract: durable vs live, the journal, `sync`, `crash(keep_count)` losing a suffix and
//! never a middle, `arm_failure` torn crashes, the `lose_synced_hard_state` plant, the shared
//! store conformance suite, `check_invariants`, leak freedom and a seeded model run.
//!
//! Choices where ADR-008 is silent (the implementation may argue, not drift silently):
//!   - One journal op per mutating call: a whole `append` batch is one op, so a crash keeps a
//!     batch entirely or not at all. `unsynced_count()` is the number of ops in the journal.
//!   - "A full journal flushes early" is lazy: `journal_ops_max` ops (and `journal_bytes_max`
//!     entry-data bytes) may be pending; the mutation that would exceed either first flushes
//!     the whole journal into `durable`, then is journaled itself. A mutation that fails
//!     (`StoreIoFailed`, `StoreFull`) flushes and journals nothing.
//!   - `arm_failure(n)` fires exactly once and then disarms. Only mutations and `sync` count as
//!     calls; reads (`last_index`, `get`, `load_*`) never consume it and never fail.
//!   - After `crash(k)` the kept ops are part of `durable` and the journal is empty
//!     (`unsynced_count() == 0`): a second `crash(0)` loses nothing more.
//!   - `lose_synced_hard_state`: at `crash`, before the kept ops are folded in, `durable`'s hard
//!     state reverts to the value it had before the last `save_hard_state` that `sync` (or an
//!     early flush) replayed into it; the revert is used up by one crash. With no such change
//!     the hard state reverts to `HardState.empty`. Entries are never affected by the plant.
//!   - `durable` and `live` are `pub` fields (tests corrupt them to provoke `check_invariants`).
//!   - `ReadError.StoreIoFailed` is never produced by this store (reads cannot fail).
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const interfaces = @import("../interfaces.zig");
const store_module = @import("../store.zig");
const types = @import("../types.zig");
const crash_store_module = @import("crash_store.zig");
const prng_module = @import("prng.zig");

const CrashStore = crash_store_module.CrashStore;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const Prng = prng_module.Prng;
const Term = types.Term;

const gpa = testing.allocator;

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn term(value: u64) Term {
    return @enumFromInt(value);
}

fn entry(index: u64, term_value: u64, data: []const u8) Entry {
    return .{ .index = idx(index), .term = term(term_value), .kind = .normal, .data = data };
}

/// A hard state: term, vote (a node id, 0 = none) and commit index.
fn hs(term_value: u64, vote: u64, commit: u64) HardState {
    return .{ .term = term(term_value), .vote = @enumFromInt(vote), .commit_index = idx(commit) };
}

const Params = struct {
    ops: u32 = 8,
    bytes: u32 = 64,
    entries: u32 = 16,
    data: u32 = 64,
    fault: CrashStore.Fault = .none,

    fn options(params: Params) CrashStore.Options {
        return .{
            .store = .{
                .entries_max = params.entries,
                .data_bytes_max = params.data,
                .snapshot_bytes_max = 32,
            },
            .journal_ops_max = params.ops,
            .journal_bytes_max = params.bytes,
            .fault = params.fault,
        };
    }
};

/// The one construction path; the caller runs `deinit(gpa)`.
fn make(target: *CrashStore, params: Params) !void {
    const options = params.options();
    try target.init(gpa, &options);
    try target.check_invariants();
}

/// The live log is exactly `expected` (indexes 1..), and the store is consistent.
fn expect_log(crash_store: *CrashStore, expected: []const Entry) !void {
    const log = crash_store.as_log_store();
    try testing.expectEqual(idx(expected.len), log.last_index());
    for (expected) |want| {
        const found = try log.get(want.index);
        try testing.expectEqual(want.index, found.index);
        try testing.expectEqual(want.term, found.term);
        try testing.expectEqualSlices(u8, want.data, found.data);
    }
    try crash_store.check_invariants();
}

fn expect_hard_state(crash_store: *CrashStore, expected: HardState) !void {
    const loaded = try crash_store.as_log_store().load_hard_state();
    try testing.expect(loaded.eql(&expected));
}

// ---- conformance ----------------------------------------------------------------------------

test "crash_store: passes the shared store conformance suite with a tiny journal" {
    const conformance = store_module.conformance;
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{
        .ops = 3, // Far fewer than the suite's mutations: early flushes happen mid-suite.
        .bytes = 128,
        .entries = conformance.entries_min,
        .data = conformance.data_bytes_min,
    });
    defer crash_store.deinit(gpa);
    try conformance.conformance(crash_store.as_log_store());
    try crash_store.check_invariants();
}

test "crash_store: a fresh store is empty, consistent and has nothing unsynced" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    try expect_log(&crash_store, &.{});
    try expect_hard_state(&crash_store, HardState.empty);
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    try testing.expect((try crash_store.as_log_store().load_snapshot()) == null);
}

// ---- sync and crash -------------------------------------------------------------------------

test "crash_store: synced writes survive a crash that keeps nothing" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    const state = hs(1, 2, 2);
    try log.append(&.{ entry(1, 1, "a"), entry(2, 1, "bc") });
    try log.save_hard_state(&state);
    try testing.expectEqual(@as(u32, 2), crash_store.unsynced_count());
    try log.sync();
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    crash_store.crash(0);
    try expect_log(&crash_store, &.{ entry(1, 1, "a"), entry(2, 1, "bc") });
    try expect_hard_state(&crash_store, state);
}

test "crash_store: unsynced writes vanish when the crash keeps none of them" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{entry(1, 1, "a")});
    try log.sync();
    const state = hs(2, 1, 1);
    try log.append(&.{entry(2, 2, "b")});
    try log.save_hard_state(&state);
    try expect_log(&crash_store, &.{ entry(1, 1, "a"), entry(2, 2, "b") }); // Live sees them.
    try expect_hard_state(&crash_store, state);
    try testing.expectEqual(@as(u32, 2), crash_store.unsynced_count());

    crash_store.crash(0);
    try expect_log(&crash_store, &.{entry(1, 1, "a")});
    try expect_hard_state(&crash_store, HardState.empty);
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
}

/// Four unsynced ops over a synced base `[1:a]`: append 2, append 3, truncate 3, append 3'.
fn expect_prefix_after(keep: u32, expected: []const Entry) !void {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{entry(1, 1, "a")});
    try log.sync();
    try log.append(&.{entry(2, 1, "b")});
    try log.append(&.{entry(3, 1, "c")});
    try log.truncate(idx(3));
    try log.append(&.{entry(3, 2, "x")});
    try testing.expectEqual(@as(u32, 4), crash_store.unsynced_count());
    crash_store.crash(keep);
    try expect_log(&crash_store, expected);
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
}

test "crash_store: a crash keeps a prefix of the unsynced ops, never a middle" {
    const a = entry(1, 1, "a");
    const b = entry(2, 1, "b");
    const c = entry(3, 1, "c");
    try expect_prefix_after(0, &.{a});
    try expect_prefix_after(1, &.{ a, b });
    try expect_prefix_after(2, &.{ a, b, c });
    try expect_prefix_after(3, &.{ a, b }); // The truncate is kept, the re-append is lost.
    try expect_prefix_after(4, &.{ a, b, entry(3, 2, "x") });
}

test "crash_store: a kept hard state brings the append it depends on, a lost one is empty" {
    const state = hs(1, 1, 1);
    for (0..4) |keep| {
        var crash_store: CrashStore = undefined;
        try make(&crash_store, .{});
        defer crash_store.deinit(gpa);
        const log = crash_store.as_log_store();
        try log.append(&.{entry(1, 1, "a")});
        try log.save_hard_state(&state);
        try log.append(&.{entry(2, 1, "b")});
        crash_store.crash(@intCast(keep));
        const all = [_]Entry{ entry(1, 1, "a"), entry(2, 1, "b") };
        const logged = [_]usize{ 0, 1, 1, 2 }; // Ops: append 1, hard state, append 2.
        try expect_log(&crash_store, all[0..logged[keep]]);
        try expect_hard_state(&crash_store, if (keep >= 2) state else HardState.empty);
    }
}

test "crash_store: after a crash the kept ops are durable and a second crash loses nothing" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{entry(1, 1, "a")});
    try log.append(&.{entry(2, 1, "b")});
    crash_store.crash(1);
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    crash_store.crash(0);
    try expect_log(&crash_store, &.{entry(1, 1, "a")});
    try log.append(&.{entry(2, 1, "z")}); // The store is usable again after a crash.
    try testing.expectEqual(@as(u32, 1), crash_store.unsynced_count());
}

test "crash_store: crashing an empty store keeps it empty, and a sync with nothing is a no-op" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    try crash_store.as_log_store().sync();
    crash_store.crash(0);
    try expect_log(&crash_store, &.{});
    try expect_hard_state(&crash_store, HardState.empty);
}

test "crash_store: the journal owns copies of what it was given" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    var buffer = [_]u8{ 'a', 'b' };
    try log.append(&.{entry(1, 1, &buffer)});
    buffer = .{ 'z', 'z' }; // The caller reuses its buffer before the sync.
    try log.sync();
    crash_store.crash(0);
    try expect_log(&crash_store, &.{entry(1, 1, "ab")});
}

// ---- journal limits -------------------------------------------------------------------------

test "crash_store: journal_ops_max ops stay unsynced and one more flushes the older ones" {
    var at_max: CrashStore = undefined;
    try make(&at_max, .{ .ops = 3 });
    defer at_max.deinit(gpa);
    for (1..4) |at| try at_max.as_log_store().append(&.{entry(at, 1, "")});
    try testing.expectEqual(@as(u32, 3), at_max.unsynced_count()); // Exactly max: all pending.
    at_max.crash(0);
    try expect_log(&at_max, &.{}); // Nothing was durable.

    var over: CrashStore = undefined;
    try make(&over, .{ .ops = 3 });
    defer over.deinit(gpa);
    for (1..5) |at| try over.as_log_store().append(&.{entry(at, 1, "")});
    try testing.expectEqual(@as(u32, 1), over.unsynced_count()); // Max + 1: flushed early.
    try over.check_invariants();
    over.crash(0);
    try expect_log(&over, &.{ entry(1, 1, ""), entry(2, 1, ""), entry(3, 1, "") });
}

test "crash_store: a journal of one op flushes the previous op at every mutation" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{ .ops = 1 });
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{entry(1, 1, "a")});
    try log.append(&.{entry(2, 1, "b")});
    try testing.expectEqual(@as(u32, 1), crash_store.unsynced_count());
    crash_store.crash(0);
    try expect_log(&crash_store, &.{entry(1, 1, "a")});
}

test "crash_store: journal_bytes_max counts entry bytes, equal fits and one over flushes" {
    var at_max: CrashStore = undefined;
    try make(&at_max, .{ .bytes = 4 });
    defer at_max.deinit(gpa);
    try at_max.as_log_store().append(&.{entry(1, 1, "abcd")}); // Exactly 4 bytes.
    try at_max.as_log_store().append(&.{entry(2, 1, "")}); // Zero bytes never flush.
    try testing.expectEqual(@as(u32, 2), at_max.unsynced_count());
    at_max.crash(0);
    try expect_log(&at_max, &.{});

    var over: CrashStore = undefined;
    try make(&over, .{ .bytes = 4 });
    defer over.deinit(gpa);
    try over.as_log_store().append(&.{entry(1, 1, "ab")});
    try over.as_log_store().append(&.{entry(2, 1, "cd")});
    try testing.expectEqual(@as(u32, 2), over.unsynced_count());
    try over.as_log_store().append(&.{entry(3, 1, "e")}); // 5 bytes would be pending.
    try testing.expectEqual(@as(u32, 1), over.unsynced_count());
    over.crash(0);
    try expect_log(&over, &.{ entry(1, 1, "ab"), entry(2, 1, "cd") });
}

// ---- StoreFull and the torn crash -----------------------------------------------------------

test "crash_store: StoreFull leaves live and the journal unchanged, at max and max plus one" {
    var by_count: CrashStore = undefined;
    try make(&by_count, .{ .entries = 2 });
    defer by_count.deinit(gpa);
    const log = by_count.as_log_store();
    try log.append(&.{ entry(1, 1, "a"), entry(2, 1, "b") }); // Exactly max.
    try testing.expectError(error.StoreFull, log.append(&.{entry(3, 1, "c")})); // Max + 1.
    try testing.expectEqual(@as(u32, 1), by_count.unsynced_count());
    try expect_log(&by_count, &.{ entry(1, 1, "a"), entry(2, 1, "b") });
    by_count.crash(1);
    try expect_log(&by_count, &.{ entry(1, 1, "a"), entry(2, 1, "b") });

    var by_bytes: CrashStore = undefined;
    try make(&by_bytes, .{ .data = 4 });
    defer by_bytes.deinit(gpa);
    const other = by_bytes.as_log_store();
    try other.append(&.{entry(1, 1, "abcd")}); // Exactly max.
    try testing.expectError(error.StoreFull, other.append(&.{entry(2, 1, "e")}));
    try testing.expectEqual(@as(u32, 1), by_bytes.unsynced_count());
    try expect_log(&by_bytes, &.{entry(1, 1, "abcd")});

    var batch: CrashStore = undefined;
    try make(&batch, .{ .entries = 2 });
    defer batch.deinit(gpa);
    const whole = batch.as_log_store();
    const three = [_]Entry{ entry(1, 1, "a"), entry(2, 1, "b"), entry(3, 1, "c") };
    try testing.expectError(error.StoreFull, whole.append(&three)); // A batch is all or none.
    try testing.expectEqual(@as(u32, 0), batch.unsynced_count());
    try expect_log(&batch, &.{});
}

const Kind = enum { append, truncate, save_hard_state };

fn mutate(log: LogStore, kind: Kind) !void {
    switch (kind) {
        .append => try log.append(&.{entry(2, 1, "b")}),
        .truncate => try log.truncate(idx(1)),
        .save_hard_state => try log.save_hard_state(&hs(1, 1, 1)),
    }
}

test "crash_store: arm_failure(0) fails the next mutation of each kind and mutates nothing" {
    for (std.enums.values(Kind)) |kind| {
        var crash_store: CrashStore = undefined;
        try make(&crash_store, .{});
        defer crash_store.deinit(gpa);
        const log = crash_store.as_log_store();
        try log.append(&.{entry(1, 1, "a")});
        try log.sync();
        crash_store.arm_failure(0);
        try testing.expectError(error.StoreIoFailed, mutate(log, kind));
        try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
        try expect_log(&crash_store, &.{entry(1, 1, "a")});
        try expect_hard_state(&crash_store, HardState.empty);

        try mutate(log, kind); // It fired once: the retry goes through.
        try testing.expectEqual(@as(u32, 1), crash_store.unsynced_count());
        try crash_store.check_invariants();
    }
}

test "crash_store: arm_failure(n) skips n calls, counting mutations and syncs but not reads" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    crash_store.arm_failure(2);
    try log.append(&.{entry(1, 1, "a")}); // Call 0.
    _ = log.last_index(); // Reads are not calls.
    _ = try log.get(idx(1));
    _ = try log.load_hard_state();
    _ = try log.load_snapshot();
    try log.sync(); // Call 1.
    try testing.expectError(error.StoreIoFailed, log.append(&.{entry(2, 1, "b")})); // Call 2.
    try expect_log(&crash_store, &.{entry(1, 1, "a")});
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
}

test "crash_store: a failed sync mutates nothing, loses the journal on crash, and can retry" {
    var lost: CrashStore = undefined;
    try make(&lost, .{});
    defer lost.deinit(gpa);
    try lost.as_log_store().append(&.{entry(1, 1, "a")});
    lost.arm_failure(0);
    try testing.expectError(error.StoreIoFailed, lost.as_log_store().sync());
    try testing.expectEqual(@as(u32, 1), lost.unsynced_count()); // Still pending.
    try expect_log(&lost, &.{entry(1, 1, "a")}); // Live is unchanged.
    lost.crash(0); // The torn crash: the driver died mid-step, nothing was durable.
    try expect_log(&lost, &.{});

    var retried: CrashStore = undefined;
    try make(&retried, .{});
    defer retried.deinit(gpa);
    try retried.as_log_store().append(&.{entry(1, 1, "a")});
    retried.arm_failure(0);
    try testing.expectError(error.StoreIoFailed, retried.as_log_store().sync());
    try retried.as_log_store().sync(); // Fired once: the retry makes it durable.
    try testing.expectEqual(@as(u32, 0), retried.unsynced_count());
    retried.crash(0);
    try expect_log(&retried, &.{entry(1, 1, "a")});
}

test "crash_store: a crash disarms a pending failure, and a huge count never fires" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{ .ops = 4 });
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    crash_store.arm_failure(3);
    try log.append(&.{entry(1, 1, "a")});
    crash_store.crash(1);
    for (2..8) |at| { // Six calls: with the failure still armed the fourth would have failed.
        try log.append(&.{entry(at, 1, "")});
        try log.sync();
    }
    crash_store.arm_failure(std.math.maxInt(u32));
    for (8..16) |at| try log.append(&.{entry(at, 1, "")}); // Never fires; inside entries_max.
    try crash_store.check_invariants();
}

// ---- the lose_synced_hard_state plant -------------------------------------------------------

/// Two synced hard states (term 1 vote 1, then term 2 vote 2), then `crash(0)`.
fn synced_twice_then_crash(fault: CrashStore.Fault, crash_store: *CrashStore) !void {
    try make(crash_store, .{ .fault = fault });
    const log = crash_store.as_log_store();
    try log.save_hard_state(&hs(1, 1, 0));
    try log.sync();
    try log.save_hard_state(&hs(2, 2, 0));
    try log.sync();
    crash_store.crash(0);
}

test "crash_store: the honest store keeps the last synced hard state across a crash" {
    var crash_store: CrashStore = undefined;
    try synced_twice_then_crash(.none, &crash_store);
    defer crash_store.deinit(gpa);
    try expect_hard_state(&crash_store, hs(2, 2, 0));
}

test "crash_store: lose_synced_hard_state reverts to the value before the last synced change" {
    var crash_store: CrashStore = undefined;
    try synced_twice_then_crash(.lose_synced_hard_state, &crash_store);
    defer crash_store.deinit(gpa);
    try expect_hard_state(&crash_store, hs(1, 1, 0)); // The vote in term 2 is forgotten.

    crash_store.crash(0); // The revert is used up: a second crash changes nothing.
    try expect_hard_state(&crash_store, hs(1, 1, 0));
    try crash_store.check_invariants();
}

test "crash_store: lose_synced_hard_state with one synced change forgets everything" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{ .fault = .lose_synced_hard_state });
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.save_hard_state(&hs(1, 3, 0));
    try log.sync();
    crash_store.crash(0);
    try expect_hard_state(&crash_store, HardState.empty);
}

test "crash_store: lose_synced_hard_state never touches the synced entries" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{ .fault = .lose_synced_hard_state });
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{ entry(1, 1, "a"), entry(2, 1, "b") });
    try log.save_hard_state(&hs(1, 1, 2));
    try log.sync();
    crash_store.crash(0);
    try expect_log(&crash_store, &.{ entry(1, 1, "a"), entry(2, 1, "b") });
    try expect_hard_state(&crash_store, HardState.empty); // The commit is lost with the vote.
}

// ---- check_invariants -----------------------------------------------------------------------

test "crash_store: check_invariants names a live store that diverged from durable plus journal" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    try log.append(&.{entry(1, 1, "a")});
    try log.sync();
    try log.save_hard_state(&hs(1, 1, 1));
    try crash_store.check_invariants();

    const saved = crash_store.live.hard_state;
    crash_store.live.hard_state.term = term(7); // Live moved without the journal knowing.
    try testing.expectError(error.CrashStoreDiverged, crash_store.check_invariants());
    crash_store.live.hard_state = saved;
    try crash_store.check_invariants();

    crash_store.live.entries[0].term = term(9); // An entry changed behind the journal's back.
    try testing.expectError(error.CrashStoreDiverged, crash_store.check_invariants());
    crash_store.live.entries[0].term = term(1);
    try crash_store.check_invariants();
}

test "crash_store: check_invariants surfaces the underlying store's invariant errors" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    crash_store.live.base_index = idx(3); // A base without a snapshot record.
    try testing.expectError(error.SnapshotMissing, crash_store.check_invariants());
    crash_store.live.base_index = .zero;
    try crash_store.check_invariants();

    crash_store.durable.base_index = idx(3);
    try testing.expectError(error.SnapshotMissing, crash_store.check_invariants());
    crash_store.durable.base_index = .zero;
    try crash_store.check_invariants();
}

test "crash_store: a persisted commit beyond the log reads back as StoreCorrupt" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{});
    defer crash_store.deinit(gpa);
    crash_store.live.hard_state = hs(1, 1, 5); // Bytes the node never wrote through the API.
    try testing.expectError(error.StoreCorrupt, crash_store.as_log_store().load_hard_state());
}

// ---- allocation -----------------------------------------------------------------------------

fn init_then_deinit(allocator: Allocator) !void {
    const options = (Params{}).options();
    var crash_store: CrashStore = undefined;
    try crash_store.init(allocator, &options);
    crash_store.deinit(allocator);
}

test "crash_store: init fails cleanly at every allocation index and leaks nothing" {
    try testing.checkAllAllocationFailures(gpa, init_then_deinit, .{});
}

test "crash_store: no method allocates after init, even with an allocator that now fails" {
    const options = (Params{ .ops = 2 }).options();
    var counting = testing.FailingAllocator.init(gpa, .{});
    var crash_store: CrashStore = undefined;
    try crash_store.init(counting.allocator(), &options);
    defer crash_store.deinit(counting.allocator());
    const allocs = counting.alloc_index;
    const bytes = counting.allocated_bytes;

    const log = crash_store.as_log_store();
    for (1..6) |at| { // More ops than the journal holds: early flushes allocate nothing either.
        try log.append(&.{entry(at, 1, "xy")});
        try log.save_hard_state(&hs(1, 1, at));
    }
    crash_store.arm_failure(0);
    try testing.expectError(error.StoreIoFailed, log.sync());
    try log.sync();
    crash_store.crash(0);
    try crash_store.check_invariants();
    try testing.expectEqual(allocs, counting.alloc_index);
    try testing.expectEqual(bytes, counting.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counting.resize_index);
}

// ---- seeded model run -----------------------------------------------------------------------

const model_ops = 5;
const model_bytes = 6;
const model_cap = 40;
const model_steps = 250;
const model_seeds = 64;

/// The reference log: terms and one data byte per entry, plus the hard state.
const Log = struct {
    len: u32 = 0,
    terms: [model_cap + 3]u64 = @splat(0),
    bytes: [model_cap + 3]u8 = @splat(0),
    hard_state: HardState = HardState.empty,
};

const Op = union(enum) {
    append: struct { len: u8, terms: [3]u64, bytes: [3]u8 },
    truncate: u32, // The first index dropped.
    hard_state: HardState,

    fn apply(op: Op, log: *Log) void {
        switch (op) {
            .append => |batch| for (0..batch.len) |at| {
                log.terms[log.len] = batch.terms[at];
                log.bytes[log.len] = batch.bytes[at];
                log.len += 1;
            },
            .truncate => |from| log.len = from - 1,
            .hard_state => |state| log.hard_state = state,
        }
    }

    fn data_bytes(op: Op) u32 {
        return switch (op) {
            .append => |batch| batch.len,
            .truncate, .hard_state => 0,
        };
    }
};

/// The trivial model of `CrashStore`: a durable log, a journal, a failure countdown.
const Model = struct {
    durable: Log = .{},
    journal: [model_ops]Op = undefined,
    journal_len: u32 = 0,
    journal_bytes: u32 = 0,
    armed: ?u32 = null,
    early_flushes: u32 = 0,
    lossy_crashes: u32 = 0,
    failures: u32 = 0,

    fn live(model: *const Model) Log {
        var log = model.durable;
        for (model.journal[0..model.journal_len]) |op| op.apply(&log);
        return log;
    }

    fn flush(model: *Model) void {
        for (model.journal[0..model.journal_len]) |op| op.apply(&model.durable);
        model.journal_len = 0;
        model.journal_bytes = 0;
    }

    /// One mutation or sync call: true when the armed failure fires on it.
    fn call_fails(model: *Model) bool {
        const left = model.armed orelse return false;
        if (left > 0) {
            model.armed = left - 1;
            return false;
        }
        model.armed = null;
        model.failures += 1;
        return true;
    }

    fn mutate(model: *Model, op: Op) void {
        const full = model.journal_len == model_ops or
            model.journal_bytes + op.data_bytes() > model_bytes;
        if (full) {
            model.flush();
            model.early_flushes += 1;
        }
        model.journal[model.journal_len] = op;
        model.journal_len += 1;
        model.journal_bytes += op.data_bytes();
    }

    fn crash(model: *Model, keep: u32) void {
        if (keep < model.journal_len) model.lossy_crashes += 1;
        for (model.journal[0..keep]) |op| op.apply(&model.durable);
        model.journal_len = 0;
        model.journal_bytes = 0;
        model.armed = null;
    }
};

fn expect_agrees(model: *const Model, crash_store: *CrashStore) !void {
    const want = model.live();
    const log = crash_store.as_log_store();
    try testing.expectEqual(idx(want.len), log.last_index());
    for (0..want.len) |at| {
        const found = try log.get(idx(at + 1));
        try testing.expectEqual(term(want.terms[at]), found.term);
        try testing.expectEqualSlices(u8, &.{want.bytes[at]}, found.data);
    }
    try expect_hard_state(crash_store, want.hard_state);
    try testing.expectEqual(model.journal_len, crash_store.unsynced_count());
    try crash_store.check_invariants();
}

/// Draws the next mutation against the model's live log; `truncate` never goes below commit.
fn draw_op(prng: *Prng, live: *const Log) Op {
    const roll = prng.uint_less_than(100);
    if (roll < 45 and live.len + 3 <= model_cap) {
        const len: u8 = @intCast(1 + prng.uint_less_than(3));
        var batch: Op = .{ .append = .{ .len = len, .terms = @splat(0), .bytes = @splat(0) } };
        var floor: u64 = if (live.len == 0) 1 else live.terms[live.len - 1];
        for (0..len) |at| {
            if (prng.chance(30)) floor += 1;
            batch.append.terms[at] = floor;
            batch.append.bytes[at] = 'a' + @as(u8, @intCast(prng.uint_less_than(26)));
        }
        return batch;
    }
    const commit: u64 = @intFromEnum(live.hard_state.commit_index);
    if (roll < 70 or live.len + 3 > model_cap) {
        const span = live.len + 1 - commit; // Candidates commit + 1 ..= len + 1.
        return .{ .truncate = @intCast(commit + 1 + prng.uint_less_than(span)) };
    }
    const upper = live.len - commit + 1;
    return .{ .hard_state = hs(
        1 + prng.uint_less_than(5),
        prng.uint_less_than(4),
        commit + prng.uint_less_than(upper),
    ) };
}

fn apply_to_store(log: LogStore, op: Op) LogStore.WriteError!void {
    switch (op) {
        .append => |batch| {
            const first: u64 = @intFromEnum(log.last_index()) + 1;
            var entries: [3]Entry = undefined;
            for (0..batch.len) |at| {
                entries[at] = entry(first + at, batch.terms[at], batch.bytes[at..][0..1]);
            }
            try log.append(entries[0..batch.len]);
        },
        .truncate => |from| try log.truncate(idx(from)),
        .hard_state => |state| try log.save_hard_state(&state),
    }
}

fn run_model_seed(seed: u64, totals: *Model) !void {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .{
        .ops = model_ops,
        .bytes = model_bytes,
        .entries = model_cap + 3,
        .data = 256,
    });
    defer crash_store.deinit(gpa);
    const log = crash_store.as_log_store();
    var model: Model = .{};
    var prng = Prng.init(seed);
    for (0..model_steps) |_| {
        const roll = prng.uint_less_than(100);
        if (roll < 70) {
            const live = model.live();
            const op = draw_op(&prng, &live);
            const outcome = apply_to_store(log, op);
            if (model.call_fails()) {
                try testing.expectError(error.StoreIoFailed, outcome);
            } else {
                try outcome;
                model.mutate(op);
            }
        } else if (roll < 82) {
            const outcome = log.sync();
            if (model.call_fails()) {
                try testing.expectError(error.StoreIoFailed, outcome);
            } else {
                try outcome;
                model.flush();
            }
        } else if (roll < 92) {
            const keep: u32 = @intCast(prng.uint_less_than(model.journal_len + 1));
            crash_store.crash(keep);
            model.crash(keep);
        } else {
            const calls: u32 = @intCast(prng.uint_less_than(4));
            crash_store.arm_failure(calls);
            model.armed = calls;
        }
        try expect_agrees(&model, &crash_store);
    }
    totals.early_flushes += model.early_flushes;
    totals.lossy_crashes += model.lossy_crashes;
    totals.failures += model.failures;
}

test "crash_store: seeded model run agrees with the reference after every step" {
    var totals: Model = .{};
    for (0..model_seeds) |seed| try run_model_seed(seed, &totals);
    // Vacuity floors: the run really flushed early, lost writes and fired torn failures.
    try testing.expect(totals.early_flushes >= 200);
    try testing.expect(totals.lossy_crashes >= 200);
    try testing.expect(totals.failures >= 200);
}
