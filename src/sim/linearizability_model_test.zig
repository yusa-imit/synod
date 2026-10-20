//! Seeded model-based test for `sim/linearizability.zig` (plan 004 item 9). A generator turns a
//! seed into a small well-formed history (3 keys, 4 clients, at most 7 operations per key, some
//! left pending) and a brute-force reference decides it: for each key, every subset of its
//! pending puts, every permutation of the chosen operations, accepted when the permutation
//! respects real time and replays as a register. The `HistoryChecker` must give the same
//! verdict on every seed. The reference shares no code or idea with a Wing-Gong search.
//!
//! Also checked: the generator's own output is well formed (the checker asserts on malformed
//! input) and covers both verdicts and pending operations, a seed replays bit for bit, a
//! never-written value read by any completed get is always a violation, and three metamorphic
//! relations (a pending get changes nothing, keys may be renamed, dropping a pending put never
//! turns a violation into a pass).

const std = @import("std");
const testing = std.testing;
const linearizability = @import("linearizability.zig");
const prng_module = @import("prng.zig");

const HistoryChecker = linearizability.HistoryChecker;
const Kind = linearizability.Kind;
const Operation = linearizability.Operation;
const Prng = prng_module.Prng;

const seeds_count = 400;
const keys_count = 3;
const clients_count = 4;
const per_key_max = 7;
const ops_max = keys_count * per_key_max;
const ops_cap = ops_max + 2; // Room for one appended pending get in the metamorphic test.
const steps_max = 200;
const never_written: u64 = 4242;
const options: HistoryChecker.Options = .{
    .history_ops_max = ops_cap,
    .keys_max = keys_count,
    .search_steps_max = 1 << 40,
};

/// One generated history, listed in invoke order, plus the generator's working state.
const Gen = struct {
    prng: Prng,
    ops: [ops_cap]Operation = undefined,
    len: usize = 0,
    event: u64 = 0,
    open: [clients_count]?usize = @splat(null),
    key_ops: [keys_count]usize = @splat(0),
    last_done: [keys_count]u64 = @splat(0),
    written: [keys_count][per_key_max]u64 = @splat(@splat(0)),
    puts_count: [keys_count]usize = @splat(0),
    next_value: u64 = 1,

    fn invoke(gen: *Gen, client: u16) void {
        const key: u16 = @intCast(gen.prng.uint_less_than(keys_count));
        if (gen.key_ops[key] == per_key_max) return;
        const kind: Kind = if (gen.prng.chance(45)) .put else .get;
        var value: u64 = 0;
        if (kind == .put) {
            value = gen.next_value;
            gen.next_value += 1;
            gen.written[key][gen.puts_count[key]] = value;
            gen.puts_count[key] += 1;
        }
        gen.event += 1;
        gen.ops[gen.len] = .{
            .client_index = client,
            .kind = kind,
            .key = key,
            .value = value,
            .invoke_event = gen.event,
            .complete_event = null,
        };
        gen.open[client] = gen.len;
        gen.len += 1;
        gen.key_ops[key] += 1;
    }

    /// The value a get returns: mostly the latest completed put, sometimes any put on the key
    /// or the initial 0, sometimes a value no one wrote.
    fn read_value(gen: *Gen, key: u16) u64 {
        const roll = gen.prng.uint_less_than(100);
        if (roll < 50) return gen.last_done[key];
        if (roll < 85) {
            const pick = gen.prng.uint_less_than(gen.puts_count[key] + 1);
            return if (pick == 0) 0 else gen.written[key][pick - 1];
        }
        return never_written + gen.prng.uint_less_than(3);
    }

    fn complete(gen: *Gen, client: u16) void {
        const op = &gen.ops[gen.open[client].?];
        gen.event += 1;
        op.complete_event = gen.event;
        switch (op.kind) {
            .put => gen.last_done[op.key] = op.value,
            .get => op.value = gen.read_value(op.key),
        }
        gen.open[client] = null;
    }

    /// End of the run: each outstanding operation is left pending or completes now.
    fn finish(gen: *Gen) void {
        for (0..clients_count) |index| {
            const client: u16 = @intCast(index);
            const open = gen.open[client] orelse continue;
            if (gen.prng.chance(50)) {
                if (gen.ops[open].kind == .get) gen.ops[open].value = gen.prng.uint_less_than(5);
                gen.open[client] = null;
            } else {
                gen.complete(client);
            }
        }
    }
};

