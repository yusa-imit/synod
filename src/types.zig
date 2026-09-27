//! synod.types — the Raft vocabulary shared by every synod module: node ids, terms, log
//! indices, log entries, persisted hard state, and snapshot metadata.
//!
//! Invariants: `NodeId`, `Term`, `Index` are distinct `enum(u64)` types — passing a term where
//! an index is expected fails to compile. 0 is a named sentinel in each (`NodeId.none`,
//! `Term.zero`, `Index.zero`); no entry is ever written at index zero or term zero.
//! `HardState` is `extern` with no padding (24 bytes), so it compares and hashes byte-for-byte.
//!
//! Allocation and ownership: this module never allocates. `Entry.data` and `Snapshot.data` are
//! borrowed; the producer owns the bytes and must outlive every copy of the value.
//!
//! Encoding: none here. The core sees `[]const u8` (PRD §7); on-disk and on-wire encodings
//! live in adapters and carry their own magic, version, and checksum (ADR-004).

/// Identifies a Raft node. Never `usize`: identical on all six cross-compile targets.
pub const NodeId = enum(u64) {
    /// No node — "has not voted this term" in `HardState.vote`. Never a real node's id.
    none = 0,
    _,
};

pub const Term = enum(u64) {
    /// Before the first election. No entry carries term zero.
    zero = 0,
    _,

    /// Total order by numeric value. Any two terms are comparable; no precondition.
    pub fn order(a: Term, b: Term) std.math.Order {
        const result = std.math.order(@intFromEnum(a), @intFromEnum(b));
        if (result == .eq) assert(a == b);
        if (result != .eq) assert(a != b);
        return result;
    }
};

pub const Index = enum(u64) {
    /// Before the first entry: the empty log's last index. Never an entry's index.
    zero = 0,
    _,

    /// Total order by numeric value. Any two indices are comparable; no precondition.
    pub fn order(a: Index, b: Index) std.math.Order {
        const result = std.math.order(@intFromEnum(a), @intFromEnum(b));
        if (result == .eq) assert(a == b);
        if (result != .eq) assert(a != b);
        return result;
    }

    /// The following index. Precondition: `index` < maxInt(u64). An index read from a message
    /// or from disk is data — range-check it and return a typed error before calling `next`.
    pub fn next(index: Index) Index {
        assert(@intFromEnum(index) < std.math.maxInt(u64));
        const result: Index = @enumFromInt(@intFromEnum(index) + 1);
        assert(result != .zero);
        assert(result.order(index) == .gt);
        return result;
    }
};

/// Discriminants start at 1 so zero-filled memory never decodes as a valid kind.
pub const EntryKind = enum(u8) {
    /// Application command. `data` may be empty (a new leader's no-op entry).
    normal = 1,
    /// Membership change; `data` holds an encoded `ConfChange` (defined in item 1A-ii).
    conf_change = 2,
};

/// One log entry. `data` is borrowed (see module header).
pub const Entry = struct {
    index: Index,
    term: Term,
    kind: EntryKind,
    data: []const u8,
};

/// Raft state that must be durable before a message is sent (term, vote, commit).
pub const HardState = extern struct {
    term: Term,
    vote: NodeId,
    commit_index: Index,

    /// A node that has persisted nothing yet.
    pub const empty: HardState = .{ .term = .zero, .vote = .none, .commit_index = .zero };

    /// Options struct for `validateTransition`: `previous` and `next` cannot be swapped silently.
    pub const Transition = struct { previous: HardState, next: HardState };

    /// Field-wise equality (used to skip a redundant persist).
    pub fn eql(a: *const HardState, b: *const HardState) bool {
        const fields_equal = a.term == b.term and a.vote == b.vote and
            a.commit_index == b.commit_index;
        const bytes_equal = std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
        assert(fields_equal == bytes_equal); // Valid only because of the no-padding asserts.
        if (!fields_equal) assert(!bytes_equal);
        return fields_equal;
    }

    /// Raft durability contract: term never decreases, commit_index never decreases, and a
    /// vote cast in a term is never changed or withdrawn in that term. Checks run in order
    /// term → vote → commit; the first failure is returned. No precondition: both states are
    /// data (read back from a store, or produced by the core under simulation).
    pub fn validateTransition(transition: *const Transition) Error!void {
        const previous = &transition.previous;
        const next = &transition.next;
        switch (next.term.order(previous.term)) {
            .lt => return error.InvariantTermRegressed,
            .eq => if (previous.vote != .none) {
                if (next.vote != previous.vote) return error.InvariantVoteChanged;
            },
            .gt => {},
        }
        if (next.commit_index.order(previous.commit_index) == .lt) {
            return error.InvariantCommitRegressed;
        }
        assert(next.term.order(previous.term) != .lt);
        assert(next.commit_index.order(previous.commit_index) != .lt);
        if (next.term == previous.term) {
            if (previous.vote != .none) assert(next.vote == previous.vote);
        }
    }
};

