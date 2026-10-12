//! Model-based seeded cluster test for `raft.Node` (plan 003, the Tiger Style section 5 library
//! form of simulation, ahead of Phase 3's `sim/`).
//!
//! A `Cluster` of 3 or 5 real nodes is driven by one seeded PRNG: tick a node, propose on a
//! leader, or deliver one message from a pool of in-flight messages (in seeded order, with
//! drops and duplicates). Every `send` effect goes back into the pool; time is logical ticks
//! only, so a seed replays bit for bit. After EVERY step `check_invariants()` runs on every
//! node and an `Oracle`, which sees only observable behavior (statuses, logs, apply effects),
//! checks the four Raft safety properties: election safety, log matching, leader completeness
//! and state machine safety. Persist and restore are out of scope (nodes never restart).
//!
//! A failing seed is reported in a `Report` (seed, node count, step) and by the error returned,
//! so the run is reproducible. The planted-bug tests prove the oracle bites: a harness-level
//! fault (forged vote grants, `Mutation.forge_votes`) models a peer that lies about its vote
//! and must be caught by some seed, without touching production code.
//!
//! Allocation: every node allocates through `std.testing.allocator`; the pool is fixed-size.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const types = @import("../types.zig");
const fx = @import("fixtures.zig");
const node_module = @import("node.zig");

const Effects = node_module.Effects;
const Entry = types.Entry;
const Message = types.Message;

const nodes_max = 5;
const steps_max = 500;
const pool_max = 40;
const index_max = 64;
const data_max = 8;
const entries_per_message = 4;
const entry_bytes = 32;
const seeds_count = 500;

/// Election timeouts land in [10, 20); the log is big enough that 500 steps rarely fill it.
const node_config: node_module.Config = blk: {
    var result = fx.config5;
    result.log_entries_max = index_max;
    result.log_bytes_max = index_max * data_max;
    break :blk result;
};

/// What the oracle found, or what the harness itself hit.
const Violation = error{
    ElectionSafety,
    LogMatching,
    LeaderCompleteness,
    StateMachineSafety,
    CommitRegression,
    ApplyOrder,
    HarnessLimit,
};

const RunError = Violation || node_module.InvariantError || node_module.InitError ||
    node_module.StepError || error{TestUnexpectedResult};

/// A fault the harness injects to prove the oracle detects safety violations.
const Mutation = enum { none, forge_votes };

/// Where a run stopped; the seed alone replays it.
const Report = struct { seed: u64 = 0, nodes: u32 = 0, step: u32 = 0 };

/// Aggregate evidence that a run did real work, not just survived.
const Stats = struct { leaders: u32 = 0, committed: u32 = 0, applied: u32 = 0 };

/// One entry as the oracle remembers it: term, kind and bytes (never a borrowed slice).
const Rec = struct {
    set: bool = false,
    term: u64 = 0,
    kind: types.EntryKind = .normal,
    len: u8 = 0,
    data: [data_max]u8 = @splat(0),

    fn of(entry: Entry) Violation!Rec {
        if (entry.data.len > data_max) return error.HarnessLimit;
        var rec: Rec = .{ .set = true, .term = @intFromEnum(entry.term), .kind = entry.kind };
        rec.len = @intCast(entry.data.len);
        @memcpy(rec.data[0..entry.data.len], entry.data);
        return rec;
    }

    fn eql(a: Rec, b: Rec) bool {
        return a.term == b.term and a.kind == b.kind and a.len == b.len and
            std.mem.eql(u8, a.data[0..a.len], b.data[0..b.len]);
    }
};

fn entry_eql(a: Entry, b: Entry) bool {
    return a.term == b.term and a.kind == b.kind and std.mem.eql(u8, a.data, b.data);
}

/// Log matching (Raft paper Figure 3): two logs holding the same term at an index agree on that
/// entry and on everything before it. Checking the entry just before each equal-term index
/// proves the whole prefix by induction.
fn log_matching(a: []const Entry, b: []const Entry) Violation!void {
    const common = @min(a.len, b.len);
    for (0..common) |i| {
        if (a[i].term != b[i].term) continue;
        if (!entry_eql(a[i], b[i])) return error.LogMatching;
        if (i > 0 and !entry_eql(a[i - 1], b[i - 1])) return error.LogMatching;
    }
}

