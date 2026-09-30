//! synod.log — In-memory Raft log with append/truncate/term lookup and invariant validation.
//!
//! Allocation and ownership: `Log.init` allocates `Options.entries_max` entries up front from
//! `gpa`; no method allocates afterward (Tiger Style §1.9). `Log.deinit` frees that allocation
//! exactly once.
//!
//! Invariant: `append`'s precondition (`entry.index == last_index().next()`) means the log's
//! entries are always contiguous starting at index 1 — `entries[i].index` always equals `i + 1`
//! for `i < count`. `term_at`/`truncate` rely on that to index directly by `index - 1`.

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
    /// Number of live entries in `entries[0..count]`. Also `last_index()`'s raw value, since
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

    /// Appends `entry` at `last_index() + 1`. Preconditions (caller contract, asserted, never
    /// returned as an error): `entry.index == self.last_index().next()` and `entry.term !=
    /// .zero`. Returns `error.LogFull` — a real operating condition, checked before the
    /// monotonicity precondition even matters — if the log is at `entries_max` capacity; the
    /// log is left unmutated in that case.
    pub fn append(self: *Log, entry: Entry) Error!void {
        assert(self.count <= self.entries.len);
        assert(entry.term != .zero);

        if (self.count == self.entries.len) return error.LogFull;

        assert(entry.index == self.last_index().next());
        self.entries[self.count] = entry;
        self.count += 1;

        assert(self.count <= self.entries.len);
        assert(self.last_index() == entry.index);
    }

    /// Drops every entry with index `>= from`, i.e. sets the log's length to `from - 1`.
    /// Preconditions: `from != .zero` and `from <= last_index() + 1` (truncating exactly at
    /// `last_index() + 1` is a legal no-op — there is nothing to drop).
    pub fn truncate(self: *Log, from: Index) void {
        assert(from != .zero);
        assert(@intFromEnum(from) <= @intFromEnum(self.last_index()) + 1);

        self.count = @intCast(@intFromEnum(from) - 1);

        assert(self.count <= self.entries.len);
        assert(self.last_index().order(from) == .lt);
    }

    /// Returns the term stored at `index`, or `.zero` for `index == .zero` (Raft's "no
    /// previous entry" sentinel). Precondition: `index <= self.last_index()`. A peer-supplied
    /// index (e.g. a leader's `prev_log_index`) is data, not a trusted caller value — range-check
    /// it against `last_index()` and return a typed error *before* calling this, the same
    /// contract `Index.next()` documents in `types.zig`; item 1B-ii's conflict-point search is
    /// where that peer-data boundary check will live.
    pub fn term_at(self: *const Log, index: Index) Term {
        assert(index.order(self.last_index()) != .gt);
        assert(self.count <= self.entries.len);

        if (index == .zero) return .zero;
        const entry_index: usize = @intCast(@intFromEnum(index) - 1);
        return self.entries[entry_index].term;
    }

    /// Returns `.zero` for an empty log, else the index of the most recently appended entry.
    pub fn last_index(self: *const Log) Index {
        assert(self.count <= self.entries.len);
        if (self.count == 0) return .zero;

        assert(self.count > 0);
        return self.entries[self.count - 1].index;
    }

    /// Raft thesis §5.3 fast-backtrack conflict-point search, run by a leader against a
    /// follower's log via the follower's own `AppendResponse.outcome.rejected`. Precondition
    /// (caller contract, asserted — not returned as an error): `(prev_log_index == .zero) ==
    /// (prev_log_term == .zero)`, the same shape `Message.validate` already enforces on every
    /// peer-supplied `prev_log_index`/`prev_log_term` pair before this is ever called. Returns
    /// `null` when there is no conflict: either `prev_log_index == .zero` (Raft's "no previous
    /// entry" sentinel always matches) or the term this log holds at `prev_log_index` equals
    /// `prev_log_term`. Returns `Conflict{ .zero, .zero }` when `prev_log_index` is past
    /// `last_index()` — the follower's log is simply shorter than the leader believes. Otherwise
    /// returns the conflicting term actually held at `prev_log_index`, together with the first
    /// index (never below 1) of that term's contiguous run, found by scanning backward.
    pub fn conflict_at(self: *const Log, prev_log_index: Index, prev_log_term: Term) ?Conflict {
        assert((prev_log_index == .zero) == (prev_log_term == .zero));
        assert(self.count <= self.entries.len);

        if (prev_log_index == .zero) return null;

        if (prev_log_index.order(self.last_index()) == .gt) {
            return .{ .index = .zero, .term = .zero };
        }

        const conflict_term = self.term_at(prev_log_index);
        if (conflict_term == prev_log_term) return null;

        var first_index = prev_log_index;
        for (0..self.entries.len) |_| {
            if (@intFromEnum(first_index) <= 1) break;
            const candidate: Index = @enumFromInt(@intFromEnum(first_index) - 1);
            if (self.term_at(candidate) != conflict_term) break;
            first_index = candidate;
        }

        assert(@intFromEnum(first_index) >= 1);
        assert(first_index.order(prev_log_index) != .gt);
        return .{ .index = first_index, .term = conflict_term };
    }

    /// Data-corruption errors `validate` returns — never raised by any state reachable through
    /// the normal `append`/`truncate` API, only by bit-rot or a hand-corrupted backing array
    /// (e.g. a test double, or a peer-loaded store in the simulator). REALM.md: "Invariant
    /// violations return `error.Invariant*` ... rather than asserting/panicking mid-run."
    pub const InvariantError = error{
        /// `entries[i].index != i + 1` for some live entry: the log is no longer contiguous.
        InvariantIndexNotContiguous,
        /// `entries[i].term` is lower than `entries[i - 1].term`: Raft terms never regress
        /// along the log.
        InvariantTermRegressed,
        /// `count > 0` and `entries[0].index != 1`: there is no compaction/snapshot offset yet
        /// (module header), so the first live entry must always be index 1.
        InvariantSnapshotGap,
    };

    /// Defense-in-depth invariant check for the simulator: index contiguity, non-decreasing
    /// terms, and no snapshot-boundary gap, across `entries[0..count]`. A log built only
    /// through `append`/`truncate` can never fail this — it exists to catch corrupted state,
    /// not caller bugs, so it returns a typed error rather than asserting (see `InvariantError`
    /// doc). No precondition beyond `self` being initialized.
    pub fn validate(self: *const Log) InvariantError!void {
        assert(self.count <= self.entries.len);

        if (self.count == 0) return;
        if (@intFromEnum(self.entries[0].index) != 1) return error.InvariantSnapshotGap;

        for (self.entries[0..self.count], 0..) |entry, i| {
            const expected_index: u64 = i + 1;
            if (@intFromEnum(entry.index) != expected_index) {
                return error.InvariantIndexNotContiguous;
            }
            if (i > 0 and entry.term.order(self.entries[i - 1].term) == .lt) {
                return error.InvariantTermRegressed;
            }
        }

        assert(@intFromEnum(self.entries[0].index) == 1);
        assert(@intFromEnum(self.entries[self.count - 1].index) == self.count);
    }
};

