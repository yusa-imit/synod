//! synod.sim.invariants — the simulator's black-box Raft safety checker (ADR-008, "Invariants"):
//! election safety, leader append-only, log matching, leader completeness and state machine
//! safety, driven by `Observation`s (a node's `status()` plus its borrowed log) and applied
//! records. It promotes `Oracle` from `raft/cluster_test.zig`, data-driven instead of wired
//! to a harness: it knows nothing of `Node` internals.
//!
//! State: chosen entries (committed by any node) are kept as 8-byte `fingerprint`s with the
//! term in which they were first seen committed, never as bytes. The first violation of each
//! property is latched and returned by `check`, so a failed run can be asked which property
//! broke and no other one did. A `TermsExhausted` is a harness limit, not a violation.
//!
//! Fingerprints are in-process only: they are never persisted or compared across builds.
//!
//! Allocation: `Checker.init` only (`gpa`, six slices: `nodes_count * log_entries_max * 8`
//! bytes of leader memory, `log_entries_max * 24` for chosen fingerprints, chosen terms and
//! scratch, `terms_max + 1` leader table, and a `NodeMemory` slice of a few words per node);
//! `observe`, `applied`, `restarted` and `check` never allocate. The checker owns its slices
//! and does not keep `gpa`; `deinit` takes it again. Observed logs are borrowed for the call.
//! Caller contract (asserted): distinct node indexes `< nodes_count` per `observe`, and logs
//! of at most `log_entries_max` entries. What a node reports (a commit index beyond its log,
//! non-contiguous entry indexes) is data, returned as `StateMachineSafety`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const raft = @import("../raft.zig");
const types = @import("../types.zig");

const Entry = types.Entry;
const Index = types.Index;

/// The five safety properties of `Checker` plus the history checker's `linearizability`.
pub const Property = enum(u8) {
    election_safety = 1,
    leader_append_only = 2,
    log_matching = 3,
    leader_completeness = 4,
    state_machine_safety = 5,
    linearizability = 6,
};

/// One named error per property; `violation_of` maps a `Property` to its error.
pub const Violation = error{
    ElectionSafety,
    LeaderAppendOnly,
    LogMatching,
    LeaderCompleteness,
    StateMachineSafety,
    Linearizability,
};

/// What `Checker.observe` returns: a safety violation or the term table running out.
pub const ObserveError = Violation || error{TermsExhausted};

/// Properties `Checker` tracks; `linearizability` belongs to the history checker.
const properties_count = 5;

/// The error naming `property`.
pub fn violation_of(property: Property) Violation {
    const violation: Violation = switch (property) {
        .election_safety => error.ElectionSafety,
        .leader_append_only => error.LeaderAppendOnly,
        .log_matching => error.LogMatching,
        .leader_completeness => error.LeaderCompleteness,
        .state_machine_safety => error.StateMachineSafety,
        .linearizability => error.Linearizability,
    };
    assert(@intFromEnum(property) >= 1);
    assert(@intFromEnum(property) <= properties_count + 1);
    return violation;
}

/// One node at one instant: its `status()` and its log (borrowed for the call).
pub const Observation = struct {
    node_index: u8,
    status: raft.Status,
    log: []const Entry,
};

/// Wyhash of term (little-endian), kind and data (the index is implied by position).
pub fn fingerprint(entry: *const Entry) u64 {
    assert(@intFromEnum(entry.kind) != 0);
    assert(entry.data.len <= std.math.maxInt(u32));
    var hasher = std.hash.Wyhash.init(0);
    const term = std.mem.nativeToLittle(u64, @intFromEnum(entry.term));
    hasher.update(std.mem.asBytes(&term));
    hasher.update(&[1]u8{@intFromEnum(entry.kind)});
    hasher.update(entry.data);
    return hasher.final();
}

fn entry_eql(a: *const Entry, b: *const Entry) bool {
    assert(@intFromEnum(a.kind) != 0);
    assert(@intFromEnum(b.kind) != 0);
    return a.term == b.term and a.kind == b.kind and std.mem.eql(u8, a.data, b.data);
}

