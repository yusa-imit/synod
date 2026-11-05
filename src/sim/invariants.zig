//! synod.sim.invariants — the simulator's black-box Raft safety checker (ADR-008, "Invariants"):
//! election safety, leader append-only, log matching, leader completeness and state machine
//! safety, driven by `Observation`s (a node's `status()` plus its borrowed log) and applied
//! records. It promotes `Oracle` from `raft/cluster_test.zig`, data-driven instead of wired
//! to a harness: it knows nothing of `Node` internals.
//!
//! State: chosen entries (committed by any node) are kept as 8-byte `fingerprint`s with the
//! term in which they were first seen committed, never as bytes. The first violation of each
//! property is latched and returned by `check`, so a failed run can be asked which property
//! broke and no other one did. `TermsExhausted` and `ChosenExhausted` are harness limits, not
//! violations.
//!
//! Windows: with compaction a node's log is a window of at most `log_entries_max` entries
//! holding the indexes `base + 1 ..= status.last_index` (`base = last_index - log.len`). All
//! indexes the checker keeps are absolute; chosen entries are remembered up to
//! `chosen_entries_max`. Two windows are compared on the indexes they share, and what a node
//! compacted below its base is not re-read.
//!
//! Fingerprints are in-process only: they are never persisted or compared across builds.
//!
//! Allocation: `Checker.init` only (`gpa`, seven slices: `nodes_count * log_entries_max * 8`
//! bytes of leader memory, `chosen_entries_max * 16` for chosen fingerprints and terms,
//! `log_entries_max * 8` of scratch, `log_entries_max * 24` for the state digest ring,
//! `terms_max + 1` leader table, and a `NodeMemory` slice of a few words per node);
//! `observe`, `applied`, `installed`, `restarted` and `check` never allocate. The checker owns
//! its slices and does not keep `gpa`; `deinit` takes it again. Observed logs are borrowed for
//! the call.
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

/// What `Checker.observe` returns: a safety violation or a harness limit (the term table or the
/// chosen-entries table running out).
pub const ObserveError = Violation || error{ TermsExhausted, ChosenExhausted };

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

/// One node at one instant: its `status()` and its log window (borrowed for the call). The
/// window holds the indexes `base + 1 ..= status.last_index`, `base = last_index - log.len`; a
/// node that never compacted has `base == 0`.
pub const Observation = struct {
    node_index: u8,
    status: raft.Status,
    log: []const Entry,
};

/// The index just before the first entry of the window `one` observes; `null` when the status
/// claims fewer than `log.len` entries.
fn window_base(one: *const Observation) ?u64 {
    const last: u64 = @intFromEnum(one.status.last_index);
    if (last < one.log.len) return null;
    const base = last - one.log.len;
    assert(base + one.log.len == last);
    return base;
}

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
    return log_matching_window(a, 0, b, 0);
}

/// `log_matching` for windows: `a` holds the indexes `a_base + 1 ..` and `b` the indexes
/// `b_base + 1 ..`. Only the indexes both hold are compared; the entry before an equal-term
/// index is compared only when both hold it too.
pub fn log_matching_window(
    a: []const Entry,
    a_base: u64,
    b: []const Entry,
    b_base: u64,
) Violation!void {
    const low = @max(a_base, b_base); // Exclusive: the first shared index is `low + 1`.
    const high = @min(a_base + a.len, b_base + b.len); // Inclusive.
    if (high <= low) return; // No shared index.
    for (low + 1..high + 1) |at| {
        const left = &a[at - a_base - 1];
        const right = &b[at - b_base - 1];
        if (left.term != right.term) continue;
        if (!entry_eql(left, right)) return error.LogMatching;
        if (at - 1 <= low) continue; // The previous entry is not held by both.
        if (!entry_eql(&a[at - a_base - 2], &b[at - b_base - 2])) return error.LogMatching;
    }
    assert(high > low);
    assert(low >= a_base and low >= b_base);
}

/// `after` must extend the log whose fingerprints are `before`: same prefix, never shorter.
pub fn leader_append_only(before: []const u64, after: []const Entry) Violation!void {
    return leader_append_only_window(before, 0, after, 0);
}

