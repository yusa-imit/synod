//! Red tests for `CrashStore` and snapshots (plan 005 item 6, ADR-009 "Simulator"):
//! `save_snapshot` is journalled like every other mutation, so an unsynced snapshot is lost by
//! a crash that keeps none of the unsynced ops, a synced one survives, and `crash` no longer
//! asserts that no snapshot exists. Written from the contract, modelled on the entry and
//! hard-state loss tests of `crash_store_test.zig`.
//!
//! Choices where ADR-009 is silent (the implementation may argue, not drift silently):
//!   - One journal op per `save_snapshot`, in call order with appends and hard states, so
//!     `unsynced_count()` counts it and `crash(keep)` keeps a prefix that may include it.
//!   - The journal owns a copy of the snapshot bytes and configuration: mutating the caller's
//!     buffer after the call changes nothing a crash keeps (ADR-009: "one journalled copy").
//!   - "Torn caught by crc32": a torn crash (`arm_failure` then `crash(keep)`) keeps a prefix
//!     of whole ops, so a snapshot is kept whole or not at all; bytes damaged below the store
//!     are the state machine's crc32 to catch (see `workload_snapshot_test.zig`).
//!   - A snapshot save that fails (`StoreIoFailed`, `StoreFull`) journals nothing and changes
//!     nothing; `lose_synced_hard_state` never touches a synced snapshot.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const crash_store_module = @import("crash_store.zig");

const CrashStore = crash_store_module.CrashStore;
const Configuration = types.Configuration;
const Entry = types.Entry;
const Index = types.Index;
const Snapshot = types.Snapshot;

const gpa = testing.allocator;
const Prng = @import("prng.zig").Prng;

const voters = [_]types.NodeId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
const configuration: Configuration = .{
    .voters = &voters,
    .voters_outgoing = &.{},
    .learners = &.{},
};

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn entry(index: u64) Entry {
    return .{ .index = idx(index), .term = @enumFromInt(1), .kind = .normal, .data = "e" };
}

fn snapshot_at(index: u64, data: []const u8) Snapshot {
    return .{ .index = idx(index), .term = @enumFromInt(1), .data = data };
}

fn make(target: *CrashStore, fault: CrashStore.Fault) !void {
    const options: CrashStore.Options = .{
        .store = .{ .entries_max = 64, .data_bytes_max = 256, .snapshot_bytes_max = 16 },
        .journal_ops_max = 8,
        .journal_bytes_max = 256,
        .fault = fault,
    };
    try target.init(gpa, &options);
    try target.check_invariants();
}

/// Appends entries 1..count (one op each) and syncs them.
fn fill(crash_store: *CrashStore, count: u64) !void {
    for (1..count + 1) |index| try crash_store.append(&.{entry(index)});
    try crash_store.sync();
}

/// `crash(keep)` after proving `keep` ops are unsynced (the contract's caller precondition).
fn crash_keeping(crash_store: *CrashStore, keep: u32) !void {
    try testing.expect(crash_store.unsynced_count() >= keep);
    crash_store.crash(keep);
}

fn expect_snapshot(crash_store: *CrashStore, index: u64, data: []const u8) !void {
    const record = (try crash_store.load_snapshot()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(idx(index), record.snapshot.index);
    try testing.expectEqualSlices(u8, data, record.snapshot.data);
    try testing.expectEqualSlices(types.NodeId, &voters, record.configuration.voters);
    try crash_store.check_invariants();
}

fn expect_no_snapshot(crash_store: *CrashStore) !void {
    try testing.expect((try crash_store.load_snapshot()) == null);
    try crash_store.check_invariants();
}

// ---- synced and unsynced ---------------------------------------------------------------------

test "crash_store snapshot: a synced snapshot survives a crash that keeps nothing" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    try crash_store.save_snapshot(&snapshot_at(3, "snap-3"), &configuration);
    try crash_store.sync();
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    crash_store.crash(0);
    try expect_snapshot(&crash_store, 3, "snap-3");
    try testing.expectEqual(idx(4), crash_store.last_index());
    try testing.expectEqual(idx(4), (try crash_store.get(idx(4))).index);
}

