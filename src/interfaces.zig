//! synod.interfaces — Transport, LogStore, StateMachine, Clock, Rng vtables.
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

test "interfaces: module compiles" {
    std.testing.refAllDecls(@This());
}
