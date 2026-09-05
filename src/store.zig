//! synod.store — In-memory LogStore for tests and simulation.
//!
//! Planned files (see docs/PRD.md):
//!   - `store/memory.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "store: module compiles" {
    std.testing.refAllDecls(@This());
}
