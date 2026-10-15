//! Tests for `sim/network.zig` (ADR-008, "Network"; plan 004 item 2): delivery timing, ordering,
//! loss, duplication, the full-table drop, partitions, planted faults, ownership of copies,
//! allocation discipline, the trace hash and `check_invariants`. The seeded model-based tests
//! live in `network_model_test.zig`. Every network is built by `fixture`/`fixture_options`.
//!
//! Pinned where the ADR is silent (the zig-developer may amend the ADR in the same PR):
//! `pop_due` consumes a message that is cut at delivery and goes on to the next due one, so it
//! returns null only when nothing deliverable is due; `drop_down` reclassifies the delivery
//! the last `pop_due` returned (`delivered - 1`, `dropped_down + 1`) so the conservation
//! identity holds; a duplicate is re-armed once and is not itself duplicated.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const fx = @import("fixtures.zig");
const network_module = @import("network.zig");

const Network = network_module.Network;
const Rig = fx.Rig;
const Message = types.Message;

fn fixture(rig: *Rig, model: Network.Model, seed: u64) !void {
    try fixture_options(rig, fx.options_of(3, model, .none), seed);
}

fn fixture_options(rig: *Rig, options: Network.Options, seed: u64) !void {
    try rig.init(testing.allocator, options, seed);
}

fn with_model(delay_min: u32, delay_max: u32, loss: u8, duplicate: u8) Network.Model {
    var model = fx.base_model;
    model.delay_ms_min = delay_min;
    model.delay_ms_max = delay_max;
    model.loss_percent = loss;
    model.duplicate_percent = duplicate;
    return model;
}

const Want = struct {
    sent: u64 = 0,
    delivered: u64 = 0,
    duplicated: u64 = 0,
    dropped_loss: u64 = 0,
    dropped_full: u64 = 0,
    dropped_cut: u64 = 0,
    dropped_down: u64 = 0,
};

fn expect_stats(network: *const Network, want: Want) !void {
    const got = network.stats();
    try testing.expectEqual(want.sent, got.sent);
    try testing.expectEqual(want.delivered, got.delivered);
    try testing.expectEqual(want.duplicated, got.duplicated);
    try testing.expectEqual(want.dropped_loss, got.dropped_loss);
    try testing.expectEqual(want.dropped_full, got.dropped_full);
    try testing.expectEqual(want.dropped_cut, got.dropped_cut);
    try testing.expectEqual(want.dropped_down, got.dropped_down);
}

/// Drains the network, requiring every delivery to equal `expected`; returns the count.
fn drain_equal(rig: *Rig, expected: *const Message) !u32 {
    var count: u32 = 0;
    var rounds: u32 = 0;
    while (rig.network.next_due_ms()) |due| {
        rounds += 1;
        try testing.expect(rounds < 1000);
        if (due > rig.clock.time_ms) rig.clock.advance_to(due);
        while (rig.network.pop_due()) |message| {
            try testing.expect(fx.message_eql(expected, message));
            count += 1;
        }
    }
    return count;
}

fn drain_terms(rig: *Rig, out: []u64) ![]const u64 {
    var seen: [64]fx.Seen = undefined;
    const deliveries = try fx.drain(rig, &seen);
    try testing.expect(deliveries.len <= out.len);
    for (deliveries, 0..) |delivery, i| out[i] = delivery.term;
    return out[0..deliveries.len];
}

// -- Fresh state and positive delivery ----------------------------------------------------

test "network: a fresh network is empty, balanced and reachable in both directions" {
    for ([_]u8{ 2, 3, 5, 7 }) |nodes_count| {
        var rig: Rig = undefined;
        try fixture_options(&rig, fx.options_of(nodes_count, fx.base_model, .none), 1);
        defer rig.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
        try testing.expectEqual(@as(?u64, null), rig.network.next_due_ms());
        try testing.expect(rig.network.pop_due() == null);
        try expect_stats(&rig.network, .{});
        try rig.network.check_invariants();
        for (0..nodes_count) |from| {
            for (0..nodes_count) |to| {
                if (from == to) continue;
                try testing.expect(rig.network.reachable(fx.link_of(from, to)));
            }
        }
    }
}

test "network: a message is not delivered before its due time and is delivered at it" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const sent = fx.vote(1, 2, 3);
    rig.network.send(&sent);
    try testing.expectEqual(@as(u32, 1), rig.network.in_flight());
    try testing.expectEqual(@as(?u64, fx.start_ms + 5), rig.network.next_due_ms());
    try testing.expect(rig.network.pop_due() == null);
    rig.advance(4);
    try testing.expect(rig.network.pop_due() == null);
    try expect_stats(&rig.network, .{ .sent = 1 });
    rig.advance(1);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(fx.message_eql(&sent, got));
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
    try testing.expectEqual(@as(?u64, null), rig.network.next_due_ms());
    try testing.expect(rig.network.pop_due() == null);
    try expect_stats(&rig.network, .{ .sent = 1, .delivered = 1 });
    try rig.network.check_invariants();
}

