//! tools/sim.zig — the seed sweep behind `zig build sim` (plan 004 item 7).
//!
//! `zig build sim [-Dseeds=N] [-Dseed=S] [-Dseed_start=S] [-Dplant=NAME]` runs `Simulation`
//! over `N` consecutive seeds (default 1000) of the stress preset: 3 or 5 nodes, a lossy
//! duplicating network, seeded crashes (some torn), partitions and proposals, 10 s of virtual
//! time per seed. The first failing seed stops the sweep: its `Report` goes to stderr with the
//! replay command and the process exits 1. `-Dseed=S` replays exactly one seed.
//!
//! `-Dplant=NAME` plants a fault (`sim.Plant`) to prove the sweep bites: it must fail.
//!
//! Allocation and ownership: `run_sweep` allocates only inside `sim.run_seed` and frees
//! everything before it returns; `Config` and `Outcome` are plain values.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synod = @import("synod");
const sim = synod.sim;

/// Virtual milliseconds simulated per seed.
pub const duration_ms_default: u64 = 10_000;

/// Seeds a sweep runs when `-Dseeds` is absent.
pub const seeds_count_default: u64 = 1000;

pub const Config = struct {
    /// First seed of the window; the window is `[seed_first, seed_first + seeds_count)`.
    seed_first: u64,
    /// Seeds to run, at least 1.
    seeds_count: u64,
    /// A fault the sweep plants; `.none` for an honest sweep.
    plant: sim.Plant,
    /// Virtual milliseconds simulated per seed, at least 1.
    duration_ms: u64,
};

pub const ParseError = error{
    ArgsTooMany,
    FlagUnknown,
    PlantUnknown,
    SeedsCountZero,
    ValueInvalid,
    WindowOverflow,
};

/// Totals over the seeds that passed; also the vacuity evidence printed after a green sweep.
pub const Summary = struct {
    seeds: u64,
    events: u64,
    crashes: u64,
    partitions: u64,
    truncates: u64,
    proposed: u64,
    applied: u64,
};

pub const Outcome = union(enum) {
    passed: Summary,
    failed: sim.Report,
};

/// Parses `--seeds=N`, `--seed=S` (one seed), `--seed-start=S`, `--plant=NAME`; `args` excludes
/// the program name. A flag may appear once, `--seed` excludes `--seeds`, and the window must fit
/// in a `u64`.
pub fn parse_args(args: []const []const u8) ParseError!Config {
    if (args.len > flags_count) return error.ArgsTooMany;
    var config: Config = .{
        .seed_first = 0,
        .seeds_count = seeds_count_default,
        .plant = .none,
        .duration_ms = duration_ms_default,
    };
    var seen: [flags_count]bool = @splat(false);
    for (args) |arg| {
        const flag = flag_of(arg) orelse return error.FlagUnknown;
        if (seen[@intFromEnum(flag)]) return error.ValueInvalid;
        seen[@intFromEnum(flag)] = true;
        const value = arg[flag_prefixes[@intFromEnum(flag)].len..];
        switch (flag) {
            .seeds => config.seeds_count = try parse_u64(value),
            .seed => {
                config.seed_first = try parse_u64(value);
                config.seeds_count = 1;
            },
            .seed_start => config.seed_first = try parse_u64(value),
            .plant => config.plant = std.meta.stringToEnum(sim.Plant, value) orelse
                return error.PlantUnknown,
        }
    }
    if (seen[@intFromEnum(Flag.seeds)] and seen[@intFromEnum(Flag.seed)]) {
        return error.ValueInvalid;
    }
    if (config.seeds_count == 0) return error.SeedsCountZero;
    if (config.seed_first > std.math.maxInt(u64) - config.seeds_count) {
        return error.WindowOverflow;
    }
    assert(config.seeds_count > 0);
    assert(config.duration_ms > 0);
    return config;
}

/// The flags; `parse_args` marks each seen by its ordinal.
const Flag = enum(u8) { seeds, seed, seed_start, plant };

const flags_count = @typeInfo(Flag).@"enum".fields.len;

/// Prefix of each flag, indexed by `Flag`; the value follows it.
const flag_prefixes = [flags_count][]const u8{ "--seeds=", "--seed=", "--seed-start=", "--plant=" };

fn flag_of(arg: []const u8) ?Flag {
    for (flag_prefixes, 0..) |prefix, index| {
        if (std.mem.startsWith(u8, arg, prefix)) return @enumFromInt(index);
    }
    return null;
}

fn parse_u64(value: []const u8) ParseError!u64 {
    return std.fmt.parseInt(u64, value, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => error.ValueInvalid,
    };
}

