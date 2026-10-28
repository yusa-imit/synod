//! synod.log — In-memory Raft log with a base index: append/truncate/compact/reset, term lookup
//! and invariant validation.
//!
//! Allocation and ownership: `Log.init` allocates `Options.entries_max` entries up front from
//! `gpa`; no method allocates afterward (Tiger Style §1.9), including `compact` and `reset`.
//! `Log.deinit` frees that allocation exactly once. The log owns no entry payload bytes: an
//! `Entry.data` slice borrows from whoever appended it.
//!
//! Base: the log holds the suffix of a longer log. `base` is the `(index, term)` of the last
//! dropped entry (`Base.zero` when nothing was dropped, ADR-009 "Log base"). Layout invariant:
//! `entries[i].index == base.index + 1 + i` for `i < count`, so `append`'s precondition
//! (`entry.index == last_index().next()`) keeps the entries contiguous from `base.index + 1`.
//! Every lookup indexes directly by `index - base.index - 1`. `last_index()` of an empty log is
//! `base.index`. With the zero base the arithmetic reduces to the original index-one origin.
//!
//! Cost sketch: `append`/`truncate`/lookups touch one slot; `compact` moves the kept suffix to
//! the front once (one `copyForwards` of `count - dropped` entries), `reset` touches no slot.

/// Operating errors — conditions a caller can hit with valid arguments (never asserted).
pub const Error = error{
    /// `append` was called with `count == entries_max`. The log is unmutated; the caller must
    /// compact (snapshot) or reject the write.
    LogFull,
};

/// Returned by `Log.term_at` for an index below `base.index`: the entry was compacted away. A
/// peer may legitimately ask for such an index, so this is data, not a caller bug.
pub const TermError = error{LogCompacted};

/// `(index, term)` of the last entry dropped from the log's prefix (a snapshot's last entry).
/// Invariant: `(index == .zero) == (term == .zero)`; `Log.validate` returns
/// `InvariantBaseMalformed` otherwise.
pub const Base = struct {
    index: Index,
    term: Term,

    /// Nothing dropped: the log starts at index one.
    pub const zero: Base = .{ .index = .zero, .term = .zero };
};

/// Construction-time limits for `Log.init`. Passed explicitly; no default.
pub const Options = struct {
    /// Upper bound on the number of entries `Log` holds at once. Precondition: `> 0`.
    entries_max: u32,
};