test "network: a message waiting past its due time is still delivered" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const sent = fx.vote(2, 3, 9);
    rig.network.send(&sent);
    rig.advance(5_000);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(fx.message_eql(&sent, got));
}

test "network: delivery happens exactly delay_ms after the send for fixed delays" {
    for ([_]u32{ 1, 5, 250, 60_000 }) |delay| {
        var rig: Rig = undefined;
        try fixture(&rig, with_model(delay, delay, 0, 0), delay);
        defer rig.deinit(testing.allocator);
        const sent = fx.vote(1, 3, 1);
        rig.network.send(&sent);
        try testing.expectEqual(@as(?u64, fx.start_ms + delay), rig.network.next_due_ms());
        var seen: [4]fx.Seen = undefined;
        const deliveries = try fx.drain(&rig, &seen);
        try testing.expectEqual(@as(usize, 1), deliveries.len);
        try testing.expectEqual(fx.start_ms + delay, deliveries[0].at_ms);
    }
}

test "network: the delivered message equals the sent one, entry bytes included" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const entries = [_]types.Entry{
        fx.entry_of(12, 4, "abc"),
        fx.entry_of(13, 4, ""),
        fx.entry_of(14, 5, "0123456789abcdef"),
    };
    const sent = fx.append(1, 2, 5, &entries);
    rig.network.send(&sent);
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(fx.message_eql(&sent, got));
    const head = got.header();
    try testing.expectEqual(@as(u64, 1), @intFromEnum(head.from));
    try testing.expectEqual(@as(u64, 2), @intFromEnum(head.to));
    try testing.expectEqual(@as(u64, 5), @intFromEnum(head.term));
    try testing.expectEqual(@as(usize, 3), got.append_entries.entries.len);
    try testing.expectEqualStrings("0123456789abcdef", got.append_entries.entries[2].data);
}

test "network: the network owns a copy, so mutating or freeing the source changes nothing" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    var bytes = [_]u8{ 'x', 'y', 'z', 'w' };
    var entries = [_]types.Entry{ fx.entry_of(1, 1, bytes[0..2]), fx.entry_of(2, 1, bytes[2..4]) };
    var sent = fx.append(1, 2, 1, &entries);
    rig.network.send(&sent);
    @memset(&bytes, 0xAA);
    entries[0] = fx.entry_of(99, 99, "");
    sent = fx.vote(3, 1, 77);
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(got.* == .append_entries);
    try testing.expectEqualStrings("xy", got.append_entries.entries[0].data);
    try testing.expectEqualStrings("zw", got.append_entries.entries[1].data);
    try testing.expectEqual(@as(u64, 1), @intFromEnum(got.append_entries.entries[0].index));
    try testing.expectEqual(@as(u64, 1), @intFromEnum(got.header().term));
}

test "network: a message at the entries and entry-bytes limits survives intact" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    var bytes: [fx.entries_max][fx.entry_bytes_max]u8 = undefined;
    var entries: [fx.entries_max]types.Entry = undefined;
    for (&entries, &bytes, 0..) |*entry, *data, k| {
        @memset(data, @intCast(0x10 + k));
        entry.* = fx.entry_of(k + 1, 2, data);
    }
    const sent = fx.append(2, 3, 2, &entries);
    rig.network.send(&sent);
    try testing.expectEqual(@as(u32, 1), try drain_equal(&rig, &sent));
}

test "network: an append with no entries is delivered with no entries" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const sent = fx.append(3, 1, 2, &.{});
    rig.network.send(&sent);
    try testing.expectEqual(@as(u32, 1), try drain_equal(&rig, &sent));
}

test "network: as_transport sends through the Transport vtable like a direct send" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const transport = rig.network.as_transport();
    const sent = fx.vote_response(2, 1, 4, true);
    transport.send(&sent);
    try testing.expectEqual(@as(u32, 1), rig.network.in_flight());
    try expect_stats(&rig.network, .{ .sent = 1 });
    try testing.expectEqual(@as(u32, 1), try drain_equal(&rig, &sent));
}

// -- Ordering, delay and reorder ----------------------------------------------------------

test "network: equal due times deliver in send order" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    for (1..6) |term| rig.network.send(&fx.vote(1, 2, term));
    var terms: [8]u64 = undefined;
    const order = try drain_terms(&rig, &terms);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, order);
}

test "network: next_due_ms is the earliest due time and advances as messages leave" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.send(&fx.vote(1, 2, 1)); // due start + 5
    rig.advance(2);
    rig.network.send(&fx.vote(2, 3, 2)); // due start + 7
    try testing.expectEqual(@as(?u64, fx.start_ms + 5), rig.network.next_due_ms());
    rig.advance(3);
    const first = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1), @intFromEnum(first.header().term));
    try testing.expect(rig.network.pop_due() == null);
    try testing.expectEqual(@as(?u64, fx.start_ms + 7), rig.network.next_due_ms());
}