/// Snapshot metadata plus opaque state-machine bytes. `index`/`term` identify the last entry
/// the snapshot replaces (inclusive). `data` is borrowed. No compaction policy (plan 002).
pub const Snapshot = struct {
    index: Index,
    term: Term,
    data: []const u8,
};

/// Module-level error set. `validateTransition` is the only fallible function here.
pub const Error = error{
    InvariantTermRegressed,
    InvariantVoteChanged,
    InvariantCommitRegressed,
};

comptime {
    assert(@sizeOf(NodeId) == 8);
    assert(@sizeOf(Term) == 8);
    assert(@sizeOf(Index) == 8);
    assert(@sizeOf(EntryKind) == 1);
    assert(@sizeOf(HardState) == 3 * @sizeOf(u64)); // No padding: `eql`'s byte path relies on it.
    assert(@alignOf(HardState) == @alignOf(u64));
}

test "types: module compiles" {
    std.testing.refAllDecls(@This());
}

test "types: NodeId, Term, Index are distinct types with a zero sentinel" {
    try std.testing.expect(@TypeOf(NodeId.none) != @TypeOf(Term.zero) or NodeId != Term);
    try std.testing.expect(Term != Index);
    try std.testing.expect(Index != NodeId);
    try std.testing.expect(@typeInfo(Term).@"enum".tag_type == u64);
    try std.testing.expect(@typeInfo(Index).@"enum".tag_type == u64);
    try std.testing.expect(@typeInfo(NodeId).@"enum".tag_type == u64);
    try std.testing.expect(!@typeInfo(Term).@"enum".is_exhaustive);
    try std.testing.expect(!@typeInfo(Index).@"enum".is_exhaustive);
    try std.testing.expect(!@typeInfo(NodeId).@"enum".is_exhaustive);
    try std.testing.expectEqual(@as(u64, 0), @intFromEnum(NodeId.none));
    try std.testing.expectEqual(@as(u64, 0), @intFromEnum(Term.zero));
    try std.testing.expectEqual(@as(u64, 0), @intFromEnum(Index.zero));
}

test "types: Term.order fixed cases" {
    const t1: Term = @enumFromInt(1);
    const t2: Term = @enumFromInt(2);
    try std.testing.expectEqual(std.math.Order.lt, Term.order(t1, t2));
    try std.testing.expectEqual(std.math.Order.eq, Term.order(t2, t2));
    try std.testing.expectEqual(std.math.Order.gt, Term.order(t2, t1));
}

test "types: Term.order boundaries" {
    const max: Term = @enumFromInt(std.math.maxInt(u64));
    const max_minus_one: Term = @enumFromInt(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.Order.eq, Term.order(.zero, .zero));
    const one: Term = @enumFromInt(1);
    try std.testing.expectEqual(std.math.Order.lt, Term.order(.zero, one));
    try std.testing.expectEqual(std.math.Order.gt, Term.order(max, max_minus_one));
}

test "types: Term.order seeded model against std.math.order" {
    var prng = std.Random.DefaultPrng.init(0x5eed_7e12);
    const random = prng.random();
    for (0..1000) |_| {
        const a_raw = random.int(u64);
        const b_raw = random.int(u64);
        const a: Term = @enumFromInt(a_raw);
        const b: Term = @enumFromInt(b_raw);
        try std.testing.expectEqual(std.math.order(a_raw, b_raw), Term.order(a, b));
        try std.testing.expectEqual(Term.order(a, b).invert(), Term.order(b, a));
    }
}

test "types: Index.order fixed cases and boundaries" {
    const index_one: Index = @enumFromInt(1);
    const index_two: Index = @enumFromInt(2);
    try std.testing.expectEqual(std.math.Order.lt, Index.order(index_one, index_two));
    try std.testing.expectEqual(std.math.Order.eq, Index.order(index_two, index_two));
    try std.testing.expectEqual(std.math.Order.gt, Index.order(index_two, index_one));
    try std.testing.expectEqual(std.math.Order.eq, Index.order(.zero, .zero));
}

