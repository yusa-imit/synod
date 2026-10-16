//! Seeded model-based and allocation tests for `sim/simulation.zig` (plan 004 item 4).
//!
//! Model: for 60 seeds of the `sweep` preset (3 or 5 nodes, lossy and duplicating network) a
//! seeded script cuts random partitions, heals, and proposes to whichever node leads. After
//! EVERY event all five properties are re-asked of the simulation (it runs every
//! `check_invariants()` itself) and a trivial reference model checks what the simulation
//! reports: a node's commit index only rises, `applied <= commit <= last`, the checker's
//! `committed_max` is the highest commit any node shows, and `stats().applied` is the sum of
//! the applied indexes (no restarts exist yet, so none of these may ever go down). After the
//! script the network is healed: within seven more virtual seconds exactly one leader remains
//! and every node holds the same committed log.
//!
//! The script draws from its own `Prng`, never from the simulation's streams. Floors keep the
//! model from passing vacuously (leaders elected, partitions that changed leaders, proposals
//! accepted). Allocation tests prove init is the only allocation point and that an allocator
//! failing at each index leaves nothing behind.

const std = @import("std");
const testing = std.testing;
const fx = @import("fixtures.zig");
const prng_module = @import("prng.zig");
const driver_module = @import("../driver.zig");
const simulation_module = @import("simulation.zig");

const Network = @import("network.zig").Network;
const Options = simulation_module.Options;
const Prng = prng_module.Prng;
const Simulation = simulation_module.Simulation;

const io = testing.io;
const gpa = testing.allocator;

const seeds_count = 60;
const script_ms = 6_000;
const heal_ms = 13_000;
const window_ms = 400;
const steps_limit = 40_000;

/// What the script did, for the vacuity floors.
const Outcome = struct { leader_terms: u32, proposals: u32, digest: u64 };

/// The reference model: only numbers the simulation also reports.
const Model = struct {
    nodes_count: u8,
    commit_seen: [simulation_module.nodes_max]u64 = @splat(0),

    /// One event happened: the reported state must agree with the model.
    fn observe(model: *Model, simulation: *const Simulation) !void {
        var commit_top: u64 = 0;
        var applied_sum: u64 = 0;
        for (0..model.nodes_count) |slot| {
            const status = simulation.status(@intCast(slot)).?;
            const commit: u64 = @intFromEnum(status.commit_index);
            const applied: u64 = @intFromEnum(status.applied_index);
            try testing.expect(commit >= model.commit_seen[slot]); // Never regresses.
            try testing.expect(applied <= commit);
            try testing.expect(commit <= @intFromEnum(status.last_index));
            model.commit_seen[slot] = commit;
            commit_top = @max(commit_top, commit);
            applied_sum += applied;
        }
        const stats = simulation.stats();
        try testing.expectEqual(commit_top, stats.committed_max);
        try testing.expectEqual(applied_sum, stats.applied);
    }
};

/// Steps event by event until the clock reaches `until_ms`, model and properties after each.
fn run_checked(model: *Model, simulation: *Simulation, until_ms: u64) !void {
    var steps: u32 = 0;
    while (simulation.virtual_clock.time_ms < until_ms) {
        steps += 1;
        try testing.expect(steps <= steps_limit);
        try simulation.step(io);
        try fx.check_all(simulation);
        try model.observe(simulation);
    }
}

/// A random split of `count` nodes into two non-empty sides.
fn partition_random(simulation: *Simulation, prng: *Prng, count: u8) void {
    var side_a: [simulation_module.nodes_max]u8 = undefined;
    var side_b: [simulation_module.nodes_max]u8 = undefined;
    var a_len: usize = 0;
    var b_len: usize = 0;
    for (0..count) |slot| {
        const to_a = if (slot == 0) true else if (slot == count - 1) false else prng.chance(50);
        if (to_a) {
            side_a[a_len] = @intCast(slot);
            a_len += 1;
        } else {
            side_b[b_len] = @intCast(slot);
            b_len += 1;
        }
    }
    simulation.network.set_partition(side_a[0..a_len], side_b[0..b_len]);
}

/// A proposal to a node that believes it leads, if any; true when it was accepted.
fn propose_somewhere(simulation: *Simulation, count: u8, serial: u8) !bool {
    var members: [simulation_module.nodes_max]u8 = undefined;
    for (members[0..count], 0..) |*member, slot| member.* = @intCast(slot);
    const leader = fx.leader_among(simulation, members[0..count]) orelse return false;
    const data = [2]u8{ serial, leader };
    simulation.propose(io, leader, &data) catch |err| switch (err) {
        error.ProposeLogFull => return false,
        else => return err,
    };
    return true;
}

/// The script of `seed` for `options`; returns what happened.
fn run_model(options: *const Options) !Outcome {
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, options);
    defer simulation.deinit(io, gpa);
    const count = options.nodes_count;
    var model: Model = .{ .nodes_count = count };
    var prng = Prng.init(options.seed ^ 0x5eed_5eed);
    var proposals: u32 = 0;
    var at_ms: u64 = 0;
    while (at_ms < script_ms) {
        const roll = prng.uint_less_than(100);
        if (roll < 35) partition_random(&simulation, &prng, count);
        if (roll >= 35 and roll < 55) simulation.network.heal();
        if (prng.chance(50) and try propose_somewhere(&simulation, count, @truncate(at_ms / 8))) {
            proposals += 1;
        }
        at_ms += window_ms;
        try run_checked(&model, &simulation, at_ms);
    }
    simulation.network.heal();
    try run_checked(&model, &simulation, heal_ms);
    try expect_converged(&simulation, count);
    const stats = simulation.stats();
    return .{ .leader_terms = stats.leader_terms, .proposals = proposals, .digest = stats.digest };
}