test "network: a later send with a shorter delay is delivered first" {
    // Delays are seeded in [1, 100], so some seed reorders two back-to-back sends.
    var reordered: u32 = 0;
    var in_order: u32 = 0;
    for (0..64) |seed| {
        var rig: Rig = undefined;
        try fixture(&rig, with_model(1, 100, 0, 0), seed);
        defer rig.deinit(testing.allocator);
        rig.network.send(&fx.vote(1, 2, 1));
        rig.network.send(&fx.vote(1, 2, 2));
        var terms: [4]u64 = undefined;
        const order = try drain_terms(&rig, &terms);
        try testing.expectEqual(@as(usize, 2), order.len);
        if (order[0] == 2) reordered += 1 else in_order += 1;
    }
    try testing.expect(reordered > 0);
    try testing.expect(in_order > 0);
}

test "network: delivery times lie in the delay range, sorted, ties in send order" {
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    for (0..32) |seed| {
        var rig: Rig = undefined;
        try fixture(&rig, with_model(10, 14, 0, 0), seed);
        defer rig.deinit(testing.allocator);
        for (1..9) |term| rig.network.send(&fx.vote(1, 2, term));
        var seen: [16]fx.Seen = undefined;
        const deliveries = try fx.drain(&rig, &seen);
        try testing.expectEqual(@as(usize, 8), deliveries.len);
        for (deliveries, 0..) |delivery, i| {
            try testing.expect(delivery.at_ms >= fx.start_ms + 10);
            try testing.expect(delivery.at_ms <= fx.start_ms + 14);
            lowest = @min(lowest, delivery.at_ms);
            highest = @max(highest, delivery.at_ms);
            if (i == 0) continue;
            const before = deliveries[i - 1];
            try testing.expect(before.at_ms <= delivery.at_ms);
            if (before.at_ms == delivery.at_ms) try testing.expect(before.term < delivery.term);
        }
    }
    try testing.expectEqual(fx.start_ms + 10, lowest); // Both ends of the range are reachable.
    try testing.expectEqual(fx.start_ms + 14, highest);
}

// -- Loss and duplication -----------------------------------------------------------------

test "network: loss_percent 100 drops every message at send and counts dropped_loss" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(5, 5, 100, 0), 1);
    defer rig.deinit(testing.allocator);
    for (1..6) |term| rig.network.send(&fx.vote(1, 2, term));
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
    try testing.expectEqual(@as(?u64, null), rig.network.next_due_ms());
    rig.advance(1000);
    try testing.expect(rig.network.pop_due() == null);
    try expect_stats(&rig.network, .{ .sent = 5, .dropped_loss = 5 });
    try rig.network.check_invariants();
}

test "network: loss_percent 0 loses nothing" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(1, 9, 0, 0), 7);
    defer rig.deinit(testing.allocator);
    for (1..9) |term| rig.network.send(&fx.vote(1, 2, term));
    var terms: [16]u64 = undefined;
    try testing.expectEqual(@as(usize, 8), (try drain_terms(&rig, &terms)).len);
    try expect_stats(&rig.network, .{ .sent = 8, .delivered = 8 });
}

test "network: loss_percent 50 loses about half of 400 messages" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(1, 3, 50, 0), 11);
    defer rig.deinit(testing.allocator);
    var delivered: u32 = 0;
    for (0..400) |term| {
        rig.network.send(&fx.vote(1, 2, term + 1));
        var seen: [4]fx.Seen = undefined;
        delivered += @intCast((try fx.drain(&rig, &seen)).len);
    }
    try testing.expect(delivered > 140 and delivered < 260);
    const stats = rig.network.stats();
    try testing.expectEqual(@as(u64, 400), stats.sent);
    try testing.expectEqual(@as(u64, delivered), stats.delivered);
    try testing.expectEqual(@as(u64, 400 - delivered), stats.dropped_loss);
}

test "network: duplicate_percent 100 delivers the message exactly twice" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(5, 5, 0, 100), 1);
    defer rig.deinit(testing.allocator);
    const entries = [_]types.Entry{fx.entry_of(1, 1, "dup")};
    const sent = fx.append(1, 2, 1, &entries);
    rig.network.send(&sent);
    try testing.expectEqual(@as(u32, 2), try drain_equal(&rig, &sent));
    try expect_stats(&rig.network, .{ .sent = 1, .delivered = 2, .duplicated = 1 });
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
    try rig.network.check_invariants();
}

