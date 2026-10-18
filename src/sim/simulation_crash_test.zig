//! Tests for crash and restart in `sim/simulation.zig` (plan 004 item 5, ADR-008
//! "Simulation" and "Crash store"): scripted `crash`/`restart`, `status` null while down,
//! deliveries to a down node counted `dropped_down`, `Checker.restarted`, a fresh `Driver.init`
//! over the same store, seeded crash draws, the planted `lose_synced_hard_state` store that
//! must break `ElectionSafety`, and the honest store that must survive crash-heavy seeds.
//!
//! Choices where ADR-008 is silent (the implementation may argue, not drift silently):
//!   - `crash` and `restart` are scripted calls like `propose`: not events, `stats().events`
//!     does not move. `crash` of a down node and `restart` of an up node are caller bugs
//!     (asserted, untested). `crash` is clean: it keeps every unsynced op (`keep_count =
//!     unsynced_count()`), which between events is none, since a step ends with a sync.
//!   - Item 5 adds `Options.faults` (`Faults`: `fault_interval_ms_max`, `crash_percent`,
//!     `torn_percent`, `down_ms_max`; the partition fields come with item 6), `Plant.
//!     lose_synced_hard_state` and `Stats.{crashes, torn_crashes, restarts}`. `Options.quiet`
//!     has `Faults.none`. A fault draw happens every `[1, fault_interval_ms_max]` ms (0 = never
//!     and then no fault event exists); with `crash_percent` it crashes a seeded up node,
//!     torn with `torn_percent`; the node restarts `[1, down_ms_max]` ms later. Crashes and
//!     restarts are counted in `Stats`; a torn crash also counts in `crashes`.
//!   - Stat identity: nodes down now == `crashes - restarts`.
//!   - The crash draws come from the `faults` stream and the node streams; the plant maps to
//!     `CrashStore.Fault` only, so a plant and its honest twin share one crash schedule.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("fixtures.zig");
const invariants = @import("invariants.zig");
const simulation_module = @import("simulation.zig");

const Error = simulation_module.Error;
const Faults = simulation_module.Faults;
const Options = simulation_module.Options;
const Plant = simulation_module.Plant;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;

const io = testing.io;
const gpa = testing.allocator;

const three = [_]u8{ 0, 1, 2 };

/// A 3-node quiet cluster that elected a leader and committed one command (index 2) on all
/// nodes. Returns the leader's slot.
fn settle(simulation: *Simulation) !u8 {
    try simulation.run_until(io, 3_000);
    const leader = fx.leader_among(simulation, &three) orelse return error.TestUnexpectedResult;
    const index = try fx.propose_to_leader(io, simulation, &three, "cmd");
    try testing.expectEqual(@as(u64, 2), index);
    try simulation.run_until(io, 4_000);
    for (three) |slot| {
        const status = simulation.status(slot).?;
        try testing.expectEqual(@as(u64, 2), @intFromEnum(status.commit_index));
        try testing.expectEqual(@as(u64, 2), @intFromEnum(status.applied_index));
    }
    return leader;
}

fn follower_of(leader: u8) u8 {
    return if (leader == 0) 1 else 0;
}

fn down_count(simulation: *const Simulation) u32 {
    var down: u32 = 0;
    for (0..simulation.options.nodes_count) |slot| {
        if (simulation.status(@intCast(slot)) == null) down += 1;
    }
    return down;
}

// ---- scripted crash and restart -------------------------------------------------------------

