//! Tests for the KV workload inside `Simulation` (plan 004 item 10, ADR-008 "Workload" and
//! "Simulation"): clients propose `put`/`get` commands through the log, the operations are
//! invoked at a successful propose and completed at the proposer's apply, and
//! `check(.linearizability)` judges the history. A planted `ack_uncommitted` lie must be caught.
//!
//! New API these tests pin (ADR-008, item 10):
//!   - `Options.workload: Workload.Options`, `Options.history_ops_max: u32`,
//!     `Options.search_steps_max: u64`. `quiet` has `clients_count == 0` (no workload),
//!     `history_ops_max > 0`, `search_steps_max > 0` and `entry_bytes_max >= command_bytes` with
//!     `log_bytes_max == log_entries_max * entry_bytes_max`. `sweep` turns the workload on.
//!   - `Stats.workload: Workload.Stats`; `Simulation.workload: Workload` (public field, tests
//!     read `simulation.workload.history()`).
//!   - `Plant.ack_uncommitted = 5` makes the workload ack a put at invoke (`Workload.Fault`).
//!   - `LimitError.CheckInconclusive` (search budget spent) and `LimitError.HistoryTooLong`
//!     (not provokable through `Simulation`: the workload stops at `history_ops_max`, which is
//!     also the checker's bound; the boundary is tested instead).
//!   - Every crash (scripted `crash` and seeded) calls `Workload.crashed(node)`; a workload
//!     `propose` goes through `Driver.propose` of a seeded node that believes it leads and
//!     calls `invoked` (event index = `stats().events` of the propose event) or `rejected`
//!     (`ProposeNotLeader`, `ProposeLogFull`); the drained applies of every node reach
//!     `Workload.applied` with the event index of the event that applied them.
//!
//! Vacuity floors below are provisional: they were set from the contract (how many operations a
//! healthy cluster can complete in the run), not measured; the implementer must measure and set
//! them under the measured values (never above), and say so in the PR.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("fixtures.zig");
const simulation_module = @import("simulation.zig");
const workload_module = @import("workload.zig");

const Error = simulation_module.Error;
const Options = simulation_module.Options;
const Plant = simulation_module.Plant;
const Proposals = simulation_module.Proposals;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;
const Stats = simulation_module.Stats;
const Workload = workload_module.Workload;

const io = testing.io;
const gpa = testing.allocator;
const command_bytes = workload_module.command_bytes;

const three = [_]u8{ 0, 1, 2 };
const seeds_count = 100;
const duration_ms = 5_000;

const workload_on: Workload.Options = .{
    .clients_count = 3,
    .keys_count = 4,
    .put_percent = 50,
    .op_interval_ms_max = 40,
    .fault = .none,
};

/// A healthy lossless cluster with the workload on: one command every 1..40 ms, 3 clients.
fn calm(seed: u64, nodes_count: u8) Options {
    var options = fx.sim_quiet(seed, nodes_count);
    options.workload = workload_on;
    options.history_ops_max = 128;
    return options;
}

/// `sweep` (lossy duplicating network, 3 or 5 nodes) plus seeded partitions and crashes, torn
/// ones included, with the workload on and `plant` planted.
fn rough(seed: u64, plant: Plant) Options {
    var options = Options.sweep(seed);
    options.plant = plant;
    options.workload = .{
        .clients_count = 3,
        .keys_count = 4,
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
    return options;
}

fn run(options: *const Options, report: *Report) Error!Stats {
    return simulation_module.run_seed(io, gpa, options, duration_ms, report);
}

fn count_kind(history: []const workload_module.Operation, kind: workload_module.Kind) u32 {
    var count: u32 = 0;
    for (history) |op| {
        if (op.kind == kind and op.complete_event != null) count += 1;
    }
    return count;
}

// ---- presets and plant ----------------------------------------------------------------------

test "options: quiet has no workload and entries large enough for one command" {
    for (2..8) |count| {
        const options = Options.quiet(count, @intCast(count));
        try testing.expectEqual(@as(u16, 0), options.workload.clients_count);
        try testing.expect(options.raft.message_limits.entry_bytes_max >= command_bytes);
        try testing.expectEqual(
            options.raft.log_entries_max * options.raft.message_limits.entry_bytes_max,
            options.raft.log_bytes_max,
        );
        try testing.expect(options.history_ops_max > 0);
        try testing.expect(options.search_steps_max > 0);
    }
}

test "options: sweep turns the workload on within its limits" {
    for (0..8) |seed| {
        const options = Options.sweep(seed);
        const spec = options.workload;
        try testing.expect(spec.clients_count > 0);
        try testing.expect(spec.keys_count > 0);
        try testing.expect(spec.put_percent > 0 and spec.put_percent < 100);
        try testing.expect(spec.op_interval_ms_max > 0);
        try testing.expectEqual(Workload.Fault.none, spec.fault);
        try testing.expectEqual(Plant.none, options.plant);
        try testing.expect(options.history_ops_max > 0);
        try testing.expect(options.search_steps_max > 0);
        try testing.expect(options.raft.message_limits.entry_bytes_max >= command_bytes);
        try testing.expectEqual(
            options.raft.log_entries_max * options.raft.message_limits.entry_bytes_max,
            options.raft.log_bytes_max,
        );
    }
}

test "plant: ack_uncommitted is variant 5 and the older four keep their numbers" {
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Plant.ack_uncommitted));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Plant.none));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Plant.lose_synced_hard_state));
}

