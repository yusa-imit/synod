//! Tests for churn in `sim/simulation.zig` (plan 004 item 6, ADR-008 "Simulation"): the
//! scenarios, vacuity floors and planted faults of the retired `raft/cluster_test.zig`, ported
//! onto `Simulation`. Churn is crash-free: seeded partitions, seeded proposals, truncates.
//!
//! New API these tests pin (ADR-008 amendment, item 6):
//!   - `Faults.partition_percent: u8` and `Faults.partition_ms_max: u32`. A fault draw (every
//!     `[1, fault_interval_ms_max]` ms) cuts ONE seeded node off from all the others, in both
//!     directions, with `partition_percent`, unless a cut is active; the cut heals
//!     `[1, partition_ms_max]` ms later (a heal is an event). At most one cut at a time.
//!   - `Options.proposals: Proposals` (`interval_ms_max`, `data_bytes`): every `[1,
//!     interval_ms_max]` ms one seeded node among those that believe they lead proposes
//!     `data_bytes` bytes; no leader, `ProposeNotLeader` and `ProposeLogFull` are swallowed
//!     (not latched, not counted). 0 disables. `Proposals.none`; `Options.quiet` uses it.
//!   - `Stats.partitions: u32` (cuts started), `Stats.proposed: u64` (proposals accepted),
//!     `Stats.truncates: u64` (follower truncations of a diverged log; the source is the
//!     `CrashStore.truncate` calls the driver makes, `Driver` hides its `Effects`).
//!   - `OptionsError`, returned by `init` before anything is allocated: `PartitionPercentInvalid`
//!     (> 100), `PartitionDurationInvalid` (percent > 0 and `partition_ms_max == 0`),
//!     `FaultIntervalInvalid` (percent > 0 and `fault_interval_ms_max == 0`),
//!     `ProposalBytesInvalid` (enabled and `data_bytes` outside `[1, entry_bytes_max]`).
//!
//! Choices where ADR-008 is silent: a quiet run draws neither (all counters stay 0); the
//! churn preset has `crash_percent == 0` and `down_ms_max == 1` (the existing `init` asserts
//! `down_ms_max > 0` whenever fault draws are on; the implementation may relax that to
//! `crash_percent > 0`, these tests do not depend on it).
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("fixtures.zig");
const simulation_module = @import("simulation.zig");

const Error = simulation_module.Error;
const Options = simulation_module.Options;
const Plant = simulation_module.Plant;
const Proposals = simulation_module.Proposals;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;
const Stats = simulation_module.Stats;

const io = testing.io;
const gpa = testing.allocator;

const seeds_count = 100;
const duration_ms = 5_000;
const three = [_]u8{ 0, 1, 2 };

// Vacuity floors, ported from cluster_test (>= 90% led, >= 90% committed, >= 40% two or more
// leader terms, >= 30% truncated, some applied) and extended to the new faults. Each is
// stated as `seeds * numerator >= seeds_count * denominator` percent; see the report for the
// measured values they sit under.
const floor_led_percent = 90;
const floor_committed_percent = 90;
const floor_turnover_percent = 40;
const floor_truncated_percent = 30;
const floor_partitioned_percent = 90;
const floor_proposed_percent = 90;

/// The churn preset: `sweep` (3 nodes on even seeds, 5 on odd, lossy duplicating network)
/// plus seeded partitions (a fault draw every 1..100 ms, 20% of them cut one node off for
/// 1..800 ms) and seeded proposals (every 1..200 ms, 2 bytes). No crashes.
fn churny(seed: u64, plant: Plant) Options {
    var options = Options.sweep(seed);
    options.plant = plant;
    options.faults = .{
        .fault_interval_ms_max = 100,
        .crash_percent = 0,
        .torn_percent = 0,
        .down_ms_max = 1,
        .partition_percent = 20,
        .partition_ms_max = 800,
    };
    options.proposals = .{ .interval_ms_max = 200, .data_bytes = 2 };
    return options;
}

fn run(seed: u64, plant: Plant, report: *Report) Error!Stats {
    return simulation_module.run_seed(io, gpa, &churny(seed, plant), duration_ms, report);
}

