//! Test support for the `sim/linearizability*_test.zig` files: operation builders, the one
//! construction path for a checker run (`verdict_with`), verdict assertions and the two history
//! shapes the boundary and budget tests share. Nothing here is public API.
//!
//! Allocation: only through `testing.allocator`, so a leak fails the calling test.

const std = @import("std");
const testing = std.testing;
const linearizability = @import("linearizability.zig");

pub const CheckError = linearizability.CheckError;
pub const HistoryChecker = linearizability.HistoryChecker;
pub const Operation = linearizability.Operation;

pub const options: HistoryChecker.Options = .{
    .history_ops_max = 64,
    .keys_max = 16,
    .search_steps_max = 10_000_000,
};
pub const budget_huge: u64 = 1 << 40;

pub fn put(client: u16, key: u16, value: u64, invoke: u64, complete: u64) Operation {
    return .{
        .client_index = client,
        .kind = .put,
        .key = key,
        .value = value,
        .invoke_event = invoke,
        .complete_event = complete,
    };
}

pub fn get(client: u16, key: u16, value: u64, invoke: u64, complete: u64) Operation {
    return .{
        .client_index = client,
        .kind = .get,
        .key = key,
        .value = value,
        .invoke_event = invoke,
        .complete_event = complete,
    };
}

pub fn put_pending(client: u16, key: u16, value: u64, invoke: u64) Operation {
    return .{
        .client_index = client,
        .kind = .put,
        .key = key,
        .value = value,
        .invoke_event = invoke,
        .complete_event = null,
    };
}

pub fn get_pending(client: u16, key: u16, value: u64, invoke: u64) Operation {
    return .{
        .client_index = client,
        .kind = .get,
        .key = key,
        .value = value,
        .invoke_event = invoke,
        .complete_event = null,
    };
}

/// One fresh checker, one `check`, torn down; the allocator is `testing.allocator` so any
/// leak or double free fails the calling test.
pub fn verdict_with(opts: HistoryChecker.Options, history: []const Operation) !void {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, opts);
    defer checker.deinit(testing.allocator);
    try checker.check(history);
}

pub fn expect_verdict(history: []const Operation, want: ?CheckError) !void {
    if (want) |err| {
        try testing.expectError(err, verdict_with(options, history));
    } else {
        try verdict_with(options, history);
    }
}

pub fn expect_ok(history: []const Operation) !void {
    try expect_verdict(history, null);
}

pub fn expect_violation(history: []const Operation) !void {
    try expect_verdict(history, error.Linearizability);
}

/// `len` operations by client 0 on key 0: put 1, get 1, put 2, get 2, ... Linearizable.
pub fn sequential(buf: []Operation, len: usize) []const Operation {
    for (buf[0..len], 0..) |*slot, index| {
        const value: u64 = index / 2 + 1;
        const invoke: u64 = 2 * index + 1;
        slot.* = switch (index % 2) {
            0 => put(0, 0, value, invoke, invoke + 1),
            else => get(0, 0, value, invoke, invoke + 1),
        };
    }
    return buf[0..len];
}

/// `count` puts on `key`, put `i` by client `client_base + i` with value `i + 1`, all pairwise
/// concurrent (invoked from `base`, completed after all invokes), then a get by a fresh client
/// returning `final`. Events are distinct for distinct `base` values at least 1000 apart.
pub fn concurrent_puts(
    buf: []Operation,
    count: u16,
    key: u16,
    final: u64,
    base: u64,
) []const Operation {
    for (0..count) |index| {
        const i: u16 = @intCast(index);
        buf[index] = put(i + key * 16, key, i + 1, base + i + 1, base + 100 + i);
    }
    buf[count] = get(count + key * 16, key, final, base + 200, base + 201);
    return buf[0 .. count + 1];
}

pub fn budget_options(budget: u64) HistoryChecker.Options {
    return .{ .history_ops_max = 64, .keys_max = 16, .search_steps_max = budget };
}
