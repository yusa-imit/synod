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

    /// Options struct for `validate_transition`: `previous` and `next` cannot be swapped silently.
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
    pub fn validate_transition(transition: *const Transition) Error!void {
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

/// Module-level error set. `validate_transition` is the only fallible function here.
pub const Error = error{
    InvariantTermRegressed,
    InvariantVoteChanged,
    InvariantCommitRegressed,
};

/// Oldest `Message.header.protocol_version` this build still accepts from a peer.
pub const protocol_version_min: u16 = 1;
/// Newest `Message.header.protocol_version` this build sends. `raft.Config` (plan 003) may
/// pin a node to an older version during a rolling upgrade.
pub const protocol_version_current: u16 = 1;
/// Per-`Configuration` cap on `voters` and `voters_outgoing`; bounds quorum math to a fixed
/// stack array (Tiger Style: a limit on everything).
pub const voters_max: u32 = 16;
/// Per-`Configuration` cap on `learners`.
pub const learners_max: u32 = 16;

comptime {
    assert(protocol_version_min > 0); // 0 is never a valid version (ADR-005).
    assert(protocol_version_min <= protocol_version_current);
    assert(voters_max > 0);
    assert(learners_max > 0);
}

/// First field of every `Message` payload. Constructing a payload without it fails to
/// compile — there is exactly one way to build a wire message (ADR-005).
pub const Header = struct {
    protocol_version: u16,
    term: Term,
    from: NodeId,
    to: NodeId,
};

/// Shared by `RequestVote` and `PreVote` (same shape, different `MessageKind`): a candidate's
/// claim to be at least as up to date as the receiver.
pub const VoteRequest = struct {
    header: Header,
    last_log_index: Index,
    last_log_term: Term,
};

/// Shared by `RequestVoteResponse` and `PreVoteResponse`.
pub const VoteResponse = struct {
    header: Header,
    granted: bool,
};

/// A rejected `AppendEntries`: the follower's term at `prev_log_index`, and — for fast
/// backtrack (Raft thesis §5.3) — that term's first index. A shorter log reports `.zero`.
pub const Conflict = struct {
    index: Index,
    term: Term,
};

/// Either the follower accepted and replicated through `Index`, or it rejected with a hint.
pub const AppendOutcome = union(enum) {
    accepted: Index,
    rejected: Conflict,
};

/// `entries` is borrowed (module header); valid until the receiver's `step()` returns.
pub const AppendRequest = struct {
    header: Header,
    prev_log_index: Index,
    prev_log_term: Term,
    leader_commit: Index,
    /// Echoed back in `AppendResponse` so a reordered response is dropped, not misapplied.
    round: u64,
    entries: []const Entry,
};

pub const AppendResponse = struct {
    header: Header,
    round: u64,
    outcome: AppendOutcome,
};

/// Cluster membership: joint consensus only, never a single-server add/remove (REALM.md).
/// `voters_outgoing` non-empty means "joint" (`C_old,new`); empty means a settled `C_new`.
/// All three lists are borrowed, strictly ascending by `NodeId`, and validated together.
pub const Configuration = struct {
    voters: []const NodeId,
    voters_outgoing: []const NodeId,
    learners: []const NodeId,

    /// Structural check only: no local state. Positive space (bounds, order) and negative
    /// space (dupes, a learner also a voter) are both asserted here on the same walk.
    pub fn validate(configuration: *const Configuration) ConfError!void {
        try validate_node_list(configuration.voters, voters_max, error.ConfVotersTooMany);
        if (configuration.voters.len == 0) return error.ConfVotersEmpty;
        try validate_node_list(configuration.voters_outgoing, voters_max, error.ConfVotersTooMany);
        try validate_node_list(configuration.learners, learners_max, error.ConfLearnersTooMany);
        for (configuration.learners) |learner| {
            for (configuration.voters) |voter| {
                if (learner == voter) return error.ConfLearnerIsVoter;
            }
        }
        assert(configuration.voters.len > 0);
        assert(configuration.voters.len <= voters_max);
    }
};

/// Checks `nodes` is strictly ascending (no duplicates, no `.none`) and within `max`. Shared
/// by `voters`, `voters_outgoing`, and `learners` — one sort-order rule, three call sites.
fn validate_node_list(nodes: []const NodeId, max: u32, too_many: ConfError) ConfError!void {
    if (nodes.len > max) return too_many;
    for (nodes, 0..) |node, i| {
        if (node == .none) return error.ConfNodesUnsorted;
        if (i == 0) continue;
        if (@intFromEnum(node) <= @intFromEnum(nodes[i - 1])) return error.ConfNodesUnsorted;
    }
}

/// Membership as of `snapshot.index`; a follower installing a snapshot has no other way to
/// learn the cluster it just joined.
pub const SnapshotRequest = struct {
    header: Header,
    snapshot: Snapshot,
    configuration: Configuration,
};

pub const SnapshotResponse = struct {
    header: Header,
    match_index: Index,
};

/// Discriminants start at 1 (see `EntryKind`); an adapter may use this as its wire tag.
pub const MessageKind = enum(u8) {
    request_vote = 1,
    request_vote_response = 2,
    pre_vote = 3,
    pre_vote_response = 4,
    append_entries = 5,
    append_entries_response = 6,
    install_snapshot = 7,
    install_snapshot_response = 8,
};

/// Everything the core sends or receives. PreVote reuses `VoteRequest`/`VoteResponse` under a
/// distinct tag (ADR-005) rather than a `pre_vote: bool` field, so a handler that forgets to
/// check the flag cannot compile — a forgotten `if` would defeat the reason PreVote exists.
pub const Message = union(MessageKind) {
    request_vote: VoteRequest,
    request_vote_response: VoteResponse,
    pre_vote: VoteRequest,
    pre_vote_response: VoteResponse,
    append_entries: AppendRequest,
    append_entries_response: AppendResponse,
    install_snapshot: SnapshotRequest,
    install_snapshot_response: SnapshotResponse,

    /// Bounds `validate` enforces on `AppendRequest`/`SnapshotRequest`; the caller (driver,
    /// plan 003) supplies them, since only it knows the deployment's real limits.
    pub const Limits = struct {
        entries_max: u32,
        entry_bytes_max: u32,
        snapshot_bytes_max: u64,
    };

    /// Every variant's field 0. One exhaustive switch; `inline else` avoids repeating it
    /// per-tag, since every branch returns the same `*const Header` type regardless of tag.
    pub fn header(message: *const Message) *const Header {
        return switch (message.*) {
            inline else => |*payload| &payload.header,
        };
    }

    /// Structural validation of peer-supplied data: version, term, node ids, log positions,
    /// and size limits. Never asserts on this — a malformed message is data, not a caller
    /// bug — but does assert the checks it just performed (positive space, on the way out).
    pub fn validate(message: *const Message, limits: Limits) MessageError!void {
        const head = message.header();
        try validate_header(head);
        switch (message.*) {
            .request_vote, .pre_vote => |*m| try validate_vote_request(m),
            .request_vote_response, .pre_vote_response => {},
            .append_entries => |*m| try validate_append_request(m, head.term, limits),
            .append_entries_response => |*m| try validate_append_response(m, head.term),
            .install_snapshot => |*m| try validate_snapshot_request(m, head.term, limits),
            .install_snapshot_response => {},
        }
        assert(head.protocol_version >= protocol_version_min);
        assert(head.term != .zero);
    }
};

fn validate_header(header: *const Header) MessageError!void {
    if (header.protocol_version < protocol_version_min or
        header.protocol_version > protocol_version_current)
    {
        return error.MessageVersionUnsupported;
    }
    if (header.term == .zero) return error.MessageTermZero;
    if (header.from == .none or header.to == .none) return error.MessageNodeInvalid;
    if (header.from == header.to) return error.MessageNodeInvalid;
    assert(header.term != .zero);
    assert(header.from != header.to);
}

/// A zero index must carry a zero term and vice versa — "no entry" is the only zero-term case.
fn validate_log_position(index: Index, term: Term) MessageError!void {
    if (index == .zero) {
        if (term != .zero) return error.MessageLogPositionInvalid;
    } else {
        if (term == .zero) return error.MessageLogPositionInvalid;
    }
    assert((index == .zero) == (term == .zero));
}

fn validate_vote_request(request: *const VoteRequest) MessageError!void {
    try validate_log_position(request.last_log_index, request.last_log_term);
    if (request.last_log_term.order(request.header.term) == .gt) {
        return error.MessageLogPositionInvalid;
    }
    assert(request.last_log_term.order(request.header.term) != .gt);
}

fn validate_append_request(
    request: *const AppendRequest,
    header_term: Term,
    limits: Message.Limits,
) MessageError!void {
    try validate_log_position(request.prev_log_index, request.prev_log_term);
    if (request.prev_log_term.order(header_term) == .gt) return error.MessageLogPositionInvalid;
    if (request.entries.len > limits.entries_max) return error.MessageTooLarge;
    var previous_index = request.prev_log_index;
    var previous_term = request.prev_log_term;
    for (request.entries) |entry| {
        if (entry.data.len > limits.entry_bytes_max) return error.MessageTooLarge;
        // `previous_index` is peer data: range-check before `.next()` (its precondition
        // asserts `< maxInt(u64)`), per `Index.next`'s own doc comment.
        if (@intFromEnum(previous_index) == std.math.maxInt(u64)) {
            return error.MessageEntriesNotContiguous;
        }
        if (entry.index != previous_index.next()) return error.MessageEntriesNotContiguous;
        if (entry.term.order(previous_term) == .lt) return error.MessageEntryTermInvalid;
        if (entry.term.order(header_term) == .gt) return error.MessageEntryTermInvalid;
        previous_index = entry.index;
        previous_term = entry.term;
    }
    assert(previous_term.order(header_term) != .gt);
}

fn validate_append_response(response: *const AppendResponse, header_term: Term) MessageError!void {
    switch (response.outcome) {
        // A heartbeat or a fresh follower legitimately reports no match yet: `.zero` is valid.
        .accepted => {},
        .rejected => |conflict| {
            validate_log_position(conflict.index, conflict.term) catch {
                return error.MessageConflictInvalid;
            };
            if (conflict.term.order(header_term) == .gt) return error.MessageConflictInvalid;
            assert(conflict.term.order(header_term) != .gt);
        },
    }
}

fn validate_snapshot_request(
    request: *const SnapshotRequest,
    header_term: Term,
    limits: Message.Limits,
) MessageError!void {
    if (request.snapshot.index == .zero) return error.MessageSnapshotInvalid;
    if (request.snapshot.term == .zero) return error.MessageSnapshotInvalid;
    if (request.snapshot.term.order(header_term) == .gt) return error.MessageSnapshotInvalid;
    if (request.snapshot.data.len > limits.snapshot_bytes_max) return error.MessageTooLarge;
    try request.configuration.validate();
    assert(request.snapshot.index != .zero);
    assert(request.snapshot.term != .zero);
}

/// Membership change: absolute configurations, never a delta, so two changes compare with
/// `std.mem.eql` and applying the same one twice is a no-op (REALM.md: joint consensus only).
pub const ConfChange = union(enum) {
    enter_joint: Configuration,
    leave_joint: Configuration,

    pub fn validate(change: *const ConfChange) ConfError!void {
        switch (change.*) {
            .enter_joint => |*configuration| {
                if (configuration.voters_outgoing.len == 0) return error.ConfJointShape;
                try configuration.validate();
            },
            .leave_joint => |*configuration| {
                if (configuration.voters_outgoing.len != 0) return error.ConfJointShape;
                try configuration.validate();
            },
        }
    }
};

pub const ConfError = error{
    ConfVotersEmpty,
    ConfVotersTooMany,
    ConfLearnersTooMany,
    ConfNodesUnsorted,
    ConfLearnerIsVoter,
    ConfJointShape,
};

pub const MessageError = ConfError || error{
    MessageVersionUnsupported,
    MessageTermZero,
    MessageNodeInvalid,
    MessageLogPositionInvalid,
    MessageEntriesNotContiguous,
    MessageEntryTermInvalid,
    MessageTooLarge,
    MessageSnapshotInvalid,
    MessageConflictInvalid,
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
fn test_entry(index: u64, term: u64, kind: EntryKind, data: []const u8) Entry {
    return .{
        .index = @enumFromInt(index),
        .term = @enumFromInt(term),
        .kind = kind,
        .data = data,
    };
}

test "types: Entry construction borrows data, not copies" {
    const buf = "hello";
    const normal_entry = test_entry(1, 1, .normal, buf);
    try std.testing.expectEqual(buf.ptr, normal_entry.data.ptr);

    const noop_entry = test_entry(1, 1, .normal, "");
    try std.testing.expectEqual(@as(usize, 0), noop_entry.data.len);

    const max_entry = test_entry(std.math.maxInt(u64), std.math.maxInt(u64), .conf_change, buf);
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
fn test_hard_state(term: u64, vote: u64, commit_index: u64) HardState {
    return .{
        .term = @enumFromInt(term),
        .vote = @enumFromInt(vote),
        .commit_index = @enumFromInt(commit_index),
    };
}

test "types: HardState.eql is reflexive and symmetric" {
    const a = HardState.empty;
    try std.testing.expect(a.eql(&a));
    const b = test_hard_state(3, 2, 5);
    try std.testing.expect(b.eql(&b));
    try std.testing.expect(HardState.empty.eql(&HardState.empty));
    try std.testing.expectEqual(a.eql(&b), b.eql(&a));
}

test "types: HardState.eql detects a single differing field" {
    const base = test_hard_state(3, 2, 5);
    const diff_term = test_hard_state(4, 2, 5);
    const diff_vote = test_hard_state(3, 9, 5);
    const diff_commit = test_hard_state(3, 2, 6);
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

/// Test-only helper: cuts the `HardState.validate_transition(&.{ .previous = ..., .next = ... })`
/// boilerplate down to one call per test case.
fn test_validate(previous: HardState, next: HardState) Error!void {
    return HardState.validate_transition(&.{ .previous = previous, .next = next });
}

test "types: validate_transition allows a no-op persist" {
    try test_validate(HardState.empty, HardState.empty);
}

test "types: validate_transition allows term advancing with a vote change" {
    const previous = test_hard_state(1, 1, 0);
    try test_validate(previous, test_hard_state(2, 0, 0)); // Vote reset to `.none`.
    try test_validate(previous, test_hard_state(2, 2, 0)); // Vote changed to a new candidate.
}

test "types: validate_transition allows first vote in a term and non-decreasing commit" {
    const not_voted = test_hard_state(1, 0, 0);
    const voted = test_hard_state(1, 3, 0);
    try test_validate(not_voted, voted);
    try test_validate(voted, test_hard_state(1, 3, 0)); // Commit stays equal.
    try test_validate(voted, test_hard_state(1, 3, 1)); // Commit advances.
}

test "types: validate_transition rejects a term regression" {
    const previous = test_hard_state(2, 0, 0);
    const result = test_validate(previous, test_hard_state(1, 0, 0));
    try std.testing.expectError(error.InvariantTermRegressed, result);
}

test "types: validate_transition rejects a vote change within the same term" {
    const previous = test_hard_state(1, 1, 0);
    try std.testing.expectError(
        error.InvariantVoteChanged,
        test_validate(previous, test_hard_state(1, 2, 0)),
    );
    try std.testing.expectError(
        error.InvariantVoteChanged,
        test_validate(previous, test_hard_state(1, 0, 0)),
    );
}

test "types: validate_transition rejects a commit regression" {
    const previous = test_hard_state(1, 0, 5);
    try std.testing.expectError(
        error.InvariantCommitRegressed,
        test_validate(previous, test_hard_state(1, 0, 4)),
    );
    try std.testing.expectError(
        error.InvariantCommitRegressed,
        test_validate(previous, test_hard_state(2, 0, 4)),
    );
}

test "types: validate_transition checks term before commit" {
    const previous = test_hard_state(2, 0, 5);
    const result = test_validate(previous, test_hard_state(1, 0, 1));
    try std.testing.expectError(error.InvariantTermRegressed, result);
}

test "types: validate_transition seeded model against a reference predicate" {
    var prng = std.Random.DefaultPrng.init(0xf00d_5eed);
    const random = prng.random();
    for (0..1000) |_| {
        const previous = test_hard_state(
            random.intRangeAtMost(u64, 0, 5),
            random.intRangeAtMost(u64, 0, 3),
            random.intRangeAtMost(u64, 0, 5),
        );
        const next = test_hard_state(
            random.intRangeAtMost(u64, 0, 5),
            random.intRangeAtMost(u64, 0, 3),
            random.intRangeAtMost(u64, 0, 5),
        );
        const result = test_validate(previous, next);
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

test "types: ConfError is exhaustively switchable" {
    const err: ConfError = error.ConfVotersEmpty;
    switch (err) {
        error.ConfVotersEmpty,
        error.ConfVotersTooMany,
        error.ConfLearnersTooMany,
        error.ConfNodesUnsorted,
        error.ConfLearnerIsVoter,
        error.ConfJointShape,
        => {},
    }
}

test "types: MessageError is exhaustively switchable" {
    const err: MessageError = error.MessageVersionUnsupported;
    switch (err) {
        error.ConfVotersEmpty,
        error.ConfVotersTooMany,
        error.ConfLearnersTooMany,
        error.ConfNodesUnsorted,
        error.ConfLearnerIsVoter,
        error.ConfJointShape,
        error.MessageVersionUnsupported,
        error.MessageTermZero,
        error.MessageNodeInvalid,
        error.MessageLogPositionInvalid,
        error.MessageEntriesNotContiguous,
        error.MessageEntryTermInvalid,
        error.MessageTooLarge,
        error.MessageSnapshotInvalid,
        error.MessageConflictInvalid,
        => {},
    }
}

/// Test-only helper: builds a `Header` from raw integers so test cases stay one line each.
fn test_header(term: u64, from: u64, to: u64) Header {
    return .{
        .protocol_version = protocol_version_current,
        .term = @enumFromInt(term),
        .from = @enumFromInt(from),
        .to = @enumFromInt(to),
    };
}

const test_limits: Message.Limits = .{
    .entries_max = 100,
    .entry_bytes_max = 1024,
    .snapshot_bytes_max = 1 << 20,
};

test "types: MessageKind has 8 discriminants starting at 1" {
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(MessageKind).@"enum".fields.len);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(MessageKind.request_vote));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(MessageKind.install_snapshot_response));
    try std.testing.expectEqual(@as(?MessageKind, null), std.enums.fromInt(MessageKind, 0));
    try std.testing.expectEqual(@as(?MessageKind, null), std.enums.fromInt(MessageKind, 9));
}

test "types: every Message payload's field 0 is header: Header" {
    inline for (@typeInfo(Message).@"union".fields) |field| {
        const info = @typeInfo(field.type).@"struct";
        try std.testing.expect(info.fields.len > 0);
        try std.testing.expectEqualStrings("header", info.fields[0].name);
        try std.testing.expectEqual(Header, info.fields[0].type);
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(field.type, "header"));
    }
}

test "types: Message.header returns each variant's header via one exhaustive switch" {
    const head = test_header(5, 1, 2);
    const snapshot_configuration: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const messages = [_]Message{
        .{ .request_vote = .{ .header = head, .last_log_index = .zero, .last_log_term = .zero } },
        .{ .request_vote_response = .{ .header = head, .granted = true } },
        .{ .pre_vote = .{ .header = head, .last_log_index = .zero, .last_log_term = .zero } },
        .{ .pre_vote_response = .{ .header = head, .granted = false } },
        .{ .append_entries = .{
            .header = head,
            .prev_log_index = .zero,
            .prev_log_term = .zero,
            .leader_commit = .zero,
            .round = 0,
            .entries = &.{},
        } },
        .{ .append_entries_response = .{
            .header = head,
            .round = 0,
            .outcome = .{ .accepted = .zero },
        } },
        .{ .install_snapshot = .{
            .header = head,
            .snapshot = .{ .index = @enumFromInt(1), .term = @enumFromInt(1), .data = "" },
            .configuration = snapshot_configuration,
        } },
        .{ .install_snapshot_response = .{ .header = head, .match_index = .zero } },
    };
    for (messages) |message| {
        try std.testing.expectEqual(head.term, message.header().term);
        try std.testing.expectEqual(head.from, message.header().from);
        try std.testing.expectEqual(head.to, message.header().to);
    }
}

test "types: Message.validate accepts a well-formed request_vote and pre_vote" {
    const request: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = @enumFromInt(10),
        .last_log_term = @enumFromInt(4),
    } };
    try request.validate(test_limits);
    const pre: Message = .{ .pre_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = .zero,
        .last_log_term = .zero,
    } };
    try pre.validate(test_limits);
}