test "network: duplicate_percent 0 delivers each message exactly once" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(1, 6, 0, 0), 5);
    defer rig.deinit(testing.allocator);
    for (1..9) |term| rig.network.send(&fx.vote(1, 3, term));
    var terms: [16]u64 = undefined;
    const order = try drain_terms(&rig, &terms);
    try testing.expectEqual(@as(usize, 8), order.len);
    try expect_stats(&rig.network, .{ .sent = 8, .delivered = 8 });
}

test "network: a full table with duplicate_percent 100 never exceeds messages_max" {
    var model = with_model(5, 5, 0, 100);
    model.messages_max = 4;
    var rig: Rig = undefined;
    try fixture(&rig, model, 1);
    defer rig.deinit(testing.allocator);
    for (1..5) |term| rig.network.send(&fx.vote(1, 2, term));
    try testing.expectEqual(@as(u32, 4), rig.network.in_flight());
    rig.advance(5);
    while (rig.network.pop_due()) |_| {
        try testing.expect(rig.network.in_flight() <= 4);
        try rig.network.check_invariants();
    }
    var seen: [16]fx.Seen = undefined;
    _ = try fx.drain(&rig, &seen);
    try expect_stats(&rig.network, .{ .sent = 4, .delivered = 8, .duplicated = 4 });
}

test "network: duplicate_percent 50 duplicates about half of 400 deliveries" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(1, 3, 0, 50), 13);
    defer rig.deinit(testing.allocator);
    for (0..400) |term| {
        rig.network.send(&fx.vote(2, 1, term + 1));
        var seen: [4]fx.Seen = undefined;
        _ = try fx.drain(&rig, &seen);
    }
    const stats = rig.network.stats();
    try testing.expect(stats.duplicated > 140 and stats.duplicated < 260);
    try testing.expectEqual(@as(u64, 400) + stats.duplicated, stats.delivered);
}

// -- The full table -----------------------------------------------------------------------

test "network: a full table drops the new message, counts dropped_full, keeps the old" {
    var model = fx.base_model;
    model.messages_max = 4;
    var rig: Rig = undefined;
    try fixture(&rig, model, 1);
    defer rig.deinit(testing.allocator);
    for (1..7) |term| rig.network.send(&fx.vote(1, 2, term));
    try testing.expectEqual(@as(u32, 4), rig.network.in_flight());
    try expect_stats(&rig.network, .{ .sent = 6, .dropped_full = 2 });
    var terms: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, try drain_terms(&rig, &terms));
    try expect_stats(&rig.network, .{ .sent = 6, .delivered = 4, .dropped_full = 2 });
    try rig.network.check_invariants();
}

test "network: exactly messages_max messages fit and messages_max plus one does not" {
    for ([_]u32{ 1, 2, 5, 16 }) |messages_max| {
        var model = fx.base_model;
        model.messages_max = messages_max;
        var rig: Rig = undefined;
        try fixture(&rig, model, 1);
        defer rig.deinit(testing.allocator);
        for (0..messages_max) |term| rig.network.send(&fx.vote(1, 2, term + 1));
        try testing.expectEqual(messages_max, rig.network.in_flight());
        try expect_stats(&rig.network, .{ .sent = messages_max });
        rig.network.send(&fx.vote(1, 2, 99));
        try testing.expectEqual(messages_max, rig.network.in_flight());
        try expect_stats(&rig.network, .{ .sent = messages_max + 1, .dropped_full = 1 });
    }
}

test "network: a freed slot is reusable and a pop makes room for a new send" {
    var model = fx.base_model;
    model.messages_max = 2;
    var rig: Rig = undefined;
    try fixture(&rig, model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.send(&fx.vote(1, 2, 1));
    rig.network.send(&fx.vote(1, 2, 2));
    rig.advance(5);
    _ = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    rig.network.send(&fx.vote(1, 2, 3));
    try testing.expectEqual(@as(u32, 2), rig.network.in_flight());
    try expect_stats(&rig.network, .{ .sent = 3, .delivered = 1 });
    var terms: [4]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, try drain_terms(&rig, &terms));
}

test "network: a send during processing does not overwrite the borrowed delivery" {
    var model = fx.base_model;
    model.messages_max = 3;
    var rig: Rig = undefined;
    try fixture(&rig, model, 1);
    defer rig.deinit(testing.allocator);
    const entries = [_]types.Entry{ fx.entry_of(5, 2, "keep"), fx.entry_of(6, 2, "me") };
    const original = fx.append(1, 2, 2, &entries);
    rig.network.send(&original);
    rig.advance(5);
    const borrowed = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    const other = [_]types.Entry{fx.entry_of(1, 9, "ZZZZZZZZ")};
    for (0..6) |_| { // Fills the table and overflows it: every slot is touched.
        rig.network.send(&fx.append(2, 1, 9, &other));
        try testing.expect(fx.message_eql(&original, borrowed));
        try testing.expectEqual(@as(u64, 2), @intFromEnum(borrowed.header().term));
    }
    try testing.expectEqualStrings("keep", borrowed.append_entries.entries[0].data);
    try testing.expectEqualStrings("me", borrowed.append_entries.entries[1].data);
}