/// Test-only helper: builds an `Entry` from raw integers so test cases stay one line each
/// (mirrors `types.zig`'s `test_entry`).
fn test_entry(index: u64, term: u64) Entry {
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

test "log: a fresh log has no last index and term_at(.zero) is .zero" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    try testing.expectEqual(Index.zero, log.last_index());
    try testing.expectEqual(Term.zero, log.term_at(.zero));
}

test "log: appending one entry becomes last_index and is visible via term_at" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    const entry = test_entry(1, 7);
    try log.append(entry);

    try testing.expectEqual(entry.index, log.last_index());
    try testing.expectEqual(entry.term, log.term_at(entry.index));
    // Term before the first entry is still the "no previous entry" sentinel.
    try testing.expectEqual(Term.zero, log.term_at(.zero));
    try log.validate();
}

test "log: appending a sequence tracks last_index and term_at at every index along the way" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    const terms = [_]u64{ 1, 1, 2, 2, 3 };
    var expected_index: Index = .zero;
    for (terms, 0..) |term, i| {
        const index_raw: u64 = i + 1;
        const entry = test_entry(index_raw, term);
        try log.append(entry);
        expected_index = entry.index;

        // Not just the tail: every index appended so far must still resolve correctly.
        try testing.expectEqual(expected_index, log.last_index());
        for (terms[0 .. i + 1], 0..) |past_term, j| {
            const past_index: Index = @enumFromInt(j + 1);
            try testing.expectEqual(@as(Term, @enumFromInt(past_term)), log.term_at(past_index));
        }
    }
    try log.validate();
}

