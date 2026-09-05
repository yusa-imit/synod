//! synod.membership — SWIM gossip protocol: ping, ping-req, suspicion, incarnation numbers.
//!
//! Planned files (see docs/PRD.md):
//!   - `membership/swim.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "membership: module compiles" {
    std.testing.refAllDecls(@This());
}
