//! synod.adapters — Opt-in adapters: sirocco Transport, strata LogStore.
//!
//! Planned files (see docs/PRD.md):
//!   - `adapters/sirocco_transport.zig`
//!   - `adapters/strata_logstore.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "adapters: module compiles" {
    std.testing.refAllDecls(@This());
}
