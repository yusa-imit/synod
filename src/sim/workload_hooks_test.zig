//! Tests for the workload option validation of `sim/workload_hooks.zig` (review findings of
//! plan 004 item 10): every `WorkloadInvalid` branch of `validate` is provoked on its own, with
//! the boundary beside it that is accepted, directly and through `Simulation.init`, which must
//! refuse before it allocates.
//!
//! Choice where ADR-008 is silent: the `ack_uncommitted` fault (the plant of the same name)
//! needs a client to lie for, so it with `clients_count == 0` is `WorkloadInvalid` too.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const simulation_module = @import("simulation.zig");
const workload_hooks = @import("workload_hooks.zig");
const workload_module = @import("workload.zig");

const Options = simulation_module.Options;
const Plant = simulation_module.Plant;
const Report = simulation_module.Report;
const Simulation = simulation_module.Simulation;
const Workload = workload_module.Workload;

const io = testing.io;
const gpa = testing.allocator;
const command_bytes = workload_module.command_bytes;

const spec_ok: Workload.Options = .{
    .clients_count = 3,
    .keys_count = 4,
    .put_percent = 50,
    .op_interval_ms_max = 40,
    .fault = .none,
};

fn validate_ok(spec: Workload.Options) !void {
    try workload_hooks.validate(spec, 128, 1_000, command_bytes);
}

fn expect_invalid(
    spec: Workload.Options,
    history_ops_max: u32,
    search_steps_max: u64,
    entry_bytes_max: u32,
) !void {
    const want = error.WorkloadInvalid;
    try testing.expectError(want, workload_hooks.validate(
        spec,
        history_ops_max,
        search_steps_max,
        entry_bytes_max,
    ));
}

/// `Simulation.init` and `run_seed` refuse `options` with `WorkloadInvalid`, at event 0.
fn expect_init_invalid(options: Options) !void {
    const want = error.WorkloadInvalid;
    var simulation: Simulation = undefined;
    try testing.expectError(want, simulation.init(io, gpa, &options)); // A leak fails the test.
    var report: Report = undefined;
    try testing.expectError(want, simulation_module.run_seed(io, gpa, &options, 100, &report));
    try testing.expectEqual(want, report.violation);
    try testing.expectEqual(@as(u64, 0), report.event_index);
}

fn sweep_with(spec: Workload.Options) Options {
    var options = Options.sweep(3);
    options.workload = spec;
    return options;
}

test "validate: a sound workload is accepted, with and without clients" {
    try validate_ok(spec_ok);
    var no_clients = spec_ok;
    no_clients.clients_count = 0;
    try validate_ok(no_clients);
}

test "validate: history_ops_max 0 is refused, 1 is accepted" {
    try expect_invalid(spec_ok, 0, 1_000, command_bytes);
    try workload_hooks.validate(spec_ok, 1, 1_000, command_bytes);
    var options = sweep_with(spec_ok);
    options.history_ops_max = 0;
    try expect_init_invalid(options);
}

test "validate: search_steps_max 0 is refused, 1 is accepted" {
    try expect_invalid(spec_ok, 128, 0, command_bytes);
    try workload_hooks.validate(spec_ok, 128, 1, command_bytes);
    var options = sweep_with(spec_ok);
    options.search_steps_max = 0;
    try expect_init_invalid(options);
}

test "validate: keys_count 0 is refused with and without clients, 1 is accepted" {
    var spec = spec_ok;
    spec.keys_count = 0;
    try expect_invalid(spec, 128, 1_000, command_bytes);
    spec.clients_count = 0;
    try expect_invalid(spec, 128, 1_000, command_bytes);
    try expect_init_invalid(sweep_with(spec));
    spec.keys_count = 1;
    try validate_ok(spec);
}

test "validate: put_percent above 100 is refused, 0 and 100 are accepted" {
    var spec = spec_ok;
    for ([_]u8{ 0, 100 }) |percent| {
        spec.put_percent = percent;
        try validate_ok(spec);
    }
    for ([_]u8{ 101, 255 }) |percent| {
        spec.put_percent = percent;
        try expect_invalid(spec, 128, 1_000, command_bytes);
        try expect_init_invalid(sweep_with(spec));
    }
    spec.clients_count = 0; // Refused even when nobody would draw a command.
    try expect_invalid(spec, 128, 1_000, command_bytes);
}

test "validate: op_interval_ms_max 0 is refused with clients, accepted without" {
    var spec = spec_ok;
    spec.op_interval_ms_max = 0;
    try expect_invalid(spec, 128, 1_000, command_bytes);
    try expect_init_invalid(sweep_with(spec));
    spec.op_interval_ms_max = 1;
    try validate_ok(spec);
    spec.op_interval_ms_max = 0;
    spec.clients_count = 0;
    try validate_ok(spec);
}

test "validate: entries smaller than one command are refused with clients" {
    try expect_invalid(spec_ok, 128, 1_000, 0);
    try expect_invalid(spec_ok, 128, 1_000, command_bytes - 1);
    try workload_hooks.validate(spec_ok, 128, 1_000, command_bytes);
    try workload_hooks.validate(spec_ok, 128, 1_000, command_bytes + 1);
    var options = sweep_with(spec_ok);
    options.raft.message_limits.entry_bytes_max = command_bytes - 1;
    try expect_init_invalid(options);

    var no_clients = spec_ok;
    no_clients.clients_count = 0;
    try workload_hooks.validate(no_clients, 128, 1_000, 0);
}

test "validate: the ack_uncommitted fault needs a client to lie for" {
    var spec = spec_ok;
    spec.fault = .ack_uncommitted;
    try validate_ok(spec);
    spec.clients_count = 0;
    try expect_invalid(spec, 128, 1_000, command_bytes);

    var options = Options.quiet(5, 3); // No clients.
    options.plant = Plant.ack_uncommitted;
    try expect_init_invalid(options);
    options = Options.sweep(5);
    options.plant = Plant.ack_uncommitted;
    var report: Report = undefined;
    _ = simulation_module.run_seed(io, gpa, &options, 100, &report) catch |err| switch (err) {
        error.WorkloadInvalid => return error.TestUnexpectedResult,
        else => {}, // The lie may well be caught; this test is about validation only.
    };
}