/// Log matching (Raft paper Figure 3): two logs holding the same term at an index agree on that
/// entry and on everything before it. Checking the entry just before each equal-term index
/// proves the whole prefix by induction.
/// Fails with `LogMatching` when two logs break the Figure 3 property.
pub fn log_matching(a: []const Entry, b: []const Entry) Violation!void {
    const common = @min(a.len, b.len);
    for (0..common) |i| {
        if (a[i].term != b[i].term) continue;
        if (!entry_eql(&a[i], &b[i])) return error.LogMatching;
        if (i > 0 and !entry_eql(&a[i - 1], &b[i - 1])) return error.LogMatching;
    }
    assert(common <= a.len);
    assert(common <= b.len);
}

/// `after` must extend the log whose fingerprints are `before`: same prefix, never shorter.
pub fn leader_append_only(before: []const u64, after: []const Entry) Violation!void {
    if (after.len < before.len) return error.LeaderAppendOnly;
    for (before, after[0..before.len]) |print, *entry| {
        if (print != fingerprint(entry)) return error.LeaderAppendOnly;
    }
    assert(after.len >= before.len);
}

/// Per-node memory: commit and applied counters, and the leader append-only record.
const NodeMemory = struct {
    commit: u64 = 0,
    applied: u64 = 0,
    leader_term: u64 = 0,
    leader_len: u32 = 0,
    leading: bool = false,
};