test "simulation: a scripted crash takes a follower down and drops what is sent to it" {
    const options = fx.sim_quiet(21, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    const leader = try settle(&simulation);
    const victim = follower_of(leader);
    const survivor: u8 = 3 - leader - victim; // The slots are 0, 1 and 2.
    const before = simulation.stats();
    try testing.expectEqual(@as(u64, 0), before.network.dropped_down);

    simulation.crash(io, victim);
    try testing.expect(simulation.status(victim) == null);
    try testing.expect(simulation.status(leader) != null);
    try testing.expect(simulation.status(survivor) != null);
    const crashed = simulation.stats();
    try testing.expectEqual(@as(u32, 1), crashed.crashes);
    try testing.expectEqual(@as(u32, 0), crashed.torn_crashes);
    try testing.expectEqual(@as(u32, 0), crashed.restarts);
    try testing.expectEqual(before.events, crashed.events); // Scripted: not an event.

    // Two of three are enough: a proposal still commits while the victim is down.
    const index = try fx.propose_to_leader(io, &simulation, &three, "more");
    try testing.expectEqual(@as(u64, 3), index);
    try simulation.run_until(io, 6_000);
    for ([_]u8{ leader, survivor }) |slot| {
        try testing.expectEqual(@as(u64, 3), @intFromEnum(simulation.status(slot).?.commit_index));
    }
    try testing.expect(simulation.status(victim) == null);
    const later = simulation.stats();
    try testing.expect(later.network.dropped_down > 0); // Heartbeats to the victim.
    try simulation.network.check_invariants(); // Conservation holds with the new counter.
    try fx.check_all(&simulation);
}

test "simulation: restart rebuilds a follower from its store and it catches up" {
    const options = fx.sim_quiet(22, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    const leader = try settle(&simulation);
    const victim = follower_of(leader);
    const applied_before = simulation.stats().applied;
    const known = simulation.status(victim).?;

    simulation.crash(io, victim);
    try simulation.restart(io, victim);
    const back = simulation.status(victim) orelse return error.RestartDidNotBringItUp;
    try testing.expect(back.role == .follower);
    try testing.expectEqual(known.term, back.term); // Hard state came from the store.
    try testing.expectEqual(known.vote, back.vote);
    try testing.expectEqual(known.last_index, back.last_index); // So did the whole log.
    try testing.expect(back.applied_index.order(back.commit_index) != .gt);
    const restarted = simulation.stats();
    try testing.expectEqual(@as(u32, 1), restarted.crashes);
    try testing.expectEqual(@as(u32, 1), restarted.restarts);

    // The state machine is volatile: the node applies its log again, and the Checker was told
    // (`restarted`), otherwise the repeat apply would be StateMachineSafety.
    try simulation.run_until(io, 6_000);
    const caught = simulation.status(victim).?;
    try testing.expectEqual(@as(u64, 2), @intFromEnum(caught.commit_index));
    try testing.expectEqual(@as(u64, 2), @intFromEnum(caught.applied_index));
    try testing.expect(simulation.stats().applied >= applied_before + 2);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &three));
    try fx.check_all(&simulation);
}

test "simulation: after the leader crashes a new one leads and the old one rejoins as follower" {
    const options = fx.sim_quiet(23, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    const old = try settle(&simulation);
    const old_term = @intFromEnum(simulation.status(old).?.term);

    simulation.crash(io, old);
    try simulation.run_until(io, 8_000);
    const successor = fx.leader_among(&simulation, &three) orelse return error.NoNewLeader;
    try testing.expect(successor != old);
    try testing.expect(@intFromEnum(simulation.status(successor).?.term) > old_term);
    const index = try fx.propose_to_leader(io, &simulation, &three, "after");
    try simulation.run_until(io, 9_000);
    try testing.expect(simulation.status(old) == null); // Down all along.

    try simulation.restart(io, old);
    try simulation.run_until(io, 13_000);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &three));
    try testing.expect(simulation.status(old).?.role != .leader);
    for (three) |slot| {
        const status = simulation.status(slot).?;
        try testing.expectEqual(index, @intFromEnum(status.commit_index)); // Nothing lost.
        try testing.expectEqual(index, @intFromEnum(status.applied_index));
    }
    try testing.expect(simulation.stats().leader_terms >= 2);
    try fx.check_all(&simulation);
}

