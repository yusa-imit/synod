//! synod benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  ops/s  ns/op` so results can be pasted into
//! docs/plans/000-inherited.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const synod = @import("synod");

const Bench = struct { name: []const u8, run: *const fn (std.mem.Allocator) anyerror!u64 };

fn noop(_: std.mem.Allocator) !u64 {
    return 1;
}

const benches = [_]Bench{
    .{ .name = "noop", .run = noop },
};

fn matchesFilter(name: []const u8, filter: ?[]const u8) bool {
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
        if (!matchesFilter(b.name, filter)) continue;
        const start = Io.Clock.Timestamp.now(init.io, .awake);
        const ops = try b.run(gpa);
        const elapsed = start.untilNow(init.io);
        assert(elapsed.raw.nanoseconds >= 0);
        const ns: u64 = @intCast(@max(elapsed.raw.nanoseconds, 0));
        const ns_per_op = if (ops == 0) 0 else ns / ops;
        if (ops == 0) assert(ns_per_op == 0);
        const ops_per_s = if (ns == 0) 0 else ops * std.time.ns_per_s / ns;
        try out.print("{s:<32} {d:>12} ops/s {d:>10} ns/op\n", .{ b.name, ops_per_s, ns_per_op });
    }
}

test "matchesFilter: no filter matches every benchmark" {
    try std.testing.expect(matchesFilter("noop", null));
}

test "matchesFilter: substring filter matches" {
    try std.testing.expect(matchesFilter("noop", "no"));
}

test "matchesFilter: non-matching filter excludes the benchmark" {
    try std.testing.expect(!matchesFilter("noop", "xyz"));
}

test "matchesFilter: empty-string filter matches everything" {
    try std.testing.expect(matchesFilter("noop", ""));
}