/// In-memory Raft log: a contiguous run of entries starting at `base.index + 1`, plus the count
/// of entries currently held. No I/O, no injected callbacks (REALM.md's pure-state-machine rule).
pub const Log = struct {
    /// Owned backing storage, `options.entries_max` slots, allocated once in `init`.
    entries: []Entry,
    /// Number of live entries in `entries[0..count]`. `last_index()` is `base.index + count`.
    count: u32,
    /// The dropped prefix's last `(index, term)`; `entries[i].index == base.index + 1 + i`.
    base: Base,

    /// Allocates `options.entries_max` entry slots from `gpa`; the log starts empty at
    /// `Base.zero`. Precondition: `options.entries_max > 0`. No method below allocates after
    /// this call returns.
    pub fn init(target: *Log, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.entries_max > 0);

        const entries = try gpa.alloc(Entry, options.entries_max);
        errdefer gpa.free(entries);

        target.* = .{ .entries = entries, .count = 0, .base = Base.zero };

        assert(target.entries.len == options.entries_max);
        assert(target.count == 0);
        assert(target.base.index == .zero);
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
    /// log is left unmutated in that case. `compact` frees capacity.
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

    /// Drops every entry with index `>= from`, i.e. keeps `from - base.index - 1` entries.
    /// Preconditions: `from > base.index` (the base itself is never truncated) and `from <=
    /// last_index() + 1` (truncating exactly at `last_index() + 1` is a legal no-op — there is
    /// nothing to drop). Truncating at `base.index + 1` empties the log; the base stays.
    pub fn truncate(self: *Log, from: Index) void {
        assert(from != .zero);
        assert(from.order(self.base.index) == .gt);
        assert(@intFromEnum(from) <= @intFromEnum(self.last_index()) + 1);

        self.count = @intCast(@intFromEnum(from) - @intFromEnum(self.base.index) - 1);

        assert(self.count <= self.entries.len);
        assert(self.last_index().order(from) == .lt);
    }

    /// Makes the log empty at `base`, discarding every entry: a restore from, or an install of,
    /// a snapshot whose last entry is `base`. The next `append` must carry index `base.index + 1`.
    /// Precondition: `(base.index == .zero) == (base.term == .zero)`, and `base.index <
    /// maxInt(u64)` (a snapshot header is peer data: range-check it before calling, since
    /// `append` computes `base.index.next()`). Never allocates.
    pub fn reset(self: *Log, base: Base) void {
        assert((base.index == .zero) == (base.term == .zero));
        assert(self.count <= self.entries.len);

        self.base = base;
        self.count = 0;

        assert(self.last_index() == base.index);
        assert(self.last_term() == base.term);
    }

    /// Drops every entry with index `<= through` and makes `(through, term_at(through))` the new
    /// base, moving the kept entries to the front of the backing array once (one `copyForwards`).
    /// Preconditions: `base.index <= through <= last_index()`; `through == base.index` is a legal
    /// no-op. Never allocates; frees `through - base.index` slots for `append`.
    pub fn compact(self: *Log, through: Index) void {
        assert(through.order(self.base.index) != .lt);
        assert(through.order(self.last_index()) != .gt);

        const dropped: u32 = @intCast(@intFromEnum(through) - @intFromEnum(self.base.index));
        if (dropped == 0) return;

        const kept: u32 = self.count - dropped;
        const base_term = self.entries[dropped - 1].term;
        std.mem.copyForwards(Entry, self.entries[0..kept], self.entries[dropped..self.count]);

        self.base = .{ .index = through, .term = base_term };
        self.count = kept;

        assert(self.base.term != .zero); // Appended entries carry a nonzero term.
        assert(self.last_index().order(through) != .lt);
        assert(self.count == kept);
        assert(kept == 0 or self.entries[0].index == through.next());
    }

    /// Returns the term stored at `index`: `base.term` at `base.index` (`.zero` for the zero
    /// base, Raft's "no previous entry" sentinel), the entry's term above it, and
    /// `error.LogCompacted` below it. Precondition: `index <= last_index()`. A peer-supplied
    /// index (e.g. a leader's `prev_log_index`) is data, not a trusted caller value — range-check
    /// it against `last_index()` *before* calling this, the same contract `Index.next()`
    /// documents in `types.zig`; a lookup below the base is a returned error, not an assertion.
    pub fn term_at(self: *const Log, index: Index) TermError!Term {
        assert(index.order(self.last_index()) != .gt);
        assert(self.count <= self.entries.len);

        if (index.order(self.base.index) == .lt) return error.LogCompacted;
        return self.term_live(index);
    }

    /// Returns the term of the last entry, or `base.term` for an empty log.
    pub fn last_term(self: *const Log) Term {
        assert(self.count <= self.entries.len);
        if (self.count == 0) return self.base.term;

        assert(self.count > 0);
        return self.entries[self.count - 1].term;
    }

    /// Returns the entry stored at `index`. Preconditions: `base.index < index <= last_index()`.
    /// The pointer is invalidated by `append`, `truncate`, `compact` and `reset`.
    pub fn entry_at(self: *const Log, index: Index) *const Entry {
        assert(index.order(self.base.index) == .gt);
        assert(index.order(self.last_index()) != .gt);

        const slot: usize = @intCast(@intFromEnum(index) - @intFromEnum(self.base.index) - 1);
        assert(self.entries[slot].index == index);
        return &self.entries[slot];
    }

    /// Returns the entries with index in `(after, through]` (exclusive, inclusive) as a view of
    /// the backing array; empty when `after == through`. Preconditions: `base.index <= after <=
    /// through <= last_index()`. The slice is invalidated by `append`, `truncate`, `compact` and
    /// `reset`.
    pub fn range(self: *const Log, after: Index, through: Index) []const Entry {
        assert(after.order(self.base.index) != .lt);
        assert(after.order(through) != .gt);
        assert(through.order(self.last_index()) != .gt);

        const base_raw: u64 = @intFromEnum(self.base.index);
        const first: usize = @intCast(@intFromEnum(after) - base_raw);
        const end: usize = @intCast(@intFromEnum(through) - base_raw);
        assert(end <= self.count);
        return self.entries[first..end];
    }

    /// Returns `base.index` for an empty log, else the index of the most recently appended entry.
    pub fn last_index(self: *const Log) Index {
        assert(self.count <= self.entries.len);
        if (self.count == 0) return self.base.index;

        assert(self.count > 0);
        return self.entries[self.count - 1].index;
    }

    /// `term_at` for an index already known to satisfy `base.index <= index <= last_index()`.
    fn term_live(self: *const Log, index: Index) Term {
        assert(index.order(self.base.index) != .lt);
        assert(index.order(self.last_index()) != .gt);

        if (index == self.base.index) return self.base.term;
        const slot: usize = @intCast(@intFromEnum(index) - @intFromEnum(self.base.index) - 1);
        return self.entries[slot].term;
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
    /// index of that term's contiguous run, found by scanning backward but never below
    /// `base.index + 1`; a mismatch at `base.index` itself reports `base.index`. Precondition:
    /// `prev_log_index == .zero` or `prev_log_index >= base.index` (callers trim a peer's older
    /// prefix first, so a compacted `prev_log_index` never reaches this function).
    pub fn conflict_at(self: *const Log, prev_log_index: Index, prev_log_term: Term) ?Conflict {
        assert((prev_log_index == .zero) == (prev_log_term == .zero));

        if (prev_log_index == .zero) return null;

        assert(prev_log_index.order(self.base.index) != .lt);

        if (prev_log_index.order(self.last_index()) == .gt) {
            return .{ .index = .zero, .term = .zero };
        }

        const conflict_term = self.term_live(prev_log_index);
        if (conflict_term == prev_log_term) return null;

        const floor_raw: u64 = @intFromEnum(self.base.index) + 1;
        var first_index = prev_log_index;
        for (0..self.entries.len) |_| {
            if (@intFromEnum(first_index) <= floor_raw) break;
            const candidate: Index = @enumFromInt(@intFromEnum(first_index) - 1);
            if (self.term_live(candidate) != conflict_term) break;
            first_index = candidate;
        }

        assert(first_index.order(self.base.index) != .lt);
        assert(first_index.order(prev_log_index) != .gt);
        return .{ .index = first_index, .term = conflict_term };
    }

    /// Data-corruption errors `validate` returns — never raised by any state reachable through
    /// the normal `append`/`truncate` API, only by bit-rot or a hand-corrupted backing array
    /// (e.g. a test double, or a peer-loaded store in the simulator). REALM.md: "Invariant
    /// violations return `error.Invariant*` ... rather than asserting/panicking mid-run."
    pub const InvariantError = error{
        /// `entries[i].index != base.index + 1 + i` for some live entry: the log is no longer
        /// contiguous.
        InvariantIndexNotContiguous,
        /// `entries[i].term` is lower than `entries[i - 1].term` (or `entries[0].term` is lower
        /// than `base.term`): Raft terms never regress along the log.
        InvariantTermRegressed,
        /// `count > 0` and `entries[0].index != base.index + 1`: a hole or an overlap between
        /// the dropped prefix and the first live entry.
        InvariantSnapshotGap,
        /// Exactly one of `base.index` and `base.term` is zero.
        InvariantBaseMalformed,
    };

    /// Defense-in-depth invariant check for the simulator: a well-formed base, index contiguity
    /// from `base.index + 1`, and non-decreasing terms starting at `base.term`, across
    /// `entries[0..count]`. A log built only through the public API can never fail this — it
    /// exists to catch corrupted state, not caller bugs, so it returns a typed error rather than
    /// asserting (see `InvariantError` doc). No precondition beyond `self` being initialized.
    pub fn validate(self: *const Log) InvariantError!void {
        assert(self.count <= self.entries.len);

        if ((self.base.index == .zero) != (self.base.term == .zero)) {
            return error.InvariantBaseMalformed;
        }
        if (self.count == 0) return;

        // A corrupt base near `maxInt` must return a typed error, never trap on overflow.
        const base_raw: u64 = @intFromEnum(self.base.index);
        const first_expected = std.math.add(u64, base_raw, 1) catch {
            return error.InvariantSnapshotGap;
        };
        if (@intFromEnum(self.entries[0].index) != first_expected) {
            return error.InvariantSnapshotGap;
        }

        var term_previous = self.base.term;
        for (self.entries[0..self.count], 0..) |entry, i| {
            const expected_index = std.math.add(u64, first_expected, i) catch {
                return error.InvariantIndexNotContiguous;
            };
            if (@intFromEnum(entry.index) != expected_index) {
                return error.InvariantIndexNotContiguous;
            }
            if (entry.term.order(term_previous) == .lt) return error.InvariantTermRegressed;
            term_previous = entry.term;
        }

        assert(@intFromEnum(self.entries[0].index) == first_expected);
        assert(@intFromEnum(self.entries[self.count - 1].index) == base_raw + self.count);
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
    try testing.expectEqual(Term.zero, try log.term_at(.zero));
}

test "log: appending one entry becomes last_index and is visible via term_at" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    const entry = test_entry(1, 7);
    try log.append(entry);

    try testing.expectEqual(entry.index, log.last_index());
    try testing.expectEqual(entry.term, try log.term_at(entry.index));
    // Term before the first entry is still the "no previous entry" sentinel.
    try testing.expectEqual(Term.zero, try log.term_at(.zero));
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
            try testing.expectEqual(
                @as(Term, @enumFromInt(past_term)),
                try log.term_at(past_index),
            );
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
    try testing.expectEqual(@as(Term, @enumFromInt(1)), try log.term_at(@enumFromInt(1)));
    try testing.expectEqual(@as(Term, @enumFromInt(2)), try log.term_at(@enumFromInt(2)));

    // The truncated suffix is gone: re-appending at the freed index must succeed.
    try log.append(test_entry(3, 99));
    try testing.expectEqual(@as(Index, @enumFromInt(3)), log.last_index());
    try testing.expectEqual(@as(Term, @enumFromInt(99)), try log.term_at(@enumFromInt(3)));
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
    try testing.expectEqual(Term.zero, try log.term_at(.zero));
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
    try testing.expectEqual(@as(Term, @enumFromInt(3)), try log.term_at(before_last));
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
    // Proof: prev_log_index >= base.index in every caller, so it is never compacted.
    const actual_term = log.term_at(prev_log_index) catch unreachable; // proof: see above.
    if (actual_term == prev_log_term) return null;

    // The run is bounded by the live entries: never scan to or below the base index.
    const floor: u64 = @intFromEnum(log.base.index) + 1;
    var first_index = prev_log_index;
    while (@intFromEnum(first_index) > floor) {
        const candidate: Index = @enumFromInt(@intFromEnum(first_index) - 1);
        // Proof: candidate >= floor > base.index, so it is never compacted.
        const term = log.term_at(candidate) catch unreachable; // proof: see above.
        if (term != actual_term) break;
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
            prev_log_term = try log.term_at(prev_log_index);
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
        error.InvariantBaseMalformed,
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
        try testing.expectEqual(model.term_at(index), try log.term_at(index));
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

// --- base index (plan 005 item 2, ADR-009 "Log base"): compaction, reset, term_at errors ---

/// Test-only helper: builds a `Base` from raw integers.
fn test_base(index: u64, term: u64) Base {
    return .{ .index = @enumFromInt(index), .term = @enumFromInt(term) };
}

/// Test-only helper: `Index` from a raw integer.
fn index_of(raw: u64) Index {
    return @enumFromInt(raw);
}

/// Test-only helper: `Term` from a raw integer.
fn term_of(raw: u64) Term {
    return @enumFromInt(raw);
}

/// Test-only helper: appends entries `first..=last`, all with `term`.
fn append_run(log: *Log, first: u64, last: u64, term: u64) !void {
    var i = first;
    while (i <= last) : (i += 1) try log.append(test_entry(i, term));
}

test "log: Base.zero is the all-zero pair and TermError is exhaustively switchable" {
    try testing.expectEqual(Index.zero, Base.zero.index);
    try testing.expectEqual(Term.zero, Base.zero.term);

    const err: TermError = error.LogCompacted;
    switch (err) {
        error.LogCompacted => {},
    }
}

test "log: a fresh log starts at the zero base with last_term zero" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    try testing.expectEqual(Base.zero, log.base);
    try testing.expectEqual(Index.zero, log.last_index());
    try testing.expectEqual(Term.zero, log.last_term());
    try log.validate();
}

test "log: last_term follows the tail through append and truncate" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);

    try log.append(test_entry(1, 2));
    try testing.expectEqual(term_of(2), log.last_term());
    try log.append(test_entry(2, 2));
    try testing.expectEqual(term_of(2), log.last_term());
    try log.append(test_entry(3, 5));
    try testing.expectEqual(term_of(5), log.last_term());

    log.truncate(index_of(3));
    try testing.expectEqual(term_of(2), log.last_term());
    log.truncate(index_of(1));
    try testing.expectEqual(Term.zero, log.last_term());
    try log.validate();
}