test "types: Message.validate accepts a well-formed append_entries with entries" {
    const entries = [_]Entry{ test_entry(11, 5, .normal, "a"), test_entry(12, 5, .normal, "b") };
    const message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = @enumFromInt(9),
        .round = 1,
        .entries = &entries,
    } };
    try message.validate(test_limits);
}

test "types: Message.validate accepts an accepted and a rejected append_entries_response" {
    const accepted: Message = .{ .append_entries_response = .{
        .header = test_header(5, 1, 2),
        .round = 1,
        .outcome = .{ .accepted = @enumFromInt(12) },
    } };
    try accepted.validate(test_limits);
    const rejected: Message = .{ .append_entries_response = .{
        .header = test_header(5, 1, 2),
        .round = 1,
        .outcome = .{ .rejected = .{ .index = .zero, .term = .zero } },
    } };
    try rejected.validate(test_limits);
}

test "types: Message.validate accepts a well-formed install_snapshot" {
    const configuration: Configuration = .{
        .voters = &.{ @as(NodeId, @enumFromInt(1)), @as(NodeId, @enumFromInt(2)) },
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const message: Message = .{ .install_snapshot = .{
        .header = test_header(5, 1, 2),
        .snapshot = .{ .index = @enumFromInt(9), .term = @enumFromInt(4), .data = "state" },
        .configuration = configuration,
    } };
    try message.validate(test_limits);
}

test "types: Message.validate rejects an unsupported protocol version" {
    var request: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = .zero,
        .last_log_term = .zero,
    } };
    request.request_vote.header.protocol_version = 0;
    try std.testing.expectError(error.MessageVersionUnsupported, request.validate(test_limits));
    request.request_vote.header.protocol_version = protocol_version_current + 1;
    try std.testing.expectError(error.MessageVersionUnsupported, request.validate(test_limits));
}

