//! Red tests for `sim/simulation.zig` (plan 004 item 4, ADR-008 "Simulation"), written from the
//! contract: scenarios, boundaries, determinism, planted faults and typed errors. The seeded
//! model run and the allocation tests live in `simulation_model_test.zig`; the `init_bytes_max`
//! sizing tests in `driver_init_bytes_test.zig`.
//!
//! Choices where ADR-008 is silent (the implementation may argue, not drift silently):
//!   - `Simulation.init(simulation, io, gpa, options)` follows the ADR argument order.
//!   - `Simulation.propose(io, node_index, data)` is a scripted proposal (amends the ADR; the
//!     workload of item 10 will make proposals itself). It is not an event.
//!   - `Report.event_index` is the number of events started, the failing one included, so after
//!     a violation it equals `stats().events`; `EventsExhausted` also yields a `Report`.
//!   - `Error` also carries `raft.ProposeError` and `Network.InvariantError`.
//!   - Item 4's `Options` has no faults, workload or crash fields; `Options.quiet` gives 10 ms
//!     ticks, 100..200 ms election timeouts, 1..10 ms delays and entries of at most 8 bytes.
//!   - A clean 5-node network elects within the first seconds; every scenario here allows 5 s.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const invariants = @import("invariants.zig");
const fx = @import("fixtures.zig");
const simulation_module = @import("simulation.zig");

const Error = simulation_module.Error;
const Options = simulation_module.Options;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;

const io = testing.io;
const gpa = testing.allocator;

// ---- PRD section 4.5 ------------------------------------------------------------------------

/// The PRD scenario for `seed`: 5 nodes, `{0,1}` cut from `{2,3,4}`, 10 s of virtual time.
fn expect_partition_scenario(seed: u64) !void {
    const options = fx.sim_quiet(seed, 5);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);

    simulation.network.set_partition(&fx.minority, &fx.majority);
    try simulation.run_until(io, 5_000);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &fx.majority));
    try testing.expectEqual(@as(u32, 0), fx.leaders_among(&simulation, &fx.minority));

    // The elected leader's empty entry is index 1, so the proposal lands at index 2.
    const index = try fx.propose_to_leader(io, &simulation, &fx.majority, "cmd");
    try testing.expectEqual(@as(u64, 2), index);
    try simulation.run_until(io, 10_000);

    for (fx.majority) |slot| {
        const status = simulation.status(slot).?;
        try testing.expectEqual(index, @intFromEnum(status.commit_index));
        try testing.expectEqual(index, @intFromEnum(status.applied_index));
    }
    for (fx.minority) |slot| {
        const status = simulation.status(slot).?;
        try testing.expectEqual(@as(u64, 0), @intFromEnum(status.commit_index));
        try testing.expectEqual(@as(u64, 0), @intFromEnum(status.last_index));
        try testing.expect(status.role != .leader);
    }
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &fx.majority));
    const stats = simulation.stats();
    try testing.expectEqual(@as(u32, 1), stats.leader_terms);
    try testing.expectEqual(index, stats.committed_max);
    try testing.expectEqual(3 * index, stats.applied); // Three nodes apply both entries.
    try testing.expect(stats.network.dropped_cut > 0); // The cut was exercised, not idle.
    try fx.check_all(&simulation);
}

test "simulation: partition 01 vs 234 elects one leader in the majority and commits" {
    for (0..12) |seed| try expect_partition_scenario(seed);
}

test "simulation: a healed partition lets the minority catch up and all five converge" {
    const options = fx.sim_quiet(5, 5);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    simulation.network.set_partition(&fx.minority, &fx.majority);
    try simulation.run_until(io, 5_000);
    const index = try fx.propose_to_leader(io, &simulation, &fx.majority, "cmd");
    try simulation.run_until(io, 8_000);
    try testing.expectEqual(@as(u64, 0), @intFromEnum(simulation.status(0).?.commit_index));

    simulation.network.heal();
    try simulation.run_until(io, 14_000);
    for (0..5) |slot| {
        const status = simulation.status(@intCast(slot)).?;
        try testing.expectEqual(index, @intFromEnum(status.commit_index));
        try testing.expectEqual(index, @intFromEnum(status.last_index));
    }
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &fx.nodes5));
    try fx.check_all(&simulation);
}

