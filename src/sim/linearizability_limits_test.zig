//! Tests for the limits of `sim/linearizability.zig` (ADR-008, "Linearizability"; plan 004
//! item 9), written before the implementation: `history_ops_max` and `keys_max` boundaries,
//! `HistoryTooLong`, the `search_steps_max` budget (`CheckInconclusive` is never a pass and is
//! summed over keys, per `check` call), and the allocation contract (everything at `init`,
//! nothing in `check`, memory linear in `history_ops_max`). The verdict tests are in
//! `linearizability_test.zig`, the seeded model test in `linearizability_model_test.zig`.
//!
//! `HistoryTooLong` is decided before any work, so it is checked against a malformed history;
//! other malformed histories are the caller's bug (asserted) and are not provoked.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const fx = @import("linearizability_fixtures.zig");

const HistoryChecker = fx.HistoryChecker;
const Operation = fx.Operation;
const options = fx.options;
const budget_huge = fx.budget_huge;
const put = fx.put;
const get = fx.get;
const concurrent_puts = fx.concurrent_puts;
const sequential = fx.sequential;
const budget_options = fx.budget_options;
const verdict_with = fx.verdict_with;

// ----------------------------------------------------------------------------- boundaries

test "linearizability: a history of exactly history_ops_max operations is checked" {
    var buf: [9]Operation = undefined;
    const opts: HistoryChecker.Options = .{
        .history_ops_max = 8,
        .keys_max = 1,
        .search_steps_max = 1_000_000,
    };
    try verdict_with(opts, sequential(&buf, 8));
    var stale = buf;
    stale[7].value = 0;
    try testing.expectError(error.Linearizability, verdict_with(opts, stale[0..8]));
}

test "linearizability: one operation over history_ops_max is HistoryTooLong" {
    var buf: [9]Operation = undefined;
    const opts: HistoryChecker.Options = .{
        .history_ops_max = 8,
        .keys_max = 1,
        .search_steps_max = 1_000_000,
    };
    const history = sequential(&buf, 9); // Linearizable: length is the only fault.
    try testing.expectError(error.HistoryTooLong, verdict_with(opts, history));
    try verdict_with(opts, history[0..8]);
}

test "linearizability: HistoryTooLong is decided before any search" {
    // 3 ops, limit 2: a stale read (a violation) and an out-of-range key (malformed and
    // asserted if looked at) both lose to the length check.
    const opts: HistoryChecker.Options = .{
        .history_ops_max = 2,
        .keys_max = 1,
        .search_steps_max = 1,
    };
    const stale = [_]Operation{ put(0, 0, 1, 1, 2), get(1, 0, 0, 3, 4), get(2, 0, 0, 5, 6) };
    try testing.expectError(error.HistoryTooLong, verdict_with(opts, &stale));
    const bad_key = [_]Operation{ put(0, 5, 1, 1, 2), get(1, 5, 1, 3, 4), get(2, 5, 1, 5, 6) };
    try testing.expectError(error.HistoryTooLong, verdict_with(opts, &bad_key));
}

test "linearizability: history_ops_max of one admits one operation and refuses two" {
    const opts: HistoryChecker.Options = .{
        .history_ops_max = 1,
        .keys_max = 1,
        .search_steps_max = 100,
    };
    try verdict_with(opts, &[_]Operation{});
    try verdict_with(opts, &.{put(0, 0, 1, 1, 2)});
    try testing.expectError(
        error.HistoryTooLong,
        verdict_with(opts, &.{ put(0, 0, 1, 1, 2), get(0, 0, 1, 3, 4) }),
    );
}

test "linearizability: the highest key below keys_max is checked like any other" {
    const stale = [_]Operation{ put(0, 3, 1, 1, 2), get(1, 3, 0, 3, 4) };
    const fresh = [_]Operation{ put(0, 3, 1, 1, 2), get(1, 3, 1, 3, 4) };
    const small: HistoryChecker.Options = .{
        .history_ops_max = 4,
        .keys_max = 4,
        .search_steps_max = 1000,
    };
    try testing.expectError(error.Linearizability, verdict_with(small, &stale));
    try verdict_with(small, &fresh);
    const last = [_]Operation{ put(0, 65534, 1, 1, 2), get(1, 65534, 0, 3, 4) };
    const wide: HistoryChecker.Options = .{
        .history_ops_max = 4,
        .keys_max = std.math.maxInt(u16),
        .search_steps_max = 1000,
    };
    try testing.expectError(error.Linearizability, verdict_with(wide, &last));
    const single: HistoryChecker.Options = .{
        .history_ops_max = 4,
        .keys_max = 1,
        .search_steps_max = 1000,
    };
    try testing.expectError(error.Linearizability, verdict_with(single, &.{
        put(0, 0, 1, 1, 2),
        get(1, 0, 0, 3, 4),
    }));
}