test "log: append succeeds exactly up to entries_max and then returns error.LogFull" {
    const entries_max = 3;
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= entries_max) : (i += 1) {
        try log.append(test_entry(i, 1));
    }
    try testing.expectEqual(@as(Index, @enumFromInt(entries_max)), log.last_index());

    // The boundary: one more append past capacity is a typed error, not a panic.
    const result = log.append(test_entry(entries_max + 1, 1));
    try testing.expectError(error.LogFull, result);
    // The failed append must not have mutated the log.
    try testing.expectEqual(@as(Index, @enumFromInt(entries_max)), log.last_index());
    try log.validate();
}

test "log: append into a single-slot log fills at entries_max = 1" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 1 });
    defer log.deinit(testing.allocator);

    try log.append(test_entry(1, 5));
    try testing.expectEqual(@as(Index, @enumFromInt(1)), log.last_index());
    try testing.expectError(error.LogFull, log.append(test_entry(2, 5)));
    try log.validate();
}

test "log: truncate mid-log drops the suffix and keeps the prefix queryable" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 5) : (i += 1) try log.append(test_entry(i, i));

    const from: Index = @enumFromInt(3);
    log.truncate(from);

    try testing.expectEqual(@as(Index, @enumFromInt(2)), log.last_index());
    try testing.expectEqual(@as(Term, @enumFromInt(1)), log.term_at(@enumFromInt(1)));
    try testing.expectEqual(@as(Term, @enumFromInt(2)), log.term_at(@enumFromInt(2)));

    // The truncated suffix is gone: re-appending at the freed index must succeed.
    try log.append(test_entry(3, 99));
    try testing.expectEqual(@as(Index, @enumFromInt(3)), log.last_index());
    try testing.expectEqual(@as(Term, @enumFromInt(99)), log.term_at(@enumFromInt(3)));
    try log.validate();
}

test "log: truncating from the first index empties the log" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 3) : (i += 1) try log.append(test_entry(i, i));

    log.truncate(Index.zero.next());

    try testing.expectEqual(Index.zero, log.last_index());
    try testing.expectEqual(Term.zero, log.term_at(.zero));
    try log.validate();
}

test "log: truncating at exactly last_index() + 1 is a legal no-op" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 3) : (i += 1) try log.append(test_entry(i, i));

    const before_last = log.last_index();
    log.truncate(before_last.next());

    try testing.expectEqual(before_last, log.last_index());
    try testing.expectEqual(@as(Term, @enumFromInt(3)), log.term_at(before_last));
    try log.validate();
}

test "log: truncating an empty log at index one is a legal no-op" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    log.truncate(Index.zero.next());

    try testing.expectEqual(Index.zero, log.last_index());
    try log.validate();
}

// --- conflict_at: Raft §5.3 fast-backtrack conflict-point search (item 1B-ii) ---

test "log: conflict_at at prev_log_index zero always matches, empty or not" {
    var empty_log: Log = undefined;
    try empty_log.init(testing.allocator, .{ .entries_max = 4 });
    defer empty_log.deinit(testing.allocator);
    try testing.expectEqual(@as(?Conflict, null), empty_log.conflict_at(.zero, .zero));

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    try log.append(test_entry(1, 5));
    try log.append(test_entry(2, 5));
    try testing.expectEqual(@as(?Conflict, null), log.conflict_at(.zero, .zero));
}

test "log: conflict_at reports a shorter log's boundary as zero, including the empty log" {
    var empty_log: Log = undefined;
    try empty_log.init(testing.allocator, .{ .entries_max = 4 });
    defer empty_log.deinit(testing.allocator);
    const expected_zero: Conflict = .{ .index = .zero, .term = .zero };
    try testing.expectEqual(
        expected_zero,
        empty_log.conflict_at(@enumFromInt(1), @enumFromInt(1)).?,
    );

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    try log.append(test_entry(1, 5));
    try log.append(test_entry(2, 5));

    // prev_log_index (5) is past last_index() (2): the follower's log is shorter.
    try testing.expectEqual(
        expected_zero,
        log.conflict_at(@enumFromInt(5), @enumFromInt(9)).?,
    );
}

test "log: conflict_at returns null when the term at prev_log_index matches" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    const terms = [_]u64{ 1, 1, 2, 3, 3 };
    for (terms, 0..) |term, i| try log.append(test_entry(i + 1, term));

    for (terms, 0..) |term, i| {
        const index: Index = @enumFromInt(i + 1);
        try testing.expectEqual(
            @as(?Conflict, null),
            log.conflict_at(index, @enumFromInt(term)),
        );
    }
}