test "workload: a quiet run without clients records nothing and leaves proposals alone" {
    var options = fx.sim_quiet(5, 3);
    options.proposals = .{ .interval_ms_max = 60, .data_bytes = 2 };
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 3_000);

    const stats = simulation.stats();
    try testing.expectEqual(
        Workload.Stats{ .ops_invoked = 0, .ops_completed = 0, .ops_pending = 0 },
        stats.workload,
    );
    try testing.expectEqual(@as(usize, 0), simulation.workload.history().len);
    try testing.expect(stats.proposed > 5); // the seeded proposals still run
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);
}

// ---- a healthy cluster ----------------------------------------------------------------------

test "workload: a calm cluster completes operations and the history is linearizable" {
    var simulation: Simulation = undefined;
    const options = calm(21, 3);
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, duration_ms);
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);

    const stats = simulation.stats();
    const history = simulation.workload.history();
    try testing.expect(stats.workload.ops_invoked >= 100);
    try testing.expect(stats.workload.ops_completed >= 64);
    try testing.expectEqual(@as(usize, stats.workload.ops_invoked), history.len);
    try testing.expectEqual(
        stats.workload.ops_invoked,
        stats.workload.ops_completed + stats.workload.ops_pending,
    );
    // Each completed operation took its own log index, so it cannot outnumber the commits.
    try testing.expect(stats.workload.ops_completed <= stats.committed_max);
    try testing.expect(stats.applied >= stats.workload.ops_completed);

    for (history) |op| {
        try testing.expect(op.key < workload_on.keys_count);
        if (op.kind == .put) try testing.expect(op.value != 0);
        if (op.complete_event) |complete| try testing.expect(complete > op.invoke_event);
    }
    try testing.expect(count_kind(history, .put) > 10);
    try testing.expect(count_kind(history, .get) > 10);
    var reads_saw_writes: u32 = 0; // vacuity: gets observed real values, not just zeros
    for (history) |op| {
        if (op.kind == .get and op.complete_event != null and op.value != 0) reads_saw_writes += 1;
    }
    try testing.expect(reads_saw_writes > 5);
}

test "workload: calm clusters of 3 and 5 nodes linearize across seeds" {
    for ([_]u8{ 3, 5 }) |nodes_count| {
        for (0..5) |seed| {
            var report: Report = undefined;
            const options = calm(seed, nodes_count);
            const stats = try run(&options, &report);
            try testing.expect(stats.workload.ops_completed >= 32);
        }
    }
}

test "workload: seeded proposals of junk bytes alongside the workload do no harm" {
    var options = calm(33, 3);
    options.proposals = .{ .interval_ms_max = 60, .data_bytes = 3 };
    var report: Report = undefined;
    const stats = try run(&options, &report); // linearizability is checked by run_seed
    try testing.expect(stats.proposed > 5);
    try testing.expect(stats.workload.ops_completed >= 32);
}

test "workload: the history stops at history_ops_max and still checks" {
    for ([_]u32{ 1, 4 }) |history_ops_max| {
        var options = calm(34, 3);
        options.history_ops_max = history_ops_max;
        var report: Report = undefined;
        const stats = try run(&options, &report);
        try testing.expectEqual(history_ops_max, stats.workload.ops_invoked);
        try testing.expect(stats.workload.ops_completed >= 1);
    }
}