fn generate(seed: u64) Gen {
    var gen: Gen = .{ .prng = Prng.init(seed) };
    const target = gen.prng.uint_less_than(ops_max + 1);
    for (0..steps_max) |_| {
        if (gen.len == target) break; // Stop with the last operations still outstanding.
        const client: u16 = @intCast(gen.prng.uint_less_than(clients_count));
        if (gen.open[client] != null) {
            if (gen.prng.chance(70)) gen.complete(client);
        } else if (gen.len < target) {
            gen.invoke(client);
        }
    }
    gen.finish();
    return gen;
}

/// Keys in range, completes after invokes, each client strictly sequential with a pending
/// operation only last, listed in invoke order: what the checker asserts on.
fn well_formed(ops: []const Operation) bool {
    var free_at: [clients_count]?u64 = @splat(0);
    var last_invoke: u64 = 0;
    for (ops) |op| {
        if (op.key >= keys_count or op.invoke_event <= last_invoke) return false;
        last_invoke = op.invoke_event;
        const free = free_at[op.client_index] orelse return false;
        if (op.invoke_event <= free) return false;
        if (op.complete_event) |end| if (end <= op.invoke_event) return false;
        free_at[op.client_index] = op.complete_event;
    }
    return true;
}

// ------------------------------------------------------------------------------ reference

fn order_valid(order: []const Operation) bool {
    for (order, 0..) |earlier, i| {
        for (order[i + 1 ..]) |later| {
            // `later` finished before `earlier` began: it may not come second.
            if (later.complete_event) |end| if (end < earlier.invoke_event) return false;
        }
    }
    var register: u64 = 0;
    for (order) |op| switch (op.kind) {
        .put => register = op.value,
        .get => if (op.value != register) return false,
    };
    return true;
}

/// Some permutation of `order[depth..]` after the fixed prefix is valid. Recursion is fine in
/// a test reference: depth is at most `per_key_max`.
fn permutes(order: []Operation, depth: usize) bool {
    if (depth == order.len) return order_valid(order);
    for (depth..order.len) |i| {
        std.mem.swap(Operation, &order[depth], &order[i]);
        const found = permutes(order, depth + 1);
        std.mem.swap(Operation, &order[depth], &order[i]);
        if (found) return true;
    }
    return false;
}

fn reference_key_ok(ops: []const Operation, key: u16) bool {
    var done: [per_key_max]Operation = undefined;
    var done_len: usize = 0;
    var pending: [per_key_max]Operation = undefined;
    var pending_len: usize = 0;
    for (ops) |op| {
        if (op.key != key) continue;
        if (op.complete_event != null) {
            done[done_len] = op;
            done_len += 1;
        } else if (op.kind == .put) {
            pending[pending_len] = op;
            pending_len += 1;
        } // A pending get is dropped.
    }
    const subsets = @as(usize, 1) << @intCast(pending_len);
    for (0..subsets) |mask| {
        var order: [per_key_max]Operation = undefined;
        @memcpy(order[0..done_len], done[0..done_len]);
        var len = done_len;
        for (0..pending_len) |bit| {
            if (mask >> @intCast(bit) & 1 == 0) continue;
            order[len] = pending[bit];
            len += 1;
        }
        if (permutes(order[0..len], 0)) return true;
    }
    return false;
}