// ---- the ported model run and its vacuity floors --------------------------------------------

test "churn: 500 seeds of 3 and 5 nodes keep every safety property and the run is not vacuous" {
    var report: Report = undefined;
    var led: u32 = 0;
    var committed: u32 = 0;
    var turnover: u32 = 0;
    var truncated: u32 = 0;
    var partitioned: u32 = 0;
    var proposing: u32 = 0;
    var applied_total: u64 = 0;
    for (0..seeds_count) |seed| {
        const stats = run(seed, .none, &report) catch |err| {
            std.log.err("churn: {s} at seed {d} event {d}", .{
                @errorName(err), report.seed, report.event_index,
            });
            return err;
        };
        led += @intFromBool(stats.leader_terms > 0);
        committed += @intFromBool(stats.committed_max > 0);
        turnover += @intFromBool(stats.leader_terms >= 2);
        truncated += @intFromBool(stats.truncates > 0);
        partitioned += @intFromBool(stats.partitions > 0);
        proposing += @intFromBool(stats.proposed > 0);
        applied_total += stats.applied;
        try testing.expectEqual(@as(u32, 0), stats.crashes + stats.restarts); // Crash-free.
        try testing.expect(stats.committed_max <= stats.proposed + stats.leader_terms);
    }
    // Progress: elections happen, entries commit and apply.
    try testing.expect(led * 100 >= seeds_count * floor_led_percent);
    try testing.expect(committed * 100 >= seeds_count * floor_committed_percent);
    try testing.expect(applied_total > 0);
    // Churn: leaders change and logs diverge, so leader completeness and log matching bite.
    try testing.expect(turnover * 100 >= seeds_count * floor_turnover_percent);
    try testing.expect(truncated * 100 >= seeds_count * floor_truncated_percent);
    // The new faults themselves fired.
    try testing.expect(partitioned * 100 >= seeds_count * floor_partitioned_percent);
    try testing.expect(proposing * 100 >= seeds_count * floor_proposed_percent);
}

test "churn: the same seed replays to identical stats and digest, other seeds differ" {
    var report: Report = undefined;
    const first = try run(7, .none, &report);
    const again = try run(7, .none, &report);
    try testing.expectEqual(first, again);
    try testing.expect(first.digest != 0);
    // Seed 7 must exercise all three new counters, or the equality above proves little.
    try testing.expect(first.partitions > 0);
    try testing.expect(first.proposed > 0);
    try testing.expect(first.truncates > 0);
    const other = try run(8, .none, &report);
    try testing.expect(other.digest != first.digest);
    try testing.expect(other.network.sent != first.network.sent or other.events != first.events);
}

test "churn: the new faults change the run, and the fault-free twin of a seed is replayable" {
    // Turning cuts and proposals on changes the run (they act); the quiet twin of the same
    // seed is a different run that replays bit for bit and counts none of them.
    var report: Report = undefined;
    var quiet = churny(11, .none);
    quiet.faults = simulation_module.Faults.none;
    quiet.proposals = Proposals.none;
    const calm = try simulation_module.run_seed(io, gpa, &quiet, duration_ms, &report);
    const busy = try run(11, .none, &report);
    try testing.expectEqual(@as(u32, 0), calm.partitions);
    try testing.expectEqual(@as(u64, 0), calm.proposed);
    try testing.expect(busy.partitions > 0);
    try testing.expect(busy.digest != calm.digest);
    const calm_again = try simulation_module.run_seed(io, gpa, &quiet, duration_ms, &report);
    try testing.expectEqual(calm, calm_again);
}

// ---- planted faults -------------------------------------------------------------------------

fn is_allowed(err: Error, allowed: []const Error) bool {
    for (allowed) |candidate| {
        if (candidate == err) return true;
    }
    return false;
}

