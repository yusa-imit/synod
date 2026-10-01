//! Tests for `interfaces.zig` (ADR-006): the five vtables `Transport`, `LogStore`,
//! `StateMachine`, `Clock`, `Rng`. Every fixture here is test-private, non-zero-sized, and
//! reaches its interface only through `X.init(&fixture)`, the single construction path.
//!
//! Forwarder contract assertions (non-empty batch, contiguous indices, `from != to`, ...) are
//! programmer errors and abort; they are exercised only by valid-path calls below.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

const Transport = interfaces.Transport;
const LogStore = interfaces.LogStore;
const StateMachine = interfaces.StateMachine;
const Clock = interfaces.Clock;
const Rng = interfaces.Rng;
const SnapshotRecord = interfaces.SnapshotRecord;

const WriteError = LogStore.WriteError;
const UpdateError = LogStore.UpdateError;
const ReadError = LogStore.ReadError;
const ApplyError = StateMachine.ApplyError;
const SnapshotError = StateMachine.SnapshotError;
const RestoreError = StateMachine.RestoreError;

const NodeId = types.NodeId;
const Term = types.Term;
const Index = types.Index;
const Entry = types.Entry;
const EntryKind = types.EntryKind;
const HardState = types.HardState;
const Snapshot = types.Snapshot;
const Configuration = types.Configuration;
const Header = types.Header;
const Message = types.Message;
const MessageKind = types.MessageKind;

// ---------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn term(value: u64) Term {
    return @enumFromInt(value);
}

fn node(value: u64) NodeId {
    return @enumFromInt(value);
}

fn test_entry(index: u64, term_value: u64) Entry {
    return .{ .index = idx(index), .term = term(term_value), .kind = .normal, .data = "" };
}

fn test_header(from: u64, to: u64) Header {
    return .{ .protocol_version = 1, .term = term(3), .from = node(from), .to = node(to) };
}

fn test_vote(from: u64, to: u64) Message {
    return .{ .request_vote = .{
        .header = test_header(from, to),
        .last_log_index = idx(7),
        .last_log_term = term(2),
    } };
}

const interface_types = .{ Transport, LogStore, StateMachine, Clock, Rng };

// ---------------------------------------------------------------------------------------
// Shape: size, vtable field names, exact error sets
// ---------------------------------------------------------------------------------------

test "interfaces: every interface is exactly two machine words" {
    inline for (interface_types) |X| {
        try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(X));
        try testing.expect(@hasField(X, "ptr"));
        try testing.expect(@hasField(X, "vtable"));
    }
}

fn expect_vtable_fields(comptime X: type, comptime expected: []const []const u8) !void {
    const names = comptime std.meta.fieldNames(X.VTable);
    try testing.expectEqual(expected.len, names.len);
    inline for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, names[i]);
        // Every entry is a function pointer whose first parameter is the erased `*anyopaque`.
        const field_type = @FieldType(X.VTable, name);
        const function = @typeInfo(@typeInfo(field_type).pointer.child).@"fn";
        try testing.expect(function.params[0].type.? == *anyopaque);
    }
}

test "interfaces: vtable fields are snake_case and one per method" {
    try expect_vtable_fields(Transport, &.{"send"});
    try expect_vtable_fields(Clock, &.{"now_ms"});
    try expect_vtable_fields(Rng, &.{"next_u64"});
    try expect_vtable_fields(StateMachine, &.{ "apply", "snapshot", "restore" });
    try expect_vtable_fields(LogStore, &.{
        "append",        "truncate",        "get",
        "last_index",    "save_hard_state", "load_hard_state",
        "save_snapshot", "load_snapshot",   "sync",
    });
}

test "interfaces: named error sets have exactly the declared variants" {
    const write_error: WriteError = error.StoreFull;
    switch (write_error) {
        error.StoreFull, error.StoreIoFailed => {},
    }
    const update_error: UpdateError = error.StoreIoFailed;
    switch (update_error) {
        error.StoreIoFailed => {},
    }
    const read_error: ReadError = error.StoreCorrupt;
    switch (read_error) {
        error.StoreCorrupt, error.StoreIoFailed => {},
    }
    const apply_error: ApplyError = error.StateMachineFailed;
    switch (apply_error) {
        error.StateMachineFailed => {},
    }
    const snapshot_error: SnapshotError = error.WriteFailed;
    switch (snapshot_error) {
        error.WriteFailed, error.StateMachineFailed => {},
    }
    const restore_error: RestoreError = error.EndOfStream;
    switch (restore_error) {
        error.ReadFailed,
        error.EndOfStream,
        error.StateMachineSnapshotInvalid,
        error.StateMachineFailed,
        => {},
    }
}

// ---------------------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------------------