test "log: conflict_at finds the first index of a single mismatching entry's term" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    // Index 1 term 1, index 2 term 2, index 3 term 3: each term appears exactly once.
    try log.append(test_entry(1, 1));
    try log.append(test_entry(2, 2));
    try log.append(test_entry(3, 3));

    // Follower's term at index 3 is 3; leader claims prev_log_term 7 (a mismatch): the
    // follower's own term (3) at that index is reported, with its own (single-entry) run start.
    const conflict = log.conflict_at(@enumFromInt(3), @enumFromInt(7)).?;
    try testing.expectEqual(@as(Term, @enumFromInt(3)), conflict.term);
    try testing.expectEqual(@as(Index, @enumFromInt(3)), conflict.index);
}

test "log: conflict_at finds the first index of a run of consecutive entries sharing a term" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    // Indices 1-2 term 1, indices 3-6 term 2 (the conflicting run), index 7 term 3.
    const terms = [_]u64{ 1, 1, 2, 2, 2, 2, 3 };
    for (terms, 0..) |term, i| try log.append(test_entry(i + 1, term));

    // prev_log_index=5 is inside the term-2 run; the leader's claimed term (9) mismatches.
    const conflict = log.conflict_at(@enumFromInt(5), @enumFromInt(9)).?;
    try testing.expectEqual(@as(Term, @enumFromInt(2)), conflict.term);
    try testing.expectEqual(@as(Index, @enumFromInt(3)), conflict.index); // First of the run.
}

test "log: conflict_at does not scan below index 1 when the conflicting run starts at 1" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    // The entire log shares one term: the conflicting run starts at index 1.
    const terms = [_]u64{ 4, 4, 4 };
    for (terms, 0..) |term, i| try log.append(test_entry(i + 1, term));

    const conflict = log.conflict_at(@enumFromInt(3), @enumFromInt(9)).?;
    try testing.expectEqual(@as(Term, @enumFromInt(4)), conflict.term);
    // Must land exactly on index 1, not underflow past it.
    try testing.expectEqual(@as(Index, @enumFromInt(1)), conflict.index);
}

/// Trivial, obviously-correct linear-scan reference for `conflict_at`, independent of whatever
/// `conflict_at` itself does: walk backward from `prev_log_index` while the term still matches
/// the term found at `prev_log_index`, and report the first index of that run.
fn reference_conflict_at(log: *const Log, prev_log_index: Index, prev_log_term: Term) ?Conflict {
    if (prev_log_index == .zero) return null;
    if (prev_log_index.order(log.last_index()) == .gt) {
        return .{ .index = .zero, .term = .zero };
    }
    const actual_term = log.term_at(prev_log_index);
    if (actual_term == prev_log_term) return null;

    var first_index = prev_log_index;
    while (@intFromEnum(first_index) > 1) {
        const candidate: Index = @enumFromInt(@intFromEnum(first_index) - 1);
        if (log.term_at(candidate) != actual_term) break;
        first_index = candidate;
    }
    return .{ .index = first_index, .term = actual_term };
}

test "log: conflict_at seeded model matches a trivial backward linear-scan reference" {
    const entries_max = 12;
    const queries_max = 200;

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0xc0f1_71c7);
    const random = prng.random();

    // Build a log with a random non-decreasing term sequence, like a real Raft log.
    var term: u64 = 1;
    var i: u64 = 1;
    while (i <= entries_max) : (i += 1) {
        if (random.boolean()) term += 1;
        try log.append(test_entry(i, term));
    }
    try log.validate();

    for (0..queries_max) |_| {
        const prev_log_index: Index = @enumFromInt(random.intRangeAtMost(u64, 0, entries_max + 2));
        var prev_log_term: Term = undefined;
        if (prev_log_index == .zero) {
            prev_log_term = .zero;
        } else if (random.boolean() and prev_log_index.order(log.last_index()) != .gt) {
            // Force the "matches" path with the real term at that index.
            prev_log_term = log.term_at(prev_log_index);
        } else {
            // Force (or at least likely force) the "mismatch" path with a deliberately wrong term.
            prev_log_term = @enumFromInt(random.intRangeAtMost(u64, 1, term + 5));
        }

        const expected = reference_conflict_at(&log, prev_log_index, prev_log_term);
        const actual = log.conflict_at(prev_log_index, prev_log_term);
        try testing.expectEqual(expected, actual);
    }
}