test "crash_store snapshot: an unsynced snapshot is one journal op, lost by crash(0)" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    try crash_store.save_snapshot(&snapshot_at(3, "snap-3"), &configuration);
    try testing.expectEqual(@as(u32, 1), crash_store.unsynced_count());
    try expect_snapshot(&crash_store, 3, "snap-3"); // the node sees it at once
    crash_store.crash(0);
    try expect_no_snapshot(&crash_store);
    try testing.expectEqual(idx(4), crash_store.last_index());
    try testing.expectEqual(idx(1), (try crash_store.get(idx(1))).index); // the log is whole
}

test "crash_store snapshot: a crash that keeps the snapshot op keeps it whole" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    try crash_store.save_snapshot(&snapshot_at(3, "snap-3"), &configuration);
    try crash_keeping(&crash_store, 1);
    try expect_snapshot(&crash_store, 3, "snap-3");
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    crash_store.crash(0); // now durable: a second crash loses nothing more
    try expect_snapshot(&crash_store, 3, "snap-3");
}

test "crash_store snapshot: the kept prefix is in call order, an append before a snapshot" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 3);
    try crash_store.append(&.{entry(4)});
    try crash_store.save_snapshot(&snapshot_at(4, "snap-4"), &configuration);
    try testing.expectEqual(@as(u32, 2), crash_store.unsynced_count());
    try crash_keeping(&crash_store, 1); // the append only
    try expect_no_snapshot(&crash_store);
    try testing.expectEqual(idx(4), crash_store.last_index());
}

test "crash_store snapshot: an older synced snapshot outlives a newer unsynced one" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 6);
    try crash_store.save_snapshot(&snapshot_at(2, "old"), &configuration);
    try crash_store.sync();
    try crash_store.save_snapshot(&snapshot_at(5, "new"), &configuration);
    try expect_snapshot(&crash_store, 5, "new");
    crash_store.crash(0);
    try expect_snapshot(&crash_store, 2, "old");
    try testing.expectEqual(idx(6), crash_store.last_index());
    try testing.expectEqual(idx(3), (try crash_store.get(idx(3))).index);
}

test "crash_store snapshot: the journal owns its copy of the snapshot bytes" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    var bytes = [_]u8{ 'a', 'b', 'c', 'd' };
    try crash_store.save_snapshot(&snapshot_at(3, &bytes), &configuration);
    @memset(&bytes, 'z');
    try crash_keeping(&crash_store, 1);
    try expect_snapshot(&crash_store, 3, "abcd");
}

test "crash_store snapshot: a snapshot over every journal flush point still reaches durable" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 12);
    try crash_store.save_snapshot(&snapshot_at(2, "s"), &configuration);
    for (13..13 + 8) |index| try crash_store.append(&.{entry(index)}); // 8 more ops: flushes
    try testing.expect(crash_store.unsynced_count() <= 8);
    crash_store.crash(0);
    try expect_snapshot(&crash_store, 2, "s"); // an early flush made it durable (ADR-006)
}

// ---- negative space --------------------------------------------------------------------------

test "crash_store snapshot: a failed save journals nothing and a crash keeps nothing of it" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    crash_store.arm_failure(0);
    try testing.expectError(
        error.StoreIoFailed,
        crash_store.save_snapshot(&snapshot_at(3, "x"), &configuration),
    );
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    try expect_no_snapshot(&crash_store);
    crash_store.crash(0);
    try expect_no_snapshot(&crash_store);
    try testing.expectEqual(idx(4), crash_store.last_index());
}

test "crash_store snapshot: data at snapshot_bytes_max fits and one byte over is StoreFull" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    const over: [17]u8 = @splat('o');
    try testing.expectError(
        error.StoreFull,
        crash_store.save_snapshot(&snapshot_at(3, &over), &configuration),
    );
    try testing.expectEqual(@as(u32, 0), crash_store.unsynced_count());
    try expect_no_snapshot(&crash_store);
    try crash_store.save_snapshot(&snapshot_at(3, over[0..16]), &configuration);
    try testing.expectEqual(@as(u32, 1), crash_store.unsynced_count());
    try crash_store.check_invariants();
}

