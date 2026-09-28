//! synod.log — In-memory Raft log with append/truncate/term lookup and invariant validation.
//!
//! Allocation and ownership: `Log.init` allocates `Options.entries_max` entries up front from
//! `gpa`; no method allocates afterward (Tiger Style §1.9). `Log.deinit` frees that allocation
//! exactly once.
//!
//! Invariant: `append`'s precondition (`entry.index == lastIndex().next()`) means the log's
//! entries are always contiguous starting at index 1 — `entries[i].index` always equals `i + 1`
//! for `i < count`. `termAt`/`truncate` rely on that to index directly by `index - 1`.

/// Operating errors — conditions a caller can hit with valid arguments (never asserted).
pub const Error = error{
    /// `append` was called with `count == entries_max`. The log is unmutated; the caller must
    /// compact (snapshot) or reject the write.
    LogFull,
};

/// Construction-time limits for `Log.init`. Passed explicitly; no default.
pub const Options = struct {
    /// Upper bound on the number of entries `Log` holds at once. Precondition: `> 0`.
    entries_max: u32,
};

/// In-memory Raft log: a contiguous run of entries starting at index 1, plus the count of
/// entries currently held. No I/O, no injected callbacks (REALM.md's pure-state-machine rule).
pub const Log = struct {
    /// Owned backing storage, `options.entries_max` slots, allocated once in `init`.
    entries: []Entry,
    /// Number of live entries in `entries[0..count]`. Also `lastIndex()`'s raw value, since
    /// entries are contiguous starting at 1.
    count: u32,

    /// Allocates `options.entries_max` entry slots from `gpa`. Precondition:
    /// `options.entries_max > 0`. No method below allocates after this call returns.
    pub fn init(target: *Log, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.entries_max > 0);

        const entries = try gpa.alloc(Entry, options.entries_max);
        errdefer gpa.free(entries);

        target.* = .{ .entries = entries, .count = 0 };

        assert(target.entries.len == options.entries_max);
        assert(target.count == 0);
    }

    /// Frees the backing storage allocated by `init`. Precondition: `init` was called exactly
    /// once and `deinit` has not run yet on `self`.
    pub fn deinit(self: *Log, gpa: std.mem.Allocator) void {
        assert(self.entries.len > 0);
        assert(self.count <= self.entries.len);

        gpa.free(self.entries);

        self.entries = &.{};
        self.count = 0;
        assert(self.count == 0);
    }

    /// Appends `entry` at `lastIndex() + 1`. Preconditions (caller contract, asserted, never
    /// returned as an error): `entry.index == self.lastIndex().next()` and `entry.term !=
    /// .zero`. Returns `error.LogFull` — a real operating condition, checked before the
    /// monotonicity precondition even matters — if the log is at `entries_max` capacity; the
    /// log is left unmutated in that case.
    pub fn append(self: *Log, entry: Entry) Error!void {
        assert(self.count <= self.entries.len);
        assert(entry.term != .zero);

        if (self.count == self.entries.len) return error.LogFull;

        assert(entry.index == self.lastIndex().next());
        self.entries[self.count] = entry;
        self.count += 1;

        assert(self.count <= self.entries.len);
        assert(self.lastIndex() == entry.index);
    }

    /// Drops every entry with index `>= from`, i.e. sets the log's length to `from - 1`.
    /// Preconditions: `from != .zero` and `from <= lastIndex() + 1` (truncating exactly at
    /// `lastIndex() + 1` is a legal no-op — there is nothing to drop).
    pub fn truncate(self: *Log, from: Index) void {
        assert(from != .zero);
        assert(@intFromEnum(from) <= @intFromEnum(self.lastIndex()) + 1);

        self.count = @intCast(@intFromEnum(from) - 1);

        assert(self.count <= self.entries.len);
        assert(self.lastIndex().order(from) == .lt);
    }

    /// Returns the term stored at `index`, or `.zero` for `index == .zero` (Raft's "no
    /// previous entry" sentinel). Precondition: `index <= self.lastIndex()`. A peer-supplied
    /// index (e.g. a leader's `prev_log_index`) is data, not a trusted caller value — range-check
    /// it against `lastIndex()` and return a typed error *before* calling this, the same
    /// contract `Index.next()` documents in `types.zig`; item 1B-ii's conflict-point search is
    /// where that peer-data boundary check will live.
    pub fn termAt(self: *const Log, index: Index) Term {
        assert(index.order(self.lastIndex()) != .gt);
        assert(self.count <= self.entries.len);

        if (index == .zero) return .zero;
        const entry_index: usize = @intCast(@intFromEnum(index) - 1);
        return self.entries[entry_index].term;
    }

    /// Returns `.zero` for an empty log, else the index of the most recently appended entry.
    pub fn lastIndex(self: *const Log) Index {
        assert(self.count <= self.entries.len);
        if (self.count == 0) return .zero;

        assert(self.count > 0);
        return self.entries[self.count - 1].index;
    }
};