// -- Partitions ---------------------------------------------------------------------------

test "network: a cut link never delivers, one direction only, and heal restores it" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.cut(.{ .from_index = 0, .to_index = 1 });
    try testing.expect(!rig.network.reachable(.{ .from_index = 0, .to_index = 1 }));
    try testing.expect(rig.network.reachable(.{ .from_index = 1, .to_index = 0 }));
    try testing.expect(rig.network.reachable(.{ .from_index = 0, .to_index = 2 }));
    rig.network.send(&fx.vote(1, 2, 1)); // Cut: slot 0 to slot 1.
    rig.network.send(&fx.vote(2, 1, 2)); // The other direction.
    rig.network.send(&fx.vote(1, 3, 3)); // Another peer.
    try testing.expectEqual(@as(u32, 3), rig.network.in_flight()); // Cut is checked on delivery.
    try expect_stats(&rig.network, .{ .sent = 3 });
    var terms: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, try drain_terms(&rig, &terms));
    try expect_stats(&rig.network, .{ .sent = 3, .delivered = 2, .dropped_cut = 1 });
    try rig.network.check_invariants();
    rig.network.heal();
    try testing.expect(rig.network.reachable(.{ .from_index = 0, .to_index = 1 }));
    rig.network.send(&fx.vote(1, 2, 4));
    try testing.expectEqualSlices(u64, &.{4}, try drain_terms(&rig, &terms));
}

test "network: reachability is judged at delivery, not at send" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const link: Network.Link = .{ .from_index = 0, .to_index = 1 };
    rig.network.cut(link);
    rig.network.send(&fx.vote(1, 2, 1)); // Sent into a cut, healed before it lands.
    rig.advance(2);
    rig.network.heal();
    rig.advance(3);
    const landed = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1), @intFromEnum(landed.header().term));
    rig.network.send(&fx.vote(1, 2, 2)); // Sent while reachable, cut before it lands.
    rig.advance(2);
    rig.network.cut(link);
    rig.advance(3);
    try testing.expect(rig.network.pop_due() == null);
    try expect_stats(&rig.network, .{ .sent = 2, .delivered = 1, .dropped_cut = 1 });
}

test "network: pop_due skips a cut message and returns the next deliverable one" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.cut(.{ .from_index = 0, .to_index = 1 });
    rig.network.send(&fx.vote(1, 2, 1));
    rig.network.send(&fx.vote(1, 2, 2));
    rig.network.send(&fx.vote(1, 3, 3));
    rig.advance(5);
    const got = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 3), @intFromEnum(got.header().term));
    try testing.expect(rig.network.pop_due() == null);
    try expect_stats(&rig.network, .{ .sent = 3, .delivered = 1, .dropped_cut = 2 });
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
}

test "network: cutting twice is idempotent and one heal clears every cut" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.cut(.{ .from_index = 2, .to_index = 0 });
    rig.network.cut(.{ .from_index = 2, .to_index = 0 });
    rig.network.cut(.{ .from_index = 1, .to_index = 2 });
    rig.network.heal();
    for (0..3) |from| {
        for (0..3) |to| {
            if (from == to) continue;
            try testing.expect(rig.network.reachable(fx.link_of(from, to)));
        }
    }
    rig.network.heal(); // Healing a healed network is a no-op.
    try testing.expect(rig.network.reachable(.{ .from_index = 2, .to_index = 0 }));
}

test "network: set_partition cuts every cross link both ways and keeps each side connected" {
    var model = fx.base_model;
    model.messages_max = 32;
    var rig: Rig = undefined;
    try fixture_options(&rig, fx.options_of(5, model, .none), 1);
    defer rig.deinit(testing.allocator);
    const side_a = [_]u8{ 0, 1 };
    const side_b = [_]u8{ 2, 3, 4 };
    rig.network.set_partition(&side_a, &side_b);
    for (0..5) |from| {
        for (0..5) |to| {
            if (from == to) continue;
            const same_side = (from < 2) == (to < 2);
            try testing.expectEqual(same_side, rig.network.reachable(fx.link_of(from, to)));
        }
    }
    for (1..6) |from| {
        for (1..6) |to| {
            if (from != to) rig.network.send(&fx.vote(from, to, from * 10 + to));
        }
    }
    var terms: [32]u64 = undefined;
    const delivered = try drain_terms(&rig, &terms);
    try testing.expectEqual(@as(usize, 8), delivered.len); // 2 inside {0,1}, 6 inside {2,3,4}.
    for (delivered) |term| {
        const from = term / 10;
        const to = term % 10;
        try testing.expectEqual(from <= 2, to <= 2);
    }
    try expect_stats(&rig.network, .{ .sent = 20, .delivered = 8, .dropped_cut = 12 });
    rig.network.heal();
    rig.network.send(&fx.vote(1, 5, 15));
    try testing.expectEqual(@as(usize, 1), (try drain_terms(&rig, &terms)).len);
}