const Recorder = struct {
    sent: u32 = 0,
    to: [4]NodeId = [_]NodeId{.none} ** 4,
    last_kind: ?MessageKind = null,
    last_term: Term = .zero,
    last_message: ?*const Message = null,
    entries_len: usize = 0,
    entries_ptr: ?[*]const Entry = null,

    pub fn send(self: *Recorder, message: *const Message) void {
        assert(self.sent < self.to.len);
        self.to[self.sent] = message.header().to;
        self.sent += 1;
        self.last_kind = std.meta.activeTag(message.*);
        self.last_term = message.header().term;
        self.last_message = message;
        switch (message.*) {
            .append_entries => |request| {
                self.entries_len = request.entries.len;
                self.entries_ptr = request.entries.ptr;
            },
            else => {},
        }
    }
};

test "transport: send dispatches to the fixture with the destination from the header" {
    var recorder: Recorder = .{};
    const transport = Transport.init(&recorder);
    const message = test_vote(1, 2);

    transport.send(&message);

    try testing.expectEqual(@as(u32, 1), recorder.sent);
    try testing.expectEqual(node(2), recorder.to[0]);
    try testing.expectEqual(MessageKind.request_vote, recorder.last_kind.?);
    try testing.expectEqual(term(3), recorder.last_term);
    try testing.expect(recorder.last_message.? == &message);
}

test "transport: sends reach the fixture in call order" {
    var recorder: Recorder = .{};
    const transport = Transport.init(&recorder);
    const first = test_vote(1, 2);
    const second = test_vote(1, 3);
    const third = test_vote(1, 4);

    transport.send(&first);
    transport.send(&second);
    transport.send(&third);

    try testing.expectEqual(@as(u32, 3), recorder.sent);
    try testing.expectEqual(node(2), recorder.to[0]);
    try testing.expectEqual(node(3), recorder.to[1]);
    try testing.expectEqual(node(4), recorder.to[2]);
    try testing.expectEqual(node(0), recorder.to[3]);
}

test "transport: borrowed entry slices reach the impl unchanged and are not copied" {
    var recorder: Recorder = .{};
    const transport = Transport.init(&recorder);
    const entries = try testing.allocator.alloc(Entry, 2);
    defer testing.allocator.free(entries);
    entries[0] = test_entry(5, 2);
    entries[1] = test_entry(6, 2);
    const message: Message = .{ .append_entries = .{
        .header = test_header(9, 8),
        .prev_log_index = idx(4),
        .prev_log_term = term(2),
        .leader_commit = idx(4),
        .round = 1,
        .entries = entries,
    } };

    transport.send(&message);

    try testing.expectEqual(MessageKind.append_entries, recorder.last_kind.?);
    try testing.expectEqual(@as(usize, 2), recorder.entries_len);
    try testing.expect(recorder.entries_ptr.? == entries.ptr);
}

test "transport: two fixtures of one type stay independent behind their own pointers" {
    var left: Recorder = .{};
    var right: Recorder = .{};
    const transport_left = Transport.init(&left);
    const transport_right = Transport.init(&right);
    const message = test_vote(1, 2);

    transport_left.send(&message);
    transport_left.send(&message);
    transport_right.send(&message);

    try testing.expectEqual(@as(u32, 2), left.sent);
    try testing.expectEqual(@as(u32, 1), right.sent);
    try testing.expect(transport_left.ptr != transport_right.ptr);
    try testing.expect(transport_left.vtable == transport_right.vtable);
}

// ---------------------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------------------

const ManualClock = struct {
    now: u64,
    reads: u32 = 0,

    pub fn now_ms(self: *ManualClock) u64 {
        self.reads += 1;
        return self.now;
    }
};

const StepClock = struct {
    now: u64 = 100,
    step: u64 = 5,

    pub fn now_ms(self: *StepClock) u64 {
        const result = self.now;
        self.now += self.step;
        return result;
    }
};

test "clock: now_ms returns what the fixture holds and reads it once per call" {
    var manual: ManualClock = .{ .now = 1234 };
    const clock = Clock.init(&manual);

    try testing.expectEqual(@as(u64, 1234), clock.now_ms());
    manual.now = 1300;
    try testing.expectEqual(@as(u64, 1300), clock.now_ms());
    try testing.expectEqual(@as(u32, 2), manual.reads);
}

test "clock: a monotonic fixture stays non-decreasing across many reads" {
    var stepping: StepClock = .{ .step = 0 };
    const clock = Clock.init(&stepping);
    var previous = clock.now_ms();
    for (0..50) |i| {
        if (i % 10 == 0) stepping.step += 3; // Plateaus (step 0) and rises both occur.
        const current = clock.now_ms();
        try testing.expect(current >= previous);
        previous = current;
    }
    try testing.expect(previous > 100);
}

