//! synod.detector — φ-accrual failure detector.
//!
//! Planned files (see docs/PRD.md):
//!   - `detector/phi_accrual.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "detector: module compiles" {
    std.testing.refAllDecls(@This());
}