test "workload: a full log rejects commands without a record, the run stays healthy" {
    var options = calm(35, 3);
    options.raft.log_entries_max = 8;
    options.raft.log_bytes_max = 8 * options.raft.message_limits.entry_bytes_max;
    var report: Report = undefined;
    const stats = try run(&options, &report);
    // Index 1 is the leader's no-op, so at most 7 commands fit; the rest were refused.
    try testing.expect(stats.workload.ops_invoked >= 3);
    try testing.expect(stats.workload.ops_invoked <= 7);
    try testing.expect(stats.workload.ops_completed >= 3);
}

test "workload: without a quorum nothing is proposed and the empty history checks" {
    const options = calm(36, 3);
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    simulation.crash(io, 1);
    simulation.crash(io, 2);
    try simulation.run_until(io, 3_000); // node 0 alone cannot win an election
    try testing.expectEqual(@as(usize, 0), simulation.workload.history().len);
    try testing.expectEqual(@as(u32, 0), simulation.stats().workload.ops_invoked);
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);
}

test "workload: workload entries change the digest and the applied count of a seed" {
    var plain: Report = undefined;
    var loaded: Report = undefined;
    const without = try run(&fx.sim_quiet(37, 3), &plain);
    const with = try run(&calm(37, 3), &loaded);
    try testing.expect(with.applied > without.applied);
    try testing.expect(with.digest != without.digest);
}

// ---- crashes --------------------------------------------------------------------------------

test "workload: a crashed proposer's operation stays pending, its client index is retired" {
    var options = calm(41, 3);
    options.workload.clients_count = 1;
    options.workload.op_interval_ms_max = 50;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);

    var steps: u32 = 0;
    while (simulation.stats().workload.ops_invoked == 0) : (steps += 1) {
        if (steps > 100_000) return error.TestUnexpectedResult;
        try simulation.step(io);
    }
    const first = simulation.workload.history()[0];
    try testing.expectEqual(@as(?u64, null), first.complete_event); // not applied yet
    const proposer = fx.leader_among(&simulation, &three) orelse return error.TestUnexpectedResult;

    simulation.crash(io, proposer);
    const crashed_at = simulation.virtual_clock.time_ms;
    try simulation.run_until(io, crashed_at + 3_000); // the others elect and carry on
    try testing.expectEqual(first, simulation.workload.history()[0]);
    try simulation.restart(io, proposer);
    try simulation.run_until(io, crashed_at + 6_000);

    const history = simulation.workload.history();
    try testing.expectEqual(first, history[0]); // never completed, even after the restart
    try testing.expect(history.len > 5);
    try testing.expect(simulation.stats().workload.ops_completed > 5);
    for (history[1..]) |op| try testing.expect(op.client_index != first.client_index);
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);
}

test "workload: a follower crash leaves every completed record as it was" {
    var options = calm(42, 3);
    options.workload.clients_count = 1;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 2_000);
    const before = simulation.stats().workload;
    try testing.expect(before.ops_completed > 0);

    const follower = for (three) |slot| {
        const status = simulation.status(slot) orelse continue;
        if (status.role != .leader) break slot;
    } else return error.TestUnexpectedResult;
    const history_before = try gpa.dupe(workload_module.Operation, simulation.workload.history());
    defer gpa.free(history_before);
    simulation.crash(io, follower); // a follower proposed nothing
    for (history_before, simulation.workload.history()[0..history_before.len]) |was, now| {
        if (was.complete_event != null) try testing.expectEqual(was, now);
    }
    try testing.expectEqual(history_before.len, simulation.workload.history().len);
}

// ---- seeds ----------------------------------------------------------------------------------

test "workload: 100 seeds of partitions, crashes and loss all linearize, with vacuity floors" {
    var seeds_completed: u32 = 0;
    var seeds_pending: u32 = 0;
    var seeds_crashed: u32 = 0;
    var seeds_partitioned: u32 = 0;
    var completed_total: u64 = 0;
    var failed_seed: ?u64 = null; // The expectation below prints the seed that failed.
    for (0..seeds_count) |seed| {
        var report: Report = undefined;
        const stats = run(&rough(seed, .none), &report) catch {
            failed_seed = seed;
            break;
        };
        completed_total += stats.workload.ops_completed;
        if (stats.workload.ops_completed > 0) seeds_completed += 1;
        if (stats.workload.ops_pending > 0) seeds_pending += 1;
        if (stats.crashes > 0) seeds_crashed += 1;
        if (stats.partitions > 0) seeds_partitioned += 1;
    }
    try testing.expectEqual(@as(?u64, null), failed_seed);
    try testing.expect(seeds_completed >= seeds_count * 9 / 10);
    try testing.expect(seeds_pending >= seeds_count / 5);
    try testing.expect(seeds_crashed >= seeds_count / 2);
    try testing.expect(seeds_partitioned >= seeds_count / 2);
    try testing.expect(completed_total >= seeds_count * 10);
}

