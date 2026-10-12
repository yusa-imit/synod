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
//! Churn comes from a seeded partition schedule: a node (often the leader) is cut off for a
//! while, keeps ticking and proposing, and rejoins with a stale or diverged log, so leaders
//! change and followers truncate. Two planted faults, `forge_votes` and `flip_data`, must be
//! caught as specific violations.
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
const seeds_count = 500;
const partition_percent = 4; // Chance per step that a node is cut off from the network.
const partition_min = 25;
const partition_span = 60;

/// Election timeouts land in [10, 20); the log is big enough that 500 steps rarely fill it.
const node_config: node_module.Config = blk: {
    var result = fx.config5;
    result.log_entries_max = index_max;
    result.log_bytes_max = index_max * data_max;
    break :blk result;
};

const entries_per_message = node_config.message_limits.entries_max;
const entry_bytes = node_config.message_limits.entry_bytes_max;

/// What the oracle found, or what the harness itself hit.
const Violation = error{
    ElectionSafety,
    LogMatching,
    LeaderCompleteness,
    StateMachineSafety,
    CommitRegression,
    CommittedOverwritten,
    ApplyOrder,
    HarnessLimit,
};

const RunError = Violation || node_module.InvariantError || node_module.InitError ||
    node_module.StepError || error{TestUnexpectedResult};

/// A fault the harness injects to prove the oracle detects safety violations.
const Mutation = enum {
    none,
    /// A peer lies about its vote: every denied `request_vote_response` is delivered granted.
    forge_votes,
    /// The network flips one data byte of the first non-empty entry in a delivered append.
    flip_data,
};

/// Where a run stopped; the seed alone replays it.
const Report = struct { seed: u64 = 0, nodes: u32 = 0, step: u32 = 0 };

