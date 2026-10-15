//! synod.sim.prng — the simulator's seeded randomness: `derive_seed` splits one root seed into
//! per-concern streams and `Prng` is a SplitMix64 generator (ADR-008, "Seeds").
//!
//! Allocation: none. Determinism: a stream is a function of `(root, stream, lane)` only.
//! Bias: `uint_less_than` is multiply-high with no rejection loop, so it is exactly one draw
//! and always terminates; its bias is below `bound / 2^64`, far under any seed count here.

const std = @import("std");
const assert = std.debug.assert;
const interfaces = @import("../interfaces.zig");

/// One independent random stream per concern; a draw in one never moves another.
pub const Stream = enum(u8) { network = 1, faults = 2, workload = 3, node = 4 };

/// SplitMix64's increment. Odd, so the state visits all 2^64 values before repeating.
const golden_gamma: u64 = 0x9e3779b97f4a7c15;

comptime {
    assert(golden_gamma & 1 == 1);
}

/// The SplitMix64 finalizer: a bijection on `u64`.
fn mix64(value: u64) u64 {
    var mixed = value;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    mixed ^= mixed >> 31;
    return mixed;
}

/// The seed of stream `stream`, lane `lane`, under `root_seed`:
/// `mix64(root ^ mix64((stream << 32) | lane))`.
pub fn derive_seed(root_seed: u64, stream: Stream, lane: u32) u64 {
    const stream_word: u64 = @intFromEnum(stream);
    return mix64(root_seed ^ mix64((stream_word << 32) | lane));
}

/// SplitMix64.
pub const Prng = struct {
    state: u64,

    pub fn init(seed: u64) Prng {
        return .{ .state = seed };
    }

    pub fn next_u64(prng: *Prng) u64 {
        const before = prng.state;
        prng.state +%= golden_gamma;
        assert(prng.state != before); // The odd increment never leaves the state fixed.
        return mix64(prng.state);
    }

    /// A value in `[0, bound)` from exactly one draw (multiply-high). Precondition: bound > 0.
    pub fn uint_less_than(prng: *Prng, bound: u64) u64 {
        assert(bound > 0);
        const product = @as(u128, prng.next_u64()) * @as(u128, bound);
        const result: u64 = @intCast(product >> 64);
        assert(result < bound);
        return result;
    }

    /// True with probability `percent / 100`, from exactly one draw. Precondition: <= 100.
    pub fn chance(prng: *Prng, percent: u8) bool {
        assert(percent <= 100);
        const roll = prng.uint_less_than(100);
        assert(roll < 100);
        return roll < percent;
    }

    pub fn as_rng(prng: *Prng) interfaces.Rng {
        return interfaces.Rng.init(prng);
    }
};