test "crash_store snapshot: a torn crash keeps whole ops, so no half a snapshot exists" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .none);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    try crash_store.save_snapshot(&snapshot_at(3, "snap-3"), &configuration);
    crash_store.arm_failure(0); // the next call (the sync) is the torn write
    try testing.expectError(error.StoreIoFailed, crash_store.sync());
    crash_store.crash(0);
    try expect_no_snapshot(&crash_store); // lost, not truncated
    try testing.expectEqual(idx(4), crash_store.last_index());
}

test "crash_store snapshot: the lose_synced_hard_state plant leaves a synced snapshot alone" {
    var crash_store: CrashStore = undefined;
    try make(&crash_store, .lose_synced_hard_state);
    defer crash_store.deinit(gpa);
    try fill(&crash_store, 4);
    try crash_store.save_snapshot(&snapshot_at(3, "snap-3"), &configuration);
    try crash_store.sync();
    crash_store.crash(0);
    try expect_snapshot(&crash_store, 3, "snap-3");
}

// ---- model -----------------------------------------------------------------------------------

/// The trivial reference: the log length and snapshot index, durable and live, plus the
/// pending ops that one `crash(keep)` may fold in.
const Model = struct {
    const Op = union(enum) { append, snapshot: u64 };
    const ops_max = 8;

    durable_last: u64 = 0,
    durable_snap: u64 = 0,
    last: u64 = 0,
    snap: u64 = 0,
    pending: [ops_max]Op = undefined,
    pending_len: usize = 0,

    fn push(model: *Model, op: Op) void {
        if (model.pending_len == ops_max) model.fold(model.pending_len); // a full journal flushes
        model.pending[model.pending_len] = op;
        model.pending_len += 1;
    }

    fn fold(model: *Model, keep: usize) void {
        for (model.pending[0..keep]) |op| switch (op) {
            .append => model.durable_last += 1,
            .snapshot => |index| model.durable_snap = index,
        };
        model.pending_len = 0;
    }

    fn crash(model: *Model, keep: usize) void {
        model.fold(keep);
        model.last = model.durable_last;
        model.snap = model.durable_snap;
    }

    fn sync(model: *Model) void {
        model.fold(model.pending_len);
    }
};

fn expect_agrees(crash_store: *CrashStore, model: *const Model) !void {
    try testing.expectEqual(idx(model.last), crash_store.last_index());
    const record = try crash_store.load_snapshot();
    if (model.snap == 0) {
        try testing.expect(record == null);
    } else {
        try testing.expectEqual(idx(model.snap), record.?.snapshot.index);
    }
    try testing.expectEqual(@as(u32, @intCast(model.pending_len)), crash_store.unsynced_count());
    try crash_store.check_invariants();
}

test "crash_store snapshot: seeded appends, snapshots, syncs and crashes match the model" {
    for (1..25) |seed| {
        var prng = Prng.init(seed);
        var crash_store: CrashStore = undefined;
        try make(&crash_store, .none);
        defer crash_store.deinit(gpa);
        var model: Model = .{};
        for (0..40) |_| {
            switch (prng.uint_less_than(10)) {
                0...3 => {
                    model.last += 1;
                    try crash_store.append(&.{entry(model.last)});
                    model.push(.append);
                },
                4...5 => if (model.last > model.snap) {
                    const span = model.last - model.snap;
                    const index = model.snap + 1 + prng.uint_less_than(span);
                    try crash_store.save_snapshot(&snapshot_at(index, "m"), &configuration);
                    model.snap = index;
                    model.push(.{ .snapshot = index });
                },
                6...7 => {
                    try crash_store.sync();
                    model.sync();
                },
                else => {
                    const keep = prng.uint_less_than(model.pending_len + 1);
                    crash_store.crash(@intCast(keep));
                    model.crash(keep);
                },
            }
            try expect_agrees(&crash_store, &model);
        }
    }
}
