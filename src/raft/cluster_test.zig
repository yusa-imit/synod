//! Model-based seeded cluster test for `raft.Node` (plan 003, the Tiger Style section 5 library
//! form of simulation, ahead of Phase 3's `sim/`).
//!
//! A `Cluster` of 3 or 5 real nodes is driven by one seeded PRNG: tick a node, propose on a
//! leader, or deliver one message from a pool of in-flight messages (in seeded order, with
//! drops and duplicates). Every `send` effect goes back into the pool; time is logical ticks
//! only, so a seed replays bit for bit. After EVERY step `check_invariants()` runs on every
//! node and the simulator's `invariants.Checker`, which sees only observable behavior
//! (statuses, logs, apply effects), checks the five Raft safety properties: election safety,
//! leader append-only, log matching, leader completeness and state machine safety. Persist and
//! restore are out of scope (nodes never restart, so `Checker.restarted` is never called).
//!
//! A failing seed is reported in a `Report` (seed, node count, step) and by the error returned,
//! so the run is reproducible. The planted-bug tests prove the checker bites: a harness-level
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
const invariants = @import("../sim/invariants.zig");

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

/// A limit of the harness itself (not a safety violation): a message that does not fit a slot
/// or a destination that is no node.
const HarnessError = error{HarnessLimit};

const RunError = invariants.Violation || invariants.ObserveError || HarnessError ||
    node_module.InvariantError || node_module.InitError || node_module.StepError ||
    error{TestUnexpectedResult};

/// A fault the harness injects to prove the checker detects safety violations.
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

/// A message in flight, owned by value: entry bytes are copied out of the sender's borrowed
/// effects. `view` rebuilds the borrowed slices on the caller's stack, so slots can move freely.
const Slot = struct {
    message: Message,
    count: u8,
    entries: [entries_per_message]Entry,
    lens: [entries_per_message]u8,
    bytes: [entries_per_message * entry_bytes]u8,

    fn from(message: Message) HarnessError!Slot {
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
fn route(count: u32, message: *const Message) HarnessError!usize {
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
    checker: invariants.Checker,
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
        const checker_options: invariants.Checker.Options = .{
            .nodes_count = @intCast(count),
            .log_entries_max = index_max,
            // A term rises by one per candidate tick, one tick per step.
            .terms_max = steps_max + 2,
        };
        try cluster.checker.init(testing.allocator, checker_options);
        errdefer cluster.checker.deinit(testing.allocator);

        cluster.count = count;
        cluster.inited = 0;
        cluster.pool_len = 0;
        cluster.prng = std.Random.DefaultPrng.init(seed);
        cluster.mutation = mutation;
        cluster.stats = .{};
        cluster.proposed = 0;
        cluster.isolated = 0;
        cluster.isolated_until = 0;
        cluster.step_no = 0;
        errdefer cluster.deinit_rigs();

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
        cluster.deinit_rigs();
        cluster.checker.deinit(testing.allocator);
    }

    fn deinit_rigs(cluster: *Cluster) void {
        for (cluster.rigs[0..cluster.inited]) |*rig| rig.deinit(testing.allocator);
        cluster.inited = 0;
    }

    fn enqueue(cluster: *Cluster, message: Message) HarnessError!void {
        const slot = try Slot.from(message);
        if (cluster.pool_len < pool_max) {
            cluster.pool[cluster.pool_len] = slot;
            cluster.pool_len += 1;
        } else { // A full network loses a random message, like any other drop.
            cluster.pool[cluster.prng.random().uintLessThan(u32, pool_max)] = slot;
        }
        assert(cluster.pool_len > 0 and cluster.pool_len <= pool_max);
    }

    /// Everything that must hold after node `slot` took one step that produced `effects`:
    /// the checker sees every node's status and log first, then the apply effects (an apply
    /// is only legal up to a commit the checker has already seen).
    fn observe(cluster: *Cluster, slot: usize, effects: Effects) RunError!void {
        try fx.expect_effects_ordered(effects, node_config);
        var observed: [nodes_max]invariants.Observation = undefined;
        for (cluster.rigs[0..cluster.count], 0..) |*rig, i| {
            try rig.node.check_invariants();
            observed[i] = .{
                .node_index = @intCast(i),
                .status = rig.node.status(),
                .log = rig.node.entries(),
            };
        }
        try cluster.checker.observe(observed[0..cluster.count]);
        for (effects.items) |effect| switch (effect) {
            .send => |message| try cluster.enqueue(message),
            .apply => |batch| {
                for (batch) |*entry| {
                    const print = invariants.fingerprint(entry);
                    try cluster.checker.applied(@intCast(slot), entry.index, print);
                }
                cluster.stats.applied += @intCast(batch.len);
            },
            .truncate => cluster.stats.truncates += 1,
            else => {},
        };
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
        stats.leaders = cluster.checker.stats().leader_terms;
        stats.committed = @intCast(cluster.checker.stats().committed_max);
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
    });
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

test "harness: every HarnessLimit of the slots and the router is provoked" {
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
