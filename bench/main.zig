//! synod benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  ops/s  ns/op` so results can be pasted into
//! docs/plans/000-inherited.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const synod = @import("synod");

const Bench = struct { name: []const u8, run: *const fn (Io, std.mem.Allocator) anyerror!u64 };

fn noop(_: Io, _: std.mem.Allocator) !u64 {
    return 1;
}

/// Scenarios `sim_cluster_5_nodes_10s` runs, one seed each; `ns/op` is the mean time of one.
const sim_runs_count: u64 = 11;

/// PRD §5: a 5-node cluster over 10 s of virtual time (healthy network, a proposal every
/// 100 ms at most), target under 50 ms per scenario. Returns the scenarios run.
fn sim_cluster_5_nodes_10s(io: Io, gpa: std.mem.Allocator) !u64 {
    var report: synod.sim.Report = undefined;
    for (0..sim_runs_count) |seed| {
        var options = synod.sim.Options.quiet(seed, 5);
        options.proposals = .{ .interval_ms_max = 100, .data_bytes = 2 };
        const stats = try synod.sim.run_seed(io, gpa, &options, 10_000, &report);
        assert(stats.events > 0);
        assert(stats.applied > 0);
    }
    return sim_runs_count;
}

const benches = [_]Bench{
    .{ .name = "noop", .run = noop },
    .{ .name = "sim_cluster_5_nodes_10s", .run = sim_cluster_5_nodes_10s },
};

fn matches_filter(name: []const u8, filter: ?[]const u8) bool {
    assert(name.len > 0);
    const f = filter orelse return true;
    const idx = std.mem.find(u8, name, f);
    if (idx) |i| assert(i + f.len <= name.len);
    return idx != null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    assert(args.len >= 1);
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    for (benches) |b| {
        if (!matches_filter(b.name, filter)) continue;
        const start = Io.Clock.Timestamp.now(init.io, .awake);
        const ops = try b.run(init.io, gpa);
        const elapsed = start.untilNow(init.io);
        assert(elapsed.raw.nanoseconds >= 0);
        const ns: u64 = @intCast(@max(elapsed.raw.nanoseconds, 0));
        const ns_per_op = if (ops == 0) 0 else ns / ops;
        if (ops == 0) assert(ns_per_op == 0);
        const ops_per_s = if (ns == 0) 0 else ops * std.time.ns_per_s / ns;
        try out.print("{s:<32} {d:>12} ops/s {d:>10} ns/op\n", .{ b.name, ops_per_s, ns_per_op });
    }
}

test "matches_filter: no filter matches every benchmark" {
    try std.testing.expect(matches_filter("noop", null));
}

test "matches_filter: substring filter matches" {
    try std.testing.expect(matches_filter("noop", "no"));
}

test "matches_filter: non-matching filter excludes the benchmark" {
    try std.testing.expect(!matches_filter("noop", "xyz"));
}

test "matches_filter: empty-string filter matches everything" {
    try std.testing.expect(matches_filter("noop", ""));
}