test "clock: the full u64 range passes through unchanged" {
    var manual: ManualClock = .{ .now = std.math.maxInt(u64) };
    const clock = Clock.init(&manual);
    try testing.expectEqual(std.math.maxInt(u64), clock.now_ms());
    manual.now = 0;
    try testing.expectEqual(@as(u64, 0), clock.now_ms());
}

test "clock: one impl type shares a vtable and different impl types get their own" {
    var manual_a: ManualClock = .{ .now = 1 };
    var manual_b: ManualClock = .{ .now = 2 };
    var stepping: StepClock = .{};
    const clock_a = Clock.init(&manual_a);
    const clock_b = Clock.init(&manual_b);
    const clock_step = Clock.init(&stepping);

    try testing.expect(clock_a.vtable == clock_b.vtable);
    try testing.expect(clock_a.vtable != clock_step.vtable);
    try testing.expectEqual(@as(u64, 1), clock_a.now_ms());
    try testing.expectEqual(@as(u64, 2), clock_b.now_ms());
    try testing.expectEqual(@as(u64, 100), clock_step.now_ms());
    try testing.expectEqual(@as(u64, 105), clock_step.now_ms());
}

// ---------------------------------------------------------------------------------------
// Rng
// ---------------------------------------------------------------------------------------

/// Replays `values` in order, wrapping. Counts draws so tests can pin "one draw per call".
const ScriptedRng = struct {
    values: []const u64,
    at: usize = 0,
    draws: u32 = 0,

    pub fn next_u64(self: *ScriptedRng) u64 {
        const result = self.values[self.at];
        self.at = (self.at + 1) % self.values.len;
        self.draws += 1;
        return result;
    }
};

const SplitMix = struct {
    state: u64,
    draws: u64 = 0,

    pub fn next_u64(self: *SplitMix) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        self.draws += 1;
        return z ^ (z >> 31);
    }
};

/// Evenly spaced draws `0, 2^54, 2*2^54, ...`: 1024 of them cover [0, 2^64) exactly once.
const StrideRng = struct {
    at: u64 = 0,

    pub fn next_u64(self: *StrideRng) u64 {
        const result = self.at << 54;
        self.at += 1;
        return result;
    }
};

test "rng: next_u64 replays the fixture's sequence in order" {
    const script = [_]u64{ 11, 0, std.math.maxInt(u64), 42 };
    var scripted: ScriptedRng = .{ .values = &script };
    const rng = Rng.init(&scripted);

    for (script ++ script) |expected| {
        try testing.expectEqual(expected, rng.next_u64());
    }
    try testing.expectEqual(@as(u32, 8), scripted.draws);
}

test "rng: uint_less_than with bound 1 is always 0" {
    const script = [_]u64{ 0, 1, 1 << 63, std.math.maxInt(u64) };
    var scripted: ScriptedRng = .{ .values = &script };
    const rng = Rng.init(&scripted);
    for (script) |_| {
        try testing.expectEqual(@as(u64, 0), rng.uint_less_than(1));
    }
}

test "rng: the maximum draw maps to bound - 1 and the zero draw maps to 0" {
    const bounds = [_]u64{ 2, 3, 10, 1000, (1 << 32) + 1, 1 << 63, std.math.maxInt(u64) };
    const script = [_]u64{ std.math.maxInt(u64), 0 };
    var scripted: ScriptedRng = .{ .values = &script };
    const rng = Rng.init(&scripted);
    for (bounds) |bound| {
        try testing.expectEqual(bound - 1, rng.uint_less_than(bound));
        try testing.expectEqual(@as(u64, 0), rng.uint_less_than(bound));
    }
}

test "rng: multiply-high cut points fall exactly where the arithmetic puts them" {
    // Hand-derived: floor(x * bound / 2^64). For bound 3 the cuts are near 2^64 / 3.
    const cases = [_]struct { draw: u64, bound: u64, expected: u64 }{
        .{ .draw = 0x5555555555555555, .bound = 3, .expected = 0 },
        .{ .draw = 0x5555555555555556, .bound = 3, .expected = 1 },
        .{ .draw = 0xAAAAAAAAAAAAAAAA, .bound = 3, .expected = 1 },
        .{ .draw = 0xAAAAAAAAAAAAAAAB, .bound = 3, .expected = 2 },
        .{ .draw = 1 << 63, .bound = 10, .expected = 5 },
        .{ .draw = 1 << 63, .bound = 2, .expected = 1 },
        .{ .draw = (1 << 63) - 1, .bound = 2, .expected = 0 },
    };
    for (cases) |case| {
        const script = [_]u64{case.draw};
        var scripted: ScriptedRng = .{ .values = &script };
        const rng = Rng.init(&scripted);
        try testing.expectEqual(case.expected, rng.uint_less_than(case.bound));
    }
}