test "types: Message.validate rejects a zero term" {
    const request: Message = .{ .request_vote = .{
        .header = test_header(0, 1, 2),
        .last_log_index = .zero,
        .last_log_term = .zero,
    } };
    try std.testing.expectError(error.MessageTermZero, request.validate(test_limits));
}

test "types: Message.validate rejects invalid node ids" {
    const no_from: Message = .{ .request_vote_response = .{
        .header = test_header(5, 0, 2),
        .granted = true,
    } };
    try std.testing.expectError(error.MessageNodeInvalid, no_from.validate(test_limits));
    const no_to: Message = .{ .request_vote_response = .{
        .header = test_header(5, 1, 0),
        .granted = true,
    } };
    try std.testing.expectError(error.MessageNodeInvalid, no_to.validate(test_limits));
    const self_message: Message = .{ .request_vote_response = .{
        .header = test_header(5, 1, 1),
        .granted = true,
    } };
    try std.testing.expectError(error.MessageNodeInvalid, self_message.validate(test_limits));
}

test "types: Message.validate rejects an inconsistent log position on request_vote" {
    const zero_index_nonzero_term: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = .zero,
        .last_log_term = @enumFromInt(1),
    } };
    try std.testing.expectError(
        error.MessageLogPositionInvalid,
        zero_index_nonzero_term.validate(test_limits),
    );
    const term_above_header: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = @enumFromInt(1),
        .last_log_term = @enumFromInt(6),
    } };
    try std.testing.expectError(
        error.MessageLogPositionInvalid,
        term_above_header.validate(test_limits),
    );
}

