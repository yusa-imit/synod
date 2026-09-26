//! synod — The council where nodes reach consensus — Raft, membership, and failure detection
//! for Zig
//!
//! Library root. Consumers `@import("synod")` and reach modules as
//! `synod.<module>`. Every module is independent; import only what you use.
//!
//! See docs/PRD.md for the full design and docs/plans/000-inherited.md for progress.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");

/// Library version, parsed at comptime from the `build.zig.zon` manifest so the two cannot drift.
pub const version = std.SemanticVersion.parse(build_options.version) catch
    @compileError("build.zig.zon `.version` is not a valid semantic version");

pub const types = @import("types.zig");
pub const interfaces = @import("interfaces.zig");
pub const log = @import("log.zig");
pub const raft = @import("raft.zig");
pub const driver = @import("driver.zig");
pub const membership = @import("membership.zig");
pub const detector = @import("detector.zig");
pub const clock = @import("clock.zig");
pub const store = @import("store.zig");
pub const sim = @import("sim.zig");
pub const adapters = @import("adapters.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version: matches the manifest string byte for byte" {
    var buffer: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{f}", .{version});
    try std.testing.expectEqualStrings(build_options.version, rendered);
    assert(build_options.version.len > 0);
}