test "network: a node on neither side of set_partition stays reachable from both" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.set_partition(&.{0}, &.{1});
    try testing.expect(!rig.network.reachable(.{ .from_index = 0, .to_index = 1 }));
    try testing.expect(!rig.network.reachable(.{ .from_index = 1, .to_index = 0 }));
    try testing.expect(rig.network.reachable(.{ .from_index = 0, .to_index = 2 }));
    try testing.expect(rig.network.reachable(.{ .from_index = 2, .to_index = 1 }));
}

test "network: a seven-node network reaches every pair and partitions its end nodes" {
    var model = fx.base_model;
    model.messages_max = 64;
    var rig: Rig = undefined;
    try fixture_options(&rig, fx.options_of(7, model, .none), 3);
    defer rig.deinit(testing.allocator);
    rig.network.set_partition(&.{6}, &.{ 0, 1, 2 });
    try testing.expect(!rig.network.reachable(.{ .from_index = 6, .to_index = 0 }));
    try testing.expect(rig.network.reachable(.{ .from_index = 6, .to_index = 3 }));
    for (1..8) |from| {
        for (1..8) |to| {
            if (from != to) rig.network.send(&fx.vote(from, to, from * 10 + to));
        }
    }
    var terms: [64]u64 = undefined;
    try testing.expectEqual(@as(usize, 42 - 6), (try drain_terms(&rig, &terms)).len);
    try expect_stats(&rig.network, .{ .sent = 42, .delivered = 36, .dropped_cut = 6 });
}

// -- Crashed targets ----------------------------------------------------------------------

test "network: drop_down turns the last delivery into a dropped_down" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.send(&fx.vote(1, 2, 1));
    rig.network.send(&fx.vote(1, 3, 2));
    rig.advance(5);
    _ = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    rig.network.drop_down(); // Node 2 is crashed.
    try expect_stats(&rig.network, .{ .sent = 2, .dropped_down = 1 });
    try rig.network.check_invariants();
    _ = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try expect_stats(&rig.network, .{ .sent = 2, .delivered = 1, .dropped_down = 1 });
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
    try rig.network.check_invariants();
}

// -- Planted faults -----------------------------------------------------------------------

fn deliver_one(rig: *Rig, sent: *const Message) !*const Message {
    rig.network.send(sent);
    rig.advance(5);
    return rig.network.pop_due() orelse error.TestUnexpectedResult;
}

test "network: forge_votes grants a denied request_vote_response and nothing else" {
    var rig: Rig = undefined;
    try fixture_options(&rig, fx.options_of(3, fx.base_model, .forge_votes), 1);
    defer rig.deinit(testing.allocator);
    const denied = try deliver_one(&rig, &fx.vote_response(2, 1, 3, false));
    try testing.expect(denied.request_vote_response.granted);
    try testing.expectEqual(@as(u64, 3), @intFromEnum(denied.header().term));
    const granted = try deliver_one(&rig, &fx.vote_response(3, 1, 3, true));
    try testing.expect(granted.request_vote_response.granted);
    const pre: Message = .{ .pre_vote_response = .{
        .header = fx.header(2, 1, 3),
        .granted = false,
    } };
    try testing.expect(!(try deliver_one(&rig, &pre)).pre_vote_response.granted);
    const request = fx.vote(2, 1, 3);
    try testing.expect(fx.message_eql(&request, try deliver_one(&rig, &request)));
}

test "network: without a fault a denied vote stays denied" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const denied = try deliver_one(&rig, &fx.vote_response(2, 1, 3, false));
    try testing.expect(!denied.request_vote_response.granted);
}

test "network: flip_data flips exactly one byte of the first non-empty entry" {
    var rig: Rig = undefined;
    try fixture_options(&rig, fx.options_of(3, fx.base_model, .flip_data), 1);
    defer rig.deinit(testing.allocator);
    const entries = [_]types.Entry{
        fx.entry_of(1, 1, ""),
        fx.entry_of(2, 1, "hello"),
        fx.entry_of(3, 1, "world"),
    };
    const sent = fx.append(1, 2, 1, &entries);
    const got = (try deliver_one(&rig, &sent)).append_entries;
    try testing.expectEqual(@as(usize, 3), got.entries.len);
    try testing.expectEqual(@as(usize, 0), got.entries[0].data.len);
    try testing.expectEqual(@as(usize, 5), got.entries[1].data.len);
    var differing: u32 = 0;
    for ("hello", got.entries[1].data) |want, have| {
        if (want != have) differing += 1;
    }
    try testing.expectEqual(@as(u32, 1), differing);
    try testing.expectEqualStrings("world", got.entries[2].data);
    try testing.expectEqualStrings("hello", entries[1].data); // The sender's bytes are untouched.
    try testing.expectEqual(@as(u64, 11), @intFromEnum(got.prev_log_index));
    try testing.expectEqual(@as(u64, 77), got.round);
}