test "log: reset to a nonzero base empties the log and the next append is base + 1" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    try append_run(&log, 1, 3, 1);

    log.reset(test_base(10, 4));

    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(test_base(10, 4), log.base);
    try testing.expectEqual(index_of(10), log.last_index());
    try testing.expectEqual(term_of(4), log.last_term());
    try testing.expectEqual(term_of(4), try log.term_at(index_of(10)));
    try testing.expectError(error.LogCompacted, log.term_at(index_of(9)));
    try testing.expectError(error.LogCompacted, log.term_at(.zero));
    try log.validate();

    try log.append(test_entry(11, 4));
    try testing.expectEqual(index_of(11), log.last_index());
    try testing.expectEqual(term_of(4), try log.term_at(index_of(11)));
    try log.validate();
}

test "log: reset back to the zero base restores the index-one origin" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(7, 2));
    try log.append(test_entry(8, 2));

    log.reset(Base.zero);

    try testing.expectEqual(Base.zero, log.base);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(Index.zero, log.last_index());
    try testing.expectEqual(Term.zero, try log.term_at(.zero));
    try log.validate();
    try log.append(test_entry(1, 1));
    try log.validate();
}

test "log: reset on a full log frees every slot" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 3 });
    defer log.deinit(testing.allocator);
    try append_run(&log, 1, 3, 1);
    try testing.expectError(error.LogFull, log.append(test_entry(4, 1)));

    log.reset(test_base(3, 1));

    try append_run(&log, 4, 6, 2);
    try testing.expectError(error.LogFull, log.append(test_entry(7, 2)));
    try testing.expectEqual(index_of(6), log.last_index());
    try log.validate();
}

