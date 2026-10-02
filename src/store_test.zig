//! Tests for `store.zig`: the shared conformance suite through the `LogStore` vtable, the
//! capacity boundaries of `MemoryStore` (each `StoreFull` cause, at max and max+1), the
//! init/deinit allocation contract, and a seeded model-based run against a trivial reference.
//!
//! Every store is reached through `LogStore.init(&store)`, never by calling the concrete methods
//! (the model test reads `check_invariants` from the concrete type, the one exception).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const conformance = @import("store_conformance.zig");
const interfaces = @import("interfaces.zig");
const store_module = @import("store.zig");
const types = @import("types.zig");

const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const MemoryStore = store_module.MemoryStore;
const NodeId = types.NodeId;
const Snapshot = types.Snapshot;
const Term = types.Term;

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn term(value: u64) Term {
    return @enumFromInt(value);
}

fn node(value: u64) NodeId {
    return @enumFromInt(value);
}

fn entry(index: u64, term_value: u64, data: []const u8) Entry {
    return .{ .index = idx(index), .term = term(term_value), .kind = .normal, .data = data };
}

/// The one construction path for a test store; the caller runs `deinit(testing.allocator)`.
fn make(target: *MemoryStore, options: store_module.Options) !void {
    try target.init(testing.allocator, options);
    try target.check_invariants();
}

const single_voter = [_]NodeId{node(1)};
const one_voter: Configuration = .{
    .voters = &single_voter,
    .voters_outgoing = &.{},
    .learners = &.{},
};

test "store: memory store passes the shared conformance suite" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{
        .entries_max = conformance.entries_min,
        .data_bytes_max = conformance.data_bytes_min,
        .snapshot_bytes_max = conformance.snapshot_bytes_min,
    });
    defer memory.deinit(testing.allocator);

    try conformance.conformance(LogStore.init(&memory));
    try memory.check_invariants();
}

test "store: append at entries_max succeeds and one more is StoreFull, unchanged" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 2, .data_bytes_max = 8, .snapshot_bytes_max = 4 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    try store.append(&.{ entry(1, 1, "a"), entry(2, 1, "b") });
    try testing.expectError(error.StoreFull, store.append(&.{entry(3, 1, "c")}));
    try testing.expectEqual(idx(2), store.last_index());
    try testing.expectEqualSlices(u8, "b", (try store.get(idx(2))).data);

    try store.truncate(idx(2));
    try store.append(&.{entry(2, 2, "d")}); // Room again after truncation.
    try memory.check_invariants();
}

test "store: a single-entry store works and a batch of two is StoreFull" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 1, .data_bytes_max = 1, .snapshot_bytes_max = 1 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    try testing.expectError(
        error.StoreFull,
        store.append(&.{ entry(1, 1, ""), entry(2, 1, "") }),
    );
    try testing.expectEqual(Index.zero, store.last_index());
    try store.append(&.{entry(1, 1, "z")});
    try testing.expectEqual(idx(1), store.last_index());
}

test "store: data bytes at data_bytes_max fit and one more byte is StoreFull" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 4, .snapshot_bytes_max = 4 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    try store.append(&.{entry(1, 1, "abc")});
    try testing.expectError(error.StoreFull, store.append(&.{entry(2, 1, "de")}));
    try testing.expectEqual(idx(1), store.last_index());
    try store.append(&.{entry(2, 1, "d")}); // Exactly data_bytes_max.
    try testing.expectError(error.StoreFull, store.append(&.{entry(3, 1, "e")}));

    // Compaction releases the bytes of the entries it drops.
    const snapshot: Snapshot = .{ .index = idx(1), .term = term(1), .data = "" };
    try store.save_snapshot(&snapshot, &one_voter);
    try store.append(&.{entry(3, 1, "xyz")});
    try testing.expectEqualSlices(u8, "d", (try store.get(idx(2))).data);
    try testing.expectEqualSlices(u8, "xyz", (try store.get(idx(3))).data);
    try memory.check_invariants();
}

