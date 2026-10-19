//! Tests for the `Options` validation and the proposal buffer of `sim/simulation.zig` (the
//! review findings of plan 004 items 4 and 6).
//!
//! New API these tests pin:
//!   - `OptionsError.CrashPercentInvalid` (`crash_percent > 100`), `TornPercentInvalid`
//!     (`torn_percent > 100`) and `DownDurationInvalid` (`crash_percent > 0` and
//!     `down_ms_max == 0`): returned by `init` before anything is allocated, never asserted.
//!   - A proposal of any `data_bytes` up to `entry_bytes_max` (here 20 > 8) is proposed, not a
//!     buffer overrun.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const simulation_module = @import("simulation.zig");

const Error = simulation_module.Error;
const Options = simulation_module.Options;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;

const io = testing.io;
const gpa = testing.allocator;

/// Crashes and torn crashes on, with a valid down time: the base every case mutates.
fn crashy(seed: u64) Options {
    var options = Options.sweep(seed);
    options.faults = .{
        .fault_interval_ms_max = 50,
        .crash_percent = 30,
        .torn_percent = 30,
        .down_ms_max = 200,
        .partition_percent = 0,
        .partition_ms_max = 0,
    };
    return options;
}

fn expect_init_error(options: Options, want: Error) !void {
    var simulation: Simulation = undefined;
    try testing.expectError(want, simulation.init(io, gpa, &options)); // A leak fails the test.
    var report: Report = undefined;
    try testing.expectError(want, simulation_module.run_seed(io, gpa, &options, 100, &report));
    try testing.expectEqual(want, report.violation);
    try testing.expectEqual(@as(u64, 0), report.event_index);
}

fn expect_runs(options: Options) !void {
    var report: Report = undefined;
    _ = try simulation_module.run_seed(io, gpa, &options, 1_500, &report);
}

test "init: crash_percent accepts 0 and 100 and refuses 101 and 255" {
    var options = crashy(1);
    options.faults.crash_percent = 0;
    try expect_runs(options);
    options.faults.crash_percent = 100;
    try expect_runs(options);
    options.faults.crash_percent = 101;
    try expect_init_error(options, error.CrashPercentInvalid);
    options.faults.crash_percent = 255;
    try expect_init_error(options, error.CrashPercentInvalid);
}

test "init: torn_percent accepts 0 and 100 and refuses 101 and 255" {
    var options = crashy(2);
    options.faults.torn_percent = 0;
    try expect_runs(options);
    options.faults.torn_percent = 100;
    try expect_runs(options);
    options.faults.torn_percent = 101;
    try expect_init_error(options, error.TornPercentInvalid);
    options.faults.torn_percent = 255;
    try expect_init_error(options, error.TornPercentInvalid);
}

test "init: crashes need a down time, down_ms_max 0 with crash_percent above 0 is refused" {
    var options = crashy(3);
    options.faults.down_ms_max = 0;
    try expect_init_error(options, error.DownDurationInvalid);
    options.faults.down_ms_max = 1;
    try expect_runs(options);
    options.faults.down_ms_max = std.math.maxInt(u32);
    try expect_runs(options);
    options.faults.crash_percent = 0; // Crashes off: the down time is then unused.
    options.faults.down_ms_max = 0;
    try expect_runs(options);
}

test "propose: data_bytes above 8 up to entry_bytes_max is proposed, not a buffer overrun" {
    var options = Options.quiet(4, 3);
    options.raft.message_limits.entry_bytes_max = 20;
    options.raft.log_bytes_max = 64 * 20;
    options.proposals = .{ .interval_ms_max = 1, .data_bytes = 20 };
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);
    try simulation.run_until(io, 1_000);
    try testing.expect(simulation.stats().proposed > 0);
    try testing.expect(simulation.stats().committed_max > 0);
}