test "simulation: a whole-cluster crash loses nothing that was committed" {
    const options = fx.sim_quiet(24, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    _ = try settle(&simulation);

    for (three) |slot| simulation.crash(io, slot);
    for (three) |slot| try testing.expect(simulation.status(slot) == null);
    try testing.expectEqual(@as(u32, 3), simulation.stats().crashes);
    try simulation.run_until(io, 5_000); // Nobody is up: time passes, nothing breaks.
    try testing.expectEqual(@as(u64, 5_000), simulation.virtual_clock.time_ms);
    try testing.expect(simulation.stats().network.dropped_down > 0 or
        simulation.network.in_flight() == 0);

    for (three) |slot| try simulation.restart(io, slot);
    try simulation.run_until(io, 10_000);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &three));
    for (three) |slot| {
        const status = simulation.status(slot).?;
        try testing.expect(@intFromEnum(status.commit_index) >= 2);
        try testing.expect(@intFromEnum(status.last_index) >= 2);
        try testing.expectEqual(status.commit_index, status.applied_index);
    }
    try testing.expectEqual(@as(u32, 3), simulation.stats().restarts);
    try fx.check_all(&simulation);
}

test "simulation: forty crash and restart cycles allocate nothing and exhaust no buffer" {
    const options = fx.sim_quiet(25, 3);
    var counting = testing.FailingAllocator.init(gpa, .{});
    var simulation: Simulation = undefined;
    try simulation.init(io, counting.allocator(), &options);
    defer simulation.deinit(io, counting.allocator());
    _ = try settle(&simulation);
    const allocs = counting.alloc_index;
    const bytes = counting.allocated_bytes;

    var at_ms: u64 = 4_000;
    for (0..40) |cycle| {
        const slot: u8 = @intCast(cycle % 3);
        simulation.crash(io, slot);
        at_ms += 200;
        try simulation.run_until(io, at_ms);
        try simulation.restart(io, slot); // Reuses the node's fixed buffer every time.
        at_ms += 300;
        try simulation.run_until(io, at_ms);
    }
    try testing.expectEqual(allocs, counting.alloc_index);
    try testing.expectEqual(bytes, counting.allocated_bytes);
    try testing.expectEqual(@as(u32, 40), simulation.stats().restarts);
    try fx.check_all(&simulation);
}

// ---- seeded crash draws ---------------------------------------------------------------------

/// Crash-heavy options: a fault draw every 1..600 ms, half of them crash a node (half of those
/// torn), a crashed node is down 1..400 ms. 3 nodes (even seed) or 5 (odd).
fn crashy(seed: u64, plant: Plant) Options {
    var options = fx.sim_quiet(seed, if (seed % 2 == 0) 3 else 5);
    options.plant = plant;
    options.faults = .{
        .fault_interval_ms_max = 600,
        .crash_percent = 50,
        .torn_percent = 50,
        .down_ms_max = 400,
        .partition_percent = 0,
        .partition_ms_max = 0,
    };
    return options;
}

test "simulation: the quiet preset has no faults and a quiet run never crashes" {
    for (2..8) |count| {
        const options = Options.quiet(count, @intCast(count));
        try testing.expectEqual(Faults.none, options.faults);
        try testing.expectEqual(@as(u32, 0), options.faults.fault_interval_ms_max);
    }
    var report: Report = undefined;
    const stats = try simulation_module.run_seed(io, gpa, &fx.sim_quiet(26, 3), 3_000, &report);
    try testing.expectEqual(@as(u32, 0), stats.crashes + stats.torn_crashes + stats.restarts);
}

test "simulation: seeded crashes take nodes down and bring them back, status null while down" {
    const options = crashy(31, .none);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    var saw_down = false;
    var saw_back = false;
    var steps: u32 = 0;
    while (simulation.virtual_clock.time_ms < 8_000) : (steps += 1) {
        if (steps > 40_000) return error.TestUnexpectedResult;
        try simulation.step(io);
        const stats = simulation.stats();
        const down = down_count(&simulation);
        try testing.expectEqual(stats.crashes - stats.restarts, down);
        try testing.expect(stats.torn_crashes <= stats.crashes);
        saw_down = saw_down or down > 0;
        saw_back = saw_back or (saw_down and stats.restarts > 0);
        try fx.check_all(&simulation);
    }
    try testing.expect(saw_down);
    try testing.expect(saw_back);
}

test "simulation: a crash-heavy seed replays to identical stats and seeds differ" {
    var report: Report = undefined;
    const first = try simulation_module.run_seed(io, gpa, &crashy(7, .none), 6_000, &report);
    const again = try simulation_module.run_seed(io, gpa, &crashy(7, .none), 6_000, &report);
    try testing.expectEqual(first, again);
    try testing.expect(first.crashes > 0);
    const other = try simulation_module.run_seed(io, gpa, &crashy(8, .none), 6_000, &report);
    try testing.expect(other.digest != first.digest);
}