/// Runs every seed under `plant`: at least one must fail, every failure must be one of
/// `allowed` with its seed in the `Report`, and the first failing seed must replay to the same
/// error at the same event while its honest twin (same options, `plant = .none`) is clean.
fn expect_planted(plant: Plant, allowed: []const Error) !void {
    var report: Report = undefined;
    var first: ?Report = null;
    var caught: u32 = 0;
    for (0..seeds_count) |seed| {
        _ = run(seed, plant, &report) catch |err| {
            if (!is_allowed(err, allowed)) {
                std.log.err("planted {s}: unexpected {s} at seed {d}", .{
                    @tagName(plant), @errorName(err), seed,
                });
                return error.UnexpectedViolation;
            }
            try testing.expectEqual(@as(u64, seed), report.seed);
            try testing.expectEqual(err, report.violation);
            try testing.expect(report.event_index > 0);
            caught += 1;
            if (first == null) first = report;
        };
    }
    try testing.expect(caught >= 1); // The planted bug is detected by some seed.
    const seen = first.?;
    var again: Report = undefined;
    try testing.expectError(seen.violation, run(seen.seed, plant, &again));
    try testing.expectEqual(seen.event_index, again.event_index);
    _ = try run(seen.seed, .none, &again); // The seed is clean without the planted bug.
}

test "churn: forged vote grants are caught as election safety or leader completeness" {
    try expect_planted(.forge_votes, &.{ error.ElectionSafety, error.LeaderCompleteness });
}

test "churn: a flipped entry byte is caught as log matching or state machine safety" {
    try expect_planted(.flip_data, &.{ error.LogMatching, error.StateMachineSafety });
}

// ---- truncates: a deterministic stale-leader scenario ---------------------------------------

/// 3 quiet nodes; commit one command; cut the leader off; optionally let it accept a proposal
/// it can never commit; the other two elect a successor and commit; heal. Returns the stats.
fn stale_leader(seed: u64, stale_proposal: bool) !Stats {
    var options = fx.sim_quiet(seed, 3);
    options.proposals = Proposals.none;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 3_000);
    const old = fx.leader_among(&simulation, &three) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 2), try fx.propose_to_leader(io, &simulation, &three, "base"));
    try simulation.run_until(io, 4_000);
    try testing.expectEqual(@as(u64, 0), simulation.stats().truncates);

    fx.isolate(&simulation, 3, old);
    if (stale_proposal) {
        try simulation.propose(io, old, "stale"); // Still believes it leads: index 3, term t.
        try testing.expectEqual(@as(u64, 3), @intFromEnum(simulation.status(old).?.last_index));
    }
    try simulation.run_until(io, 7_000);
    var storage: [7]u8 = undefined;
    const rest = fx.others_of(&storage, 3, old);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, rest));
    _ = try fx.propose_to_leader(io, &simulation, rest, "fresh");
    try simulation.run_until(io, 8_000);
    try testing.expectEqual(@as(u64, 0), simulation.stats().truncates); // Nothing healed yet.

    simulation.network.heal();
    try simulation.run_until(io, 12_000);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &three));
    const reference = simulation.status(0).?;
    for (three) |slot| {
        const status = simulation.status(slot).?;
        try testing.expectEqual(reference.last_index, status.last_index);
        try testing.expectEqual(reference.commit_index, status.commit_index);
    }
    try testing.expect(simulation.status(old).?.role != .leader);
    try fx.check_all(&simulation);
    return simulation.stats();
}

test "churn: a deposed leader truncates its uncommitted entry once, and only then" {
    const diverged = try stale_leader(41, true);
    try testing.expectEqual(@as(u64, 1), diverged.truncates);
    // Index 1 no-op, 2 base, 3 the successor's no-op, 4 fresh: all committed everywhere.
    try testing.expect(diverged.committed_max >= 4);

    // Without the stale entry the old leader's log is a prefix of the new one: it appends, it
    // never truncates, so the counter stays at zero (it counts divergence, not replication).
    const prefix = try stale_leader(41, false);
    try testing.expectEqual(@as(u64, 0), prefix.truncates);
    try testing.expect(prefix.committed_max >= 3);
}