/// Healed and quiet for seven seconds: one leader, one committed log everywhere.
fn expect_converged(simulation: *const Simulation, count: u8) !void {
    var members: [simulation_module.nodes_max]u8 = undefined;
    for (members[0..count], 0..) |*member, slot| member.* = @intCast(slot);
    try testing.expectEqual(@as(u32, 1), fx.leaders_among(simulation, members[0..count]));
    const top = fx.commit_max(simulation, count);
    try testing.expect(top >= 1); // At least the new leader's empty entry is committed.
    for (0..count) |slot| {
        const status = simulation.status(@intCast(slot)).?;
        try testing.expectEqual(top, @intFromEnum(status.commit_index));
        try testing.expectEqual(top, @intFromEnum(status.last_index));
    }
}

test "simulation model: 60 seeds keep every property each event and converge once healed" {
    var led: u32 = 0;
    var turnover: u32 = 0;
    var proposed: u32 = 0;
    for (0..seeds_count) |seed| {
        const options = Options.sweep(seed);
        const outcome = run_model(&options) catch |err| {
            std.log.err("simulation model: {s} at seed {d}", .{ @errorName(err), seed });
            return err;
        };
        led += @intFromBool(outcome.leader_terms >= 1);
        turnover += @intFromBool(outcome.leader_terms >= 2);
        proposed += @intFromBool(outcome.proposals >= 1);
    }
    try testing.expect(led * 10 >= seeds_count * 9); // Elections happen.
    try testing.expect(turnover * 5 >= seeds_count); // Partitions change leaders in 20%.
    try testing.expect(proposed * 2 >= seeds_count); // The script gets proposals accepted.
}

test "simulation model: a seed replays to the same outcome and seeds differ" {
    const options = Options.sweep(13);
    const first = try run_model(&options);
    const second = try run_model(&options);
    try testing.expectEqual(first, second);
    try testing.expect(first.digest != 0);
    const other = try run_model(&Options.sweep(14));
    try testing.expect(other.digest != first.digest);
}

// ---- allocation -----------------------------------------------------------------------------

/// Init with an allocator failing at every index in turn: each failure is `OutOfMemory` with
/// nothing left allocated, and the first success makes exactly as many allocations as the
/// failing index it first survived.
fn expect_init_clean(options: *const Options) !void {
    var attempts: u32 = 0;
    while (attempts < 4096) : (attempts += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = attempts });
        var simulation: Simulation = undefined;
        simulation.init(io, failing.allocator(), options) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        try testing.expectEqual(attempts, failing.alloc_index);
        try testing.expect(attempts > options.nodes_count); // At least one per node.
        simulation.deinit(io, failing.allocator());
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return;
    }
    return error.TestUnexpectedResult; // init never succeeded within 4096 allocations.
}

test "simulation: init fails cleanly at each allocation index for 3 and 5 nodes" {
    try expect_init_clean(&Options.sweep(2)); // 3 nodes.
    try expect_init_clean(&Options.sweep(3)); // 5 nodes.
}

/// A busy script: election, proposals, a partition, a heal, queries. Allocates nothing itself.
fn busy_script(simulation: *Simulation, nodes_count: u8) !void {
    try simulation.run_until(io, 2_000);
    _ = try fx.propose_to_leader(io, simulation, &fx.nodes5, "ab");
    simulation.network.set_partition(&fx.minority, &fx.majority);
    try simulation.run_until(io, 5_000);
    simulation.network.heal();
    for (0..400) |_| try simulation.step(io);
    try simulation.run_until(io, 9_000);
    try fx.check_all(simulation);
    for (0..nodes_count) |slot| try testing.expect(simulation.status(@intCast(slot)) != null);
    try testing.expect(simulation.stats().events > 0);
}

test "simulation: nothing allocates after init, even with an allocator that now always fails" {
    const options = Options.quiet(31, 5);
    var counting = testing.FailingAllocator.init(gpa, .{});
    var first: Simulation = undefined;
    try first.init(io, counting.allocator(), &options);
    const init_allocs = counting.alloc_index;
    const init_bytes = counting.allocated_bytes;
    try busy_script(&first, 5);
    try testing.expectEqual(init_allocs, counting.alloc_index);
    try testing.expectEqual(init_bytes, counting.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counting.resize_index);
    first.deinit(io, counting.allocator());
    try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);

    // Same run, but the allocator refuses everything after init's own allocations.
    var strict = testing.FailingAllocator.init(gpa, .{ .fail_index = init_allocs });
    var second: Simulation = undefined;
    try second.init(io, strict.allocator(), &options);
    defer second.deinit(io, strict.allocator());
    try busy_script(&second, 5);
    try testing.expect(!strict.has_induced_failure);
}

test "simulation: init allocates at least the drivers' and the network's declared bytes" {
    const options = Options.quiet(32, 5);
    var counting = testing.FailingAllocator.init(gpa, .{});
    var simulation: Simulation = undefined;
    try simulation.init(io, counting.allocator(), &options);
    defer simulation.deinit(io, counting.allocator());

    const network_options: Network.Options = .{
        .nodes_count = options.nodes_count,
        .message_limits = options.raft.message_limits,
        .model = options.network,
        .fault = .none,
    };
    const drivers = 5 * driver_module.Driver.init_bytes_max(&options.raft);
    const floor = drivers + Network.bytes_required(&network_options);
    try testing.expect(drivers > 0); // The sizing exists (driver_init_bytes_test pins it).
    try testing.expect(counting.allocated_bytes >= floor);
}
