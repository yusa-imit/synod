//! synod.sim.prng — the simulator's seeded randomness: `derive_seed` splits one root seed into
//! per-concern streams and `Prng` is a SplitMix64 generator (ADR-008, "Seeds").
//!
//! STUB (plan 004 item 2, Red step): every function returns a deliberately wrong value so the
//! tests in `prng_test.zig` fail until the zig-developer implements the contract.
//!
//! Allocation: none. Determinism: a stream is a function of `(root, stream, lane)` only.

const std = @import("std");
const interfaces = @import("../interfaces.zig");

/// One independent random stream per concern; a draw in one never moves another.
pub const Stream = enum(u8) { network = 1, faults = 2, workload = 3, node = 4 };

/// The seed of stream `stream`, lane `lane`, under `root_seed`.
pub fn derive_seed(root_seed: u64, stream: Stream, lane: u32) u64 {
    _ = .{ root_seed, stream, lane };
    return 0;
}

/// SplitMix64.
pub const Prng = struct {
    state: u64,

    pub fn init(seed: u64) Prng {
        _ = seed;
        return .{ .state = 0 };
    }

    pub fn next_u64(prng: *Prng) u64 {
        _ = prng;
        return 0;
    }

    /// A value in `[0, bound)` from exactly one draw (multiply-high). Precondition: bound > 0.
    pub fn uint_less_than(prng: *Prng, bound: u64) u64 {
        _ = .{ prng, bound };
        return 0;
    }

    /// True with probability `percent / 100`, from exactly one draw. Precondition: <= 100.
    pub fn chance(prng: *Prng, percent: u8) bool {
        _ = .{ prng, percent };
        return false;
    }

    pub fn as_rng(prng: *Prng) interfaces.Rng {
        return interfaces.Rng.init(prng);
    }
};