test "log: term_at is LogCompacted below the base, base.term at it, entry term above" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(5, 3));
    try log.append(test_entry(6, 3));
    try log.append(test_entry(7, 4));
    try log.append(test_entry(8, 4));

    // Every index below the base, including the .zero sentinel, has been compacted away.
    var below: u64 = 0;
    while (below < 5) : (below += 1) {
        try testing.expectError(error.LogCompacted, log.term_at(index_of(below)));
    }
    try testing.expectEqual(term_of(3), try log.term_at(index_of(5)));
    try testing.expectEqual(term_of(3), try log.term_at(index_of(6)));
    try testing.expectEqual(term_of(4), try log.term_at(index_of(7)));
    try testing.expectEqual(term_of(4), try log.term_at(index_of(8)));
}

test "log: compact mid-log moves the kept entries to the front and sets the base" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    const terms = [_]u64{ 1, 1, 2, 2, 3, 3 };
    for (terms, 0..) |term, i| try log.append(test_entry(i + 1, term));

    log.compact(index_of(4));

    try testing.expectEqual(test_base(4, 2), log.base);
    try testing.expectEqual(@as(u32, 2), log.count);
    try testing.expectEqual(index_of(6), log.last_index());
    try testing.expectEqual(term_of(3), log.last_term());
    try testing.expectEqual(index_of(5), log.entries[0].index);
    try testing.expectEqual(index_of(6), log.entries[1].index);
    try testing.expectError(error.LogCompacted, log.term_at(index_of(3)));
    try testing.expectEqual(term_of(2), try log.term_at(index_of(4)));
    try testing.expectEqual(term_of(3), try log.term_at(index_of(5)));
    try testing.expectEqual(term_of(3), try log.term_at(index_of(6)));
    try log.validate();
}

