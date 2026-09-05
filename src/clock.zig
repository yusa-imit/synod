//! synod.clock — Hybrid logical clock, Lamport clock, monotonic Clock interface.
//!
//! Planned files (see docs/PRD.md):
//!   - `clock/hlc.zig`
//!   - `clock/lamport.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "clock: module compiles" {
    std.testing.refAllDecls(@This());
}
