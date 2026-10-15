//! synod.sim — Deterministic simulation: virtual clock, virtual network (delay, loss,
//! partition, reorder), scenarios, Raft safety invariants, linearizability checker.
//!
//! Files (see docs/adr/0008-simulator-contract.md and docs/plans/004-phase3-simulation-harness.md):
//!   - `sim/prng.zig`, `sim/clock.zig`, `sim/network.zig`: plan 004 item 2 (stubs until the
//!     zig-developer lands them; their tests are red by design)
//!   - `sim/crash_store.zig`, `sim/invariants.zig`, `sim/linearizability.zig`,
//!     `sim/workload.zig`, `sim/simulation.zig`: planned
//!
//! Status: stub. Public declarations are added as plan 004 items land.

const std = @import("std");

pub const prng = @import("sim/prng.zig");
pub const clock = @import("sim/clock.zig");
pub const network = @import("sim/network.zig");
pub const Prng = prng.Prng;
pub const VirtualClock = clock.VirtualClock;
pub const Network = network.Network;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "sim: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    // The tests of plan 004 item 2 live beside their files and are pulled in here.
    _ = @import("sim/prng_test.zig");
    _ = @import("sim/clock_test.zig");
    _ = @import("sim/network_test.zig");
    _ = @import("sim/network_model_test.zig");
}