test "linearizability: a history using every slot with one deep concurrent key is checked" {
    // 9 concurrent puts and a get: the search must hold a frame per operation (10 deep).
    const opts: HistoryChecker.Options = .{
        .history_ops_max = 10,
        .keys_max = 1,
        .search_steps_max = budget_huge,
    };
    var buf: [10]Operation = undefined;
    const history = concurrent_puts(&buf, 9, 0, 5, 0);
    try verdict_with(opts, history);
}

test "linearizability: a checker is reusable and keeps no verdict between histories" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    const stale = [_]Operation{ put(0, 0, 1, 1, 2), get(1, 0, 0, 3, 4) };
    const fresh = [_]Operation{ put(0, 0, 1, 1, 2), get(1, 0, 1, 3, 4) };
    try testing.expectError(error.Linearizability, checker.check(&stale));
    try checker.check(&fresh);
    try checker.check(&[_]Operation{});
    try testing.expectError(error.Linearizability, checker.check(&stale));
    try testing.expectError(error.Linearizability, checker.check(&stale));
}

// ----------------------------------------------------------------- the search-step budget

test "linearizability: an unsatisfiable concurrent history is CheckInconclusive over budget" {
    var buf: [9]Operation = undefined;
    const history = concurrent_puts(&buf, 8, 0, 99, 0); // 8 puts, a get of an unwritten 99.
    const result = verdict_with(budget_options(1000), history);
    try testing.expectError(error.CheckInconclusive, result);
}

test "linearizability: the same history is a violation once the budget is large" {
    var buf: [9]Operation = undefined;
    const history = concurrent_puts(&buf, 8, 0, 99, 0);
    const result = verdict_with(budget_options(budget_huge), history);
    try testing.expectError(error.Linearizability, result);
}

test "linearizability: a satisfiable concurrent history passes with a large budget" {
    var buf: [9]Operation = undefined;
    for ([_]u64{ 1, 3, 8 }) |final| {
        const history = concurrent_puts(&buf, 8, 0, final, 0);
        try verdict_with(budget_options(budget_huge), history);
    }
}

test "linearizability: a bigger budget never turns a verdict back into Inconclusive" {
    var buf: [6]Operation = undefined;
    const history = concurrent_puts(&buf, 5, 0, 99, 0);
    try testing.expectError(error.CheckInconclusive, verdict_with(budget_options(1), history));
    var settled = false;
    var budget: u64 = 1;
    while (budget <= (1 << 30)) : (budget *= 2) {
        const result = verdict_with(budget_options(budget), history);
        if (result) |_| {
            return error.TestUnexpectedResult; // 99 was never written: never a pass.
        } else |err| switch (err) {
            error.CheckInconclusive => try testing.expect(!settled),
            error.Linearizability => settled = true,
            else => return err,
        }
    }
    try testing.expect(settled);
}

test "linearizability: exhausting the budget is never reported as a pass" {
    var buf: [9]Operation = undefined;
    const history = concurrent_puts(&buf, 8, 0, 99, 0);
    var budget: u64 = 1;
    while (budget <= 4096) : (budget *= 2) {
        const result = verdict_with(budget_options(budget), history);
        if (result) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "linearizability: a trivial sequential history needs only a tiny budget" {
    var buf: [6]Operation = undefined;
    try verdict_with(budget_options(100), sequential(&buf, 6));
    try verdict_with(budget_options(100), &[_]Operation{});
}

/// The least budget under which `history` passes, found by scanning upward; every smaller
/// budget must be `CheckInconclusive`.
fn least_passing_budget(history: []const Operation) !u64 {
    var budget: u64 = 1;
    while (budget <= 4000) : (budget += 1) {
        verdict_with(budget_options(budget), history) catch |err| switch (err) {
            error.CheckInconclusive => continue,
            else => return err,
        };
        return budget;
    }
    return error.TestUnexpectedResult;
}

test "linearizability: steps are summed over keys, not budgeted per key" {
    var one: [5]Operation = undefined;
    const single = concurrent_puts(&one, 4, 0, 1, 0);
    const per_key = try least_passing_budget(single);
    try testing.expect(per_key >= 2); // A satisfiable 4-way race is not free.
    var three: [15]Operation = undefined;
    var len: usize = 0;
    for (0..3) |key| {
        const part = concurrent_puts(three[len..], 4, @intCast(key), 1, key * 1000);
        len += part.len;
    }
    const history = three[0..len];
    const at_one_key = verdict_with(budget_options(per_key), history);
    try testing.expectError(error.CheckInconclusive, at_one_key);
    try testing.expectError(
        error.CheckInconclusive,
        verdict_with(budget_options(2 * per_key - 1), history),
    );
    try verdict_with(budget_options(3 * per_key + 3), history);
}

test "linearizability: the budget is per check call, not used up across calls" {
    var buf: [5]Operation = undefined;
    const history = concurrent_puts(&buf, 4, 0, 1, 0);
    const budget = try least_passing_budget(history);
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, budget_options(budget));
    defer checker.deinit(testing.allocator);
    for (0..5) |_| try checker.check(history);
    var bad_buf: [9]Operation = undefined;
    const unsat = concurrent_puts(&bad_buf, 8, 0, 99, 0);
    try testing.expectError(error.CheckInconclusive, checker.check(unsat));
    try checker.check(history); // An inconclusive run leaves nothing behind.
}

// ----------------------------------------------------------------------------- allocation

fn init_then_deinit(gpa: Allocator, opts: HistoryChecker.Options) !void {
    var checker: HistoryChecker = undefined;
    try checker.init(gpa, opts);
    checker.deinit(gpa);
}

test "linearizability: init failing at any allocation leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, init_then_deinit, .{options});
    try testing.checkAllAllocationFailures(testing.allocator, init_then_deinit, .{
        HistoryChecker.Options{ .history_ops_max = 1, .keys_max = 1, .search_steps_max = 1 },
    });
}