test "store: snapshot at snapshot_bytes_max fits and one more byte is StoreFull" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 4, .snapshot_bytes_max = 2 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);
    try store.append(&.{ entry(1, 1, ""), entry(2, 1, "") });

    const too_big: Snapshot = .{ .index = idx(2), .term = term(1), .data = "abc" };
    try testing.expectError(error.StoreFull, store.save_snapshot(&too_big, &one_voter));
    try testing.expect((try store.load_snapshot()) == null);
    try testing.expectEqual(idx(2), store.last_index());
    _ = try store.get(idx(1)); // Nothing was compacted.

    const fits: Snapshot = .{ .index = idx(2), .term = term(1), .data = "ab" };
    try store.save_snapshot(&fits, &one_voter);
    try testing.expectEqualSlices(u8, "ab", (try store.load_snapshot()).?.snapshot.data);
}

test "store: a shorter snapshot replaces a longer one with no stale bytes" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 4, .snapshot_bytes_max = 3 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    const first: Snapshot = .{ .index = idx(5), .term = term(2), .data = "abc" };
    try store.save_snapshot(&first, &one_voter);
    const second: Snapshot = .{ .index = idx(9), .term = term(3), .data = "x" };
    const two_voters = [_]NodeId{ node(1), node(2) };
    const learner = [_]NodeId{node(7)};
    const wider: Configuration = .{
        .voters = &two_voters,
        .voters_outgoing = &.{},
        .learners = &learner,
    };
    try store.save_snapshot(&second, &wider);
    const record = (try store.load_snapshot()).?;
    try testing.expectEqual(idx(9), record.snapshot.index);
    try testing.expectEqualSlices(u8, "x", record.snapshot.data);
    try testing.expectEqualSlices(NodeId, &two_voters, record.configuration.voters);
    try testing.expectEqualSlices(NodeId, &learner, record.configuration.learners);
    try memory.check_invariants();
    try testing.expectEqual(idx(9), store.last_index());
}

test "store: init fails cleanly at each allocation and deinit frees them all" {
    var attempts: u32 = 0;
    while (attempts < 16) : (attempts += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = attempts });
        var memory: MemoryStore = undefined;
        const options: store_module.Options = .{
            .entries_max = 2,
            .data_bytes_max = 2,
            .snapshot_bytes_max = 2,
        };
        memory.init(failing.allocator(), options) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
        memory.deinit(failing.allocator());
        try testing.expect(attempts > 0); // Index 0 must have failed, so this ran last.
        break;
    } else return error.TestUnexpectedResult;
}

test "store: compaction moves overlapping bytes and empty entries intact" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 8, .snapshot_bytes_max = 1 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    // Entry 2 is longer than the 1 byte dropped before it, so source and destination overlap.
    try store.append(&.{ entry(1, 1, "a"), entry(2, 1, "bcdefgh") });
    const snapshot: Snapshot = .{ .index = idx(1), .term = term(1), .data = "" };
    try store.save_snapshot(&snapshot, &one_voter);
    try testing.expectEqualSlices(u8, "bcdefgh", (try store.get(idx(2))).data);
    try testing.expectEqual(@as(u32, 7), memory.data_used);
    try memory.check_invariants();

    // Dropped entries with no bytes: the retained ones do not move.
    try store.truncate(idx(2));
    try store.append(&.{ entry(2, 1, ""), entry(3, 1, "xy"), entry(4, 1, "") });
    const second: Snapshot = .{ .index = idx(2), .term = term(1), .data = "" };
    try store.save_snapshot(&second, &one_voter);
    try testing.expectEqualSlices(u8, "xy", (try store.get(idx(3))).data);
    try testing.expectEqualSlices(u8, "", (try store.get(idx(4))).data);
    try testing.expectEqual(@as(u32, 2), memory.data_used);
    try memory.check_invariants();
}