test "log: compact at the current base is a legal no-op, at zero and at a nonzero base" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    try append_run(&log, 1, 3, 1);

    log.compact(.zero);
    try testing.expectEqual(Base.zero, log.base);
    try testing.expectEqual(@as(u32, 3), log.count);
    try testing.expectEqual(index_of(3), log.last_index());
    try log.validate();

    log.compact(index_of(2));
    const base_before = log.base;
    log.compact(index_of(2));
    try testing.expectEqual(base_before, log.base);
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(index_of(3), log.entries[0].index);
    try log.validate();
}

test "log: compact on an empty log at its base changes nothing" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);

    log.compact(.zero);
    try testing.expectEqual(Base.zero, log.base);
    try testing.expectEqual(@as(u32, 0), log.count);
    try log.validate();

    log.reset(test_base(7, 2));
    log.compact(index_of(7));
    try testing.expectEqual(test_base(7, 2), log.base);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(index_of(7), log.last_index());
    try log.validate();
}

test "log: compact through last_index empties the log with the base at the last entry" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    const terms = [_]u64{ 1, 1, 2, 2, 3 };
    for (terms, 0..) |term, i| try log.append(test_entry(i + 1, term));

    log.compact(index_of(5));

    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(test_base(5, 3), log.base);
    try testing.expectEqual(index_of(5), log.last_index());
    try testing.expectEqual(term_of(3), log.last_term());
    try testing.expectEqual(term_of(3), try log.term_at(index_of(5)));
    try testing.expectError(error.LogCompacted, log.term_at(index_of(4)));
    try log.validate();

    try log.append(test_entry(6, 3));
    try testing.expectEqual(index_of(6), log.last_index());
    try log.validate();
}

test "log: compact frees capacity so a full log accepts appends again" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 3 });
    defer log.deinit(testing.allocator);
    try append_run(&log, 1, 3, 1);
    try testing.expectError(error.LogFull, log.append(test_entry(4, 1)));

    log.compact(index_of(2));

    try log.append(test_entry(4, 1));
    try log.append(test_entry(5, 1));
    try testing.expectError(error.LogFull, log.append(test_entry(6, 1)));
    try testing.expectEqual(index_of(5), log.last_index());
    try log.validate();
}

test "log: truncate above a base keeps the base and falls back to it when emptied" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 2));
    try log.append(test_entry(11, 2));
    try log.append(test_entry(12, 3));
    try log.append(test_entry(13, 3));

    log.truncate(index_of(12));
    try testing.expectEqual(index_of(11), log.last_index());
    try testing.expectEqual(term_of(2), log.last_term());

    log.truncate(index_of(11));
    try testing.expectEqual(test_base(10, 2), log.base);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(index_of(10), log.last_index());
    try testing.expectEqual(term_of(2), log.last_term());
    try log.validate();

    // Truncating exactly at last_index() + 1 of an empty-at-base log is still a legal no-op.
    log.truncate(index_of(11));
    try testing.expectEqual(index_of(10), log.last_index());
    try log.append(test_entry(11, 5));
    try log.validate();
}

test "log: entry_at returns the live entry for every index above the base" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 2));
    const terms = [_]u64{ 2, 2, 3, 3, 4 };
    for (terms, 0..) |term, i| try log.append(test_entry(11 + i, term));

    for (terms, 0..) |term, i| {
        const entry = log.entry_at(index_of(11 + i));
        try testing.expectEqual(index_of(11 + i), entry.index);
        try testing.expectEqual(term_of(term), entry.term);
    }
}

test "log: range covers (after, through] and is empty, single, partial or full" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 2));

    // Empty log at its base: the only legal range is empty.
    try testing.expectEqual(@as(usize, 0), log.range(index_of(10), index_of(10)).len);

    try append_run(&log, 11, 15, 3);

    try testing.expectEqual(@as(usize, 0), log.range(index_of(12), index_of(12)).len);
    try testing.expectEqual(@as(usize, 0), log.range(index_of(15), index_of(15)).len);

    const one = log.range(index_of(14), index_of(15));
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(index_of(15), one[0].index);

    const mid = log.range(index_of(11), index_of(13));
    try testing.expectEqual(@as(usize, 2), mid.len);
    try testing.expectEqual(index_of(12), mid[0].index);
    try testing.expectEqual(index_of(13), mid[1].index);

    const full = log.range(index_of(10), index_of(15));
    try testing.expectEqual(@as(usize, 5), full.len);
    for (full, 0..) |entry, i| {
        try testing.expectEqual(index_of(11 + i), entry.index);
        try testing.expectEqual(term_of(3), entry.term);
    }
}

