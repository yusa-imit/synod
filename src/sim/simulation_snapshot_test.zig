//! Red tests for the simulator with compaction on (plan 005 item 6, ADR-009 "Simulator"): the
//! sim nodes take real snapshots of the `"SKV1"` KV stream, a node cut off across compactions
//! catches up by `install_snapshot`, the checker compares state digests at equal applied
//! indexes, and a planted restore that drops a key fails with its seed.
//!
//! API these tests assume (ADR-009):
//!   - Compaction is on when `options.raft.snapshot_entries_min > 0` and
//!     `options.raft.message_limits.snapshot_bytes_max > 0`; the workload test returns to
//!     `log_entries_max = 64`.
//!   - `Plant.restore_drops_key = 6`: every node's `KvStateMachine` is built with
//!     `Fault.restore_drops_key`, so an install leaves a table that differs from the leader's.
//!     The checker names it `StateMachineSafety` (the digest comparison), with the seed.
//!   - `Stats.snapshots: u64` (snapshots saved and confirmed, summed over nodes) and
//!     `Stats.installs: u64` (snapshots a follower installed).
//!   - `Simulation.init` refuses compaction on with `snapshot_bytes_max <
//!     KvStateMachine.snapshot_bytes(keys_count)` as `WorkloadInvalid`.
//!   - "Past 63 ops" is `Stats.committed_max > 63`: the highest log index any node committed,
//!     which a `log_entries_max = 64` window cannot hold without compaction.
//!
//! Vacuity floors are the plan's: at least 30% of 1000 seeds past 63 ops and at least 20% with
//! an install. Allocation: `std.testing.allocator` and `std.testing.io`; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("fixtures.zig");
const simulation_module = @import("simulation.zig");
const workload_module = @import("workload.zig");

const Error = simulation_module.Error;
const Options = simulation_module.Options;
const Plant = simulation_module.Plant;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;
const Stats = simulation_module.Stats;
const KvStateMachine = workload_module.KvStateMachine;

const io = testing.io;
const gpa = testing.allocator;
const three = [_]u8{ 0, 1, 2 };
const duration_ms = 5_000;
const keys_count = 4;
const seeds_count = 1000;
const snapshot_entries_min = 16;

/// Switches compaction on in `options`: 64-entry logs, a snapshot every 16 applied entries
/// keeping 4 trailing, messages able to carry one whole KV snapshot.
fn compacting(options: *Options) void {
    options.raft.log_entries_max = 64;
    options.raft.log_bytes_max = 64 * options.raft.message_limits.entry_bytes_max;
    options.raft.snapshot_entries_min = snapshot_entries_min;
    options.raft.snapshot_trailing = 4;
    options.raft.message_limits.snapshot_bytes_max = KvStateMachine.snapshot_bytes(keys_count);
}

/// A healthy lossless cluster, workload on, compaction on.
fn calm(seed: u64, plant: Plant) Options {
    var options = fx.sim_quiet(seed, 3);
    options.plant = plant;
    options.workload = .{
        .clients_count = 3,
        .keys_count = keys_count,
        .put_percent = 50,
        .op_interval_ms_max = 40,
        .fault = .none,
    };
    options.history_ops_max = 256;
    compacting(&options);
    return options;
}

/// `sweep` with seeded partitions and crashes, workload on, compaction on.
fn rough(seed: u64, plant: Plant) Options {
    var options = Options.sweep(seed);
    options.plant = plant;
    options.workload = .{
        .clients_count = 3,
        .keys_count = keys_count,
        .put_percent = 50,
        .op_interval_ms_max = 30,
        .fault = .none,
    };
    options.history_ops_max = 256;
    options.faults = .{
        .fault_interval_ms_max = 200,
        .crash_percent = 25,
        .torn_percent = 30,
        .down_ms_max = 300,
        .partition_percent = 30,
        .partition_ms_max = 800,
    };
    compacting(&options);
    return options;
}

fn run(options: *const Options, report: *Report) Error!Stats {
    return simulation_module.run_seed(io, gpa, options, duration_ms, report);
}

/// Node 2 is cut off from the start, the other two run past two compactions, then it heals.
fn cut_off_across_compactions(simulation: *Simulation) !void {
    fx.isolate(simulation, 3, 2);
    try simulation.run_until(io, 3_000);
    try testing.expect(simulation.stats().committed_max > 2 * snapshot_entries_min);
    simulation.network.heal();
    try simulation.run_until(io, 6_000);
}

/// Steps until every node reports one applied index, then compares their KV digests.
fn expect_converged(simulation: *Simulation) !void {
    var steps: u32 = 0;
    while (steps < 50_000) : (steps += 1) {
        const first = simulation.status(0) orelse return error.TestUnexpectedResult;
        var same = true;
        for (1..3) |slot| {
            const status = simulation.status(@intCast(slot)) orelse
                return error.TestUnexpectedResult;
            if (status.applied_index != first.applied_index) same = false;
        }
        if (same and first.applied_index != .zero) break;
        try simulation.step(io);
    } else return error.TestUnexpectedResult;
    const want = simulation.nodes[0].kv.digest();
    try testing.expectEqual(want, simulation.nodes[1].kv.digest());
    try testing.expectEqual(want, simulation.nodes[2].kv.digest());
}