test "rng: uint_less_than consumes exactly one draw per call, with no rejection loop" {
    var mix: SplitMix = .{ .state = 0xC0FFEE };
    const rng = Rng.init(&mix);
    const bounds = [_]u64{ 3, 7, (1 << 63) + 1, std.math.maxInt(u64) };
    for (0..100) |i| {
        const before = mix.draws;
        _ = rng.uint_less_than(bounds[i % bounds.len]);
        try testing.expectEqual(before + 1, mix.draws);
    }
}

test "rng: seeded draws stay below the bound over ten thousand calls" {
    const bounds = [_]u64{ 1, 2, 3, 7, 10, 1000, (1 << 32) + 1, std.math.maxInt(u64) };
    for ([_]u64{ 1, 2, 0xDEADBEEF }) |seed| {
        var mix: SplitMix = .{ .state = seed };
        const rng = Rng.init(&mix);
        for (0..10_000) |i| {
            const bound = bounds[i % bounds.len];
            try testing.expect(rng.uint_less_than(bound) < bound);
        }
        try testing.expectEqual(@as(u64, 10_000), mix.draws);
    }
}

test "rng: evenly spaced draws fill every bucket evenly (deterministic uniformity)" {
    var counts8 = [_]u32{0} ** 8;
    var counts10 = [_]u32{0} ** 10;
    var stride8: StrideRng = .{};
    var stride10: StrideRng = .{};
    const rng8 = Rng.init(&stride8);
    const rng10 = Rng.init(&stride10);
    for (0..1024) |_| {
        counts8[rng8.uint_less_than(8)] += 1;
        counts10[rng10.uint_less_than(10)] += 1;
    }
    // 1024 / 8 divides exactly; 1024 / 10 = 102.4 so every bucket holds 102 or 103.
    for (counts8) |count| try testing.expectEqual(@as(u32, 128), count);
    var total: u32 = 0;
    for (counts10) |count| {
        try testing.expect(count == 102 or count == 103);
        total += count;
    }
    try testing.expectEqual(@as(u32, 1024), total);
}

test "rng: the same seed replays the same bounded sequence and another seed diverges" {
    var mix_a: SplitMix = .{ .state = 99 };
    var mix_b: SplitMix = .{ .state = 99 };
    var mix_c: SplitMix = .{ .state = 100 };
    const rng_a = Rng.init(&mix_a);
    const rng_b = Rng.init(&mix_b);
    const rng_c = Rng.init(&mix_c);
    var diverged = false;
    for (0..64) |_| {
        const a = rng_a.uint_less_than(1000);
        try testing.expectEqual(a, rng_b.uint_less_than(1000));
        if (a != rng_c.uint_less_than(1000)) diverged = true;
    }
    try testing.expect(diverged);
}

// ---------------------------------------------------------------------------------------
// LogStore
// ---------------------------------------------------------------------------------------

const slots_max = 16;

/// Which failure the stub raises, where that failure is in the method's error set.
const Fault = enum { none, full, io, corrupt };

/// Absolute-index table: `entries[i]` holds index `i` (slot 0 unused). `base` is the snapshot
/// index, `last` the last index. Copies nothing: entry data stays borrowed from the test.
const StubStore = struct {
    entries: [slots_max]Entry = undefined,
    base: u64 = 0,
    last: u64 = 0,
    capacity: u64 = 4,
    hard_state: HardState = HardState.empty,
    record: ?SnapshotRecord = null,
    syncs: u32 = 0,
    fault: Fault = .none,

    fn write_fault(self: *const StubStore) WriteError!void {
        switch (self.fault) {
            .full => return error.StoreFull,
            .io => return error.StoreIoFailed,
            .none, .corrupt => {},
        }
    }

    fn update_fault(self: *const StubStore) UpdateError!void {
        if (self.fault == .io) return error.StoreIoFailed;
    }

    fn read_fault(self: *const StubStore) ReadError!void {
        switch (self.fault) {
            .corrupt => return error.StoreCorrupt,
            .io => return error.StoreIoFailed,
            .none, .full => {},
        }
    }

    pub fn append(self: *StubStore, entries: []const Entry) WriteError!void {
        try self.write_fault();
        if (self.last - self.base + entries.len > self.capacity) return error.StoreFull;
        assert(self.last + entries.len < slots_max);
        for (entries) |entry| self.entries[@intFromEnum(entry.index)] = entry;
        self.last += entries.len;
    }

    pub fn truncate(self: *StubStore, from: Index) UpdateError!void {
        try self.update_fault();
        self.last = @intFromEnum(from) - 1;
    }

    pub fn get(self: *StubStore, index: Index) ReadError!Entry {
        try self.read_fault();
        return self.entries[@intFromEnum(index)];
    }

    pub fn last_index(self: *StubStore) Index {
        return idx(self.last);
    }

    pub fn save_hard_state(self: *StubStore, hard_state: *const HardState) UpdateError!void {
        try self.update_fault();
        self.hard_state = hard_state.*;
    }

    pub fn load_hard_state(self: *StubStore) ReadError!HardState {
        try self.read_fault();
        return self.hard_state;
    }

    pub fn save_snapshot(
        self: *StubStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) WriteError!void {
        try self.write_fault();
        const index = @intFromEnum(snapshot.index);
        const compaction = index <= self.last and self.entries[index].term == snapshot.term;
        if (!compaction) self.last = index;
        self.base = index;
        self.record = .{ .snapshot = snapshot.*, .configuration = configuration.* };
    }

    pub fn load_snapshot(self: *StubStore) ReadError!?SnapshotRecord {
        try self.read_fault();
        return self.record;
    }

    pub fn sync(self: *StubStore) UpdateError!void {
        try self.update_fault();
        self.syncs += 1;
    }
};