fn reference_ok(ops: []const Operation) bool {
    for (0..keys_count) |key| {
        if (!reference_key_ok(ops, @intCast(key))) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------- tests

/// The checker's verdict as a bool; any error but `Linearizability` fails the calling test.
fn checker_ok(checker: *HistoryChecker, history: []const Operation) !bool {
    checker.check(history) catch |err| switch (err) {
        error.Linearizability => return false,
        error.CheckInconclusive, error.HistoryTooLong => return err,
    };
    return true;
}

test "linearizability model: the checker agrees with brute force on every seed" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    for (1..seeds_count + 1) |seed| {
        errdefer std.log.err("model mismatch at seed {d}", .{seed});
        const gen = generate(seed);
        const history = gen.ops[0..gen.len];
        try testing.expectEqual(reference_ok(history), try checker_ok(&checker, history));
    }
}

test "linearizability model: the generator is well formed and covers both verdicts" {
    var passes: usize = 0;
    var pending_puts: usize = 0;
    var pending_gets: usize = 0;
    var empty: usize = 0;
    for (1..seeds_count + 1) |seed| {
        const gen = generate(seed);
        const history = gen.ops[0..gen.len];
        try testing.expect(well_formed(history));
        try testing.expect(history.len <= ops_max);
        if (history.len == 0) empty += 1;
        if (reference_ok(history)) passes += 1;
        for (history) |op| {
            if (op.complete_event != null) continue;
            if (op.kind == .put) pending_puts += 1 else pending_gets += 1;
        }
    }
    const fails = seeds_count - passes;
    try testing.expect(passes >= seeds_count / 10);
    try testing.expect(fails >= seeds_count / 10);
    try testing.expect(pending_puts >= seeds_count / 10);
    try testing.expect(pending_gets >= seeds_count / 10);
    try testing.expect(empty < seeds_count / 10);
}

test "linearizability model: a seed replays the same history and the same verdict" {
    var first: HistoryChecker = undefined;
    try first.init(testing.allocator, options);
    defer first.deinit(testing.allocator);
    var second: HistoryChecker = undefined;
    try second.init(testing.allocator, options);
    defer second.deinit(testing.allocator);
    for (1..101) |seed| {
        const a = generate(seed);
        const b = generate(seed);
        try testing.expectEqual(a.len, b.len);
        try testing.expectEqualSlices(Operation, a.ops[0..a.len], b.ops[0..b.len]);
        const history = a.ops[0..a.len];
        const verdict = try checker_ok(&first, history);
        try testing.expectEqual(verdict, try checker_ok(&first, history)); // Reused.
        try testing.expectEqual(verdict, try checker_ok(&second, history)); // Fresh.
    }
    const x = generate(1);
    const y = generate(2);
    try testing.expect(x.len != y.len or !std.meta.eql(x.ops, y.ops));
}

test "linearizability model: a completed get of a never written value is always a violation" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    var corrupted: usize = 0;
    for (1..seeds_count + 1) |seed| {
        errdefer std.log.err("corruption missed at seed {d}", .{seed});
        var gen = generate(seed);
        for (gen.ops[0..gen.len]) |*op| {
            if (op.kind != .get or op.complete_event == null) continue;
            op.value = never_written;
            corrupted += 1;
            try testing.expectError(error.Linearizability, checker.check(gen.ops[0..gen.len]));
            break;
        }
    }
    try testing.expect(corrupted >= seeds_count / 4);
}

test "linearizability model: a pending get changes no verdict" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    for (1..seeds_count + 1) |seed| {
        errdefer std.log.err("pending get changed the verdict at seed {d}", .{seed});
        var gen = generate(seed);
        const before = try checker_ok(&checker, gen.ops[0..gen.len]);
        const key: u16 = @intCast(seed % keys_count);
        gen.ops[gen.len] = .{
            .client_index = 9,
            .kind = .get,
            .key = key,
            .value = never_written, // Whatever it carries, it is dropped.
            .invoke_event = gen.event + 1000,
            .complete_event = null,
        };
        try testing.expectEqual(before, try checker_ok(&checker, gen.ops[0 .. gen.len + 1]));
    }
}

test "linearizability model: renaming the keys changes no verdict" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    for (1..seeds_count + 1) |seed| {
        errdefer std.log.err("key renaming changed the verdict at seed {d}", .{seed});
        var gen = generate(seed);
        const before = try checker_ok(&checker, gen.ops[0..gen.len]);
        for (gen.ops[0..gen.len]) |*op| op.key = (op.key + 1) % keys_count;
        try testing.expectEqual(before, try checker_ok(&checker, gen.ops[0..gen.len]));
    }
}

test "linearizability model: dropping a pending put never turns a violation into a pass" {
    var checker: HistoryChecker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    var dropped: usize = 0;
    for (1..seeds_count + 1) |seed| {
        errdefer std.log.err("pending put drop broke monotonicity at seed {d}", .{seed});
        const gen = generate(seed);
        const index = for (gen.ops[0..gen.len], 0..) |op, i| {
            if (op.kind == .put and op.complete_event == null) break i;
        } else continue;
        var smaller: [ops_max]Operation = undefined;
        @memcpy(smaller[0..index], gen.ops[0..index]);
        @memcpy(smaller[index .. gen.len - 1], gen.ops[index + 1 .. gen.len]);
        dropped += 1;
        const without = try checker_ok(&checker, smaller[0 .. gen.len - 1]);
        const with = try checker_ok(&checker, gen.ops[0..gen.len]);
        try testing.expect(with or !without); // without => with.
    }
    try testing.expect(dropped >= seeds_count / 10);
}
