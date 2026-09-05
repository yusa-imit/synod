//! synod.sim — Deterministic simulation: virtual clock, virtual network (delay, loss, partition, reorder), scenarios, Raft safety invariants, linearizability checker.
//!
//! Planned files (see docs/PRD.md):
//!   - `sim/clock.zig`
//!   - `sim/network.zig`
//!   - `sim/simulation.zig`
//!   - `sim/invariants.zig`
//!   - `sim/linearizability.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "sim: module compiles" {
    std.testing.refAllDecls(@This());
}