const voters_three = [_]NodeId{ node(1), node(2), node(3) };
const test_configuration: Configuration = .{
    .voters = &voters_three,
    .voters_outgoing = &.{},
    .learners = &.{},
};

fn append_three(store: LogStore) !void {
    const batch = [_]Entry{ test_entry(1, 1), test_entry(2, 1), test_entry(3, 2) };
    try store.append(&batch);
}

test "log_store: a fresh store is empty and appends advance last_index" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try testing.expectEqual(Index.zero, store.last_index());

    try append_three(store);
    try testing.expectEqual(idx(3), store.last_index());

    const more = [_]Entry{test_entry(4, 2)};
    try store.append(&more);
    try testing.expectEqual(idx(4), store.last_index());
}

test "log_store: get returns the entry at the index with its term and borrowed data" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    const payload = try testing.allocator.dupe(u8, "set x 1");
    defer testing.allocator.free(payload);
    const batch = [_]Entry{
        test_entry(1, 1),
        .{ .index = idx(2), .term = term(4), .kind = .normal, .data = payload },
    };
    try store.append(&batch);

    const first = try store.get(idx(1));
    try testing.expectEqual(idx(1), first.index);
    try testing.expectEqual(term(1), first.term);
    const second = try store.get(idx(2));
    try testing.expectEqual(idx(2), second.index);
    try testing.expectEqual(term(4), second.term);
    try testing.expectEqualStrings("set x 1", second.data);
    try testing.expect(second.data.ptr == payload.ptr); // Borrowed: this fixture copies nothing.
}

test "log_store: StoreFull passes through, leaves last_index unchanged, entries readable" {
    var stub: StubStore = .{ .capacity = 2 };
    const store = LogStore.init(&stub);
    const fill = [_]Entry{ test_entry(1, 1), test_entry(2, 1) };
    try store.append(&fill);

    const over = [_]Entry{test_entry(3, 1)};
    try testing.expectError(error.StoreFull, store.append(&over));

    try testing.expectEqual(idx(2), store.last_index());
    try testing.expectEqual(term(1), (try store.get(idx(2))).term);
}

test "log_store: a batch that only partly fits is rejected whole (StoreFull boundary)" {
    var stub: StubStore = .{ .capacity = 2 };
    const store = LogStore.init(&stub);
    const one = [_]Entry{test_entry(1, 1)};
    try store.append(&one);

    const two = [_]Entry{ test_entry(2, 1), test_entry(3, 1) };
    try testing.expectError(error.StoreFull, store.append(&two));
    try testing.expectEqual(idx(1), store.last_index());

    const exact = [_]Entry{test_entry(2, 1)}; // Exactly the remaining capacity fits.
    try store.append(&exact);
    try testing.expectEqual(idx(2), store.last_index());
}

test "log_store: freeing space after StoreFull lets the same append succeed" {
    var stub: StubStore = .{ .capacity = 2 };
    const store = LogStore.init(&stub);
    const fill = [_]Entry{ test_entry(1, 1), test_entry(2, 1) };
    try store.append(&fill);
    const next = [_]Entry{test_entry(3, 2)};
    try testing.expectError(error.StoreFull, store.append(&next));

    try store.truncate(idx(2));
    const replacement = [_]Entry{test_entry(2, 2)};
    try store.append(&replacement);

    try testing.expectEqual(idx(2), store.last_index());
    try testing.expectEqual(term(2), (try store.get(idx(2))).term);
}