/// `leader_append_only` for windows: `before` holds the fingerprints of the indexes
/// `before_base + 1 ..`, `after` the entries from `after_base + 1`. The window may slide forward
/// (compaction) but never back, the last index never shrinks, and the shared indexes agree.
pub fn leader_append_only_window(
    before: []const u64,
    before_base: u64,
    after: []const Entry,
    after_base: u64,
) Violation!void {
    if (after_base < before_base) return error.LeaderAppendOnly;
    if (after_base + after.len < before_base + before.len) return error.LeaderAppendOnly;
    const skip = after_base - before_base; // Positions of `before` that `after` compacted.
    if (skip >= before.len) return;
    const kept = before[@intCast(skip)..];
    assert(after.len >= kept.len); // The last index did not shrink.
    for (kept, after[0..kept.len]) |print, *entry| {
        if (print != fingerprint(entry)) return error.LeaderAppendOnly;
    }
}

/// Per-node memory: commit and applied counters, and the leader append-only record.
const NodeMemory = struct {
    commit: u64 = 0,
    applied: u64 = 0,
    leader_term: u64 = 0,
    leader_base: u64 = 0,
    leader_len: u32 = 0,
    leading: bool = false,
};

/// One remembered `(index, digest)` of the state digest ring; `used` is false until first write.
const DigestSlot = struct { index: u64, digest: u64, used: bool };