/// The sweep's `Options` for `seed`: `Options.sweep` plus seeded crashes, partitions and
/// proposals. Every fault field is spelled out so a library default cannot move the sweep.
pub fn stress_options(seed: u64, plant: sim.Plant) sim.Options {
    var options = sim.Options.sweep(seed);
    options.plant = plant;
    options.faults = .{
        .fault_interval_ms_max = 300,
        .crash_percent = 40,
        .torn_percent = 50,
        .down_ms_max = 400,
        .partition_percent = 30,
        .partition_ms_max = 800,
    };
    options.proposals = .{ .interval_ms_max = 200, .data_bytes = 2 };
    assert(options.faults.crash_percent + options.faults.partition_percent <= 100);
    assert(options.plant == plant);
    return options;
}

/// Runs the window of `config`; stops at the first failing seed.
pub fn run_sweep(io: Io, gpa: Allocator, config: *const Config) Outcome {
    assert(config.seeds_count > 0);
    assert(config.seed_first <= std.math.maxInt(u64) - config.seeds_count);
    var summary: Summary = std.mem.zeroes(Summary);
    var report: sim.Report = undefined;
    for (0..config.seeds_count) |offset| {
        const seed = config.seed_first + offset;
        const options = stress_options(seed, config.plant);
        const stats = sim.run_seed(io, gpa, &options, config.duration_ms, &report) catch {
            assert(report.seed == seed);
            return .{ .failed = report };
        };
        summary.seeds += 1;
        summary.events += stats.events;
        summary.crashes += stats.crashes;
        summary.partitions += stats.partitions;
        summary.truncates += stats.truncates;
        summary.proposed += stats.proposed;
        summary.applied += stats.applied;
    }
    assert(summary.seeds == config.seeds_count);
    return .{ .passed = summary };
}