test "store: a commit left above the log is StoreCorrupt on load, not a panic" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 4, .snapshot_bytes_max = 1 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    try store.append(&.{ entry(1, 1, ""), entry(2, 1, "") });
    const hard_state: HardState = .{ .term = term(1), .vote = .none, .commit_index = idx(2) };
    try store.save_hard_state(&hard_state);
    try store.truncate(idx(2)); // Raft's contract forbids this; the store must report it.
    try testing.expectError(error.StoreCorrupt, store.load_hard_state());
}

test "store: a partial batch that busts the byte limit changes nothing" {
    var memory: MemoryStore = undefined;
    try make(&memory, .{ .entries_max = 4, .data_bytes_max = 2, .snapshot_bytes_max = 1 });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);

    try testing.expectError(
        error.StoreFull,
        store.append(&.{ entry(1, 1, "a"), entry(2, 1, "bc") }),
    );
    try testing.expectEqual(Index.zero, store.last_index());
    try testing.expectEqual(@as(u32, 0), memory.data_used);
    try memory.check_invariants();
}

// ---------------------------------------------------------------------------------------
// Model-based test: the same seeded operation stream into MemoryStore and a trivial table.
// ---------------------------------------------------------------------------------------

const model_slots = 512;

/// Absolute-index table. `terms[i]` / `bytes[i]` describe index `i` for `base < i <= last`.
const Model = struct {
    terms: [model_slots]u64 = @splat(0),
    bytes: [model_slots]u8 = @splat(0),
    base: u64 = 0,
    base_term: u64 = 0,
    last: u64 = 0,
    hard_state: HardState = HardState.empty,
    snapshot_bytes: [4]u8 = @splat(0),
    snapshot_len: u32 = 0,

    fn last_term(model: *const Model) u64 {
        return if (model.last == model.base) model.base_term else model.terms[model.last];
    }
};

const model_entries_max = 6;

fn model_verify(model: *const Model, store: LogStore, memory: *const MemoryStore) !void {
    try testing.expectEqual(idx(model.last), store.last_index());
    var index = model.base + 1;
    while (index <= model.last) : (index += 1) {
        const found = try store.get(idx(index));
        try testing.expectEqual(term(model.terms[index]), found.term);
        try testing.expectEqualSlices(u8, &.{model.bytes[index]}, found.data);
    }
    try testing.expect((try store.load_hard_state()).eql(&model.hard_state));
    const record = try store.load_snapshot();
    if (model.base == 0) {
        try testing.expect(record == null);
    } else {
        try testing.expectEqual(idx(model.base), record.?.snapshot.index);
        try testing.expectEqual(term(model.base_term), record.?.snapshot.term);
        const expected = model.snapshot_bytes[0..model.snapshot_len];
        try testing.expectEqualSlices(u8, expected, record.?.snapshot.data);
    }
    try memory.check_invariants();
}

fn model_append(model: *Model, store: LogStore, random: std.Random, nonce: u8) !void {
    const count = 1 + random.uintLessThan(u64, 3);
    assert(model.last + 3 < model_slots);
    var entries: [3]Entry = undefined;
    var payload: [3]u8 = undefined;
    var term_value = @max(model.last_term(), 1) + random.uintLessThan(u64, 2);
    for (0..count) |offset| {
        payload[offset] = nonce +% @as(u8, @intCast(offset));
        entries[offset] = entry(model.last + 1 + offset, term_value, payload[offset..][0..1]);
        term_value += random.uintLessThan(u64, 2);
    }
    const result = store.append(entries[0..count]);
    if (model.last - model.base + count > model_entries_max) {
        try testing.expectError(error.StoreFull, result);
        return;
    }
    try result;
    for (0..count) |offset| {
        model.terms[model.last + 1 + offset] = @intFromEnum(entries[offset].term);
        model.bytes[model.last + 1 + offset] = payload[offset];
    }
    model.last += count;
}

fn model_truncate(model: *Model, store: LogStore, random: std.Random) !void {
    const low = @max(@intFromEnum(model.hard_state.commit_index), model.base) + 1;
    assert(low <= model.last + 1);
    const from = low + random.uintLessThan(u64, model.last + 2 - low);
    try store.truncate(idx(from));
    model.last = from - 1;
}