test "simulation: two halves of four nodes have no quorum, so no leader and no commit" {
    const options = fx.sim_quiet(9, 4);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    simulation.network.set_partition(&.{ 0, 1 }, &.{ 2, 3 });
    try simulation.run_until(io, 10_000);

    try testing.expectEqual(@as(u32, 0), fx.leaders_among(&simulation, &.{ 0, 1, 2, 3 }));
    try testing.expectEqual(@as(u32, 0), simulation.stats().leader_terms);
    try testing.expectEqual(@as(u64, 0), simulation.stats().committed_max);
    try testing.expectEqual(@as(u64, 0), fx.commit_max(&simulation, 4));
    try fx.check_all(&simulation);
}

test "simulation: a cut-off leader's proposal is discarded and never commits" {
    const options = fx.sim_quiet(21, 5);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 3_000);
    const old = fx.leader_among(&simulation, &fx.nodes5).?;
    const old_term = simulation.status(old).?.term;
    try testing.expectEqual(@as(u64, 1), fx.commit_max(&simulation, 5));

    var storage: [7]u8 = undefined;
    const rest = fx.others_of(&storage, 5, old);
    simulation.network.set_partition(&.{old}, rest);
    try simulation.propose(io, old, "lost");
    try simulation.run_until(io, 6_000);

    const stale = simulation.status(old).?;
    try testing.expectEqual(@as(u64, 2), @intFromEnum(stale.last_index));
    try testing.expectEqual(@as(u64, 1), @intFromEnum(stale.commit_index)); // Never reaches 2.
    const fresh = fx.leader_among(&simulation, rest).?;
    try testing.expect(@intFromEnum(simulation.status(fresh).?.term) > @intFromEnum(old_term));

    simulation.network.heal();
    try simulation.run_until(io, 9_000);
    try testing.expect(simulation.status(old).?.role != .leader);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(&simulation, &fx.nodes5));
    const commit = fx.commit_max(&simulation, 5);
    try testing.expect(commit >= 2); // The new leader's own empty entry took index 2.
    for (0..5) |slot| {
        const status = simulation.status(@intCast(slot)).?;
        try testing.expectEqual(commit, @intFromEnum(status.commit_index));
    }
    try fx.check_all(&simulation); // The overwrite of "lost" breaks no safety property.
}

// ---- events_max and the clock ---------------------------------------------------------------

test "simulation: events_max boundaries 0, 1, N-1, N and N+1 end in the typed error or in time" {
    const options = fx.sim_quiet(3, 5);
    var probe: Simulation = undefined;
    try probe.init(io, gpa, &options);
    defer probe.deinit(io, gpa);
    try probe.run_until(io, 1_000);
    const total = probe.stats().events; // Events due in the first second of this seed.
    try testing.expect(total >= 100); // One tick per 10 ms alone.

    const limits = [_]u64{ 0, 1, total - 1, total, total + 1 };
    for (limits) |limit| {
        var limited = options;
        limited.events_max = limit;
        var simulation: Simulation = undefined;
        try simulation.init(io, gpa, &limited);
        defer simulation.deinit(io, gpa);
        if (limit >= total) {
            try simulation.run_until(io, 1_000);
            try testing.expectEqual(total, simulation.stats().events);
            try testing.expectEqual(@as(u64, 1_000), simulation.virtual_clock.time_ms);
            continue;
        }
        try testing.expectError(error.EventsExhausted, simulation.run_until(io, 1_000));
        try testing.expectEqual(limit, simulation.stats().events);
        const report = simulation.report();
        try testing.expectEqual(options.seed, report.seed);
        try testing.expectEqual(limit, report.event_index);
        try testing.expectEqual(error.EventsExhausted, report.violation);
    }
}

test "simulation: step stops at events_max without running one more event" {
    var options = fx.sim_quiet(4, 3);
    options.events_max = 2;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.step(io);
    try simulation.step(io);
    const clock_ms = simulation.virtual_clock.time_ms;
    try testing.expectError(error.EventsExhausted, simulation.step(io));
    try testing.expectEqual(@as(u64, 2), simulation.stats().events);
    try testing.expectEqual(clock_ms, simulation.virtual_clock.time_ms);
}