test "network: flip_data leaves empty appends and other message kinds alone" {
    var rig: Rig = undefined;
    try fixture_options(&rig, fx.options_of(3, fx.base_model, .flip_data), 1);
    defer rig.deinit(testing.allocator);
    const only_empty = [_]types.Entry{ fx.entry_of(1, 1, ""), fx.entry_of(2, 1, "") };
    const heartbeat = fx.append(1, 2, 1, &only_empty);
    try testing.expect(fx.message_eql(&heartbeat, try deliver_one(&rig, &heartbeat)));
    const none = fx.append(1, 2, 1, &.{});
    try testing.expect(fx.message_eql(&none, try deliver_one(&rig, &none)));
    const request = fx.vote(1, 3, 2);
    try testing.expect(fx.message_eql(&request, try deliver_one(&rig, &request)));
}

test "network: without a fault no byte of an append is changed" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const entries = [_]types.Entry{fx.entry_of(1, 1, "hello")};
    const sent = fx.append(1, 2, 1, &entries);
    try testing.expect(fx.message_eql(&sent, try deliver_one(&rig, &sent)));
}

// -- Allocation discipline ----------------------------------------------------------------

test "network: init allocates exactly bytes_required and traffic allocates nothing more" {
    var model = with_model(1, 9, 20, 20);
    model.messages_max = 6;
    const options = fx.options_of(5, model, .none);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rig: Rig = undefined;
    try rig.init(failing.allocator(), options, 9);
    try testing.expect(failing.allocated_bytes > 0);
    try testing.expectEqual(Network.bytes_required(&options), failing.allocated_bytes);
    const allocations = failing.allocations;
    const resizes = failing.resize_index;
    for (0..300) |round| { // Overfills the table, cuts, duplicates, drops and drains.
        rig.network.send(&fx.vote(1 + round % 5, 1 + (round + 1) % 5, round + 1));
        if (round % 7 == 0) rig.network.cut(.{ .from_index = 0, .to_index = 1 });
        if (round % 11 == 0) rig.network.heal();
        if (round % 5 == 0) rig.advance(4);
        if (rig.network.pop_due()) |_| if (round % 3 == 0) rig.network.drop_down();
    }
    var seen: [64]fx.Seen = undefined;
    _ = try fx.drain(&rig, &seen);
    try testing.expectEqual(allocations, failing.allocations);
    try testing.expectEqual(resizes, failing.resize_index);
    try testing.expectEqual(@as(usize, 0), failing.deallocations);
    rig.deinit(failing.allocator());
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try testing.expectEqual(failing.allocations, failing.deallocations);
}

test "network: bytes_required equals the bytes requested for every size" {
    const sizes = [_][3]u32{ .{ 1, 1, 1 }, .{ 8, 4, 16 }, .{ 16, 2, 32 }, .{ 5, 3, 7 } };
    for (sizes) |size| {
        for ([_]u8{ 2, 7 }) |nodes_count| {
            var options = fx.options_of(nodes_count, fx.base_model, .none);
            options.model.messages_max = size[0];
            options.message_limits.entries_max = size[1];
            options.message_limits.entry_bytes_max = size[2];
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var rig: Rig = undefined;
            try rig.init(failing.allocator(), options, 1);
            defer rig.deinit(failing.allocator());
            try testing.expect(failing.allocated_bytes > 0);
            try testing.expectEqual(Network.bytes_required(&options), failing.allocated_bytes);
        }
    }
}

test "network: bytes_required grows by one message slot per extra messages_max" {
    var small = fx.options_of(3, fx.base_model, .none);
    var large = small;
    small.model.messages_max = 4;
    large.model.messages_max = 12;
    const slot = @sizeOf(Message) +
        fx.entries_max * (@sizeOf(types.Entry) + fx.entry_bytes_max);
    const grown = Network.bytes_required(&large) - Network.bytes_required(&small);
    try testing.expectEqual(8 * slot, grown);
    var wide = small;
    wide.message_limits.entry_bytes_max = fx.entry_bytes_max + 3;
    try testing.expectEqual(
        (small.model.messages_max + 1) * fx.entries_max * 3,
        Network.bytes_required(&wide) - Network.bytes_required(&small),
    );
}

test "network: the sweep preset (256 messages, 16 entries of 32 bytes) is about 0.3 MiB" {
    var options = fx.options_of(5, fx.base_model, .none);
    options.model.messages_max = 256;
    options.message_limits.entries_max = 16;
    options.message_limits.entry_bytes_max = 32;
    const bytes = Network.bytes_required(&options);
    try testing.expect(bytes > 200_000 and bytes < 400_000);
}