test "types: Message.validate rejects a nonzero log index with a zero term on request_vote" {
    const message: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = @enumFromInt(1),
        .last_log_term = .zero,
    } };
    try std.testing.expectError(error.MessageLogPositionInvalid, message.validate(test_limits));
    const empty_log: Message = .{ .request_vote = .{
        .header = test_header(5, 1, 2),
        .last_log_index = .zero,
        .last_log_term = .zero,
    } };
    try empty_log.validate(test_limits); // Both zero is the one valid "no entry" position.
}

test "types: Message.validate rejects an inconsistent prev log position on append_entries" {
    const zero_index_nonzero_term: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = .zero,
        .prev_log_term = @enumFromInt(1),
        .leader_commit = .zero,
        .round = 1,
        .entries = &.{},
    } };
    try std.testing.expectError(
        error.MessageLogPositionInvalid,
        zero_index_nonzero_term.validate(test_limits),
    );
    const term_above_header: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(6),
        .leader_commit = .zero,
        .round = 1,
        .entries = &.{},
    } };
    try std.testing.expectError(
        error.MessageLogPositionInvalid,
        term_above_header.validate(test_limits),
    );
    const term_at_header: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(5),
        .leader_commit = .zero,
        .round = 1,
        .entries = &.{},
    } };
    try term_at_header.validate(test_limits); // Boundary: prev term == header term is valid.
}