/// Test-only helper: builds an `Entry` from raw integers so test cases stay one line each
/// (mirrors `types.zig`'s `testEntry`).
fn testEntry(index: u64, term: u64) Entry {
    return .{
        .index = @enumFromInt(index),
        .term = @enumFromInt(term),
        .kind = .normal,
        .data = "",
    };
}

test "log: Error is exhaustively switchable" {
    const err: Error = error.LogFull;
    switch (err) {
        error.LogFull => {},
    }
}

test "log: a fresh log has no last index and termAt(.zero) is .zero" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    try testing.expectEqual(Index.zero, log.lastIndex());
    try testing.expectEqual(Term.zero, log.termAt(.zero));
}

test "log: appending one entry becomes lastIndex and is visible via termAt" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    const entry = testEntry(1, 7);
    try log.append(entry);

    try testing.expectEqual(entry.index, log.lastIndex());
    try testing.expectEqual(entry.term, log.termAt(entry.index));
    // Term before the first entry is still the "no previous entry" sentinel.
    try testing.expectEqual(Term.zero, log.termAt(.zero));
}

test "log: appending a sequence tracks lastIndex and termAt at every index along the way" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    const terms = [_]u64{ 1, 1, 2, 2, 3 };
    var expected_index: Index = .zero;
    for (terms, 0..) |term, i| {
        const index_raw: u64 = i + 1;
        const entry = testEntry(index_raw, term);
        try log.append(entry);
        expected_index = entry.index;

        // Not just the tail: every index appended so far must still resolve correctly.
        try testing.expectEqual(expected_index, log.lastIndex());
        for (terms[0 .. i + 1], 0..) |past_term, j| {
            const past_index: Index = @enumFromInt(j + 1);
            try testing.expectEqual(@as(Term, @enumFromInt(past_term)), log.termAt(past_index));
        }
    }
}

test "log: append succeeds exactly up to entries_max and then returns error.LogFull" {
    const entries_max = 3;
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= entries_max) : (i += 1) {
        try log.append(testEntry(i, 1));
    }
    try testing.expectEqual(@as(Index, @enumFromInt(entries_max)), log.lastIndex());

    // The boundary: one more append past capacity is a typed error, not a panic.
    const result = log.append(testEntry(entries_max + 1, 1));
    try testing.expectError(error.LogFull, result);
    // The failed append must not have mutated the log.
    try testing.expectEqual(@as(Index, @enumFromInt(entries_max)), log.lastIndex());
}

test "log: append into a single-slot log fills at entries_max = 1" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 1 });
    defer log.deinit(testing.allocator);

    try log.append(testEntry(1, 5));
    try testing.expectEqual(@as(Index, @enumFromInt(1)), log.lastIndex());
    try testing.expectError(error.LogFull, log.append(testEntry(2, 5)));
}

