//! Tests for `sim/clock.zig` (ADR-008, "Clock"). A backwards `advance_to` is a caller-contract
//! assert, so only the forward and equal cases are exercised here.

const std = @import("std");
const testing = std.testing;
const clock_module = @import("clock.zig");

const VirtualClock = clock_module.VirtualClock;

test "clock: starts at the requested millisecond" {
    var clock = VirtualClock.init(1000);
    try testing.expectEqual(@as(u64, 1000), clock.time_ms);
    try testing.expectEqual(@as(u64, 1000), clock.now_ms());
}

test "clock: starting at zero and at the u64 limit both read back exactly" {
    var zero = VirtualClock.init(0);
    try testing.expectEqual(@as(u64, 0), zero.now_ms());
    var top = VirtualClock.init(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), top.now_ms());
}

test "clock: advance_to moves time forward to the exact target" {
    var clock = VirtualClock.init(10);
    clock.advance_to(11);
    try testing.expectEqual(@as(u64, 11), clock.now_ms());
    clock.advance_to(5_000);
    try testing.expectEqual(@as(u64, 5_000), clock.now_ms());
    try testing.expectEqual(@as(u64, 5_000), clock.time_ms);
}

test "clock: advance_to the current time is a no-op" {
    var clock = VirtualClock.init(42);
    clock.advance_to(42);
    try testing.expectEqual(@as(u64, 42), clock.now_ms());
    clock.advance_to(43);
    clock.advance_to(43);
    try testing.expectEqual(@as(u64, 43), clock.now_ms());
}

test "clock: time does not move on its own between reads" {
    var clock = VirtualClock.init(7);
    const first = clock.now_ms();
    try testing.expectEqual(@as(u64, 7), first);
    for (0..100) |_| try testing.expectEqual(first, clock.now_ms());
}

test "clock: the Clock vtable reads the same time as the virtual clock" {
    var clock = VirtualClock.init(250);
    const view = clock.as_clock();
    try testing.expectEqual(@as(u64, 250), view.now_ms());
    clock.advance_to(900);
    try testing.expectEqual(@as(u64, 900), view.now_ms());
}

test "clock: every Clock built from one virtual clock shares its time" {
    var clock = VirtualClock.init(1);
    const a = clock.as_clock();
    const b = clock.as_clock();
    clock.advance_to(77);
    try testing.expectEqual(@as(u64, 77), a.now_ms());
    try testing.expectEqual(a.now_ms(), b.now_ms());
}

test "clock: readings through the vtable are non-decreasing across advances" {
    var clock = VirtualClock.init(0);
    const view = clock.as_clock();
    var last = view.now_ms();
    var target: u64 = 0;
    for (0..50) |step| {
        target += step % 3; // 0, 1 or 2: equal advances included.
        clock.advance_to(target);
        const now = view.now_ms();
        try testing.expect(now >= last);
        try testing.expectEqual(target, now);
        last = now;
    }
}