// --- validate(): defense-in-depth invariant checker for Phase 3's simulator (item 1B-ii) ---

test "log: InvariantError is exhaustively switchable" {
    const err: Log.InvariantError = error.InvariantIndexNotContiguous;
    switch (err) {
        error.InvariantIndexNotContiguous,
        error.InvariantTermRegressed,
        error.InvariantSnapshotGap,
        => {},
    }
}

test "log: a fresh empty log validates successfully" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    try log.validate();
}

test "log: a log built entirely through append/truncate always validates successfully" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 5) : (i += 1) try log.append(test_entry(i, i));
    try log.validate();

    log.truncate(@enumFromInt(3));
    try log.validate();

    try log.append(test_entry(3, 9));
    try log.append(test_entry(4, 9));
    try log.validate();
}

test "log: validate rejects a hand-corrupted non-contiguous index" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 4) : (i += 1) try log.append(test_entry(i, 1));
    try log.validate();

    // Test-only escape hatch: simulate bit-rot/corruption by writing directly into the backing
    // array, bypassing `append`'s precondition asserts entirely (this is exactly the kind of
    // corruption `validate()` exists to catch, since the normal API can never produce it).
    log.entries[2].index = @enumFromInt(99); // Was index 3; now breaks contiguity.

    try testing.expectError(error.InvariantIndexNotContiguous, log.validate());
}

test "log: validate rejects a hand-corrupted term regression" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 4) : (i += 1) try log.append(test_entry(i, i)); // Terms 1,2,3,4.
    try log.validate();

    // Corrupt entry 3 (index 3, was term 3) to a term below its predecessor's (entry 2, term 2).
    log.entries[2].term = @enumFromInt(1);

    try testing.expectError(error.InvariantTermRegressed, log.validate());
}

test "log: validate rejects a hand-corrupted snapshot-boundary gap" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    var i: u64 = 1;
    while (i <= 3) : (i += 1) try log.append(test_entry(i, 1));
    try log.validate();

    // Corrupt the first live entry's index: there is no compaction/snapshot-offset support yet
    // (item 1B-ii's scope), so index 1 must always be the first live entry.
    log.entries[0].index = @enumFromInt(2);

    try testing.expectError(error.InvariantSnapshotGap, log.validate());
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

    fn last_index(self: *const ReferenceModel) Index {
        if (self.entries.items.len == 0) return .zero;
        return self.entries.items[self.entries.items.len - 1].index;
    }

    fn term_at(self: *const ReferenceModel, index: Index) Term {
        if (index == .zero) return .zero;
        return self.entries.items[@intFromEnum(index) - 1].term;
    }
};

/// Checks `log` and `model` agree on every index the model has ever held. Called after every
/// step of the seeded test (Tiger Style: `check_invariants()` after each mutation).
fn check_invariants(log: *const Log, model: *const ReferenceModel) !void {
    try testing.expectEqual(model.last_index(), log.last_index());
    var i: u64 = 0;
    while (i <= @intFromEnum(model.last_index())) : (i += 1) {
        const index: Index = @enumFromInt(i);
        try testing.expectEqual(model.term_at(index), log.term_at(index));
    }
    // ADR-003: `validate()` runs alongside `check_invariants` after every step, since a log
    // built entirely through the normal API must never fail its own invariant checker.
    try log.validate();
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

    try check_invariants(&log, &model);
    for (0..ops_max) |_| {
        const do_append = random.boolean();
        if (do_append) {
            const entry = test_entry(@intFromEnum(model.last_index()) + 1, next_term);
            next_term += 1;
            const result = log.append(entry);
            if (model.entries.items.len == entries_max) {
                try testing.expectError(error.LogFull, result);
            } else {
                try result;
                try model.entries.append(testing.allocator, entry);
            }
        } else {
            const last_raw = @intFromEnum(model.last_index());
            const from_raw = random.intRangeAtMost(u64, 1, last_raw + 1);
            const from: Index = @enumFromInt(from_raw);
            log.truncate(from);
            model.entries.shrinkRetainingCapacity(from_raw - 1);
        }
        try check_invariants(&log, &model);
    }
}

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const Index = types.Index;
const Term = types.Term;
const Entry = types.Entry;
const Conflict = types.Conflict;
const assert = std.debug.assert;