/// Aggregate evidence that a run did real work, not just survived.
const Stats = struct {
    leaders: u32 = 0, // Distinct terms that had a leader.
    committed: u32 = 0,
    applied: u32 = 0,
    truncates: u32 = 0, // `truncate` effects: a follower cut a diverged suffix.
    digest: u64 = 0, // Hash of every node's final log, to pin replay equality.
};

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

    /// A committed entry is never overwritten: node `slot`'s log still starts with the chosen
    /// entries up to the commit index it last reported.
    fn committed_prefix(oracle: *const Oracle, slot: usize, log: []const Entry) Violation!void {
        const upto: usize = @intCast(oracle.seen_commit[slot]);
        if (log.len < upto) return error.CommittedOverwritten;
        for (log[0..upto], 1..) |entry, index| {
            if (!oracle.chosen[index].eql(try Rec.of(entry))) return error.CommittedOverwritten;
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

    /// Corrupts one byte of the first non-empty entry, as a faulty network would.
    fn flip(slot: *Slot) void {
        for (0..slot.count) |k| {
            if (slot.lens[k] == 0) continue;
            slot.bytes[k * entry_bytes] ^= 0xff;
            return;
        }
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

/// Index of the node a message is addressed to; an unknown id is a harness bug.
fn route(count: u32, message: *const Message) Violation!usize {
    const to = @intFromEnum(message.header().to);
    if (to == 0 or to > count) return error.HarnessLimit;
    return @intCast(to - 1);
}

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
    isolated: u8, // Node id cut off from the network, 0 for none.
    isolated_until: u32,
    step_no: u32,

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
        cluster.isolated = 0;
        cluster.isolated_until = 0;
        cluster.step_no = 0;
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
        assert(cluster.pool_len > 0 and cluster.pool_len <= pool_max);
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
            .truncate => cluster.stats.truncates += 1,
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
            try cluster.oracle.committed_prefix(i, log);
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
        var leaders: [nodes_max]usize = undefined;
        var leaders_len: usize = 0;
        for (0..cluster.count) |i| { // Every node that believes it leads, a stale one included.
            if (cluster.rigs[i].node.status().role != .leader) continue;
            leaders[leaders_len] = i;
            leaders_len += 1;
        }
        const slot = if (leaders_len > 0)
            leaders[random.uintLessThan(usize, leaders_len)]
        else
            random.uintLessThan(usize, cluster.count);
        cluster.proposed +%= 1;
        const data = [2]u8{ cluster.proposed, @intCast(slot + 1) };
        const effects = cluster.rigs[slot].node.step(.{ .propose = &data }) catch |err|
            switch (err) {
                error.ProposeNotLeader, error.ProposeLogFull => return,
                error.ProposeTooLarge => return error.ProposeTooLarge,
                else => return err,
            };
        try cluster.observe(slot, effects);
    }

    fn step_deliver(cluster: *Cluster) RunError!void {
        assert(cluster.pool_len > 0);
        const random = cluster.prng.random();
        const at = random.uintLessThan(u32, cluster.pool_len);
        var local = cluster.pool[at];
        const fate = random.uintLessThan(u32, 100);
        const duplicate = fate >= 10 and fate < 20;
        if (!duplicate) { // Delivered or dropped: leaves the pool. A duplicate stays for later.
            cluster.pool_len -= 1;
            cluster.pool[at] = cluster.pool[cluster.pool_len];
        }
        if (fate < 10) return; // Dropped.
        if (cluster.mutation == .flip_data) local.flip();
        var buffer: [entries_per_message]Entry = undefined;
        var message = local.view(&buffer);
        if (cluster.mutation == .forge_votes and message == .request_vote_response) {
            message.request_vote_response.granted = true;
        }
        if (cluster.cut(&message)) return; // Lost to the partition.
        const slot = try route(cluster.count, &message);
        const effects = try cluster.rigs[slot].node.step(.{ .message = &message });
        try cluster.observe(slot, effects);
    }

    /// Whether the partition swallows `message`: one end is the isolated node.
    fn cut(cluster: *const Cluster, message: *const Message) bool {
        if (cluster.isolated == 0) return false;
        const head = message.header();
        const id = cluster.isolated;
        return @intFromEnum(head.from) == id or @intFromEnum(head.to) == id;
    }

    /// Seeded partition schedule: sometimes cut one node (often the leader) off for a while;
    /// its clock and proposals keep running, so stale leaders and diverging logs happen.
    fn partition_update(cluster: *Cluster) void {
        const random = cluster.prng.random();
        cluster.step_no += 1;
        if (cluster.isolated != 0) {
            if (cluster.step_no >= cluster.isolated_until) cluster.isolated = 0;
            return;
        }
        if (random.uintLessThan(u32, 100) >= partition_percent) return;
        var victim = random.uintLessThan(usize, cluster.count);
        if (random.boolean()) {
            for (0..cluster.count) |i| {
                if (cluster.rigs[i].node.status().role == .leader) victim = i;
            }
        }
        cluster.isolated = @intCast(victim + 1);
        cluster.isolated_until = cluster.step_no + partition_min +
            random.uintLessThan(u32, partition_span);
        if (random.boolean()) cluster.purge(cluster.isolated);
    }

    /// Drops every in-flight message to or from node `id` (a crash that loses its buffers).
    fn purge(cluster: *Cluster, id: u8) void {
        var at: u32 = 0;
        while (at < cluster.pool_len) {
            var scratch: [entries_per_message]Entry = undefined;
            const message = cluster.pool[at].view(&scratch);
            const head = message.header();
            if (@intFromEnum(head.from) == id or @intFromEnum(head.to) == id) {
                cluster.pool_len -= 1;
                cluster.pool[at] = cluster.pool[cluster.pool_len];
            } else at += 1;
        }
    }

    fn step_once(cluster: *Cluster) RunError!void {
        cluster.partition_update();
        const random = cluster.prng.random();
        const roll = random.uintLessThan(u32, 100);
        if (roll < 25 or cluster.pool_len == 0) {
            try cluster.step_tick(random.uintLessThan(usize, cluster.count));
        } else if (roll < 37) {
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
        var hasher = std.hash.Wyhash.init(0);
        for (cluster.rigs[0..cluster.count]) |*rig| {
            for (rig.node.entries()) |entry| {
                hasher.update(std.mem.asBytes(&entry.term));
                hasher.update(entry.data);
            }
            hasher.update("|");
        }
        stats.digest = hasher.final();
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
    var seeds_turnover: u32 = 0;
    var seeds_truncated: u32 = 0;
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
        seeds_turnover += @intFromBool(stats.leaders >= 2);
        seeds_truncated += @intFromBool(stats.truncates > 0);
        applied_total += stats.applied;
    }
    // Progress: the harness is not vacuous. Elections happen and entries commit and apply.
    try testing.expect(seeds_led * 10 >= seeds_count * 9);
    try testing.expect(seeds_committed * 10 >= seeds_count * 9);
    try testing.expect(applied_total > 0);
    // Churn: leaders change and logs diverge, so leader completeness and log matching bite.
    try testing.expect(seeds_turnover * 5 >= seeds_count * 2);
    try testing.expect(seeds_truncated * 10 >= seeds_count * 3);
}

test "cluster model: the same seed replays to the same outcome and final logs" {
    var report: Report = .{};
    const first = try run(7, .none, &report);
    const second = try run(7, .none, &report);
    try testing.expectEqual(first, second);
    try testing.expect(first.digest != 0);
    const other = try run(8, .none, &report);
    try testing.expect(other.digest != first.digest);
}

/// Runs every seed under `mutation`: at least one must fail, every failure must be one of
/// `allowed`, and the first failing seed must replay to the same error at the same step.
fn expect_planted(mutation: Mutation, allowed: []const anyerror) !void {
    var report: Report = .{};
    var first: ?Report = null;
    var first_error: anyerror = undefined;
    for (0..seeds_count) |seed| {
        if (run(seed, mutation, &report)) |_| continue else |err| {
            const permitted = std.mem.indexOfScalar(anyerror, allowed, err) != null;
            if (!permitted) std.log.err("planted {s}: unexpected {s}", .{
                @tagName(mutation), @errorName(err),
            });
            try testing.expect(permitted);
            if (first == null) {
                first = report;
                first_error = err;
            }
        }
    }
    const seen = first orelse return error.PlantedBugUndetected;
    var again: Report = .{};
    try testing.expectError(first_error, run(seen.seed, mutation, &again));
    try testing.expectEqual(seen.step, again.step);
    _ = try run(seen.seed, .none, &again); // The seed is clean without the planted bug.
}

test "cluster model: forged vote grants are caught as election or leader safety" {
    try expect_planted(.forge_votes, &.{ error.ElectionSafety, error.LeaderCompleteness });
}

test "cluster model: a flipped entry byte is caught as log matching or state machine safety" {
    try expect_planted(.flip_data, &.{
        error.LogMatching,
        error.StateMachineSafety,
        error.CommittedOverwritten,
    });
}

test "oracle: two leaders in one term is an election safety violation" {
    var oracle: Oracle = .{};
    try oracle.leader(3, 1);
    try oracle.leader(3, 1); // The same leader again is fine.
    try oracle.leader(4, 2);
    try testing.expectError(error.ElectionSafety, oracle.leader(3, 2));
}

test "oracle: equal terms with different bytes, or a diverged prefix, break log matching" {
    const a = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b") };
    const same = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b"), fx.entry(3, 2, "c") };
    const other_data = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "x") };
    const other_prefix = [_]Entry{ fx.entry(1, 1, "z"), fx.entry(2, 2, "b") };
    const other_term = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 3, "x") };
    try log_matching(&a, &same);
    try log_matching(&a, &other_term); // Different terms at index 2 may differ.
    try testing.expectError(error.LogMatching, log_matching(&a, &other_data));
    try testing.expectError(error.LogMatching, log_matching(&a, &other_prefix));
}