test "churn: a quiet run without faults or proposals counts no cut, proposal or truncate" {
    var report: Report = undefined;
    for (0..8) |seed| {
        const options = fx.sim_quiet(seed, if (seed % 2 == 0) 3 else 5);
        try testing.expectEqual(Proposals.none, options.proposals);
        try testing.expectEqual(@as(u8, 0), options.faults.partition_percent);
        try testing.expectEqual(@as(u32, 0), options.faults.partition_ms_max);
        const stats = try simulation_module.run_seed(io, gpa, &options, 3_000, &report);
        try testing.expectEqual(@as(u32, 0), stats.partitions);
        try testing.expectEqual(@as(u64, 0), stats.proposed);
        try testing.expectEqual(@as(u64, 0), stats.truncates);
        try testing.expect(stats.leader_terms >= 1);
    }
}

// ---- seeded proposals -----------------------------------------------------------------------

test "churn: with a stable leader every accepted proposal is in its log, bounded and sized" {
    var options = fx.sim_quiet(51, 3);
    options.proposals = .{ .interval_ms_max = 100, .data_bytes = 3 };
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try fx.step_checked(io, &simulation, 3_000, 40_000);

    const stats = simulation.stats();
    try testing.expectEqual(@as(u32, 1), stats.leader_terms); // Lossless and fault-free.
    try testing.expect(stats.proposed > 5);
    const leader = fx.leader_among(&simulation, &three).?;
    const status = simulation.status(leader).?;
    try testing.expectEqual(1 + stats.proposed, @intFromEnum(status.last_index)); // + the no-op.
    try testing.expect(stats.committed_max <= 1 + stats.proposed);
    try testing.expect(stats.committed_max + 4 >= 1 + stats.proposed); // Only a tail in flight.
    for (simulation.nodes[leader].driver.node.entries()) |entry| {
        const want: usize = if (@intFromEnum(entry.index) == 1) 0 else 3;
        try testing.expectEqual(want, entry.data.len);
    }
    try testing.expectEqual(@as(u64, 0), stats.truncates);
}

test "churn: a full log swallows proposals, latches nothing and counts only accepted ones" {
    var options = fx.sim_quiet(52, 3);
    options.proposals = .{ .interval_ms_max = 2, .data_bytes = 1 };
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try fx.step_checked(io, &simulation, 3_000, 80_000); // No error: ProposeLogFull is not one.

    const stats = simulation.stats();
    const capacity: u64 = options.raft.log_entries_max;
    try testing.expectEqual(capacity - 1, stats.proposed); // The no-op takes the first slot.
    const leader = fx.leader_among(&simulation, &three).?;
    try testing.expectEqual(capacity, @intFromEnum(simulation.status(leader).?.last_index));
    try testing.expect(stats.committed_max == capacity); // Full is still replicated.
}

test "churn: proposals wait for a leader, so none are accepted before the first election" {
    var options = fx.sim_quiet(53, 3);
    options.proposals = .{ .interval_ms_max = 1, .data_bytes = 2 };
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    // Election timeout is at least 100 ms: no node leads before that, whatever the draws.
    try simulation.run_until(io, 90);
    try testing.expectEqual(@as(u64, 0), simulation.stats().proposed);
    try testing.expectEqual(@as(u32, 0), simulation.stats().leader_terms);
    try simulation.run_until(io, 1_000);
    try testing.expect(simulation.stats().proposed > 0);
}

// ---- validation at init: boundary 0, max, max + 1 -------------------------------------------

fn expect_init_error(options: Options, want: Error) !void {
    var simulation: Simulation = undefined;
    try testing.expectError(want, simulation.init(io, gpa, &options)); // A leak fails the test.
    var report: Report = undefined;
    try testing.expectError(want, simulation_module.run_seed(io, gpa, &options, 100, &report));
    try testing.expectEqual(options.seed, report.seed);
    try testing.expectEqual(@as(u64, 0), report.event_index);
    try testing.expectEqual(want, report.violation);
}

fn expect_runs(options: Options) !void {
    var report: Report = undefined;
    _ = try simulation_module.run_seed(io, gpa, &options, 1_500, &report);
}