test "simulation: each step runs one event and the clock only moves forward" {
    const options = fx.sim_quiet(6, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try testing.expectEqual(@as(u64, 0), simulation.virtual_clock.time_ms);
    try testing.expectEqual(@as(u64, 0), simulation.stats().events);

    try simulation.step(io); // Nothing is in flight yet: the first event is the first tick.
    try testing.expectEqual(@as(u64, options.tick_ms), simulation.virtual_clock.time_ms);
    var previous_ms = simulation.virtual_clock.time_ms;
    for (2..301) |count| {
        try simulation.step(io);
        try testing.expectEqual(@as(u64, count), simulation.stats().events);
        try testing.expect(simulation.virtual_clock.time_ms >= previous_ms);
        previous_ms = simulation.virtual_clock.time_ms;
    }
}

test "simulation: run_until lands the clock on the target and a repeat runs nothing" {
    const options = fx.sim_quiet(8, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 1_234);
    try testing.expectEqual(@as(u64, 1_234), simulation.virtual_clock.time_ms);
    const before = simulation.stats();
    try simulation.run_until(io, 1_234);
    try testing.expectEqual(before, simulation.stats());
    try simulation.run_until(io, 1_235);
    try testing.expectEqual(@as(u64, 1_235), simulation.virtual_clock.time_ms);
}

test "simulation: staged run_until equals one run to the same time, event for event" {
    const options = fx.sim_quiet(10, 5);
    var staged: Simulation = undefined;
    try staged.init(io, gpa, &options);
    defer staged.deinit(io, gpa);
    var whole: Simulation = undefined;
    try whole.init(io, gpa, &options);
    defer whole.deinit(io, gpa);

    for ([_]u64{ 777, 2_000, 2_001, 6_500, 10_000 }) |stage_ms| {
        try staged.run_until(io, stage_ms);
    }
    try whole.run_until(io, 10_000);
    try testing.expectEqual(whole.stats(), staged.stats());
    try testing.expectEqual(whole.network.trace_hash(), staged.network.trace_hash());
}

// ---- determinism ----------------------------------------------------------------------------

test "simulation: one seed replays to an identical timeline and different seeds differ" {
    const options = fx.sim_quiet(77, 5);
    var first: Simulation = undefined;
    try first.init(io, gpa, &options);
    defer first.deinit(io, gpa);
    var second: Simulation = undefined;
    try second.init(io, gpa, &options);
    defer second.deinit(io, gpa);

    for (0..2_000) |_| {
        try first.step(io);
        try second.step(io);
        try testing.expectEqual(first.virtual_clock.time_ms, second.virtual_clock.time_ms);
        try testing.expectEqual(first.network.trace_hash(), second.network.trace_hash());
        for (0..5) |slot| {
            try testing.expectEqual(first.status(@intCast(slot)), second.status(@intCast(slot)));
        }
    }
    try testing.expectEqual(first.stats(), second.stats());
}

fn digest_of(seed: u64) !u64 {
    const options = fx.sim_quiet(seed, 5);
    var report: Report = undefined;
    const stats = try simulation_module.run_seed(io, gpa, &options, 10_000, &report);
    try testing.expect(stats.events >= 1_000);
    try testing.expect(stats.leader_terms >= 1);
    return stats.digest;
}

test "simulation: run_seed gives equal stats for equal seeds and distinct digests otherwise" {
    var report: Report = undefined;
    const options = fx.sim_quiet(5, 5);
    const first = try simulation_module.run_seed(io, gpa, &options, 10_000, &report);
    const again = try simulation_module.run_seed(io, gpa, &options, 10_000, &report);
    try testing.expectEqual(first, again);
    try testing.expect(first.digest != 0);

    const base = try digest_of(1);
    try testing.expect(base != try digest_of(2));
    try testing.expect(base != try digest_of(3));
    try testing.expectEqual(base, try digest_of(1));
}

// ---- planted faults and the Report ----------------------------------------------------------

/// Runs the flip-data script of `seed`: elect, propose bytes, run on. The planted network flips a
/// data byte of the first non-empty entry of every delivered append.
fn run_flip_script(seed: u64, plant: simulation_module.Plant, out: *Report) !?Error {
    var options = fx.sim_quiet(seed, 5);
    options.plant = plant;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 3_000);
    _ = try fx.propose_to_leader(io, &simulation, &fx.nodes5, "ab");
    simulation.run_until(io, 6_000) catch |err| {
        out.* = simulation.report();
        try testing.expectEqual(simulation.stats().events, out.event_index);
        return @as(?Error, err); // The violation is the result, not a failure of the script.
    };
    try fx.check_all(&simulation);
    return null;
}