test "types: Message.validate rejects non-contiguous append_entries" {
    const entries = [_]Entry{test_entry(12, 5, .normal, "a")}; // Skips index 11.
    const message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &entries,
    } };
    try std.testing.expectError(error.MessageEntriesNotContiguous, message.validate(test_limits));
}

test "types: Message.validate rejects entries at prev_log_index == maxInt without panicking" {
    // Regression: previous_index.next() must never be called on peer-supplied maxInt data.
    const entries = [_]Entry{test_entry(std.math.maxInt(u64), 5, .normal, "a")};
    const message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(std.math.maxInt(u64) - 1),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &entries,
    } };
    try message.validate(test_limits); // maxInt(u64) - 1 -> maxInt(u64) is a valid step.

    const two_entries = [_]Entry{
        test_entry(std.math.maxInt(u64), 5, .normal, "a"),
        test_entry(std.math.maxInt(u64), 5, .normal, "b"), // Would overflow .next() on the retry.
    };
    const overflow_message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(std.math.maxInt(u64) - 1),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &two_entries,
    } };
    try std.testing.expectError(
        error.MessageEntriesNotContiguous,
        overflow_message.validate(test_limits),
    );
}

test "types: Message.validate rejects an out-of-range entry term" {
    const decreasing = [_]Entry{
        test_entry(11, 5, .normal, "a"),
        test_entry(12, 4, .normal, "b"), // Term regresses within the batch.
    };
    const decreasing_message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &decreasing,
    } };
    try std.testing.expectError(
        error.MessageEntryTermInvalid,
        decreasing_message.validate(test_limits),
    );

    const above_header = [_]Entry{test_entry(11, 6, .normal, "a")}; // header.term is 5.
    const above_message: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &above_header,
    } };
    try std.testing.expectError(error.MessageEntryTermInvalid, above_message.validate(test_limits));
}