test "log_store: truncate drops the suffix and a conflicting entry can replace it" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);

    try store.truncate(idx(3)); // Drops only index 3.
    try testing.expectEqual(idx(2), store.last_index());
    const conflicting = [_]Entry{test_entry(3, 5)};
    try store.append(&conflicting);
    try testing.expectEqual(term(5), (try store.get(idx(3))).term);

    try store.truncate(idx(4)); // last_index().next(): drops nothing.
    try testing.expectEqual(idx(3), store.last_index());
    try store.truncate(idx(1)); // Drops everything.
    try testing.expectEqual(Index.zero, store.last_index());
}

test "log_store: load_hard_state is empty until saved, then round-trips" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    const initial = try store.load_hard_state();
    try testing.expect(initial.eql(&HardState.empty));

    try append_three(store); // commit_index <= last_index: append before save.
    const saved: HardState = .{ .term = term(2), .vote = node(3), .commit_index = idx(2) };
    try store.save_hard_state(&saved);

    const loaded = try store.load_hard_state();
    try testing.expect(loaded.eql(&saved));
    try testing.expectEqual(term(2), loaded.term);
    try testing.expectEqual(node(3), loaded.vote);
    try testing.expectEqual(idx(2), loaded.commit_index);
}

test "log_store: load_snapshot is null on a fresh store" {
    var stub: StubStore = .{};
    const store = LogStore.init(&stub);
    try testing.expect((try store.load_snapshot()) == null);
}

test "log_store: compaction snapshot keeps the suffix and round-trips its record" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);
    const snapshot: Snapshot = .{ .index = idx(2), .term = term(1), .data = "state@2" };

    try store.save_snapshot(&snapshot, &test_configuration);

    try testing.expectEqual(idx(3), store.last_index()); // Suffix past the snapshot survives.
    try testing.expectEqual(term(2), (try store.get(idx(3))).term);
    const record = (try store.load_snapshot()).?;
    try testing.expectEqual(idx(2), record.snapshot.index);
    try testing.expectEqual(term(1), record.snapshot.term);
    try testing.expectEqualStrings("state@2", record.snapshot.data);
    try testing.expectEqualSlices(NodeId, &voters_three, record.configuration.voters);
}

test "log_store: install snapshot with a different term drops all entries" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);
    // Index 2 is held at term 1 locally; the snapshot says term 9: histories diverged.
    const diverged: Snapshot = .{ .index = idx(2), .term = term(9), .data = "" };
    try store.save_snapshot(&diverged, &test_configuration);
    try testing.expectEqual(idx(2), store.last_index());

    // A snapshot ahead of the whole log advances last_index to the snapshot index.
    const ahead: Snapshot = .{ .index = idx(6), .term = term(9), .data = "" };
    try store.save_snapshot(&ahead, &test_configuration);
    try testing.expect(store.last_index().order(idx(6)) != .lt);
    try testing.expectEqual(idx(6), (try store.load_snapshot()).?.snapshot.index);
}

test "log_store: sync is the durability barrier and is called through the vtable" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try store.sync();
    try append_three(store);
    try store.sync();
    try testing.expectEqual(@as(u32, 2), stub.syncs);
}

test "log_store: StoreIoFailed on append and save_snapshot leaves the store unchanged" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);

    stub.fault = .io;
    const next = [_]Entry{test_entry(4, 2)};
    try testing.expectError(error.StoreIoFailed, store.append(&next));
    const snapshot: Snapshot = .{ .index = idx(2), .term = term(1), .data = "" };
    const saved = store.save_snapshot(&snapshot, &test_configuration);
    try testing.expectError(error.StoreIoFailed, saved);

    stub.fault = .none;
    try testing.expectEqual(idx(3), store.last_index());
    try testing.expect((try store.load_snapshot()) == null);
    try store.append(&next); // Valid again once the fault clears.
    try testing.expectEqual(idx(4), store.last_index());
}

test "log_store: StoreFull on save_snapshot passes through and stores nothing" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);
    stub.fault = .full;
    const snapshot: Snapshot = .{ .index = idx(2), .term = term(1), .data = "big" };

    try testing.expectError(error.StoreFull, store.save_snapshot(&snapshot, &test_configuration));

    stub.fault = .none;
    try testing.expect((try store.load_snapshot()) == null);
    try testing.expectEqual(idx(3), store.last_index());
}

test "log_store: StoreIoFailed on truncate, save_hard_state and sync passes through" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);
    stub.fault = .io;

    try testing.expectError(error.StoreIoFailed, store.truncate(idx(2)));
    const hard_state: HardState = .{ .term = term(2), .vote = .none, .commit_index = idx(1) };
    try testing.expectError(error.StoreIoFailed, store.save_hard_state(&hard_state));
    try testing.expectError(error.StoreIoFailed, store.sync());

    stub.fault = .none;
    try testing.expectEqual(idx(3), store.last_index());
    try testing.expect((try store.load_hard_state()).eql(&HardState.empty));
    try testing.expectEqual(@as(u32, 0), stub.syncs);
}