test "log: range with the zero base starts at index one" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), log.range(.zero, .zero).len);
    try append_run(&log, 1, 3, 1);

    const full = log.range(.zero, index_of(3));
    try testing.expectEqual(@as(usize, 3), full.len);
    try testing.expectEqual(index_of(1), full[0].index);
    try testing.expectEqual(index_of(3), full[2].index);
}

// --- conflict_at with a base: stops at base.index + 1, compares base.term at the base ---

test "log: conflict_at at prev_log_index == base compares against base.term" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 3));
    try log.append(test_entry(11, 3));
    try log.append(test_entry(12, 3));
    try log.append(test_entry(13, 4));

    try testing.expectEqual(@as(?Conflict, null), log.conflict_at(index_of(10), term_of(3)));

    // Mismatch at the base itself: the run cannot extend below the base, so it is the base.
    const expected: Conflict = .{ .index = index_of(10), .term = term_of(3) };
    try testing.expectEqual(expected, log.conflict_at(index_of(10), term_of(9)).?);
}

test "log: conflict_at backward scan stops at base.index + 1 even when base.term repeats" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 3));
    try log.append(test_entry(11, 3));
    try log.append(test_entry(12, 3));
    try log.append(test_entry(13, 4));

    // Index 12 is in a term-3 run that starts at 11; term_at(10) is also 3 but is the base.
    const in_run: Conflict = .{ .index = index_of(11), .term = term_of(3) };
    try testing.expectEqual(in_run, log.conflict_at(index_of(12), term_of(9)).?);

    const single: Conflict = .{ .index = index_of(13), .term = term_of(4) };
    try testing.expectEqual(single, log.conflict_at(index_of(13), term_of(9)).?);

    try testing.expectEqual(@as(?Conflict, null), log.conflict_at(index_of(13), term_of(4)));
}

test "log: conflict_at past last_index reports the zero boundary above a base" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(10, 3));
    const expected_zero: Conflict = .{ .index = .zero, .term = .zero };

    // Empty log at its base: base.index + 1 is already past the end.
    try testing.expectEqual(expected_zero, log.conflict_at(index_of(11), term_of(1)).?);
    try testing.expectEqual(@as(?Conflict, null), log.conflict_at(index_of(10), term_of(3)));

    try log.append(test_entry(11, 3));
    try testing.expectEqual(expected_zero, log.conflict_at(index_of(12), term_of(3)).?);
}

/// Runs the compacted-log `conflict_at` comparison for one seed.
fn conflict_compacted_run(seed: u64) !void {
    const entries_max = 12;
    const queries_max = 200;

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var term: u64 = 1;
    var i: u64 = 1;
    while (i <= entries_max) : (i += 1) {
        if (random.boolean()) term += 1;
        try log.append(test_entry(i, term));
    }
    log.compact(index_of(random.intRangeAtMost(u64, 0, entries_max)));
    try log.validate();

    const base_raw = @intFromEnum(log.base.index);
    for (0..queries_max) |_| {
        const prev_raw = random.intRangeAtMost(u64, base_raw, entries_max + 2);
        const prev_log_index = index_of(prev_raw);
        var prev_log_term: Term = .zero;
        if (prev_raw != 0) {
            if (random.boolean() and prev_log_index.order(log.last_index()) != .gt) {
                prev_log_term = try log.term_at(prev_log_index);
            } else {
                prev_log_term = term_of(random.intRangeAtMost(u64, 1, term + 5));
            }
        }
        const expected = reference_conflict_at(&log, prev_log_index, prev_log_term);
        try testing.expectEqual(expected, log.conflict_at(prev_log_index, prev_log_term));
    }
}

test "log: conflict_at on a compacted log matches the linear-scan reference over many seeds" {
    const seeds = [_]u64{ 0xc0f1_0001, 0xc0f1_0002, 0xc0f1_0003, 0xc0f1_0004, 0xc0f1_0005 };
    for (seeds) |seed| try conflict_compacted_run(seed);
}

// --- validate(): base-aware invariants, every new variant provoked by hand-corruption ---

test "log: validate returns a typed error for a base at maxInt instead of overflowing" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 2 });
    defer log.deinit(testing.allocator);
    log.base = test_base(std.math.maxInt(u64), 1);
    log.entries[0] = test_entry(std.math.maxInt(u64), 1);
    log.count = 1;
    try testing.expectError(error.InvariantSnapshotGap, log.validate());

    // Valid first entry, second one would need index maxInt + 1.
    log.base = test_base(std.math.maxInt(u64) - 1, 1);
    log.entries[0] = test_entry(std.math.maxInt(u64), 1);
    log.entries[1] = test_entry(std.math.maxInt(u64), 1);
    log.count = 2;
    try testing.expectError(error.InvariantIndexNotContiguous, log.validate());
}