/// The black-box safety checker. It is told what happened and knows nothing of `Node` internals.
const Oracle = struct {
    leader_of_term: [steps_max + 2]u8 = @splat(0),
    chosen: [index_max + 1]Rec = @splat(.{}),
    chosen_term: [index_max + 1]u64 = @splat(0),
    chosen_max: u64 = 0,
    seen_commit: [nodes_max]u64 = @splat(0),
    applied_len: [nodes_max]u64 = @splat(0),

    /// Election safety: at most one leader per term.
    fn leader(oracle: *Oracle, term: u64, id: u8) Violation!void {
        if (term >= oracle.leader_of_term.len) return error.HarnessLimit;
        const known = oracle.leader_of_term[term];
        if (known != 0 and known != id) return error.ElectionSafety;
        oracle.leader_of_term[term] = id;
    }

    /// Newly committed entries of node `slot` (log prefix up to `commit`) become chosen: the
    /// first node to commit an index fixes it, and every other must agree (safety).
    fn commit(
        oracle: *Oracle,
        slot: usize,
        term: u64,
        commit_index: u64,
        log: []const Entry,
    ) Violation!void {
        if (commit_index < oracle.seen_commit[slot]) return error.CommitRegression;
        if (commit_index > log.len or commit_index > index_max) return error.HarnessLimit;
        var index = oracle.seen_commit[slot] + 1;
        while (index <= commit_index) : (index += 1) {
            const entry = log[@intCast(index - 1)];
            if (@intFromEnum(entry.index) != index) return error.HarnessLimit;
            try oracle.choose(index, entry, term);
        }
        oracle.seen_commit[slot] = commit_index;
    }

    fn choose(oracle: *Oracle, index: u64, entry: Entry, term: u64) Violation!void {
        const rec = try Rec.of(entry);
        const slot: usize = @intCast(index);
        if (oracle.chosen[slot].set) {
            if (!oracle.chosen[slot].eql(rec)) return error.StateMachineSafety;
            return;
        }
        oracle.chosen[slot] = rec;
        oracle.chosen_term[slot] = term;
        oracle.chosen_max = @max(oracle.chosen_max, index);
    }

    /// State machine safety: node `slot` applies indices in order, once, each already chosen
    /// (committed) and equal to what every other node applied at that index.
    fn applied(oracle: *Oracle, slot: usize, batch: []const Entry) Violation!void {
        for (batch) |entry| {
            const index = @intFromEnum(entry.index);
            if (index != oracle.applied_len[slot] + 1) return error.ApplyOrder;
            if (index > oracle.seen_commit[slot]) return error.ApplyOrder;
            const chosen = oracle.chosen[@intCast(index)];
            if (!chosen.set or !chosen.eql(try Rec.of(entry))) return error.StateMachineSafety;
            oracle.applied_len[slot] = index;
        }
    }

    /// Leader completeness: a leader of `term` holds every entry committed in a term <= `term`.
    fn leader_completeness(oracle: *const Oracle, term: u64, log: []const Entry) Violation!void {
        var index: u64 = 1;
        while (index <= oracle.chosen_max) : (index += 1) {
            const slot: usize = @intCast(index);
            if (oracle.chosen_term[slot] > term) continue;
            if (index > log.len) return error.LeaderCompleteness;
            const rec = try Rec.of(log[slot - 1]);
            if (!oracle.chosen[slot].eql(rec)) return error.LeaderCompleteness;
        }
    }
};