test "simulation: a planted flipped entry byte fails the run and the Report names the seed" {
    var report: Report = undefined;
    for (0..4) |seed| {
        const err = (try run_flip_script(seed, .flip_data, &report)) orelse
            return error.PlantedBugUndetected;
        const named = err == error.LogMatching or err == error.StateMachineSafety;
        try testing.expect(named);
        try testing.expectEqual(@as(u64, seed), report.seed);
        try testing.expectEqual(err, report.violation);
        try testing.expect(report.event_index > 0);

        var again: Report = undefined; // The seed replays to the same failure at the same event.
        const replay = (try run_flip_script(seed, .flip_data, &again)).?;
        try testing.expectEqual(err, replay);
        try testing.expectEqual(report.event_index, again.event_index);
        // The same script on an honest network is clean: the plant, not the script, failed it.
        try testing.expectEqual(@as(?Error, null), try run_flip_script(seed, .none, &again));
    }
}

test "simulation: after a violation check names the broken property and spares the others" {
    var options = fx.sim_quiet(2, 5);
    options.plant = .flip_data;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 3_000);
    _ = try fx.propose_to_leader(io, &simulation, &fx.nodes5, "ab");
    const err = simulation.run_until(io, 6_000);
    const failure = if (err) |_| return error.PlantedBugUndetected else |e| e;
    const which: invariants.Property = switch (failure) {
        error.LogMatching => .log_matching,
        error.StateMachineSafety => .state_machine_safety,
        else => return error.UnexpectedViolation,
    };
    try testing.expectError(invariants.violation_of(which), simulation.check(which));
    try simulation.check(.election_safety); // A flipped byte elects no second leader.
}

/// One churn run: the leader is cut off and healed in turn, so elections contest. Returns the
/// violation that ended it, or null for a clean run.
fn run_churn(seed: u64, plant: simulation_module.Plant, out: *Report) !?Error {
    var options = fx.sim_quiet(seed, 5);
    options.plant = plant;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    var at_ms: u64 = 0;
    for (0..16) |round| {
        at_ms += 600;
        if (round % 2 == 0) {
            const guess: u8 = @intCast(seed % 5);
            const victim = fx.leader_among(&simulation, &fx.nodes5) orelse guess;
            fx.isolate(&simulation, 5, victim);
        } else simulation.network.heal();
        simulation.run_until(io, at_ms) catch |err| {
            out.* = simulation.report();
            return @as(?Error, err); // The violation is the result, not a script failure.
        };
    }
    return null;
}

test "simulation: planted forged votes are caught as election or completeness violations" {
    // Detectability needs a denied RequestVote, i.e. contested elections; the churn script makes
    // them. If no seed bites once implemented, widen the churn, never the allowed set.
    var report: Report = undefined;
    var caught: ?Report = null;
    for (0..200) |seed| {
        const err = (try run_churn(seed, .forge_votes, &report)) orelse continue;
        try testing.expect(err == error.ElectionSafety or err == error.LeaderCompleteness);
        try testing.expectEqual(@as(u64, seed), report.seed);
        try testing.expectEqual(err, report.violation);
        if (caught == null) caught = report;
    }
    const first = caught orelse return error.PlantedBugUndetected;
    var again: Report = undefined;
    const replay = (try run_churn(first.seed, .forge_votes, &again)).?;
    try testing.expectEqual(first.violation, replay);
    try testing.expectEqual(first.event_index, again.event_index);
    try testing.expectEqual(@as(?Error, null), try run_churn(first.seed, .none, &again));
}

test "simulation: honest churn over many seeds raises no violation" {
    var report: Report = undefined;
    for (0..40) |seed| {
        const err = try run_churn(seed, .none, &report);
        if (err) |violation| {
            std.log.err("honest churn: {s} at seed {d}", .{ @errorName(violation), report.seed });
            return error.HonestRunFailed;
        }
    }
}