test "oracle: commit regress, divergent commit, and incomplete leader are detected" {
    const log = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b") };
    const forked = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "q") };
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
    const log = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b") };
    var oracle: Oracle = .{};
    try oracle.commit(0, 2, 1, &log);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Skips index 1.
    try testing.expectError(error.StateMachineSafety, oracle.applied(0, &.{fx.entry(1, 1, "x")}));
    try oracle.applied(0, log[0..1]);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Not committed yet.
    try oracle.commit(0, 2, 2, &log);
    try oracle.applied(0, log[1..2]);
    try testing.expectError(error.ApplyOrder, oracle.applied(0, log[1..2])); // Twice.
}

test "cluster model: a message slot keeps entry bytes after the sender's buffer changes" {
    var scratch = [_]u8{ 'a', 'b' };
    const entries = [_]Entry{fx.entry(1, 1, scratch[0..2])};
    const message = fx.append_request(2, 1, 0, 0, 0, &entries);
    const slot = try Slot.from(message);
    scratch = .{ 'z', 'z' };
    var out: [entries_per_message]Entry = undefined;
    const view = slot.view(&out);
    try testing.expectEqualStrings("ab", view.append_entries.entries[0].data);
}

test "oracle: an overwritten or shortened committed prefix is caught" {
    const log = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 2, "b") };
    const rewritten = [_]Entry{ fx.entry(1, 1, "a"), fx.entry(2, 3, "b") };
    var oracle: Oracle = .{};
    try oracle.commit(0, 2, 2, &log);
    try oracle.committed_prefix(0, &log);
    try oracle.committed_prefix(1, &rewritten); // Node 1 committed nothing yet.
    try testing.expectError(error.CommittedOverwritten, oracle.committed_prefix(0, &rewritten));
    try testing.expectError(error.CommittedOverwritten, oracle.committed_prefix(0, log[0..1]));
}