/// The checker; see the module header for state, limits and the latching rule.
pub const Checker = struct {
    /// `log_entries_max` is the length of one node's log window; `chosen_entries_max` (>=
    /// `log_entries_max`) is the highest absolute log index the checker can remember as chosen.
    pub const Options = struct {
        nodes_count: u8,
        log_entries_max: u32,
        chosen_entries_max: u32,
        terms_max: u32,
    };
    pub const Stats = struct { leader_terms: u32, committed_max: u64 };

    options: Options,
    latched: [properties_count]?Violation,
    nodes: []NodeMemory,
    leader_prints: []u64, // nodes_count rows of log_entries_max fingerprints.
    chosen_prints: []u64, // Index i holds the fingerprint chosen at log index i + 1.
    chosen_terms: []u64, // The observer's term when index i + 1 was first seen committed.
    scratch: []u64, // The fingerprints of the window being observed (by position).
    leader_of_term: []u8, // terms_max + 1 slots: leader node_index + 1, or 0 for none.
    digests: []DigestSlot, // log_entries_max slots; index `i` lives in slot `i % len`.
    digest_newest: u64, // The highest applied index any `state_digest` reported.
    chosen_max: u32,
    leader_terms: u32,

    /// Allocates every slice from `gpa`; the checker starts clean. `deinit` frees them.
    pub fn init(checker: *Checker, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.nodes_count > 0);
        assert(options.nodes_count < std.math.maxInt(u8)); // `node_index + 1` is the table id.
        assert(options.log_entries_max > 0);
        assert(options.chosen_entries_max >= options.log_entries_max);
        assert(options.terms_max > 0);
        const log_max: usize = options.log_entries_max;
        const chosen_max: usize = options.chosen_entries_max;
        const nodes = try gpa.alloc(NodeMemory, options.nodes_count);
        errdefer gpa.free(nodes);

        const leader_prints = try gpa.alloc(u64, options.nodes_count * log_max);
        errdefer gpa.free(leader_prints);

        const chosen_prints = try gpa.alloc(u64, chosen_max);
        errdefer gpa.free(chosen_prints);

        const chosen_terms = try gpa.alloc(u64, chosen_max);
        errdefer gpa.free(chosen_terms);

        const scratch = try gpa.alloc(u64, log_max);
        errdefer gpa.free(scratch);

        const leader_of_term = try gpa.alloc(u8, @as(usize, options.terms_max) + 1);
        errdefer gpa.free(leader_of_term);

        const digests = try gpa.alloc(DigestSlot, log_max);
        errdefer gpa.free(digests);

        @memset(nodes, .{});
        @memset(leader_of_term, 0);
        @memset(digests, .{ .index = 0, .digest = 0, .used = false });
        checker.* = .{
            .options = options,
            .latched = @splat(null),
            .nodes = nodes,
            .leader_prints = leader_prints,
            .chosen_prints = chosen_prints,
            .chosen_terms = chosen_terms,
            .scratch = scratch,
            .leader_of_term = leader_of_term,
            .digests = digests,
            .digest_newest = 0,
            .chosen_max = 0,
            .leader_terms = 0,
        };
    }

    /// Frees the slices `init` allocated; `gpa` must be the one given to `init`.
    pub fn deinit(checker: *Checker, gpa: Allocator) void {
        assert(checker.nodes.len == checker.options.nodes_count);
        assert(checker.leader_of_term.len == @as(usize, checker.options.terms_max) + 1);
        assert(checker.digests.len == checker.options.log_entries_max);
        assert(checker.chosen_prints.len == checker.options.chosen_entries_max);
        gpa.free(checker.digests);
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
                // Each window was validated by `observe_one`, so the bases exist.
                const first_base = window_base(&first).?;
                const second_base = window_base(&second).?;
                log_matching_window(first.log, first_base, second.log, second_base) catch {
                    return checker.fail(.log_matching);
                };
            }
        }
        assert(checker.chosen_max <= checker.options.chosen_entries_max);
    }

    /// Node `node_index` applied the entry at `index` whose fingerprint is `entry_fingerprint`.
    pub fn applied(
        checker: *Checker,
        node_index: u8,
        index: Index,
        entry_fingerprint: u64,
    ) Violation!void {
        assert(node_index < checker.options.nodes_count);
        assert(checker.chosen_max <= checker.options.chosen_entries_max);
        const memory = &checker.nodes[node_index];
        const at: u64 = @intFromEnum(index);
        if (at != memory.applied + 1) return checker.fail(.state_machine_safety);
        if (at > memory.commit) return checker.fail(.state_machine_safety);
        assert(memory.commit <= checker.chosen_max); // A commit is chosen when observed.
        const chosen = checker.chosen_prints[@intCast(at - 1)];
        if (chosen != entry_fingerprint) return checker.fail(.state_machine_safety);
        memory.applied = at;
    }

    /// Node `node_index` installed a snapshot: its applied index jumps to `applied_index`
    /// without per-entry `applied` reports (the next `applied` must be `applied_index + 1`).
    /// An install never goes back (`applied_index` must exceed the node's applied index) and a
    /// snapshot covers only chosen entries (`applied_index <= chosen_max`); either breach is
    /// `StateMachineSafety`. An installed snapshot is committed, so the node's commit rises to
    /// at least `applied_index`.
    pub fn installed(
        checker: *Checker,
        node_index: u8,
        applied_index: Index,
    ) Violation!void {
        assert(node_index < checker.options.nodes_count);
        assert(checker.chosen_max <= checker.options.chosen_entries_max);
        const memory = &checker.nodes[node_index];
        const at: u64 = @intFromEnum(applied_index);
        if (at <= memory.applied) return checker.fail(.state_machine_safety);
        if (at > checker.chosen_max) return checker.fail(.state_machine_safety);
        memory.applied = at;
        memory.commit = @max(memory.commit, at);
        assert(memory.applied <= memory.commit); // Applied never passes commit.
        assert(memory.commit <= checker.chosen_max); // A commit is chosen when observed.
    }

    /// Node `node_index` holds state digest `digest` at applied index `applied_index` (a
    /// snapshot install jumps the index, so reports need not be contiguous). The first digest
    /// seen at an index is remembered in a ring of `log_entries_max` slots; any other digest at
    /// that index, from any node, is `StateMachineSafety`. An index `log_entries_max` or more
    /// behind the newest reported one is forgotten and not compared.
    pub fn state_digest(
        checker: *Checker,
        node_index: u8,
        applied_index: Index,
        digest: u64,
    ) Violation!void {
        assert(node_index < checker.options.nodes_count);
        assert(checker.digests.len == checker.options.log_entries_max);
        const at: u64 = @intFromEnum(applied_index);
        const ring_len: u64 = checker.digests.len;
        if (at +| ring_len <= checker.digest_newest) return; // Older than the ring.

        const slot = &checker.digests[@intCast(at % ring_len)];
        if (slot.used and slot.index == at) {
            if (slot.digest != digest) return checker.fail(.state_machine_safety);
            return;
        }
        // The slot is empty or holds an index below the ring: `at` is in the window, so a
        // slot index `at + k * ring_len` with k > 0 would have made `at` older than the ring.
        assert(!slot.used or slot.index < at);
        slot.* = .{ .index = at, .digest = digest, .used = true };
        checker.digest_newest = @max(checker.digest_newest, at);
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
        assert(checker.chosen_max <= checker.options.chosen_entries_max);
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
        const base = window_base(one) orelse return checker.fail(.state_machine_safety);
        for (one.log, 0..) |*entry, i| {
            if (@intFromEnum(entry.index) != base + 1 + i) {
                return checker.fail(.state_machine_safety);
            }
            checker.scratch[i] = fingerprint(entry);
        }
        try checker.commit_node(one, base);
        if (one.status.role != .leader) return;
        try checker.leader_log(one, base);
        try checker.leader_complete(one, base);
    }

    /// State machine safety: the node's commit never regresses, the part of its window inside
    /// the chosen prefix still equals it, and each newly committed index equals what anyone
    /// committed there. Indexes below `base` were compacted: they cannot be re-read, so they
    /// are skipped, but they must already be chosen (the checker cannot extend by what it
    /// cannot see). Chosen entries past `chosen_entries_max` are `ChosenExhausted`.
    fn commit_node(checker: *Checker, one: *const Observation, base: u64) ObserveError!void {
        const memory = &checker.nodes[one.node_index];
        const commit: u64 = @intFromEnum(one.status.commit_index);
        if (commit > base + one.log.len) return checker.fail(.state_machine_safety); // Not held.
        const seen = memory.commit;
        assert(seen <= checker.chosen_max);
        if (commit < seen) return checker.fail(.state_machine_safety);
        if (seen > base) { // The window part inside the chosen prefix `[1, seen]`.
            const overlap: usize = @intCast(seen - base);
            assert(overlap <= one.log.len); // `seen <= commit <= base + log.len`.
            const chosen = checker.chosen_prints[@intCast(base)..][0..overlap];
            for (checker.scratch[0..overlap], chosen) |have, want| {
                if (have != want) return checker.fail(.state_machine_safety);
            }
        }
        const term: u64 = @intFromEnum(one.status.term);
        for (@as(usize, @intCast(seen))..@as(usize, @intCast(commit))) |i| {
            const have = if (i < base) // Compacted: chosen already, or in a leader's old window.
                checker.compacted_print(one, i) orelse return checker.fail(.state_machine_safety)
            else
                checker.scratch[i - @as(usize, @intCast(base))];
            if (i < checker.chosen_max) {
                if (have != checker.chosen_prints[i]) {
                    return checker.fail(.state_machine_safety);
                }
                continue;
            }
            assert(i == checker.chosen_max); // Commits extend the chosen prefix by one.
            if (i >= checker.options.chosen_entries_max) return error.ChosenExhausted;
            checker.chosen_prints[i] = have;
            checker.chosen_terms[i] = term;
            checker.chosen_max += 1;
        }
        memory.commit = commit;
    }

    /// The fingerprint at the absolute 0-based position `at`, below the window of `one`, that a
    /// commit skipped: the chosen one, or (for an index not chosen yet) the one in the previous
    /// window of a node that led in the same term, which never truncates. `null`: unverifiable.
    fn compacted_print(checker: *const Checker, one: *const Observation, at: usize) ?u64 {
        assert(at < window_base(one).?);
        if (at < checker.chosen_max) return checker.chosen_prints[at];
        const memory = &checker.nodes[one.node_index];
        if (!memory.leading) return null;
        if (memory.leader_term != @intFromEnum(one.status.term)) return null;
        if (at < memory.leader_base) return null; // Compacted before it was last seen.
        const offset = at - @as(usize, @intCast(memory.leader_base));
        if (offset >= memory.leader_len) return null;
        const log_max: usize = checker.options.log_entries_max;
        return checker.leader_prints[one.node_index * log_max ..][offset];
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
    fn leader_log(checker: *Checker, one: *const Observation, base: u64) Violation!void {
        assert(one.status.role == .leader);
        assert(one.log.len <= checker.options.log_entries_max);
        const memory = &checker.nodes[one.node_index];
        const term: u64 = @intFromEnum(one.status.term);
        const log_max: usize = checker.options.log_entries_max;
        const row = checker.leader_prints[one.node_index * log_max ..][0..log_max];
        if (memory.leading and memory.leader_term == term) {
            const before = row[0..memory.leader_len];
            leader_append_only_window(before, memory.leader_base, one.log, base) catch {
                return checker.fail(.leader_append_only);
            };
        }
        @memcpy(row[0..one.log.len], checker.scratch[0..one.log.len]);
        memory.leader_len = @intCast(one.log.len);
        memory.leader_base = base;
        memory.leader_term = term;
        memory.leading = true;
        assert(memory.leader_len == one.log.len);
    }

    /// Leader completeness: a leader of `term` holds every entry chosen in a term <= `term`
    /// (the ones it compacted below its window are not re-read).
    fn leader_complete(checker: *Checker, one: *const Observation, base: u64) Violation!void {
        const term: u64 = @intFromEnum(one.status.term);
        assert(one.status.role == .leader);
        assert(checker.chosen_max <= checker.options.chosen_entries_max);
        const last = base + one.log.len;
        const first: usize = @intCast(@min(base, checker.chosen_max));
        for (first..checker.chosen_max) |i| {
            if (checker.chosen_terms[i] > term) continue;
            if (i >= last) return checker.fail(.leader_completeness);
            if (checker.scratch[i - @as(usize, @intCast(base))] != checker.chosen_prints[i]) {
                return checker.fail(.leader_completeness);
            }
        }
    }
};