/// The checker; see the module header for state, limits and the latching rule.
pub const Checker = struct {
    pub const Options = struct { nodes_count: u8, log_entries_max: u32, terms_max: u32 };
    pub const Stats = struct { leader_terms: u32, committed_max: u64 };

    options: Options,
    latched: [properties_count]?Violation,
    nodes: []NodeMemory,
    leader_prints: []u64, // nodes_count rows of log_entries_max fingerprints.
    chosen_prints: []u64, // Index i holds the fingerprint chosen at log index i + 1.
    chosen_terms: []u64, // The observer's term when index i + 1 was first seen committed.
    scratch: []u64, // The fingerprints of the log being observed.
    leader_of_term: []u8, // terms_max + 1 slots: leader node_index + 1, or 0 for none.
    chosen_max: u32,
    leader_terms: u32,

    /// Allocates every slice from `gpa`; the checker starts clean. `deinit` frees them.
    pub fn init(checker: *Checker, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.nodes_count > 0);
        assert(options.nodes_count < std.math.maxInt(u8)); // `node_index + 1` is the table id.
        assert(options.log_entries_max > 0);
        assert(options.terms_max > 0);
        const log_max: usize = options.log_entries_max;
        const nodes = try gpa.alloc(NodeMemory, options.nodes_count);
        errdefer gpa.free(nodes);

        const leader_prints = try gpa.alloc(u64, options.nodes_count * log_max);
        errdefer gpa.free(leader_prints);

        const chosen_prints = try gpa.alloc(u64, log_max);
        errdefer gpa.free(chosen_prints);

        const chosen_terms = try gpa.alloc(u64, log_max);
        errdefer gpa.free(chosen_terms);

        const scratch = try gpa.alloc(u64, log_max);
        errdefer gpa.free(scratch);

        const leader_of_term = try gpa.alloc(u8, @as(usize, options.terms_max) + 1);
        errdefer gpa.free(leader_of_term);

        @memset(nodes, .{});
        @memset(leader_of_term, 0);
        checker.* = .{
            .options = options,
            .latched = @splat(null),
            .nodes = nodes,
            .leader_prints = leader_prints,
            .chosen_prints = chosen_prints,
            .chosen_terms = chosen_terms,
            .scratch = scratch,
            .leader_of_term = leader_of_term,
            .chosen_max = 0,
            .leader_terms = 0,
        };
    }

    /// Frees the slices `init` allocated; `gpa` must be the one given to `init`.
    pub fn deinit(checker: *Checker, gpa: Allocator) void {
        assert(checker.nodes.len == checker.options.nodes_count);
        assert(checker.leader_of_term.len == @as(usize, checker.options.terms_max) + 1);
        gpa.free(checker.leader_of_term);
        gpa.free(checker.scratch);
        gpa.free(checker.chosen_terms);
        gpa.free(checker.chosen_prints);
        gpa.free(checker.leader_prints);
        gpa.free(checker.nodes);
        checker.* = undefined;
    }

    /// Checks every node observed at one instant: each observation alone, then all pairs of
    /// logs. Returns the first violation found (and latches it) or a harness limit.
    pub fn observe(
        checker: *Checker,
        observations: []const Observation,
    ) ObserveError!void {
        assert(observations.len <= checker.options.nodes_count);
        for (observations, 0..) |first, at| { // Distinct, in range: `id` below cannot overflow.
            assert(first.node_index < checker.options.nodes_count);
            for (observations[at + 1 ..]) |second| assert(first.node_index != second.node_index);
        }
        for (observations) |*one| { // First, so a second leader is named before its symptoms.
            if (one.status.role == .leader) try checker.leader_table(one);
        }
        for (observations) |*one| try checker.observe_one(one);
        for (observations, 0..) |first, at| {
            for (observations[at + 1 ..]) |second| {
                log_matching(first.log, second.log) catch return checker.fail(.log_matching);
            }
        }
        assert(checker.chosen_max <= checker.options.log_entries_max);
    }

    /// Node `node_index` applied the entry at `index` whose fingerprint is `entry_fingerprint`.
    pub fn applied(
        checker: *Checker,
        node_index: u8,
        index: Index,
        entry_fingerprint: u64,
    ) Violation!void {
        assert(node_index < checker.options.nodes_count);
        assert(checker.chosen_max <= checker.options.log_entries_max);
        const memory = &checker.nodes[node_index];
        const at: u64 = @intFromEnum(index);
        if (at != memory.applied + 1) return checker.fail(.state_machine_safety);
        if (at > memory.commit) return checker.fail(.state_machine_safety);
        assert(memory.commit <= checker.chosen_max); // A commit is chosen when observed.
        const chosen = checker.chosen_prints[@intCast(at - 1)];
        if (chosen != entry_fingerprint) return checker.fail(.state_machine_safety);
        memory.applied = at;
    }

    /// A restart forgets a node's commit, applied length and leader memory, never the chosen
    /// entries or the one-leader-per-term table.
    pub fn restarted(checker: *Checker, node_index: u8) void {
        assert(node_index < checker.options.nodes_count);
        checker.nodes[node_index] = .{};
        assert(checker.nodes[node_index].commit == 0);
        assert(!checker.nodes[node_index].leading);
    }

    /// The first latched violation of `property`, or ok.
    pub fn check(checker: *const Checker, property: Property) Violation!void {
        assert(property != .linearizability);
        const slot = @intFromEnum(property) - 1;
        assert(slot < properties_count);
        if (checker.latched[slot]) |violation| return violation;
    }

    /// Leader terms seen and the highest log index any node committed.
    pub fn stats(checker: *const Checker) Stats {
        assert(checker.chosen_max <= checker.options.log_entries_max);
        assert(checker.leader_terms <= checker.options.terms_max);
        return .{ .leader_terms = checker.leader_terms, .committed_max = checker.chosen_max };
    }

    /// Latches the first violation of `property` and returns it.
    fn fail(checker: *Checker, property: Property) Violation {
        assert(property != .linearizability);
        const slot = @intFromEnum(property) - 1;
        assert(slot < properties_count);
        if (checker.latched[slot] == null) checker.latched[slot] = violation_of(property);
        return violation_of(property);
    }

    fn observe_one(checker: *Checker, one: *const Observation) ObserveError!void {
        assert(one.node_index < checker.options.nodes_count);
        assert(one.log.len <= checker.options.log_entries_max);
        for (one.log, 0..) |*entry, i| {
            if (@intFromEnum(entry.index) != i + 1) return checker.fail(.state_machine_safety);
            checker.scratch[i] = fingerprint(entry);
        }
        try checker.commit_node(one);
        if (one.status.role != .leader) return;
        try checker.leader_log(one);
        try checker.leader_complete(one);
    }

    /// State machine safety: the node's commit never regresses, its committed prefix is still
    /// the chosen one, and each newly committed index equals what anyone committed there.
    fn commit_node(checker: *Checker, one: *const Observation) Violation!void {
        const memory = &checker.nodes[one.node_index];
        const commit_index: u64 = @intFromEnum(one.status.commit_index);
        if (commit_index > one.log.len) return checker.fail(.state_machine_safety); // Not held.
        const commit: u32 = @intCast(commit_index);
        const seen: u32 = @intCast(memory.commit);
        assert(seen <= checker.chosen_max);
        if (commit < seen) return checker.fail(.state_machine_safety);
        assert(one.log.len >= seen); // `seen <= commit <= log.len`.
        for (checker.scratch[0..seen], checker.chosen_prints[0..seen]) |have, chosen| {
            if (have != chosen) return checker.fail(.state_machine_safety);
        }
        const term: u64 = @intFromEnum(one.status.term);
        for (seen..commit) |i| {
            if (i < checker.chosen_max) {
                if (checker.scratch[i] != checker.chosen_prints[i]) {
                    return checker.fail(.state_machine_safety);
                }
                continue;
            }
            assert(i == checker.chosen_max); // Commits extend the chosen prefix by one.
            checker.chosen_prints[i] = checker.scratch[i];
            checker.chosen_terms[i] = term;
            checker.chosen_max += 1;
        }
        memory.commit = commit;
    }

    /// Election safety: at most one leader per term.
    fn leader_table(checker: *Checker, one: *const Observation) ObserveError!void {
        assert(one.status.role == .leader);
        assert(one.node_index < checker.options.nodes_count);
        const term: u64 = @intFromEnum(one.status.term);
        if (term > checker.options.terms_max) return error.TermsExhausted;
        const id = one.node_index + 1;
        const known = checker.leader_of_term[@intCast(term)];
        if (known != 0 and known != id) return checker.fail(.election_safety);
        if (known == 0) checker.leader_terms += 1;
        checker.leader_of_term[@intCast(term)] = id;
        assert(checker.leader_of_term[@intCast(term)] == id);
    }

    /// Leader append-only: in the term it was last seen leading, a node's log only extends.
    fn leader_log(checker: *Checker, one: *const Observation) Violation!void {
        assert(one.status.role == .leader);
        assert(one.log.len <= checker.options.log_entries_max);
        const memory = &checker.nodes[one.node_index];
        const term: u64 = @intFromEnum(one.status.term);
        const log_max: usize = checker.options.log_entries_max;
        const row = checker.leader_prints[one.node_index * log_max ..][0..log_max];
        if (memory.leading and memory.leader_term == term) {
            leader_append_only(row[0..memory.leader_len], one.log) catch {
                return checker.fail(.leader_append_only);
            };
        }
        @memcpy(row[0..one.log.len], checker.scratch[0..one.log.len]);
        memory.leader_len = @intCast(one.log.len);
        memory.leader_term = term;
        memory.leading = true;
        assert(memory.leader_len == one.log.len);
    }

    /// Leader completeness: a leader of `term` holds every entry chosen in a term <= `term`.
    fn leader_complete(checker: *Checker, one: *const Observation) Violation!void {
        const term: u64 = @intFromEnum(one.status.term);
        assert(one.status.role == .leader);
        assert(checker.chosen_max <= checker.options.log_entries_max);
        for (0..checker.chosen_max) |i| {
            if (checker.chosen_terms[i] > term) continue;
            if (i >= one.log.len) return checker.fail(.leader_completeness);
            if (checker.scratch[i] != checker.chosen_prints[i]) {
                return checker.fail(.leader_completeness);
            }
        }
    }
};