// ---- the acceptance tests of plan 004 item 5 ------------------------------------------------

const duration_ms = 10_000;

fn is_violation(err: Error) bool {
    return switch (err) {
        error.ElectionSafety,
        error.LeaderAppendOnly,
        error.LogMatching,
        error.LeaderCompleteness,
        error.StateMachineSafety,
        => true,
        else => false,
    };
}

test "simulation: a store that loses a synced hard state breaks ElectionSafety, seed in Report" {
    // A node that forgets its durable vote after a crash can vote twice in one term, so two
    // candidates of that term both win. With `crashy` the first bite lands within the first few
    // dozen seeds; the loop allows 300. If none bites, raise `crash_percent` or lower
    // `fault_interval_ms_max` in `crashy`, never relax the assertions.
    var report: Report = undefined;
    var first: ?u64 = null;
    var election_safety: u32 = 0;
    for (0..300) |seed| {
        const options = crashy(seed, .lose_synced_hard_state);
        _ = simulation_module.run_seed(io, gpa, &options, duration_ms, &report) catch |err| {
            try testing.expect(is_violation(err)); // Not a limit, not a node error.
            try testing.expectEqual(@as(u64, seed), report.seed);
            try testing.expectEqual(err, report.violation);
            try testing.expect(report.event_index > 0);
            if (err == error.ElectionSafety) {
                election_safety += 1;
                if (first == null) first = seed;
            }
        };
    }
    try testing.expect(election_safety >= 1);

    // The failing seed replays: same violation at the same event, and the property check names
    // it. Its honest twin (same crash schedule, honest store) is clean.
    const seed = first.?;
    var again: Report = undefined;
    const options = crashy(seed, .lose_synced_hard_state);
    try testing.expectError(
        error.ElectionSafety,
        simulation_module.run_seed(io, gpa, &options, duration_ms, &again),
    );
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try testing.expectError(error.ElectionSafety, simulation.run_until(io, duration_ms));
    try testing.expectEqual(seed, simulation.report().seed);
    try testing.expectEqual(again.event_index, simulation.report().event_index);
    try testing.expectError(error.ElectionSafety, simulation.check(.election_safety));

    const honest = crashy(seed, .none);
    _ = try simulation_module.run_seed(io, gpa, &honest, duration_ms, &again);
}

test "simulation: the honest store passes 200 crash-heavy seeds and the run is not vacuous" {
    var report: Report = undefined;
    var crashes: u64 = 0;
    var torn: u64 = 0;
    var lossy: u64 = 0;
    var restarts: u64 = 0;
    var leader_terms: u64 = 0;
    var seeds_committing: u64 = 0;
    for (0..200) |seed| {
        const options = crashy(seed, .none);
        const stats = simulation_module.run_seed(io, gpa, &options, 8_000, &report) catch |err| {
            std.log.err("honest crash run: {s} at seed {d}", .{ @errorName(err), report.seed });
            return error.HonestRunFailed;
        };
        try testing.expect(stats.torn_crashes <= stats.crashes);
        try testing.expect(stats.restarts <= stats.crashes);
        crashes += stats.crashes;
        torn += stats.torn_crashes;
        lossy += stats.lossy_crashes;
        try testing.expect(stats.lossy_crashes <= stats.crashes);
        restarts += stats.restarts;
        leader_terms += stats.leader_terms;
        if (stats.committed_max > 0) seeds_committing += 1;
    }
    // Vacuity floors (measured over seeds 0..200: 1584 crashes, 280 torn, 1548 restarts, 523
    // leader terms): crashes happened, torn ones too (they are the ones that lose unsynced
    // writes), nodes came back, and the cluster still made progress under them.
    try testing.expect(crashes >= 1_000);
    try testing.expect(torn >= 200);
    try testing.expect(lossy >= 30); // Measured 71: crashes that really dropped a write.
    try testing.expect(restarts * 4 >= crashes * 3);
    try testing.expect(leader_terms >= 200);
    try testing.expect(seeds_committing >= 150);
}