// ---- options and presets -----------------------------------------------------------------------

test "sim snapshots: compaction on with a snapshot buffer one byte short is WorkloadInvalid" {
    const need = KvStateMachine.snapshot_bytes(keys_count);
    var options = calm(1, .none);
    options.raft.message_limits.snapshot_bytes_max = need - 1;
    var simulation: Simulation = undefined;
    if (simulation.init(io, gpa, &options)) |_| {
        simulation.deinit(io, gpa);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.WorkloadInvalid, err);

    options.raft.message_limits.snapshot_bytes_max = need; // exactly enough is accepted
    try simulation.init(io, gpa, &options);
    simulation.deinit(io, gpa);
}

test "sim snapshots: the plant names exist and are additive" {
    try testing.expectEqual(@as(u8, 6), @intFromEnum(Plant.restore_drops_key));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Plant.ack_uncommitted));
}

// ---- compaction in a run -----------------------------------------------------------------------

test "sim snapshots: a calm cluster snapshots, compacts, and installs nothing" {
    var report: Report = undefined;
    const stats = try run(&calm(11, .none), &report);
    // Past the 64-entry window: only compaction allows it.
    try testing.expect(stats.committed_max > 63);
    try testing.expect(stats.snapshots >= 3);
    try testing.expectEqual(@as(u64, 0), stats.installs);
    try testing.expect(stats.workload.ops_completed > 63);
}

test "sim snapshots: the same seed twice gives the same stats, installs included" {
    const options = rough(9, .none);
    var report: Report = undefined;
    const first = try run(&options, &report);
    const second = try run(&options, &report);
    try testing.expectEqual(first, second);
    try testing.expect(first.snapshots > 0);
}

test "sim snapshots: a follower cut off across two compactions catches up by install" {
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &calm(21, .none));
    defer simulation.deinit(io, gpa);
    try cut_off_across_compactions(&simulation);
    const stats = simulation.stats();
    try testing.expect(stats.installs >= 1);
    try testing.expect(stats.snapshots >= 2);
    const status = simulation.status(2) orelse return error.TestUnexpectedResult;
    try testing.expect(@intFromEnum(status.snapshot_index) >= snapshot_entries_min);
    try testing.expect(@intFromEnum(status.applied_index) > 2 * snapshot_entries_min);
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);
    try expect_converged(&simulation);
}

test "sim snapshots: an honest install leaves the digest check green on every step" {
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &calm(22, .none));
    defer simulation.deinit(io, gpa);
    fx.isolate(&simulation, 3, 2);
    try fx.step_checked(io, &simulation, 3_000, 200_000);
    simulation.network.heal();
    try fx.step_checked(io, &simulation, 5_000, 200_000);
    try testing.expect(simulation.stats().installs >= 1);
}

// ---- the planted restore -----------------------------------------------------------------------

test "sim snapshots: a restore that drops a key fails the digest check after an install" {
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &calm(21, .restore_drops_key));
    defer simulation.deinit(io, gpa);
    const failed = cut_off_across_compactions(&simulation);
    try testing.expectError(error.StateMachineSafety, failed);
    try testing.expectEqual(@as(u64, 21), simulation.report().seed);
    try testing.expectError(error.StateMachineSafety, simulation.check(.state_machine_safety));
}

test "sim snapshots: a planted restore fails for some seed, with that seed in the report" {
    const seeds_tried = 150;
    var first_failed: ?u64 = null;
    for (0..seeds_tried) |seed| {
        var report: Report = undefined;
        if (run(&rough(seed, .restore_drops_key), &report)) |_| continue else |err| {
            try testing.expectEqual(error.StateMachineSafety, err); // nothing else breaks
            try testing.expectEqual(seed, report.seed);
            try testing.expectEqual(@as(Error, error.StateMachineSafety), report.violation);
            first_failed = seed;
            break;
        }
    }
    const seed = first_failed orelse return error.TestUnexpectedResult;
    var report: Report = undefined; // The honest twin of the failing seed passes.
    _ = try run(&rough(seed, .none), &report);
}

test "sim snapshots: the plant is inert while nothing installs a snapshot" {
    var report: Report = undefined;
    const planted = try run(&calm(31, .restore_drops_key), &report); // a calm run never installs
    const honest = try run(&calm(31, .none), &report);
    try testing.expectEqual(@as(u64, 0), honest.installs);
    try testing.expectEqual(honest.digest, planted.digest);
}

// ---- the sweep ---------------------------------------------------------------------------------

test "sim snapshots: 1000 seeds with compaction on are green, past the log window, with installs" {
    var seeds_past_window: u32 = 0;
    var seeds_installing: u32 = 0;
    var failed_seed: ?u64 = null; // The expectation below prints the seed that failed.
    for (0..seeds_count) |seed| {
        var report: Report = undefined;
        const stats = run(&rough(seed, .none), &report) catch {
            failed_seed = seed;
            break;
        };
        if (stats.committed_max > 63) seeds_past_window += 1;
        if (stats.installs >= 1) seeds_installing += 1;
    }
    try testing.expectEqual(@as(?u64, null), failed_seed);
    try testing.expect(seeds_past_window >= seeds_count * 30 / 100);
    try testing.expect(seeds_installing >= seeds_count * 20 / 100);
}