// ---- declared errors ------------------------------------------------------------------------

test "simulation: TermsExhausted is returned when a leader's term passes terms_max" {
    var options = fx.sim_quiet(12, 5);
    options.terms_max = 1;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    var failure: ?Error = null;
    simulation.run_until(io, 3_000) catch |err| {
        failure = err;
    };
    if (failure == null) { // Elected in term 1: cutting the leader off forces a later term.
        const old = fx.leader_among(&simulation, &fx.nodes5).?;
        fx.isolate(&simulation, 5, old);
        simulation.run_until(io, 8_000) catch |err| {
            failure = err;
        };
    }
    try testing.expectEqual(@as(?Error, error.TermsExhausted), failure);
    const report = simulation.report();
    try testing.expectEqual(error.TermsExhausted, report.violation);
    try testing.expectEqual(options.seed, report.seed);
    try fx.check_all(&simulation); // A harness limit is not a safety violation.
}

test "simulation: propose returns ProposeNotLeader, ProposeTooLarge and ProposeLogFull" {
    var options = fx.sim_quiet(14, 3);
    options.raft.log_entries_max = 4;
    options.raft.message_limits.entry_bytes_max = 8; // The preset's is a KV command's size.
    options.raft.log_bytes_max = 4 * 8;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try testing.expectError(error.ProposeNotLeader, simulation.propose(io, 0, "x")); // Cold.
    try simulation.run_until(io, 3_000);
    const leader = fx.leader_among(&simulation, &.{ 0, 1, 2 }).?;
    const follower: u8 = if (leader == 0) 1 else 0;
    const events = simulation.stats().events;

    try testing.expectError(error.ProposeNotLeader, simulation.propose(io, follower, "x"));
    try testing.expectError(error.ProposeTooLarge, simulation.propose(io, leader, "123456789"));
    try testing.expectEqual(@as(u64, 1), @intFromEnum(simulation.status(leader).?.last_index));
    for (0..3) |_| try simulation.propose(io, leader, "fill"); // Indexes 2, 3 and 4.
    try testing.expectError(error.ProposeLogFull, simulation.propose(io, leader, "over"));
    try testing.expectEqual(@as(u64, 4), @intFromEnum(simulation.status(leader).?.last_index));
    try testing.expectEqual(events, simulation.stats().events); // A proposal is not an event.

    try simulation.run_until(io, 6_000); // Rejections latched nothing.
    try testing.expectEqual(@as(u64, 4), fx.commit_max(&simulation, 3));
    try fx.check_all(&simulation);
}

test "simulation: Error is a superset of the violation, limit and propose error sets" {
    const names = [_]Error{
        error.ElectionSafety,     error.LeaderAppendOnly,   error.LogMatching,
        error.LeaderCompleteness, error.StateMachineSafety, error.EventsExhausted,
        error.TermsExhausted,     error.ProposeNotLeader,   error.ProposeTooLarge,
        error.ProposeLogFull,     error.OutOfMemory,
    };
    for (names, 0..) |name, at| {
        try testing.expect(@errorName(name).len > 0);
        for (names[at + 1 ..]) |other| try testing.expect(name != other);
    }
}

test "simulation: Options presets keep the id unset and the node count in range" {
    for (2..8) |count| {
        const options = Options.quiet(count, @intCast(count));
        try testing.expectEqual(types.NodeId.none, options.raft.id);
        try testing.expectEqual(@as(u8, @intCast(count)), options.nodes_count);
        try testing.expectEqual(@as(u8, 0), options.network.loss_percent);
        try testing.expectEqual(simulation_module.Plant.none, options.plant);
        try testing.expect(options.events_max > 0 and options.tick_ms > 0);
    }
    const even = Options.sweep(4);
    const odd = Options.sweep(5);
    try testing.expectEqual(@as(u8, 3), even.nodes_count);
    try testing.expectEqual(@as(u8, 5), odd.nodes_count);
    try testing.expect(odd.network.loss_percent > 0);
    try testing.expectEqual(@as(u64, 5), odd.seed);
}