/// A message in flight, owned by value: entry bytes are copied out of the sender's borrowed
/// effects. `view` rebuilds the borrowed slices on the caller's stack, so slots can move freely.
const Slot = struct {
    message: Message,
    count: u8,
    entries: [entries_per_message]Entry,
    lens: [entries_per_message]u8,
    bytes: [entries_per_message * entry_bytes]u8,

    fn from(message: Message) Violation!Slot {
        var slot: Slot = undefined;
        slot.message = message;
        slot.count = 0;
        if (message != .append_entries) return slot;
        const request = message.append_entries;
        if (request.entries.len > entries_per_message) return error.HarnessLimit;
        slot.message.append_entries.entries = &.{};
        for (request.entries, 0..) |entry, k| {
            if (entry.data.len > entry_bytes) return error.HarnessLimit;
            const at = k * entry_bytes;
            @memcpy(slot.bytes[at..][0..entry.data.len], entry.data);
            slot.lens[k] = @intCast(entry.data.len);
            slot.entries[k] = entry;
            slot.entries[k].data = "";
        }
        slot.count = @intCast(request.entries.len);
        return slot;
    }

    fn view(slot: *const Slot, out: *[entries_per_message]Entry) Message {
        var message = slot.message;
        if (message != .append_entries) return message;
        for (0..slot.count) |k| {
            out[k] = slot.entries[k];
            out[k].data = slot.bytes[k * entry_bytes ..][0..slot.lens[k]];
        }
        message.append_entries.entries = out[0..slot.count];
        return message;
    }
};

const Cluster = struct {
    count: u32,
    rigs: [nodes_max]fx.Rig,
    inited: u32,
    pool: [pool_max]Slot,
    pool_len: u32,
    prng: std.Random.DefaultPrng,
    oracle: Oracle,
    mutation: Mutation,
    stats: Stats,
    proposed: u8,

    /// In place: each `Rig` owns the `Rng` its node points at, so it must never move.
    fn init(
        cluster: *Cluster,
        count: u32,
        seed: u64,
        mutation: Mutation,
    ) node_module.InitError!void {
        assert(count == 3 or count == 5);
        cluster.count = count;
        cluster.inited = 0;
        cluster.pool_len = 0;
        cluster.prng = std.Random.DefaultPrng.init(seed);
        cluster.oracle = .{};
        cluster.mutation = mutation;
        cluster.stats = .{};
        cluster.proposed = 0;
        errdefer cluster.deinit();
        const voters = if (count == 3) &fx.voters else &fx.voters5;
        const configuration: types.Configuration = .{
            .voters = voters,
            .voters_outgoing = &.{},
            .learners = &.{},
        };
        const restore = fx.restore_with(configuration, fx.hard_state_of(0, 0, 0), &.{});
        for (0..count) |i| {
            var node_cfg = node_config;
            node_cfg.id = fx.node_id(i + 1);
            const node_seed = cluster.prng.random().int(u64);
            try cluster.rigs[i].init(testing.allocator, node_cfg, &restore, node_seed);
            cluster.inited += 1;
        }
    }

    fn deinit(cluster: *Cluster) void {
        for (cluster.rigs[0..cluster.inited]) |*rig| rig.deinit(testing.allocator);
        cluster.inited = 0;
    }

    fn enqueue(cluster: *Cluster, message: Message) Violation!void {
        const slot = try Slot.from(message);
        if (cluster.pool_len < pool_max) {
            cluster.pool[cluster.pool_len] = slot;
            cluster.pool_len += 1;
        } else { // A full network loses a random message, like any other drop.
            cluster.pool[cluster.prng.random().uintLessThan(u32, pool_max)] = slot;
        }
    }

    /// Everything that must hold after node `slot` took one step that produced `effects`.
    fn observe(cluster: *Cluster, slot: usize, effects: Effects) RunError!void {
        try fx.expect_effects_ordered(effects, node_config);
        const status = cluster.rigs[slot].node.status();
        const term = @intFromEnum(status.term);
        const log = cluster.rigs[slot].node.entries();
        try cluster.oracle.commit(slot, term, @intFromEnum(status.commit_index), log);
        for (effects.items) |effect| switch (effect) {
            .send => |message| try cluster.enqueue(message),
            .apply => |batch| {
                try cluster.oracle.applied(slot, batch);
                cluster.stats.applied += @intCast(batch.len);
            },
            else => {},
        };
        if (status.role == .leader) try cluster.oracle.leader(term, @intCast(slot + 1));
        try cluster.check_all(slot);
    }

    fn check_all(cluster: *Cluster, stepped: usize) RunError!void {
        const stepped_log = cluster.rigs[stepped].node.entries();
        for (cluster.rigs[0..cluster.count], 0..) |*rig, i| {
            try rig.node.check_invariants();
            const log = rig.node.entries();
            if (i != stepped) try log_matching(stepped_log, log);
            const status = rig.node.status();
            if (status.role != .leader) continue;
            try cluster.oracle.leader_completeness(@intFromEnum(status.term), log);
        }
    }

    fn step_tick(cluster: *Cluster, slot: usize) RunError!void {
        const effects = try cluster.rigs[slot].node.step(.tick);
        try cluster.observe(slot, effects);
    }

    fn step_propose(cluster: *Cluster) RunError!void {
        const random = cluster.prng.random();
        var slot = random.uintLessThan(usize, cluster.count);
        for (0..cluster.count) |i| { // Prefer a node that believes it leads.
            if (cluster.rigs[i].node.status().role == .leader) slot = i;
        }
        cluster.proposed +%= 1;
        const data = [2]u8{ cluster.proposed, @intCast(slot + 1) };
        const effects = cluster.rigs[slot].node.step(.{ .propose = &data }) catch |err|
            switch (err) {
                error.ProposeNotLeader, error.ProposeLogFull => return,
                else => return err,
            };
        try cluster.observe(slot, effects);
    }

    fn step_deliver(cluster: *Cluster) RunError!void {
        const random = cluster.prng.random();
        const at = random.uintLessThan(u32, cluster.pool_len);
        const local = cluster.pool[at];
        const fate = random.uintLessThan(u32, 100);
        const duplicate = fate >= 10 and fate < 20;
        if (!duplicate) { // Delivered or dropped: leaves the pool. A duplicate stays for later.
            cluster.pool_len -= 1;
            cluster.pool[at] = cluster.pool[cluster.pool_len];
        }
        if (fate < 10) return; // Dropped.
        var buffer: [entries_per_message]Entry = undefined;
        var message = local.view(&buffer);
        if (cluster.mutation == .forge_votes and message == .request_vote_response) {
            message.request_vote_response.granted = true;
        }
        const to = @intFromEnum(message.header().to);
        if (to == 0 or to > cluster.count) return error.HarnessLimit;
        const slot: usize = @intCast(to - 1);
        const effects = try cluster.rigs[slot].node.step(.{ .message = &message });
        try cluster.observe(slot, effects);
    }

    fn step_once(cluster: *Cluster) RunError!void {
        const random = cluster.prng.random();
        const roll = random.uintLessThan(u32, 100);
        if (roll < 25 or cluster.pool_len == 0) {
            try cluster.step_tick(random.uintLessThan(usize, cluster.count));
        } else if (roll < 40) {
            try cluster.step_propose();
        } else {
            try cluster.step_deliver();
        }
    }

    fn finish(cluster: *Cluster) Stats {
        var stats = cluster.stats;
        stats.leaders = 0;
        for (cluster.oracle.leader_of_term) |id| stats.leaders += @intFromBool(id != 0);
        stats.committed = @intCast(cluster.oracle.chosen_max);
        return stats;
    }
};