test "log: validate rejects a base with exactly one of index and term zero" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 4 });
    defer log.deinit(testing.allocator);
    try log.validate();

    log.base = .{ .index = index_of(5), .term = .zero };
    try testing.expectError(error.InvariantBaseMalformed, log.validate());

    log.base = .{ .index = .zero, .term = term_of(3) };
    try testing.expectError(error.InvariantBaseMalformed, log.validate());

    log.base = Base.zero;
    try log.validate();
    log.base = test_base(5, 3);
    try log.validate();
}

test "log: validate rejects a first live entry that is not base.index + 1" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(5, 2));
    try log.append(test_entry(6, 2));
    try log.append(test_entry(7, 2));
    try log.validate();

    log.entries[0].index = index_of(8); // A hole after the base.
    try testing.expectError(error.InvariantSnapshotGap, log.validate());

    log.entries[0].index = index_of(5); // Overlaps the base itself.
    try testing.expectError(error.InvariantSnapshotGap, log.validate());

    log.entries[0].index = index_of(1); // Index-one origin although the base is 5.
    try testing.expectError(error.InvariantSnapshotGap, log.validate());
}

test "log: validate rejects an entry whose term is below base.term but allows equal" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(5, 4));
    try log.append(test_entry(6, 4)); // Equal to base.term is legal.
    try log.append(test_entry(7, 5));
    try log.validate();

    log.entries[0].term = term_of(3);
    try testing.expectError(error.InvariantTermRegressed, log.validate());
}

test "log: validate rejects a non-contiguous index above a base" {
    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = 8 });
    defer log.deinit(testing.allocator);
    log.reset(test_base(5, 1));
    try append_run(&log, 6, 8, 1);
    try log.validate();

    log.entries[2].index = index_of(99);

    try testing.expectError(error.InvariantIndexNotContiguous, log.validate());
}

// --- bounded growth, allocation freedom, and the seeded model against a trivial reference ---

/// Non-decreasing term schedule for the long-run test, independent of `Log`.
fn run_term(index: u64) u64 {
    return index / 10 + 1;
}

test "log: 200 appends through a 64-entry log stay bounded when compacting every 32" {
    const entries_max = 64;
    const appends_total = 200;
    const compact_every = 32;
    const keep = 16;

    var log: Log = undefined;
    try log.init(testing.allocator, .{ .entries_max = entries_max });
    defer log.deinit(testing.allocator);

    var count_peak: u32 = 0;
    var i: u64 = 1;
    while (i <= appends_total) : (i += 1) {
        try log.append(test_entry(i, run_term(i)));
        count_peak = @max(count_peak, log.count);
        try log.validate();
        try testing.expect(log.count <= entries_max);
        try testing.expectEqual(index_of(i), log.last_index());
        try testing.expectEqual(term_of(run_term(i)), log.last_term());

        if (i % compact_every == 0) {
            log.compact(index_of(i - keep));
            try log.validate();
            try testing.expectEqual(test_base(i - keep, run_term(i - keep)), log.base);
            try testing.expectEqual(@as(u32, keep), log.count);
        }

        // Indices stay contiguous from base + 1 and every term matches the schedule.
        const base_raw = @intFromEnum(log.base.index);
        try testing.expectEqual(i - base_raw, @as(u64, log.count));
        var j = base_raw + 1;
        while (j <= i) : (j += 1) {
            try testing.expectEqual(index_of(j), log.entry_at(index_of(j)).index);
            try testing.expectEqual(term_of(run_term(j)), try log.term_at(index_of(j)));
        }
    }

    // Last compaction ran at i = 192, leaving base 176; peak is 16 kept + 32 new = 48.
    try testing.expectEqual(index_of(appends_total), log.last_index());
    try testing.expectEqual(test_base(176, run_term(176)), log.base);
    try testing.expectEqual(@as(u32, 24), log.count);
    try testing.expectEqual(@as(u32, 48), count_peak);
}

test "log: append, truncate, compact and reset never allocate after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();

    var log: Log = undefined;
    try log.init(gpa, .{ .entries_max = 4 });
    defer log.deinit(gpa);

    try append_run(&log, 1, 4, 1);
    log.truncate(index_of(3));
    try log.append(test_entry(3, 2));
    log.compact(index_of(2));
    try log.append(test_entry(4, 2));
    log.reset(test_base(9, 3));
    try log.append(test_entry(10, 3));
    log.compact(index_of(10));
    try log.validate();

    try testing.expectEqual(@as(usize, 1), failing.allocations);
    try testing.expect(!failing.has_induced_failure);
}