test "log_store: StoreCorrupt and StoreIoFailed on every read path pass through" {
    var stub: StubStore = .{ .capacity = 8 };
    const store = LogStore.init(&stub);
    try append_three(store);

    stub.fault = .corrupt;
    try testing.expectError(error.StoreCorrupt, store.get(idx(1)));
    try testing.expectError(error.StoreCorrupt, store.load_hard_state());
    try testing.expectError(error.StoreCorrupt, store.load_snapshot());

    stub.fault = .io;
    try testing.expectError(error.StoreIoFailed, store.get(idx(1)));
    try testing.expectError(error.StoreIoFailed, store.load_hard_state());
    try testing.expectError(error.StoreIoFailed, store.load_snapshot());

    stub.fault = .none;
    try testing.expectEqual(term(1), (try store.get(idx(1))).term);
}

// ---------------------------------------------------------------------------------------
// StateMachine
// ---------------------------------------------------------------------------------------

/// Sums entry bytes and counts applies. Snapshot stream, 24 bytes: magic "SMSN", sum (u64 LE),
/// applied (u64 LE), CRC-32 of the first 20 bytes (u32 LE). `restore` resets state first.
const Machine = struct {
    sum: u64 = 0,
    applied: u64 = 0,
    fault: bool = false,

    const magic = "SMSN";
    const stream_len = 24;

    pub fn apply(self: *Machine, entry: *const Entry) ApplyError!void {
        if (self.fault) return error.StateMachineFailed;
        for (entry.data) |byte| self.sum +%= byte;
        self.applied += 1;
    }

    pub fn snapshot(self: *Machine, writer: *std.Io.Writer) SnapshotError!void {
        if (self.fault) return error.StateMachineFailed;
        var bytes: [stream_len]u8 = undefined;
        @memcpy(bytes[0..4], magic);
        std.mem.writeInt(u64, bytes[4..12], self.sum, .little);
        std.mem.writeInt(u64, bytes[12..20], self.applied, .little);
        std.mem.writeInt(u32, bytes[20..24], std.hash.Crc32.hash(bytes[0..20]), .little);
        try writer.writeAll(&bytes);
    }

    pub fn restore(self: *Machine, reader: *std.Io.Reader) RestoreError!void {
        self.sum = 0;
        self.applied = 0;
        if (self.fault) return error.StateMachineFailed;
        var bytes: [stream_len]u8 = undefined;
        try reader.readSliceAll(&bytes);
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.StateMachineSnapshotInvalid;
        const crc = std.mem.readInt(u32, bytes[20..24], .little);
        if (crc != std.hash.Crc32.hash(bytes[0..20])) return error.StateMachineSnapshotInvalid;
        self.sum = std.mem.readInt(u64, bytes[4..12], .little);
        self.applied = std.mem.readInt(u64, bytes[12..20], .little);
    }
};

/// Snapshots `machine` through the vtable into a `gpa`-owned buffer of exactly the stream size.
fn snapshot_bytes(gpa: std.mem.Allocator, machine: StateMachine) ![]u8 {
    const buffer = try gpa.alloc(u8, Machine.stream_len);
    errdefer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try machine.snapshot(&writer);
    try writer.flush();
    try testing.expectEqual(@as(usize, Machine.stream_len), writer.buffered().len);
    return buffer;
}

fn machine_with_state() Machine {
    return .{ .sum = 195 + 1, .applied = 3 };
}

test "state_machine: apply sees every entry kind in order, no-ops and conf_change included" {
    var machine: Machine = .{};
    const sm = StateMachine.init(&machine);
    const normal: Entry = .{
        .index = idx(1),
        .term = term(1),
        .kind = .normal,
        .data = "ab", // 97 + 98
    };
    const no_op: Entry = .{ .index = idx(2), .term = term(1), .kind = .normal, .data = "" };
    const conf: Entry = .{
        .index = idx(3),
        .term = term(2),
        .kind = .conf_change,
        .data = "\x01",
    };

    try sm.apply(&normal);
    try sm.apply(&no_op);
    try sm.apply(&conf);

    try testing.expectEqual(@as(u64, 3), machine.applied);
    try testing.expectEqual(@as(u64, 196), machine.sum);
}