/// A green sweep prints its totals (the vacuity evidence); a red one prints the failing seed
/// and the command that replays it.
pub fn write_outcome(out: *Io.Writer, config: *const Config, outcome: *const Outcome) !void {
    switch (outcome.*) {
        .passed => |summary| {
            assert(summary.seeds == config.seeds_count);
            try out.print("sim: ok: {d} seeds [{d}, {d}), {d} ms each: events={d} crashes={d} " ++
                "partitions={d} truncates={d} proposed={d} applied={d}\n", .{
                summary.seeds,      config.seed_first, config.seed_first + config.seeds_count,
                config.duration_ms, summary.events,    summary.crashes,
                summary.partitions, summary.truncates, summary.proposed,
                summary.applied,
            });
        },
        .failed => |report| {
            assert(report.seed >= config.seed_first);
            try out.print("sim: FAIL seed={d} event={d} violation={s}\n", .{
                report.seed, report.event_index, @errorName(report.violation),
            });
            try out.print("sim: replay: zig build sim -Dseed={d}", .{report.seed});
            if (config.plant != .none) try out.print(" -Dplant={s}", .{@tagName(config.plant)});
            try out.print("\n", .{});
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    assert(args.len >= 1);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    const config = parse_args(args[1..]) catch |err| {
        try err_out.print("sim: bad arguments: {s}\n", .{@errorName(err)});
        try err_out.flush();
        std.process.exit(2);
    };

    const outcome = run_sweep(init.io, init.gpa, &config);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    switch (outcome) {
        .passed => {
            try write_outcome(&stdout_writer.interface, &config, &outcome);
            try stdout_writer.interface.flush();
        },
        .failed => {
            try write_outcome(err_out, &config, &outcome);
            try err_out.flush();
            std.process.exit(1);
        },
    }
}

const testing = std.testing;

test "parse_args: no flags is the default window of 1000 seeds from 0" {
    const config = try parse_args(&.{});
    try testing.expectEqual(@as(u64, 0), config.seed_first);
    try testing.expectEqual(seeds_count_default, config.seeds_count);
    try testing.expectEqual(sim.Plant.none, config.plant);
    try testing.expectEqual(duration_ms_default, config.duration_ms);
}

test "parse_args: seeds, seed-start and plant are read" {
    const config = try parse_args(&.{
        "--seeds=7",
        "--seed-start=100",
        "--plant=lose_synced_hard_state",
    });
    try testing.expectEqual(@as(u64, 7), config.seeds_count);
    try testing.expectEqual(@as(u64, 100), config.seed_first);
    try testing.expectEqual(sim.Plant.lose_synced_hard_state, config.plant);
}

test "parse_args: seed replays exactly one seed" {
    const config = try parse_args(&.{"--seed=42"});
    try testing.expectEqual(@as(u64, 42), config.seed_first);
    try testing.expectEqual(@as(u64, 1), config.seeds_count);
}

test "parse_args: every error variant is provoked" {
    try testing.expectError(error.FlagUnknown, parse_args(&.{"--bogus=1"}));
    try testing.expectError(error.FlagUnknown, parse_args(&.{"seeds=3"}));
    try testing.expectError(error.ValueInvalid, parse_args(&.{"--seeds=x"}));
    try testing.expectError(error.FlagUnknown, parse_args(&.{"--seeds"}));
    try testing.expectError(error.ValueInvalid, parse_args(&.{ "--seeds=1", "--seeds=2" }));
    try testing.expectError(error.ValueInvalid, parse_args(&.{ "--seed=1", "--seeds=2" }));
    try testing.expectError(error.PlantUnknown, parse_args(&.{"--plant=nope"}));
    try testing.expectError(error.SeedsCountZero, parse_args(&.{"--seeds=0"}));
    try testing.expectError(error.ArgsTooMany, parse_args(&.{ "a", "b", "c", "d", "e" }));
    try testing.expectError(error.WindowOverflow, parse_args(&.{
        "--seed-start=18446744073709551615",
        "--seeds=2",
    }));
    const last = try parse_args(&.{ "--seed-start=18446744073709551614", "--seeds=1" });
    try testing.expectEqual(std.math.maxInt(u64) - 1, last.seed_first);
}

test "stress_options: crashes, partitions and proposals are all switched on" {
    const options = stress_options(5, .none);
    try testing.expectEqual(@as(u64, 5), options.seed);
    try testing.expect(options.faults.crash_percent > 0);
    try testing.expect(options.faults.partition_percent > 0);
    try testing.expect(options.proposals.interval_ms_max > 0);
    const planted = stress_options(5, .lose_synced_hard_state);
    try testing.expectEqual(sim.Plant.lose_synced_hard_state, planted.plant);
}

test "run_sweep: honest seeds pass and the sweep is not vacuous" {
    const config: Config = .{
        .seed_first = 0,
        .seeds_count = 20,
        .plant = .none,
        .duration_ms = duration_ms_default,
    };
    const outcome = run_sweep(testing.io, testing.allocator, &config);
    const summary = switch (outcome) {
        .passed => |summary| summary,
        .failed => |report| {
            std.debug.print("seed {d}: {s}\n", .{ report.seed, @errorName(report.violation) });
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(u64, 20), summary.seeds);
    try testing.expect(summary.events > 0);
    try testing.expect(summary.crashes > 0);
    try testing.expect(summary.partitions > 0);
    try testing.expect(summary.proposed > 0);
    try testing.expect(summary.applied > 0);
}

test "run_sweep: a planted lost synced write fails with the seed named" {
    const config: Config = .{
        .seed_first = 1000,
        .seeds_count = 200,
        .plant = .lose_synced_hard_state,
        .duration_ms = duration_ms_default,
    };
    const outcome = run_sweep(testing.io, testing.allocator, &config);
    const report = switch (outcome) {
        .failed => |report| report,
        .passed => return error.TestUnexpectedResult,
    };
    try testing.expect(report.seed >= 1000);
    try testing.expect(report.seed < 1200);
    try testing.expectEqual(@as(sim.Error, error.ElectionSafety), report.violation);

    var buffer: [512]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try write_outcome(&out, &config, &outcome);
    var want: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&want, "FAIL seed={d} ", .{report.seed});
    try testing.expect(std.mem.find(u8, out.buffered(), needle) != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "-Dseed=") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "-Dplant=lose_synced_hard_state") != null);
}

test "run_sweep: one window run twice gives the same summary" {
    const config: Config = .{
        .seed_first = 77,
        .seeds_count = 5,
        .plant = .none,
        .duration_ms = duration_ms_default,
    };
    const first = run_sweep(testing.io, testing.allocator, &config);
    const second = run_sweep(testing.io, testing.allocator, &config);
    try testing.expectEqual(first, second);
}

test "write_outcome: a green sweep prints the totals" {
    const config: Config = .{
        .seed_first = 0,
        .seeds_count = 3,
        .plant = .none,
        .duration_ms = duration_ms_default,
    };
    const outcome: Outcome = .{ .passed = .{
        .seeds = 3,
        .events = 9,
        .crashes = 1,
        .partitions = 2,
        .truncates = 3,
        .proposed = 4,
        .applied = 5,
    } };
    var buffer: [512]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try write_outcome(&out, &config, &outcome);
    try testing.expect(std.mem.find(u8, out.buffered(), "ok: 3 seeds [0, 3)") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "crashes=1") != null);
}