fn model_hard_state(model: *Model, store: LogStore, random: std.Random) !void {
    const commit_low = @intFromEnum(model.hard_state.commit_index);
    const commit = commit_low + random.uintLessThan(u64, model.last + 1 - commit_low);
    const next: HardState = .{
        .term = term(1 + random.uintLessThan(u64, 4)),
        .vote = node(random.uintLessThan(u64, 3)),
        .commit_index = idx(commit),
    };
    try store.save_hard_state(&next);
    model.hard_state = next;
}

fn model_snapshot(model: *Model, store: LogStore, random: std.Random, nonce: u8) !void {
    const commit = @intFromEnum(model.hard_state.commit_index);
    const compaction = model.last > model.base and random.boolean();
    const index_low = if (compaction) model.base + 1 else @max(model.base + 1, commit);
    const index_high = if (compaction) model.last else model.last + 3;
    const index = index_low + random.uintLessThan(u64, index_high + 1 - index_low);
    const matching = compaction or (index <= model.last and random.boolean());
    const snapshot_term = if (index <= model.last)
        model.terms[index] + @intFromBool(!matching)
    else
        @max(model.last_term(), 1);
    const length = random.uintLessThan(u32, 5);
    var data: [4]u8 = @splat(nonce);
    const snapshot: Snapshot = .{
        .index = idx(index),
        .term = term(snapshot_term),
        .data = data[0..length],
    };
    try store.save_snapshot(&snapshot, &one_voter);
    if (!(index <= model.last and matching)) model.last = index;
    model.base = index;
    model.base_term = snapshot_term;
    model.snapshot_bytes = data;
    model.snapshot_len = length;
}

fn model_run(seed: u64, steps: u32) !void {
    var memory: MemoryStore = undefined;
    try make(&memory, .{
        .entries_max = model_entries_max,
        .data_bytes_max = model_entries_max,
        .snapshot_bytes_max = 4,
    });
    defer memory.deinit(testing.allocator);
    const store = LogStore.init(&memory);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var model: Model = .{};

    for (0..steps) |step| {
        const nonce: u8 = @truncate(step);
        switch (random.uintLessThan(u32, 8)) {
            0, 1, 2, 3 => try model_append(&model, store, random, nonce),
            4 => try model_truncate(&model, store, random),
            5, 6 => try model_hard_state(&model, store, random),
            7 => try model_snapshot(&model, store, random, nonce),
            else => unreachable, // proof: uintLessThan(8) is < 8.
        }
        try store.sync();
        try model_verify(&model, store, &memory);
    }
}

test "store: memory store matches the reference model over seeded operation streams" {
    for (0..24) |seed| try model_run(seed, 400);
}

/// A store holding entries 1..2 (terms 1, 2; data "ab", "c") and no snapshot.
fn make_with_entries(target: *MemoryStore) !void {
    try make(target, .{ .entries_max = 4, .data_bytes_max = 8, .snapshot_bytes_max = 4 });
    errdefer target.deinit(testing.allocator);
    try LogStore.init(target).append(&.{ entry(1, 1, "ab"), entry(2, 2, "c") });
    try target.check_invariants();
}

/// A store with one saved snapshot at index 3, term 2, with a one-voter configuration.
fn make_with_snapshot(target: *MemoryStore) !void {
    try make(target, .{ .entries_max = 4, .data_bytes_max = 4, .snapshot_bytes_max = 4 });
    errdefer target.deinit(testing.allocator);
    const snapshot: Snapshot = .{ .index = idx(3), .term = term(2), .data = "xy" };
    try LogStore.init(target).save_snapshot(&snapshot, &one_voter);
    try target.check_invariants();
}

