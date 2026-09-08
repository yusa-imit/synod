//! Minimal CLI: `synod version` / `synod --help`.
//! Diagnostic subcommands are added as modules land (see docs/PRD.md).

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const synod = @import("synod");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    assert(args.len >= 1);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "--help";
    assert(cmd.len > 0);
    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("synod {f}\n", .{synod.version});
    } else {
        try out.print(
            \\synod — The council where nodes reach consensus — Raft, membership, and failure
            \\detection for Zig
            \\
            \\usage: synod <command>
            \\  version    print library version
            \\  --help     this text
            \\
        , .{});
    }
}

test "cli: version is exposed" {
    try std.testing.expectEqual(@as(u32, 0), synod.version.major);
}