test "types: Index.order seeded model against std.math.order" {
    var prng = std.Random.DefaultPrng.init(0x1dea_1dea);
    const random = prng.random();
    for (0..1000) |_| {
        const a_raw = random.int(u64);
        const b_raw = random.int(u64);
        const a: Index = @enumFromInt(a_raw);
        const b: Index = @enumFromInt(b_raw);
        try std.testing.expectEqual(std.math.order(a_raw, b_raw), Index.order(a, b));
        try std.testing.expectEqual(Index.order(a, b).invert(), Index.order(b, a));
    }
}

test "types: Index.next moves strictly forward" {
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(Index.zero.next()));
    const forty_one: Index = @enumFromInt(41);
    try std.testing.expectEqual(@as(u64, 42), @intFromEnum(forty_one.next()));
    const max_minus_one: Index = @enumFromInt(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), @intFromEnum(max_minus_one.next()));
    // Index.next's `assert(index < maxInt(u64))` precondition guards caller state, not data —
    // calling it on `maxInt` would panic, which cannot be exercised without crashing the test
    // process, so it is documented here rather than tested.
    var prng = std.Random.DefaultPrng.init(0x9e5f);
    const random = prng.random();
    for (0..100) |_| {
        const raw = random.intRangeAtMost(u64, 0, std.math.maxInt(u64) - 1);
        const index: Index = @enumFromInt(raw);
        try std.testing.expectEqual(std.math.Order.gt, index.next().order(index));
    }
}

test "types: EntryKind is exhaustive with discriminants starting at 1" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EntryKind.normal));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EntryKind.conf_change));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(EntryKind).@"enum".fields.len);
    try std.testing.expectEqual(@as(?EntryKind, null), std.enums.fromInt(EntryKind, 0));
    try std.testing.expectEqual(@as(?EntryKind, null), std.enums.fromInt(EntryKind, 3));

    var seen_normal = false;
    var seen_conf_change = false;
    for ([_]EntryKind{ .normal, .conf_change }) |kind| {
        switch (kind) {
            .normal => seen_normal = true,
            .conf_change => seen_conf_change = true,
        }
    }
    try std.testing.expect(seen_normal);
    try std.testing.expect(seen_conf_change);
}

/// Test-only helper: builds an `Entry` from raw integers so test cases stay one line each.
fn testEntry(index: u64, term: u64, kind: EntryKind, data: []const u8) Entry {
    return .{
        .index = @enumFromInt(index),
        .term = @enumFromInt(term),
        .kind = kind,
        .data = data,
    };
}

test "types: Entry construction borrows data, not copies" {
    const buf = "hello";
    const normal_entry = testEntry(1, 1, .normal, buf);
    try std.testing.expectEqual(buf.ptr, normal_entry.data.ptr);

    const noop_entry = testEntry(1, 1, .normal, "");
    try std.testing.expectEqual(@as(usize, 0), noop_entry.data.len);

    const max_entry = testEntry(std.math.maxInt(u64), std.math.maxInt(u64), .conf_change, buf);
    try std.testing.expectEqual(EntryKind.conf_change, max_entry.kind);
}

test "types: HardState layout has no padding" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(HardState));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HardState, "term"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HardState, "vote"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(HardState, "commit_index"));
    const empty = HardState.empty;
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&empty), 0));
}

/// Test-only helper: builds a `HardState` from raw integers so test cases stay one line each.
fn testHardState(term: u64, vote: u64, commit_index: u64) HardState {
    return .{
        .term = @enumFromInt(term),
        .vote = @enumFromInt(vote),
        .commit_index = @enumFromInt(commit_index),
    };
}

test "types: HardState.eql is reflexive and symmetric" {
    const a = HardState.empty;
    try std.testing.expect(a.eql(&a));
    const b = testHardState(3, 2, 5);
    try std.testing.expect(b.eql(&b));
    try std.testing.expect(HardState.empty.eql(&HardState.empty));
    try std.testing.expectEqual(a.eql(&b), b.eql(&a));
}

test "types: HardState.eql detects a single differing field" {
    const base = testHardState(3, 2, 5);
    const diff_term = testHardState(4, 2, 5);
    const diff_vote = testHardState(3, 9, 5);
    const diff_commit = testHardState(3, 2, 6);
    try std.testing.expect(!base.eql(&diff_term));
    try std.testing.expect(!base.eql(&diff_vote));
    try std.testing.expect(!base.eql(&diff_commit));
}

test "types: HardState.eql seeded model against field-wise reference" {
    var prng = std.Random.DefaultPrng.init(0xba5e);
    const random = prng.random();
    for (0..1000) |_| {
        const a: HardState = .{
            .term = @enumFromInt(random.int(u64)),
            .vote = @enumFromInt(random.int(u64)),
            .commit_index = @enumFromInt(random.int(u64)),
        };
        const b: HardState = .{
            .term = @enumFromInt(random.int(u64)),
            .vote = @enumFromInt(random.int(u64)),
            .commit_index = @enumFromInt(random.int(u64)),
        };
        const expected = a.term == b.term and a.vote == b.vote and a.commit_index == b.commit_index;
        try std.testing.expectEqual(expected, a.eql(&b));
    }
}