/// One seeded run of `steps_max` steps over 3 nodes (even seeds) or 5 (odd seeds).
fn run(seed: u64, mutation: Mutation, report: *Report) RunError!Stats {
    const count: u32 = if (seed % 2 == 0) 3 else 5;
    report.* = .{ .seed = seed, .nodes = count };
    var cluster: Cluster = undefined;
    try cluster.init(count, seed, mutation);
    defer cluster.deinit();
    for (0..steps_max) |step| {
        report.step = @intCast(step);
        try cluster.step_once();
    }
    return cluster.finish();
}

test "cluster model: 500 seeds of 3 and 5 nodes keep every safety property" {
    var report: Report = .{};
    var seeds_led: u32 = 0;
    var seeds_committed: u32 = 0;
    var applied_total: u32 = 0;
    for (0..seeds_count) |seed| {
        const stats = run(seed, .none, &report) catch |err| {
            std.log.err("cluster model: {s} at seed {d} ({d} nodes) step {d}", .{
                @errorName(err), report.seed, report.nodes, report.step,
            });
            return err;
        };
        seeds_led += @intFromBool(stats.leaders > 0);
        seeds_committed += @intFromBool(stats.committed > 0);
        applied_total += stats.applied;
    }
    // Progress: the harness is not vacuous. Elections happen and entries commit and apply.
    try testing.expect(seeds_led * 10 >= seeds_count * 9);
    try testing.expect(seeds_committed * 10 >= seeds_count * 9);
    try testing.expect(applied_total > 0);
}

