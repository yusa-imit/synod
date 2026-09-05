//! synod.log — In-memory Raft log with append/truncate/term lookup and invariant validation.
//!
//! Planned files (see docs/PRD.md):
//!   (single-file module)
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "log: module compiles" {
    std.testing.refAllDecls(@This());
}