test "network: init fails cleanly with OutOfMemory at every allocation" {
    const options = fx.options_of(3, fx.base_model, .none);
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var probe: Rig = undefined;
    try probe.init(counting.allocator(), options, 1);
    probe.deinit(counting.allocator());
    const allocations = counting.allocations;
    try testing.expect(allocations > 0);
    for (0..allocations) |fail_index| {
        const config: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, config);
        var rig: Rig = undefined;
        try testing.expectError(error.OutOfMemory, rig.init(failing.allocator(), options, 1));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes); // No leak.
    }
}

// -- The trace hash -----------------------------------------------------------------------

fn trace_of(model: Network.Model, seed: u64, kind_pre: bool, to: u64) !u64 {
    var rig: Rig = undefined;
    try fixture(&rig, model, seed);
    defer rig.deinit(testing.allocator);
    for (1..11) |term| {
        const request = fx.vote(1, to, term);
        if (kind_pre) {
            rig.network.send(&.{ .pre_vote = request.request_vote });
        } else {
            rig.network.send(&request);
        }
    }
    var seen: [32]fx.Seen = undefined;
    _ = try fx.drain(&rig, &seen);
    return rig.network.trace_hash();
}

test "network: the same seed run twice has the same trace hash, a different seed another" {
    const model = with_model(1, 60, 15, 15);
    const first = try trace_of(model, 42, false, 2);
    try testing.expectEqual(first, try trace_of(model, 42, false, 2));
    try testing.expect(first != 0);
    for ([_]u64{ 43, 44, 1, 0xdead_beef }) |other| {
        try testing.expect(first != try trace_of(model, other, false, 2));
    }
}

test "network: the trace hash depends on kind, destination and delivery time" {
    const model = with_model(5, 5, 0, 0);
    const base = try trace_of(model, 1, false, 2);
    try testing.expectEqual(base, try trace_of(model, 99, false, 2)); // Fixed delay: seed-free.
    try testing.expect(base != try trace_of(model, 1, true, 2));
    try testing.expect(base != try trace_of(model, 1, false, 3));
    try testing.expect(base != try trace_of(with_model(6, 6, 0, 0), 1, false, 2));
}

test "network: the trace hash does not move until something is delivered" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const fresh = rig.network.trace_hash();
    rig.network.send(&fx.vote(1, 2, 1));
    try testing.expectEqual(fresh, rig.network.trace_hash());
    rig.advance(5);
    _ = rig.network.pop_due() orelse return error.TestUnexpectedResult;
    try testing.expect(fresh != rig.network.trace_hash());
}

// -- check_invariants and its error variants ----------------------------------------------

test "network: check_invariants passes after every kind of traffic" {
    var rig: Rig = undefined;
    try fixture(&rig, with_model(1, 5, 30, 30), 3);
    defer rig.deinit(testing.allocator);
    for (0..100) |round| {
        rig.network.send(&fx.vote(1 + round % 3, 1 + (round + 1) % 3, round + 1));
        try rig.network.check_invariants();
        if (round % 4 == 0) rig.advance(2);
        if (round % 9 == 0) rig.network.cut(.{ .from_index = 1, .to_index = 2 });
        if (round % 13 == 0) rig.network.heal();
        while (rig.network.pop_due()) |_| try rig.network.check_invariants();
    }
    const stats = rig.network.stats();
    try testing.expectEqual(@as(u64, 100), stats.sent);
    try testing.expect(stats.delivered > 0 and stats.dropped_loss > 0 and stats.dropped_cut > 0);
}

test "network: check_invariants reports NetworkStatsDiverged when a counter is off" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    rig.network.send(&fx.vote(1, 2, 1));
    try rig.network.check_invariants();
    rig.network.counters.sent += 1; // A send that was never accounted anywhere.
    try testing.expectError(error.NetworkStatsDiverged, rig.network.check_invariants());
    rig.network.counters.sent -= 1;
    rig.network.counters.delivered += 1; // A delivery from nowhere.
    try testing.expectError(error.NetworkStatsDiverged, rig.network.check_invariants());
    rig.network.counters.delivered -= 1;
    try rig.network.check_invariants();
}

test "network: check_invariants reports NetworkTableOverfull past messages_max" {
    var rig: Rig = undefined;
    try fixture(&rig, fx.base_model, 1);
    defer rig.deinit(testing.allocator);
    const real_used = rig.network.used;
    const real_sent = rig.network.counters.sent;
    rig.network.used = fx.base_model.messages_max + 1;
    rig.network.counters.sent = fx.base_model.messages_max + 1; // Balanced, only overfull.
    try testing.expectError(error.NetworkTableOverfull, rig.network.check_invariants());
    rig.network.used = real_used;
    rig.network.counters.sent = real_sent;
    try rig.network.check_invariants();
}