test "harness: every HarnessLimit is provoked" {
    var oracle: Oracle = .{};
    const long = [_]Entry{fx.entry(1, 1, "123456789")}; // One byte above `data_max`.
    try testing.expectError(error.HarnessLimit, oracle.commit(0, 1, 1, &long));
    const short = [_]Entry{fx.entry(1, 1, "a")};
    try testing.expectError(error.HarnessLimit, oracle.commit(0, 1, 2, &short)); // Past the log.
    const misplaced = [_]Entry{fx.entry(5, 1, "a")};
    try testing.expectError(error.HarnessLimit, oracle.commit(0, 1, 1, &misplaced));
    var big: [index_max + 1]Entry = undefined;
    for (&big, 1..) |*entry, index| entry.* = fx.entry(index, 1, "");
    try testing.expectError(error.HarnessLimit, oracle.commit(0, 1, index_max + 1, &big));
    try testing.expectError(error.HarnessLimit, oracle.leader(steps_max + 2, 1));
    try testing.expectError(error.HarnessLimit, Rec.of(long[0]));

    var many: [entries_per_message + 1]Entry = undefined;
    for (&many, 1..) |*entry, index| entry.* = fx.entry(index, 1, "");
    const crowded = fx.append_request(2, 1, 0, 0, 0, &many);
    try testing.expectError(error.HarnessLimit, Slot.from(crowded));
    var wide: [entry_bytes + 1]u8 = @splat('w');
    const fat = [_]Entry{fx.entry(1, 1, &wide)};
    const stuffed = fx.append_request(2, 1, 0, 0, 0, &fat);
    try testing.expectError(error.HarnessLimit, Slot.from(stuffed));

    const nowhere = fx.vote_request(1, 0, 1);
    const beyond = fx.vote_request(1, 4, 1);
    const there = fx.vote_request(1, 3, 1);
    try testing.expectError(error.HarnessLimit, route(3, &nowhere));
    try testing.expectError(error.HarnessLimit, route(3, &beyond));
    try testing.expectEqual(@as(usize, 2), try route(3, &there));
}
