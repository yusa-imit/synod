//! synod.sim.clock — the simulator's virtual clock (ADR-008, "Clock"): one shared, forward-only
//! millisecond counter that every node reads through `interfaces.Clock`.
//!
//! STUB (plan 004 item 2, Red step): returns deliberately wrong values so the tests in
//! `clock_test.zig` fail until the zig-developer implements the contract.
//!
//! Allocation: none. Time moves only through `advance_to`; nothing here reads a wall clock.

const interfaces = @import("../interfaces.zig");

pub const VirtualClock = struct {
    time_ms: u64,

    pub fn init(start_ms: u64) VirtualClock {
        _ = start_ms;
        return .{ .time_ms = 0 };
    }

    pub fn now_ms(virtual_clock: *VirtualClock) u64 {
        _ = virtual_clock;
        return 0;
    }

    /// Precondition: `time_ms >= now_ms()` (time never runs backwards).
    pub fn advance_to(virtual_clock: *VirtualClock, time_ms: u64) void {
        _ = .{ virtual_clock, time_ms };
    }

    pub fn as_clock(virtual_clock: *VirtualClock) interfaces.Clock {
        return interfaces.Clock.init(virtual_clock);
    }
};