/// Trivial reference for the base-aware log: a base pair plus a plain array of terms.
const BaseModel = struct {
    base_index: u64,
    base_term: u64,
    terms: [terms_max]u64,
    len: usize,

    const terms_max = 8;

    fn init() BaseModel {
        return .{ .base_index = 0, .base_term = 0, .terms = [_]u64{0} ** terms_max, .len = 0 };
    }

    fn last_index(self: *const BaseModel) u64 {
        return self.base_index + self.len;
    }

    fn last_term(self: *const BaseModel) u64 {
        if (self.len == 0) return self.base_term;
        return self.terms[self.len - 1];
    }

    /// Null when `index` lies below the base, i.e. was compacted away.
    fn term_at(self: *const BaseModel, index: u64) ?u64 {
        if (index < self.base_index) return null;
        if (index == self.base_index) return self.base_term;
        return self.terms[@intCast(index - self.base_index - 1)];
    }

    fn append(self: *BaseModel, term: u64) void {
        self.terms[self.len] = term;
        self.len += 1;
    }

    fn truncate(self: *BaseModel, from: u64) void {
        self.len = @intCast(from - self.base_index - 1);
    }

    fn compact(self: *BaseModel, through: u64) void {
        const dropped: usize = @intCast(through - self.base_index);
        const new_term = self.term_at(through).?;
        for (0..self.len - dropped) |i| self.terms[i] = self.terms[i + dropped];
        self.len -= dropped;
        self.base_index = through;
        self.base_term = new_term;
    }

    fn reset(self: *BaseModel, index: u64, term: u64) void {
        self.base_index = index;
        self.base_term = term;
        self.len = 0;
    }
};

/// Checks `log` agrees with `model` on base, tail, every index from zero to last, and validate.
fn check_base_model(log: *const Log, model: *const BaseModel) !void {
    try testing.expectEqual(model.base_index, @intFromEnum(log.base.index));
    try testing.expectEqual(model.base_term, @intFromEnum(log.base.term));
    try testing.expectEqual(model.last_index(), @intFromEnum(log.last_index()));
    try testing.expectEqual(model.last_term(), @intFromEnum(log.last_term()));
    try testing.expectEqual(model.len, @as(usize, log.count));

    var i: u64 = 0;
    while (i <= model.last_index()) : (i += 1) {
        if (model.term_at(i)) |term| {
            try testing.expectEqual(term_of(term), try log.term_at(index_of(i)));
        } else {
            try testing.expectError(error.LogCompacted, log.term_at(index_of(i)));
        }
        if (i > model.base_index) {
            const entry = log.entry_at(index_of(i));
            try testing.expectEqual(index_of(i), entry.index);
            try testing.expectEqual(term_of(model.term_at(i).?), entry.term);
        }
    }
    try testing.expectEqual(model.len, log.range(log.base.index, log.last_index()).len);
    try log.validate();
}

/// Applies one random operation to both `log` and `model`.
fn step_base_model(log: *Log, model: *BaseModel, random: std.Random) !void {
    switch (random.uintLessThan(u8, 10)) {
        0...4 => {
            const term = @max(model.last_term() + random.intRangeAtMost(u64, 0, 1), 1);
            const result = log.append(test_entry(model.last_index() + 1, term));
            if (model.len == BaseModel.terms_max) {
                try testing.expectError(error.LogFull, result);
            } else {
                try result;
                model.append(term);
            }
        },
        5 => {
            const from = random.intRangeAtMost(u64, model.base_index + 1, model.last_index() + 1);
            log.truncate(index_of(from));
            model.truncate(from);
        },
        6...8 => {
            const through = random.intRangeAtMost(u64, model.base_index, model.last_index());
            log.compact(index_of(through));
            model.compact(through);
        },
        9 => {
            var base: Base = Base.zero;
            if (random.uintLessThan(u8, 4) != 0) {
                base = test_base(
                    random.intRangeAtMost(u64, 1, 100),
                    random.intRangeAtMost(u64, 1, 20),
                );
            }
            log.reset(base);
            model.reset(@intFromEnum(base.index), @intFromEnum(base.term));
        },
        else => unreachable,
    }
}

test "log: seeded model-based append/truncate/compact/reset matches a trivial reference" {
    const seeds = [_]u64{ 0x5eed_0001, 0x5eed_0002, 0xba5e_1dea, 0xc0ff_ee11, 0x0123_4567 };
    const ops_max = 400;
    var saw_compacted_base = false;

    for (seeds) |seed| {
        var log: Log = undefined;
        try log.init(testing.allocator, .{ .entries_max = BaseModel.terms_max });
        defer log.deinit(testing.allocator);

        var model = BaseModel.init();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        try check_base_model(&log, &model);
        for (0..ops_max) |_| {
            try step_base_model(&log, &model, random);
            try check_base_model(&log, &model);
            if (model.base_index > 0) saw_compacted_base = true;
        }
    }
    // The walk must have actually reached nonzero bases, or the LogCompacted path is unproven.
    try testing.expect(saw_compacted_base);
}

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const Index = types.Index;
const Term = types.Term;
const Entry = types.Entry;
const Conflict = types.Conflict;
const assert = std.debug.assert;