test "log: truncate mid-log drops the suffix and keeps the prefix queryable" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 5) : (i += 1) try log.append(testEntry(i, i));

    const from: Index = @enumFromInt(3);
    log.truncate(from);

    try testing.expectEqual(@as(Index, @enumFromInt(2)), log.lastIndex());
    try testing.expectEqual(@as(Term, @enumFromInt(1)), log.termAt(@enumFromInt(1)));
    try testing.expectEqual(@as(Term, @enumFromInt(2)), log.termAt(@enumFromInt(2)));

    // The truncated suffix is gone: re-appending at the freed index must succeed.
    try log.append(testEntry(3, 99));
    try testing.expectEqual(@as(Index, @enumFromInt(3)), log.lastIndex());
    try testing.expectEqual(@as(Term, @enumFromInt(99)), log.termAt(@enumFromInt(3)));
}

test "log: truncating from the first index empties the log" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 3) : (i += 1) try log.append(testEntry(i, i));

    log.truncate(Index.zero.next());

    try testing.expectEqual(Index.zero, log.lastIndex());
    try testing.expectEqual(Term.zero, log.termAt(.zero));
}

test "log: truncating at exactly lastIndex() + 1 is a legal no-op" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 3) : (i += 1) try log.append(testEntry(i, i));

    const before_last = log.lastIndex();
    log.truncate(before_last.next());

    try testing.expectEqual(before_last, log.lastIndex());
    try testing.expectEqual(@as(Term, @enumFromInt(3)), log.termAt(before_last));
}

test "log: truncating an empty log at index one is a legal no-op" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    log.truncate(Index.zero.next());

    try testing.expectEqual(Index.zero, log.lastIndex());
}

/// A trivial, obviously-correct reference model against which `Log`'s behavior is compared
/// after every operation in the seeded test below. It is not the implementation under test —
/// it is a plain list, so any divergence points at `Log`, not at the model.
const ReferenceModel = struct {
    entries: std.ArrayList(Entry),

    fn init() ReferenceModel {
        return .{ .entries = .empty };
    }

    fn deinit(self: *ReferenceModel, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    fn lastIndex(self: *const ReferenceModel) Index {
        if (self.entries.items.len == 0) return .zero;
        return self.entries.items[self.entries.items.len - 1].index;
    }

    fn termAt(self: *const ReferenceModel, index: Index) Term {
        if (index == .zero) return .zero;
        return self.entries.items[@intFromEnum(index) - 1].term;
    }
};

/// Checks `log` and `model` agree on every index the model has ever held. Called after every
/// step of the seeded test (Tiger Style: `check_invariants()` after each mutation).
fn checkInvariants(log: *const Log, model: *const ReferenceModel) !void {
    try testing.expectEqual(model.lastIndex(), log.lastIndex());
    var i: u64 = 0;
    while (i <= @intFromEnum(model.lastIndex())) : (i += 1) {
        const index: Index = @enumFromInt(i);
        try testing.expectEqual(model.termAt(index), log.termAt(index));
    }
}

test "log: seeded model-based append/truncate matches a trivial reference" {
    const entries_max = 6;
    const ops_max = 20;

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var model = ReferenceModel.init();
    defer model.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x1067_5eed);
    const random = prng.random();
    var next_term: u64 = 1;

    try checkInvariants(&log, &model);
    for (0..ops_max) |_| {
        const do_append = random.boolean();
        if (do_append) {
            const entry = testEntry(@intFromEnum(model.lastIndex()) + 1, next_term);
            next_term += 1;
            const result = log.append(entry);
            if (model.entries.items.len == entries_max) {
                try testing.expectError(error.LogFull, result);
            } else {
                try result;
                try model.entries.append(testing.allocator, entry);
            }
        } else {
            const last_raw = @intFromEnum(model.lastIndex());
            const from_raw = random.intRangeAtMost(u64, 1, last_raw + 1);
            const from: Index = @enumFromInt(from_raw);
            log.truncate(from);
            model.entries.shrinkRetainingCapacity(from_raw - 1);
        }
        try checkInvariants(&log, &model);
    }
}

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const Index = types.Index;
const Term = types.Term;
const Entry = types.Entry;
const assert = std.debug.assert;