test "workload: the same seed twice gives the same stats and history, another seed differs" {
    const options = rough(7, .none);
    var report: Report = undefined;
    const first = try run(&options, &report);
    const second = try run(&options, &report);
    try testing.expectEqual(first, second);
    try testing.expect(first.workload.ops_invoked > 0);

    const other = try run(&rough(8, .none), &report);
    try testing.expect(other.digest != first.digest);

    var histories: [2][]workload_module.Operation = undefined;
    for (&histories) |*slot| {
        var simulation: Simulation = undefined;
        try simulation.init(io, gpa, &options);
        defer simulation.deinit(io, gpa);
        try simulation.run_until(io, duration_ms);
        slot.* = try gpa.dupe(workload_module.Operation, simulation.workload.history());
    }
    defer for (histories) |history| gpa.free(history);
    try testing.expect(histories[0].len > 0);
    try testing.expectEqualSlices(workload_module.Operation, histories[0], histories[1]);
}

// ---- limits and the planted lie -------------------------------------------------------------

test "workload: a spent search budget is CheckInconclusive with the seed, never a pass" {
    var options = calm(51, 3);
    options.search_steps_max = 1;
    var report: Report = undefined;
    try testing.expectError(error.CheckInconclusive, run(&options, &report));
    try testing.expectEqual(@as(u64, 51), report.seed);
    try testing.expectEqual(@as(Error, error.CheckInconclusive), report.violation);

    options.search_steps_max = 10_000_000; // the same run with a real budget passes
    _ = try run(&options, &report);
}

test "workload: a put acked before it commits fails linearizability for some seed, with the seed" {
    const seeds_tried = 100;
    var failures: u32 = 0;
    var first_failed: ?u64 = null;
    for (0..seeds_tried) |seed| {
        var report: Report = undefined;
        if (run(&rough(seed, .ack_uncommitted), &report)) |_| {
            continue;
        } else |err| {
            try testing.expectEqual(@as(Error, error.Linearizability), err); // nothing else breaks
            try testing.expectEqual(seed, report.seed);
            try testing.expectEqual(@as(Error, error.Linearizability), report.violation);
            failures += 1;
            if (first_failed == null) first_failed = seed;
        }
    }
    try testing.expect(failures >= 1);
    // The honest twin of the first failing seed passes: it is the plant that bites.
    var report: Report = undefined;
    _ = try run(&rough(first_failed.?, .none), &report);
}

/// A scripted lie: the leader is cut off the moment the first put is invoked, so that put never
/// commits; the majority carries on and reads the register. One key, many clients, mostly gets.
fn deposed_leader(seed: u64, plant: Plant) !void {
    var options = calm(seed, 3);
    options.plant = plant;
    options.workload = .{
        .clients_count = 8,
        .keys_count = 1,
        .put_percent = 20,
        .op_interval_ms_max = 40,
        .fault = .none,
    };
    options.history_ops_max = 256;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);

    var steps: u32 = 0;
    while (count_kind(simulation.workload.history(), .put) + puts_pending(&simulation) == 0) {
        steps += 1;
        if (steps > 200_000) return error.TestUnexpectedResult;
        try simulation.step(io);
    }
    const leader = fx.leader_among(&simulation, &three) orelse return error.TestUnexpectedResult;
    fx.isolate(&simulation, 3, leader);
    try simulation.run_until(io, simulation.virtual_clock.time_ms + 3_000);
    try fx.check_all(&simulation);
    try simulation.check(.linearizability);
}

fn puts_pending(simulation: *const Simulation) u32 {
    var count: u32 = 0;
    for (simulation.workload.history()) |op| {
        if (op.kind == .put and op.complete_event == null) count += 1;
    }
    return count;
}

test "workload: an honest cluster survives a deposed leader, the ack lie does not" {
    var lies_caught: u32 = 0;
    for (1..13) |seed| {
        try deposed_leader(seed, .none); // pending puts on a cut-off leader are fine
        if (deposed_leader(seed, .ack_uncommitted)) |_| {} else |err| {
            try testing.expectEqual(error.Linearizability, err);
            lies_caught += 1;
        }
    }
    try testing.expect(lies_caught >= 1);
}
