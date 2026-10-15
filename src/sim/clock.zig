//! synod.sim.clock — the simulator's virtual clock (ADR-008, "Clock"): one shared, forward-only
//! millisecond counter that every node reads through `interfaces.Clock`.
//!
//! Allocation: none. Time moves only through `advance_to`; nothing here reads a wall clock.

const std = @import("std");
const assert = std.debug.assert;
const interfaces = @import("../interfaces.zig");

pub const VirtualClock = struct {
    time_ms: u64,

    pub fn init(start_ms: u64) VirtualClock {
        return .{ .time_ms = start_ms };
    }

    pub fn now_ms(virtual_clock: *VirtualClock) u64 {
        return virtual_clock.time_ms;
    }

    /// Precondition: `time_ms >= now_ms()` (time never runs backwards).
    pub fn advance_to(virtual_clock: *VirtualClock, time_ms: u64) void {
        const before_ms = virtual_clock.time_ms;
        assert(time_ms >= before_ms);
        virtual_clock.time_ms = time_ms;
        assert(virtual_clock.time_ms >= before_ms);
    }

    pub fn as_clock(virtual_clock: *VirtualClock) interfaces.Clock {
        return interfaces.Clock.init(virtual_clock);
    }
};