test "linearizability: init reports OutOfMemory when the first allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var checker: HistoryChecker = undefined;
    try testing.expectError(error.OutOfMemory, checker.init(failing.allocator(), options));
}

test "linearizability: check allocates nothing after init, whatever the verdict" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var checker: HistoryChecker = undefined;
    try checker.init(gpa, budget_options(1000));
    defer checker.deinit(gpa);
    failing.fail_index = failing.alloc_index; // The next allocation, of any size, fails.
    const allocs = failing.alloc_index;
    const allocated = failing.allocated_bytes;
    var buf: [9]Operation = undefined;
    try checker.check(&[_]Operation{});
    try checker.check(&.{ put(0, 0, 1, 1, 2), get(1, 0, 1, 3, 4) });
    try testing.expectError(error.Linearizability, checker.check(&.{
        put(0, 0, 1, 1, 2),
        get(1, 0, 0, 3, 4),
    }));
    try testing.expectError(
        error.CheckInconclusive,
        checker.check(concurrent_puts(&buf, 8, 0, 99, 0)),
    );
    try testing.expectError(error.HistoryTooLong, checker.check(&over_long));
    try testing.expectEqual(allocs, failing.alloc_index);
    try testing.expectEqual(allocated, failing.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), failing.freed_bytes);
}

const over_long = [_]Operation{get(0, 0, 0, 1, 2)} ** 65;

fn init_bytes(history_ops_max: u32, keys_max: u16) !usize {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var checker: HistoryChecker = undefined;
    try checker.init(failing.allocator(), .{
        .history_ops_max = history_ops_max,
        .keys_max = keys_max,
        .search_steps_max = 1,
    });
    checker.deinit(failing.allocator());
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    return failing.allocated_bytes;
}

test "linearizability: memory is linear in history_ops_max and free of keys_max" {
    const bytes_per_op_max = 256;
    const slack = 4096;
    for ([_]u32{ 1, 100, 1000, 10_000 }) |ops| {
        for ([_]u16{ 1, 1000, std.math.maxInt(u16) }) |keys| {
            const bytes = try init_bytes(ops, keys);
            try testing.expect(bytes >= 1);
            try testing.expect(bytes <= bytes_per_op_max * @as(usize, ops) + slack);
        }
    }
    const small = try init_bytes(1000, 1);
    const large = try init_bytes(10_000, 1);
    try testing.expect(large <= 10 * small + slack);
    try testing.expect(large > small);
}

test "linearizability: twelve pending puts do not exhaust a modest budget on a violation" {
    // A completed put 100, then a read of the pending 5, then a read of 100 again: no valid
    // order. Pending puts nobody reads are skipped, so the verdict is a violation, not
    // `CheckInconclusive` from trying every position of every pending put.
    var buf: [15]Operation = undefined;
    for (0..12) |index| {
        const client: u16 = @intCast(index + 1);
        buf[index] = fx.put_pending(client, 0, client, client);
    }
    buf[12] = put(0, 0, 100, 20, 21);
    buf[13] = get(0, 0, 5, 30, 31);
    buf[14] = get(0, 0, 100, 40, 41);
    const result = verdict_with(budget_options(10_000), &buf);
    try testing.expectError(error.Linearizability, result);
}