test "state_machine: StateMachineFailed passes through apply, snapshot and restore" {
    var machine: Machine = .{ .fault = true };
    const sm = StateMachine.init(&machine);
    const entry = test_entry(1, 1);
    try testing.expectError(error.StateMachineFailed, sm.apply(&entry));

    var storage: [Machine.stream_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try testing.expectError(error.StateMachineFailed, sm.snapshot(&writer));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var reader = std.Io.Reader.fixed(&storage);
    try testing.expectError(error.StateMachineFailed, sm.restore(&reader));
    try testing.expectEqual(@as(u64, 0), machine.applied);
}

test "state_machine: snapshot then restore into a fresh machine reproduces the state" {
    var source = machine_with_state();
    const bytes = try snapshot_bytes(testing.allocator, StateMachine.init(&source));
    defer testing.allocator.free(bytes);

    var target: Machine = .{ .sum = 999, .applied = 9 }; // Prior state must be replaced.
    var reader = std.Io.Reader.fixed(bytes);
    try StateMachine.init(&target).restore(&reader);

    try testing.expectEqual(@as(u64, 196), target.sum);
    try testing.expectEqual(@as(u64, 3), target.applied);
    try testing.expectEqual(@as(usize, 0), reader.bufferedLen()); // Stream fully consumed.
}

test "state_machine: a writer one byte too small fails with WriteFailed, exact size fits" {
    var source = machine_with_state();
    const sm = StateMachine.init(&source);
    var small: [Machine.stream_len - 1]u8 = undefined;
    var short_writer = std.Io.Writer.fixed(&small);
    try testing.expectError(error.WriteFailed, sm.snapshot(&short_writer));

    var empty: [0]u8 = undefined;
    var zero_writer = std.Io.Writer.fixed(&empty);
    try testing.expectError(error.WriteFailed, sm.snapshot(&zero_writer));

    const bytes = try snapshot_bytes(testing.allocator, sm); // Exact size succeeds.
    testing.allocator.free(bytes);
}

test "state_machine: every truncated prefix of a snapshot fails with EndOfStream" {
    var source = machine_with_state();
    const bytes = try snapshot_bytes(testing.allocator, StateMachine.init(&source));
    defer testing.allocator.free(bytes);

    for (0..bytes.len) |length| {
        var target = machine_with_state();
        var reader = std.Io.Reader.fixed(bytes[0..length]);
        try testing.expectError(error.EndOfStream, StateMachine.init(&target).restore(&reader));
    }
}

test "state_machine: a failing reader surfaces ReadFailed" {
    var target = machine_with_state();
    var reader = std.Io.Reader.failing;
    try testing.expectError(error.ReadFailed, StateMachine.init(&target).restore(&reader));
}

test "state_machine: bad magic and a corrupted body are StateMachineSnapshotInvalid" {
    var source = machine_with_state();
    const bytes = try snapshot_bytes(testing.allocator, StateMachine.init(&source));
    defer testing.allocator.free(bytes);
    var target: Machine = .{};
    const sm = StateMachine.init(&target);

    bytes[0] ^= 0xFF; // Magic.
    var bad_magic = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.StateMachineSnapshotInvalid, sm.restore(&bad_magic));
    bytes[0] ^= 0xFF;

    bytes[6] ^= 0x01; // Payload bit flip: magic intact, checksum wrong.
    var bad_body = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.StateMachineSnapshotInvalid, sm.restore(&bad_body));
    bytes[6] ^= 0x01;

    var good = std.Io.Reader.fixed(bytes); // Same bytes, restored: valid again.
    try sm.restore(&good);
    try testing.expectEqual(@as(u64, 3), target.applied);
}

test "state_machine: a failed restore leaves reset state and a retry with a fresh reader works" {
    var source = machine_with_state();
    const bytes = try snapshot_bytes(testing.allocator, StateMachine.init(&source));
    defer testing.allocator.free(bytes);
    var target: Machine = .{ .sum = 999, .applied = 9 };
    const sm = StateMachine.init(&target);

    var truncated = std.Io.Reader.fixed(bytes[0..10]);
    try testing.expectError(error.EndOfStream, sm.restore(&truncated));
    try testing.expectEqual(@as(u64, 0), target.sum); // Reset first, never half-old state.
    try testing.expectEqual(@as(u64, 0), target.applied);

    var fresh = std.Io.Reader.fixed(bytes);
    try sm.restore(&fresh);
    try testing.expectEqual(source.sum, target.sum);
    try testing.expectEqual(source.applied, target.applied);
}

test "interfaces: fixtures are non-zero-sized so the erased pointer is a real address" {
    inline for (.{ Recorder, ManualClock, StepClock, ScriptedRng, SplitMix, StrideRng }) |T| {
        comptime assert(@sizeOf(T) > 0);
    }
    inline for (.{ StubStore, Machine }) |T| comptime assert(@sizeOf(T) > 0);

    var machine: Machine = .{};
    var stub: StubStore = .{};
    const sm = StateMachine.init(&machine);
    const store = LogStore.init(&stub);
    try testing.expect(@intFromPtr(sm.ptr) == @intFromPtr(&machine));
    try testing.expect(@intFromPtr(store.ptr) == @intFromPtr(&stub));
}