/// Test-only helper: cuts the `HardState.validateTransition(&.{ .previous = ..., .next = ... })`
/// boilerplate down to one call per test case.
fn testValidate(previous: HardState, next: HardState) Error!void {
    return HardState.validateTransition(&.{ .previous = previous, .next = next });
}

test "types: validateTransition allows a no-op persist" {
    try testValidate(HardState.empty, HardState.empty);
}

test "types: validateTransition allows term advancing with a vote change" {
    const previous = testHardState(1, 1, 0);
    try testValidate(previous, testHardState(2, 0, 0)); // Vote reset to `.none`.
    try testValidate(previous, testHardState(2, 2, 0)); // Vote changed to a new candidate.
}

test "types: validateTransition allows first vote in a term and non-decreasing commit" {
    const not_voted = testHardState(1, 0, 0);
    const voted = testHardState(1, 3, 0);
    try testValidate(not_voted, voted);
    try testValidate(voted, testHardState(1, 3, 0)); // Commit stays equal.
    try testValidate(voted, testHardState(1, 3, 1)); // Commit advances.
}

test "types: validateTransition rejects a term regression" {
    const previous = testHardState(2, 0, 0);
    const result = testValidate(previous, testHardState(1, 0, 0));
    try std.testing.expectError(error.InvariantTermRegressed, result);
}

test "types: validateTransition rejects a vote change within the same term" {
    const previous = testHardState(1, 1, 0);
    try std.testing.expectError(
        error.InvariantVoteChanged,
        testValidate(previous, testHardState(1, 2, 0)),
    );
    try std.testing.expectError(
        error.InvariantVoteChanged,
        testValidate(previous, testHardState(1, 0, 0)),
    );
}

test "types: validateTransition rejects a commit regression" {
    const previous = testHardState(1, 0, 5);
    try std.testing.expectError(
        error.InvariantCommitRegressed,
        testValidate(previous, testHardState(1, 0, 4)),
    );
    try std.testing.expectError(
        error.InvariantCommitRegressed,
        testValidate(previous, testHardState(2, 0, 4)),
    );
}

test "types: validateTransition checks term before commit" {
    const previous = testHardState(2, 0, 5);
    const result = testValidate(previous, testHardState(1, 0, 1));
    try std.testing.expectError(error.InvariantTermRegressed, result);
}

test "types: validateTransition seeded model against a reference predicate" {
    var prng = std.Random.DefaultPrng.init(0xf00d_5eed);
    const random = prng.random();
    for (0..1000) |_| {
        const previous = testHardState(
            random.intRangeAtMost(u64, 0, 5),
            random.intRangeAtMost(u64, 0, 3),
            random.intRangeAtMost(u64, 0, 5),
        );
        const next = testHardState(
            random.intRangeAtMost(u64, 0, 5),
            random.intRangeAtMost(u64, 0, 3),
            random.intRangeAtMost(u64, 0, 5),
        );
        const result = testValidate(previous, next);
        const vote_changed = previous.vote != .none and next.vote != previous.vote;
        if (next.term.order(previous.term) == .lt) {
            try std.testing.expectError(error.InvariantTermRegressed, result);
        } else if (next.term == previous.term and vote_changed) {
            try std.testing.expectError(error.InvariantVoteChanged, result);
        } else if (next.commit_index.order(previous.commit_index) == .lt) {
            try std.testing.expectError(error.InvariantCommitRegressed, result);
        } else {
            try result;
        }
    }
}

test "types: Snapshot construction" {
    const empty_snapshot: Snapshot = .{ .index = .zero, .term = .zero, .data = "" };
    try std.testing.expectEqual(@as(usize, 0), empty_snapshot.data.len);

    const max_snapshot: Snapshot = .{
        .index = @enumFromInt(std.math.maxInt(u64)),
        .term = @enumFromInt(std.math.maxInt(u64)),
        .data = "state",
    };
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), @intFromEnum(max_snapshot.index));
}

test "types: Error is exhaustively switchable" {
    const err: Error = error.InvariantTermRegressed;
    switch (err) {
        error.InvariantTermRegressed,
        error.InvariantVoteChanged,
        error.InvariantCommitRegressed,
        => {},
    }
}

const std = @import("std");
const assert = std.debug.assert;