test "cluster model: the same seed replays to the same outcome" {
    var report: Report = .{};
    const first = try run(7, .none, &report);
    const second = try run(7, .none, &report);
    try testing.expectEqual(first, second);
}

test "cluster model: planted bug of forged vote grants is detected and reports its seed" {
    var report: Report = .{};
    var found: ?u64 = null;
    var violation: ?RunError = null;
    for (0..seeds_count) |seed| {
        if (run(seed, .forge_votes, &report)) |_| continue else |err| {
            found = report.seed;
            violation = err;
            break;
        }
    }
    const seed = found orelse return error.PlantedBugUndetected;
    try testing.expectEqual(seed, report.seed);
    // The same seed fails the same way (reproducible), and passes without the planted bug.
    var again: Report = .{};
    try testing.expectError(violation.?, run(seed, .forge_votes, &again));
    try testing.expectEqual(report.step, again.step);
    _ = try run(seed, .none, &again);
}

fn entry_of(index: u64, term: u64, data: []const u8) Entry {
    return fx.entry(index, term, data);
}

test "oracle: two leaders in one term is an election safety violation" {
    var oracle: Oracle = .{};
    try oracle.leader(3, 1);
    try oracle.leader(3, 1); // The same leader again is fine.
    try oracle.leader(4, 2);
    try testing.expectError(error.ElectionSafety, oracle.leader(3, 2));
}

test "oracle: equal terms with different bytes, or a diverged prefix, break log matching" {
    const a = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "b") };
    const same = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "b"), entry_of(3, 2, "c") };
    const other_data = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "x") };
    const other_prefix = [_]Entry{ entry_of(1, 1, "z"), entry_of(2, 2, "b") };
    const other_term = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 3, "x") };
    try log_matching(&a, &same);
    try log_matching(&a, &other_term); // Different terms at index 2 may differ.
    try testing.expectError(error.LogMatching, log_matching(&a, &other_data));
    try testing.expectError(error.LogMatching, log_matching(&a, &other_prefix));
}

test "oracle: commit regress, divergent commit, and incomplete leader are detected" {
    const log = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "b") };
    const forked = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "q") };
    var oracle: Oracle = .{};
    try oracle.commit(0, 2, 2, &log);
    try testing.expectError(error.CommitRegression, oracle.commit(0, 2, 1, &log));
    try testing.expectError(error.StateMachineSafety, oracle.commit(1, 2, 2, &forked));
    try oracle.leader_completeness(2, &log);
    try oracle.leader_completeness(1, log[0..1]); // Index 2 was committed in term 2 > 1.
    try testing.expectError(error.LeaderCompleteness, oracle.leader_completeness(3, log[0..1]));
    try testing.expectError(error.LeaderCompleteness, oracle.leader_completeness(3, &forked));
}

test "oracle: apply out of order, past commit, or diverging from the chosen entry is caught" {
    const log = [_]Entry{ entry_of(1, 1, "a"), entry_of(2, 2, "b") };
    var oracle: Oracle = .{};
    try oracle.commit(0, 2, 1, &log);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Skips index 1.
    try testing.expectError(error.StateMachineSafety, oracle.applied(0, &.{entry_of(1, 1, "x")}));
    try oracle.applied(0, log[0..1]);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Not committed yet.
    try oracle.commit(0, 2, 2, &log);
    try oracle.applied(0, log[1..2]);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Twice.
}

test "cluster model: a message slot keeps entry bytes after the sender's buffer changes" {
    var scratch = [_]u8{ 'a', 'b' };
    const entries = [_]Entry{entry_of(1, 1, scratch[0..2])};
    const message = fx.append_request(2, 1, 0, 0, 0, &entries);
    const slot = try Slot.from(message);
    scratch = .{ 'z', 'z' };
    var out: [entries_per_message]Entry = undefined;
    const view = slot.view(&out);
    try testing.expectEqualStrings("ab", view.append_entries.entries[0].data);
}