test "store: check_invariants names CountOverCapacity and DataOverCapacity" {
    var memory: MemoryStore = undefined;
    try make_with_entries(&memory);
    defer memory.deinit(testing.allocator);

    memory.count = 5; // entries_max is 4.
    try testing.expectError(error.CountOverCapacity, memory.check_invariants());
    memory.count = 2;
    memory.data_used = 9; // data_bytes_max is 8.
    try testing.expectError(error.DataOverCapacity, memory.check_invariants());
    memory.data_used = 3;
    try memory.check_invariants(); // Restored state is valid again.
}

test "store: check_invariants names EntryIndexGap and EntryTermInvalid" {
    var memory: MemoryStore = undefined;
    try make_with_entries(&memory);
    defer memory.deinit(testing.allocator);

    memory.entries[1].index = idx(3); // Window must continue at base_index + 1 + position.
    try testing.expectError(error.EntryIndexGap, memory.check_invariants());
    memory.entries[1].index = idx(2);

    memory.entries[0].term = Term.zero; // Term zero is never a stored term.
    try testing.expectError(error.EntryTermInvalid, memory.check_invariants());
    memory.entries[0].term = term(3); // Terms must not regress: 3 then 2.
    try testing.expectError(error.EntryTermInvalid, memory.check_invariants());
    memory.entries[0].term = term(1);
    try memory.check_invariants();
}

test "store: check_invariants names EntryDataMisplaced for a moved slice and a stray byte" {
    var memory: MemoryStore = undefined;
    try make_with_entries(&memory);
    defer memory.deinit(testing.allocator);

    const original = memory.entries[1].data;
    memory.entries[1].data = memory.data[3..4]; // Not packed right after entry 1's bytes.
    try testing.expectError(error.EntryDataMisplaced, memory.check_invariants());
    memory.entries[1].data = original;

    memory.data_used = 4; // Packed bytes sum to 3, so one byte is unaccounted for.
    try testing.expectError(error.EntryDataMisplaced, memory.check_invariants());
    memory.data_used = 3;
    try memory.check_invariants();
}

test "store: check_invariants names SnapshotMissing and SnapshotUnexpected" {
    var memory: MemoryStore = undefined;
    try make_with_snapshot(&memory);
    defer memory.deinit(testing.allocator);

    const record = memory.snapshot;
    memory.snapshot = null; // A compaction offset with nothing to restore from.
    try testing.expectError(error.SnapshotMissing, memory.check_invariants());
    memory.snapshot = record;

    const base = memory.base_index;
    memory.base_index = Index.zero; // A snapshot while the log claims to start at the beginning.
    try testing.expectError(error.SnapshotUnexpected, memory.check_invariants());
    memory.base_index = base;
    try memory.check_invariants();
}

test "store: check_invariants names SnapshotMisplaced for each way the record drifts" {
    var memory: MemoryStore = undefined;
    try make_with_snapshot(&memory);
    defer memory.deinit(testing.allocator);
    const saved = memory.snapshot.?;

    var drifted = saved;
    drifted.snapshot.index = idx(4);
    memory.snapshot = drifted;
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    drifted = saved;
    drifted.snapshot.term = term(9);
    memory.snapshot = drifted;
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    drifted = saved;
    drifted.snapshot.data = memory.snapshot_data[0..4]; // Fits the buffer exactly: still valid.
    memory.snapshot = drifted;
    try memory.check_invariants();
    drifted.snapshot.data = memory.snapshot_data.ptr[0 .. memory.snapshot_data.len + 1];
    memory.snapshot = drifted; // One byte past the buffer.
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    drifted = saved;
    drifted.snapshot.data = memory.data[0..2]; // Payload outside `snapshot_data`.
    memory.snapshot = drifted;
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    drifted = saved;
    drifted.configuration.voters = single_voter[0..]; // Node list outside `node_ids`.
    memory.snapshot = drifted;
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    drifted = saved;
    drifted.configuration.learners = memory.node_ids; // More nodes than `node_ids` holds.
    memory.snapshot = drifted;
    try testing.expectError(error.SnapshotMisplaced, memory.check_invariants());

    memory.snapshot = saved;
    try memory.check_invariants();
}