test "types: Message.validate rejects append_entries over the entries or bytes limit" {
    var buf: [8]Entry = undefined;
    for (&buf, 0..) |*entry, i| entry.* = test_entry(11 + i, 5, .normal, "x");
    const over_count: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &buf,
    } };
    const tight_limits: Message.Limits = .{
        .entries_max = 1,
        .entry_bytes_max = 1024,
        .snapshot_bytes_max = 1 << 20,
    };
    try std.testing.expectError(error.MessageTooLarge, over_count.validate(tight_limits));

    const big_entry = [_]Entry{test_entry(11, 5, .normal, "too big")};
    const over_bytes: Message = .{ .append_entries = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &big_entry,
    } };
    const small_bytes: Message.Limits = .{
        .entries_max = 100,
        .entry_bytes_max = 3,
        .snapshot_bytes_max = 1 << 20,
    };
    try std.testing.expectError(error.MessageTooLarge, over_bytes.validate(small_bytes));
}

test "types: Message.validate rejects an invalid append_entries_response conflict" {
    const bad_shape: Message = .{ .append_entries_response = .{
        .header = test_header(5, 1, 2),
        .round = 1,
        .outcome = .{ .rejected = .{ .index = .zero, .term = @enumFromInt(1) } },
    } };
    try std.testing.expectError(error.MessageConflictInvalid, bad_shape.validate(test_limits));

    const term_above_header: Message = .{ .append_entries_response = .{
        .header = test_header(5, 1, 2),
        .round = 1,
        .outcome = .{ .rejected = .{ .index = @enumFromInt(1), .term = @enumFromInt(6) } },
    } };
    try std.testing.expectError(
        error.MessageConflictInvalid,
        term_above_header.validate(test_limits),
    );
}

