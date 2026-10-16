//! synod.sim — Deterministic simulation: virtual clock, virtual network (delay, loss,
//! partition, reorder), scenarios, Raft safety invariants, linearizability checker.
//!
//! Files (see docs/adr/0008-simulator-contract.md and docs/plans/004-phase3-simulation-harness.md):
//!   - `sim/prng.zig`, `sim/clock.zig`, `sim/network.zig`: plan 004 item 2 (landed)
//!   - `sim/invariants.zig`: plan 004 item 3 (landed)
//!   - `sim/simulation.zig`: plan 004 item 4 (event loop; landed)
//!   - `sim/crash_store.zig`, `sim/linearizability.zig`, `sim/workload.zig`: planned
//!
//! Status: partial. Public declarations are added as plan 004 items land.

const std = @import("std");

pub const prng = @import("sim/prng.zig");
pub const clock = @import("sim/clock.zig");
pub const network = @import("sim/network.zig");
pub const invariants = @import("sim/invariants.zig");
pub const simulation = @import("sim/simulation.zig");
pub const Prng = prng.Prng;
pub const VirtualClock = clock.VirtualClock;
pub const Network = network.Network;
pub const Checker = invariants.Checker;
pub const Simulation = simulation.Simulation;
pub const Options = simulation.Options;
pub const Report = simulation.Report;
pub const Stats = simulation.Stats;
pub const Plant = simulation.Plant;
pub const run_seed = simulation.run_seed;

/// Everything a simulation run can return: safety violations, harness limits, node errors.
pub const Error = simulation.Error;

test "sim: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    // The tests of plan 004 item 2 live beside their files and are pulled in here.
    _ = @import("sim/prng_test.zig");
    _ = @import("sim/clock_test.zig");
    _ = @import("sim/network_test.zig");
    _ = @import("sim/network_model_test.zig");
    // Plan 004 item 3: the invariant checker.
    _ = @import("sim/invariants_test.zig");
    _ = @import("sim/invariants_model_test.zig");
    // Plan 004 item 4: the event loop.
    _ = @import("sim/simulation_test.zig");
    _ = @import("sim/simulation_model_test.zig");
}