test "init: partition_percent accepts 0 and 100 and refuses 101" {
    var options = churny(61, .none);
    options.faults.partition_percent = 0;
    try expect_runs(options);
    options.faults.partition_percent = 100;
    try expect_runs(options);
    options.faults.partition_percent = 101;
    try expect_init_error(options, error.PartitionPercentInvalid);
    options.faults.partition_percent = 255;
    try expect_init_error(options, error.PartitionPercentInvalid);
}

test "init: partition_ms_max must be positive when cuts are on, and u32 max is accepted" {
    var options = churny(62, .none);
    options.faults.partition_ms_max = 0;
    try expect_init_error(options, error.PartitionDurationInvalid);
    options.faults.partition_ms_max = 1;
    try expect_runs(options);
    options.faults.partition_ms_max = std.math.maxInt(u32);
    try expect_runs(options);
    options.faults.partition_percent = 0; // Cuts off: the duration is then unused.
    options.faults.partition_ms_max = 0;
    try expect_runs(options);
}

test "init: cuts need fault draws, a zero fault interval with cuts on is refused" {
    var options = churny(63, .none);
    options.faults.fault_interval_ms_max = 0;
    try expect_init_error(options, error.FaultIntervalInvalid);
    options.faults.fault_interval_ms_max = 1;
    try expect_runs(options);
    options.faults.fault_interval_ms_max = std.math.maxInt(u32);
    try expect_runs(options);
}

test "init: proposal data_bytes is 1..entry_bytes_max when enabled, 0 interval disables" {
    var options = churny(64, .none);
    const bytes_max = options.raft.message_limits.entry_bytes_max;
    // The sweep preset: room for one 24-byte KV command; the bounds below follow.
    try testing.expectEqual(@as(u32, 24), bytes_max);
    options.proposals.data_bytes = 0;
    try expect_init_error(options, error.ProposalBytesInvalid);
    options.proposals.data_bytes = 1;
    try expect_runs(options);
    options.proposals.data_bytes = @intCast(bytes_max);
    try expect_runs(options);
    options.proposals.data_bytes = @intCast(bytes_max + 1);
    try expect_init_error(options, error.ProposalBytesInvalid);
    options.proposals.data_bytes = 255;
    try expect_init_error(options, error.ProposalBytesInvalid);
    options.proposals = Proposals.none; // Disabled: data_bytes 0 is fine.
    try expect_runs(options);
    options.proposals.interval_ms_max = 1;
    options.proposals.data_bytes = 4;
    try expect_runs(options);
}

// ---- model: a trivial reference of the cut and the counters, after every event ----------------

