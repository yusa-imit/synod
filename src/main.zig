//! Minimal CLI: `synod version` / `synod --help`.
//! Diagnostic subcommands are added as modules land (see docs/PRD.md).

const std = @import("std");
const synod = @import("synod");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "--help";
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