test "types: Message.validate rejects an invalid install_snapshot" {
    const configuration: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const zero_index: Message = .{ .install_snapshot = .{
        .header = test_header(5, 1, 2),
        .snapshot = .{ .index = .zero, .term = @enumFromInt(4), .data = "" },
        .configuration = configuration,
    } };
    try std.testing.expectError(error.MessageSnapshotInvalid, zero_index.validate(test_limits));

    const term_above_header: Message = .{ .install_snapshot = .{
        .header = test_header(5, 1, 2),
        .snapshot = .{ .index = @enumFromInt(9), .term = @enumFromInt(6), .data = "" },
        .configuration = configuration,
    } };
    try std.testing.expectError(
        error.MessageSnapshotInvalid,
        term_above_header.validate(test_limits),
    );

    const bad_configuration: Configuration = .{
        .voters = &.{},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const empty_voters: Message = .{ .install_snapshot = .{
        .header = test_header(5, 1, 2),
        .snapshot = .{ .index = @enumFromInt(9), .term = @enumFromInt(4), .data = "" },
        .configuration = bad_configuration,
    } };
    try std.testing.expectError(error.ConfVotersEmpty, empty_voters.validate(test_limits));
}

test "types: Message.validate rejects an oversized snapshot" {
    const configuration: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const message: Message = .{ .install_snapshot = .{
        .header = test_header(5, 1, 2),
        .snapshot = .{ .index = @enumFromInt(9), .term = @enumFromInt(4), .data = "too big" },
        .configuration = configuration,
    } };
    const tight: Message.Limits = .{
        .entries_max = 100,
        .entry_bytes_max = 1024,
        .snapshot_bytes_max = 3,
    };
    try std.testing.expectError(error.MessageTooLarge, message.validate(tight));
}

test "types: AppendRequest.entries and SnapshotRequest.snapshot.data are borrowed" {
    const entries = [_]Entry{test_entry(11, 5, .normal, "a")};
    const append: AppendRequest = .{
        .header = test_header(5, 1, 2),
        .prev_log_index = @enumFromInt(10),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = .zero,
        .round = 1,
        .entries = &entries,
    };
    try std.testing.expectEqual(@as([*]const Entry, &entries), append.entries.ptr);

    const data = "state";
    const snapshot: Snapshot = .{ .index = @enumFromInt(1), .term = @enumFromInt(1), .data = data };
    try std.testing.expectEqual(data.ptr, snapshot.data.ptr);

    const voters = [_]NodeId{@enumFromInt(1)};
    const configuration: Configuration = .{
        .voters = &voters,
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectEqual(@as([*]const NodeId, &voters), configuration.voters.ptr);
}

test "types: Configuration.validate accepts a minimal and a joint configuration" {
    const solo: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try solo.validate();
    const joint: Configuration = .{
        .voters = &.{ @as(NodeId, @enumFromInt(2)), @as(NodeId, @enumFromInt(3)) },
        .voters_outgoing = &.{@as(NodeId, @enumFromInt(1))},
        .learners = &.{@as(NodeId, @enumFromInt(4))},
    };
    try joint.validate();
}

test "types: Configuration.validate rejects an empty voter set" {
    const configuration: Configuration = .{
        .voters = &.{},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectError(error.ConfVotersEmpty, configuration.validate());
}

test "types: Configuration.validate rejects more than voters_max voters" {
    var voters: [voters_max + 1]NodeId = undefined;
    for (&voters, 0..) |*voter, i| voter.* = @enumFromInt(i + 1);
    const configuration: Configuration = .{
        .voters = &voters,
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectError(error.ConfVotersTooMany, configuration.validate());
}

test "types: Configuration.validate rejects more than learners_max learners" {
    var learners: [learners_max + 1]NodeId = undefined;
    for (&learners, 0..) |*learner, i| learner.* = @enumFromInt(i + 1);
    const configuration: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &learners,
    };
    try std.testing.expectError(error.ConfLearnersTooMany, configuration.validate());
}

test "types: Configuration.validate rejects unsorted, duplicate, and .none node lists" {
    const unsorted: Configuration = .{
        .voters = &.{ @as(NodeId, @enumFromInt(2)), @as(NodeId, @enumFromInt(1)) },
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectError(error.ConfNodesUnsorted, unsorted.validate());

    const duplicate: Configuration = .{
        .voters = &.{ @as(NodeId, @enumFromInt(1)), @as(NodeId, @enumFromInt(1)) },
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectError(error.ConfNodesUnsorted, duplicate.validate());

    const has_none: Configuration = .{
        .voters = &.{NodeId.none},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    try std.testing.expectError(error.ConfNodesUnsorted, has_none.validate());
}

test "types: Configuration.validate rejects a learner that is also a voter" {
    const configuration: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{@as(NodeId, @enumFromInt(1))},
    };
    try std.testing.expectError(error.ConfLearnerIsVoter, configuration.validate());
}

test "types: ConfChange.validate enforces enter_joint and leave_joint shape" {
    const settled: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(1))},
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const joint: Configuration = .{
        .voters = &.{@as(NodeId, @enumFromInt(2))},
        .voters_outgoing = &.{@as(NodeId, @enumFromInt(1))},
        .learners = &.{},
    };
    const enter: ConfChange = .{ .enter_joint = joint };
    try enter.validate();
    const leave: ConfChange = .{ .leave_joint = settled };
    try leave.validate();

    const bad_enter: ConfChange = .{ .enter_joint = settled };
    try std.testing.expectError(error.ConfJointShape, bad_enter.validate());
    const bad_leave: ConfChange = .{ .leave_joint = joint };
    try std.testing.expectError(error.ConfJointShape, bad_leave.validate());
}

test "types: ConfChange.validate propagates a malformed configuration's error" {
    const bad: Configuration = .{ .voters = &.{}, .voters_outgoing = &.{}, .learners = &.{} };
    const change: ConfChange = .{ .leave_joint = bad };
    try std.testing.expectError(error.ConfVotersEmpty, change.validate());
}

test "types: Configuration.validate seeded model against a reference predicate" {
    var prng = std.Random.DefaultPrng.init(0xc0a1_c0a1);
    const random = prng.random();
    for (0..500) |_| {
        var voters_buf: [4]NodeId = undefined;
        const voters_len = random.intRangeAtMost(usize, 0, 4);
        for (voters_buf[0..voters_len], 0..) |*node, i| node.* = @enumFromInt(i + 1);
        const configuration: Configuration = .{
            .voters = voters_buf[0..voters_len],
            .voters_outgoing = &.{},
            .learners = &.{},
        };
        const result = configuration.validate();
        if (voters_len == 0) {
            try std.testing.expectError(error.ConfVotersEmpty, result);
        } else {
            try result;
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;