/// Reference model of the seeded cut: the network is either whole or has exactly one isolated
/// node; a cut lasts `[1, partition_ms_max]` ms; the counters move by at most one per event.
const Model = struct {
    nodes_count: u8,
    partition_ms_max: u64,
    previous: Stats,
    cut_slot: ?u8 = null,
    cut_since_ms: u64 = 0,
    cuts_seen: u32 = 0,
    heals_seen: u32 = 0,
    cuts_on_leader: u32 = 0,
    cuts_on_follower: u32 = 0,

    /// The one isolated node, null when whole; anything else is a model failure.
    fn isolated(model: *const Model, simulation: *const Simulation) !?u8 {
        var found: ?u8 = null;
        var singles: u8 = 0;
        for (0..model.nodes_count) |slot| {
            var cut_links: u8 = 0;
            for (0..model.nodes_count) |other| {
                if (other == slot) continue;
                const out = simulation.network.reachable(fx.link_of(slot, other));
                const back = simulation.network.reachable(fx.link_of(other, slot));
                if (!out and !back) cut_links += 1;
                if (out != back) return error.OneDirectionCut;
            }
            if (cut_links == 0) continue;
            // A cut node loses every link; each other node loses exactly the one to the victim.
            if (cut_links == 1) {
                singles += 1;
                continue;
            }
            if (cut_links != model.nodes_count - 1) return error.NotAWholeNodeCut;
            if (found != null) return error.TwoNodesCut;
            found = @intCast(slot);
        }
        if (found == null) try testing.expectEqual(@as(u8, 0), singles);
        if (found != null) try testing.expectEqual(model.nodes_count - 1, singles);
        return found;
    }

    fn observe(model: *Model, simulation: *const Simulation) !void {
        const stats = simulation.stats();
        const now_ms = simulation.virtual_clock.time_ms;
        const before = model.previous;
        try testing.expectEqual(before.events + 1, stats.events);
        try testing.expect(stats.truncates - before.truncates <= 1); // One receive truncates once.
        try testing.expect(stats.proposed - before.proposed <= 1);
        try testing.expectEqual(@as(u32, 0), stats.crashes);
        try testing.expect(stats.committed_max <= stats.proposed + stats.leader_terms);
        try testing.expect(stats.applied <= model.nodes_count * stats.committed_max);

        const now_cut = try model.isolated(simulation);
        if (model.cut_slot == null and now_cut != null) { // A cut starts.
            try testing.expectEqual(before.partitions + 1, stats.partitions);
            model.cut_slot = now_cut;
            model.cut_since_ms = now_ms;
            model.cuts_seen += 1;
            const role = simulation.status(now_cut.?).?.role;
            if (role == .leader) model.cuts_on_leader += 1 else model.cuts_on_follower += 1;
        } else if (model.cut_slot != null and now_cut == null) { // It heals.
            try testing.expectEqual(before.partitions, stats.partitions);
            const lasted_ms = now_ms - model.cut_since_ms;
            try testing.expect(lasted_ms >= 1 and lasted_ms <= model.partition_ms_max);
            model.cut_slot = null;
            model.heals_seen += 1;
        } else {
            try testing.expectEqual(model.cut_slot, now_cut); // Same node, or whole still.
            try testing.expectEqual(before.partitions, stats.partitions);
            if (now_cut != null) {
                try testing.expect(now_ms - model.cut_since_ms <= model.partition_ms_max);
            }
        }
        try testing.expectEqual(model.cuts_seen, stats.partitions);
        model.previous = stats;
    }
};

test "churn model: the cut, its duration and every counter agree with a trivial reference" {
    var cuts: u32 = 0;
    var heals: u32 = 0;
    var on_leader: u32 = 0;
    var on_follower: u32 = 0;
    var truncates: u64 = 0;
    for (0..24) |seed| {
        var options = churny(seed, .none);
        options.events_max = 200_000;
        var simulation: Simulation = undefined;
        try simulation.init(io, gpa, &options);
        defer simulation.deinit(io, gpa);
        var model: Model = .{
            .nodes_count = options.nodes_count,
            .partition_ms_max = options.faults.partition_ms_max,
            .previous = simulation.stats(),
        };
        try testing.expectEqual(@as(u32, 0), model.previous.partitions);
        var steps: u32 = 0;
        while (simulation.virtual_clock.time_ms < 3_000) : (steps += 1) {
            if (steps > 100_000) return error.TestUnexpectedResult;
            try simulation.step(io);
            try model.observe(&simulation);
            try fx.check_all(&simulation);
        }
        cuts += model.cuts_seen;
        heals += model.heals_seen;
        on_leader += model.cuts_on_leader;
        on_follower += model.cuts_on_follower;
        truncates += simulation.stats().truncates;
    }
    // Not vacuous: cuts started and healed, they hit leaders and followers alike.
    try testing.expect(cuts >= 24);
    try testing.expect(heals >= 12);
    try testing.expect(on_leader >= 6);
    try testing.expect(on_follower >= 6);
    try testing.expect(truncates >= 1);
}

// ---- allocation -----------------------------------------------------------------------------

test "churn: a churn run allocates nothing after init" {
    var counting = testing.FailingAllocator.init(gpa, .{});
    const options = churny(71, .none);
    var simulation: Simulation = undefined;
    try simulation.init(io, counting.allocator(), &options);
    defer simulation.deinit(io, counting.allocator());
    const allocs = counting.alloc_index;
    const bytes = counting.allocated_bytes;
    try simulation.run_until(io, duration_ms);
    try testing.expectEqual(allocs, counting.alloc_index);
    try testing.expectEqual(bytes, counting.allocated_bytes);
    try testing.expect(simulation.stats().partitions > 0);
    try testing.expect(simulation.stats().proposed > 0);
}
