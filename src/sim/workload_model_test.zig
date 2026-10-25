//! Seeded model-based tests for `sim/workload.zig` (plan 004 item 10): one random op stream
//! into the structure and into a trivial reference, compared after every step, with
//! `check_invariants()` after every mutation. Reproduce from the seed alone.
//!
//!   - `KvStateMachine` against a plain array of registers: valid puts and gets, out-of-range
//!     keys, no-ops, membership entries carrying valid command bytes, corrupted commands,
//!     drains and restarts.
//!   - `Workload` against a list of operations with a state each (open, done, pending): random
//!     draws, invocations, rejections, matching and non-matching applies, crashes. The model
//!     does not predict client indices; it checks the rules about them (no busy client, no
//!     retired client, one command per free client).
//!
//! Vacuity: the totals over all seeds must show every branch was taken.
//!
//! Allocation: `std.testing.allocator`; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("workload_fixtures.zig");
const invariants = @import("invariants.zig");
const linearizability = @import("linearizability.zig");
const types = @import("../types.zig");
const workload_module = @import("workload.zig");

const Command = workload_module.Command;
const Prng = fx.Prng;
const Workload = workload_module.Workload;
const command_bytes = workload_module.command_bytes;
const encode = workload_module.encode;

const gpa = testing.allocator;
const seeds_count = 250;
const steps_count = 300;

// ---- KvStateMachine versus an array of registers --------------------------------------------

const Expected = struct {
    index: u64,
    entry_fingerprint: u64,
    command: ?Command,
    result: u64,
};

const KvTotals = struct {
    puts: u32 = 0,
    gets_nonzero: u32 = 0,
    refused: u32 = 0,
    resets: u32 = 0,
    drains: u32 = 0,
};

fn expect_drained(kv: *workload_module.KvStateMachine, expected: []const Expected) !void {
    const records = kv.drain();
    try testing.expectEqual(expected.len, records.len);
    for (records, expected) |record, want| {
        try testing.expectEqual(want.index, @intFromEnum(record.index));
        try testing.expectEqual(want.entry_fingerprint, record.entry_fingerprint);
        try testing.expectEqual(want.command, record.command);
        try testing.expectEqual(want.result, record.result);
    }
}

/// One random entry and the command a correct machine takes from it (null: it must refuse).
const Drawn = struct { entry: types.Entry, want: ?Command };

/// Builds a random entry whose bytes live in `storage`: 60% valid in-range commands, the rest
/// refusals of every kind (key out of range, no-op, membership entry, corrupt, wrong size).
fn draw_entry(
    prng: *Prng,
    keys: u16,
    index: u64,
    storage: *[command_bytes + 16]u8,
    totals: *KvTotals,
) Drawn {
    const roll = prng.uint_less_than(100);
    var command: Command = .{
        .kind = if (prng.chance(50)) .put else .get,
        .client_index = @intCast(prng.uint_less_than(5)),
        .key = @intCast(prng.uint_less_than(keys)),
        .value = 1 + prng.uint_less_than(1000), // a put never writes 0
        .op_id = @intCast(prng.uint_less_than(1 << 20)),
    };
    if (command.kind == .get) command.value = 0;
    if (roll >= 60 and roll < 70) command.key = keys + @as(u16, @intCast(prng.uint_less_than(3)));
    encode(&command, storage[0..command_bytes]);
    var kind: types.EntryKind = .normal;
    var len: usize = command_bytes;
    var want: ?Command = null;
    if (roll < 60) {
        want = command;
    } else if (roll < 70) {
        totals.refused += 1;
    } else if (roll < 78) {
        len = 0; // a new leader's no-op
    } else if (roll < 88) {
        kind = .conf_change; // valid command bytes inside a membership entry
    } else if (roll < 94) {
        const bit = prng.uint_less_than(command_bytes * 8);
        storage[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
    } else {
        len = @intCast(prng.uint_less_than(command_bytes + 16));
        if (len == command_bytes) len += 1;
        for (storage[0..len]) |*byte| byte.* = @truncate(prng.next_u64());
    }
    return .{ .entry = fx.raw_entry(index, kind, storage[0..len]), .want = want };
}

/// The reference register file: applies `want` and returns the result a record must carry.
fn model_apply(registers: *[8]u64, want: ?Command, totals: *KvTotals) u64 {
    const command = want orelse return 0;
    switch (command.kind) {
        .put => {
            registers[command.key] = command.value;
            totals.puts += 1;
            return command.value;
        },
        .get => {
            if (registers[command.key] != 0) totals.gets_nonzero += 1;
            return registers[command.key];
        },
    }
}

fn kv_run(seed: u64, totals: *KvTotals) !void {
    var prng = Prng.init(seed);
    const keys: u16 = @intCast(1 + prng.uint_less_than(6));
    const applied_max: u32 = 8;
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, keys, applied_max);
    defer rig.deinit(gpa);

    var registers = [_]u64{0} ** 8;
    var undrained: [applied_max]Expected = undefined;
    var undrained_len: usize = 0;
    var index: u64 = 1;
    for (0..steps_count) |_| {
        if (undrained_len == applied_max or prng.chance(25)) {
            try expect_drained(&rig.kv, undrained[0..undrained_len]);
            undrained_len = 0;
            totals.drains += 1;
        }
        if (prng.chance(3)) {
            rig.kv.reset();
            registers = [_]u64{0} ** 8;
            undrained_len = 0; // the machine is volatile: undrained records are void
            totals.resets += 1;
            try rig.kv.check_invariants();
            continue;
        }
        index += 1;
        var storage: [command_bytes + 16]u8 = undefined;
        const drawn = draw_entry(&prng, keys, index, &storage, totals);
        undrained[undrained_len] = .{
            .index = index,
            .entry_fingerprint = invariants.fingerprint(&drawn.entry),
            .command = drawn.want,
            .result = model_apply(&registers, drawn.want, totals),
        };
        undrained_len += 1;
        try rig.kv.apply(&drawn.entry);
        try rig.kv.check_invariants();
    }
    try expect_drained(&rig.kv, undrained[0..undrained_len]);
}

test "kv model: seeded streams of commands, junk, drains and restarts match the registers" {
    var totals: KvTotals = .{};
    for (0..seeds_count) |seed| try kv_run(seed, &totals);
    // Vacuity: every branch ran, and reads saw writes.
    try testing.expect(totals.puts > seeds_count * 20);
    try testing.expect(totals.gets_nonzero > seeds_count * 5);
    try testing.expect(totals.refused > seeds_count * 5);
    try testing.expect(totals.resets > seeds_count);
    try testing.expect(totals.drains > seeds_count * 10);
}

// ---- Workload versus a list of operations ---------------------------------------------------

const State = enum { open, done, pending };

const ModelOp = struct {
    command: Command,
    node: u8,
    log_index: u64,
    state: State,
    invoke: u64,
    complete: ?u64,
    result: u64,
};

const WorkloadTotals = struct {
    invoked: u32 = 0,
    rejected: u32 = 0,
    completed: u32 = 0,
    lost_entry: u32 = 0,
    crashed_ops: u32 = 0,
    no_change_applies: u32 = 0,
    all_busy_draws: u32 = 0,
    history_full: u32 = 0,
};

/// The model's own counters: virtual time, event numbers, the next log index.
const Clock = struct { now: u64, event: u64, log_index: u64 };

const Model = struct {
    ops: [64]ModelOp = undefined,
    len: u32 = 0,
    retired: [256]bool = @splat(false),
    op_ids_seen: [512]u32 = undefined,
    op_ids_len: u32 = 0,

    fn open_count(model: *const Model) u32 {
        var count: u32 = 0;
        for (model.ops[0..model.len]) |op| {
            if (op.state == .open) count += 1;
        }
        return count;
    }

    fn is_open_client(model: *const Model, client: u16) bool {
        for (model.ops[0..model.len]) |op| {
            if (op.state == .open and op.command.client_index == client) return true;
        }
        return false;
    }

    fn retire(model: *Model, op: *ModelOp) void {
        op.state = .pending;
        model.retired[op.command.client_index] = true;
    }

    fn pick_open(model: *Model, prng: *Prng) ?*ModelOp {
        const open = model.open_count();
        if (open == 0) return null;
        var skip = prng.uint_less_than(open);
        for (model.ops[0..model.len]) |*op| {
            if (op.state != .open) continue;
            if (skip == 0) return op;
            skip -= 1;
        }
        unreachable;
    }
};

fn expect_agree(workload: *const Workload, model: *const Model) !void {
    const history = workload.history();
    try testing.expectEqual(@as(usize, model.len), history.len);
    var done: u32 = 0;
    for (history, model.ops[0..model.len]) |got, want| {
        try testing.expectEqual(want.command.client_index, got.client_index);
        try testing.expectEqual(want.command.kind, got.kind);
        try testing.expectEqual(want.command.key, got.key);
        try testing.expectEqual(want.invoke, got.invoke_event);
        try testing.expectEqual(want.complete, got.complete_event);
        switch (want.command.kind) {
            .put => try testing.expectEqual(want.command.value, got.value),
            .get => if (want.state == .done) try testing.expectEqual(want.result, got.value),
        }
        if (want.state == .done) done += 1;
    }
    const stats = workload.stats();
    try testing.expectEqual(model.len, stats.ops_invoked);
    try testing.expectEqual(done, stats.ops_completed);
    try testing.expectEqual(model.len - done, stats.ops_pending);
    try workload.check_invariants();
}

fn draw_step(
    rig: *fx.WorkloadRig,
    model: *Model,
    prng: *Prng,
    options: Workload.Options,
    history_ops_max: u32,
    state: *Clock,
    totals: *WorkloadTotals,
) !void {
    const workload = &rig.workload;
    const due = workload.next_due_ms();
    const room = model.len < history_ops_max;
    try testing.expectEqual(room, due != null);
    if (due == null) {
        totals.history_full += 1;
        return;
    }
    state.now = @max(state.now, due.?) + prng.uint_less_than(3);
    const command = workload.next_command(state.now);
    const next_due = workload.next_due_ms();
    if (next_due) |next_ms| {
        try testing.expect(next_ms > state.now);
        try testing.expect(next_ms <= state.now + options.op_interval_ms_max);
    }
    const free = model.open_count() < options.clients_count;
    if (!free) totals.all_busy_draws += 1;
    try testing.expectEqual(free, command != null);
    const drawn = command orelse return;

    try testing.expect(!model.is_open_client(drawn.client_index));
    try testing.expect(!model.retired[drawn.client_index]);
    try testing.expect(drawn.key < options.keys_count);
    if (drawn.kind == .put) try testing.expect(drawn.value != 0);
    if (options.put_percent == 100) try testing.expect(drawn.kind == .put);
    if (options.put_percent == 0) try testing.expect(drawn.kind == .get);
    for (model.op_ids_seen[0..model.op_ids_len]) |seen| try testing.expect(seen != drawn.op_id);
    model.op_ids_seen[model.op_ids_len] = drawn.op_id;
    model.op_ids_len += 1;

    if (prng.chance(25)) {
        workload.rejected(&drawn);
        totals.rejected += 1;
        return;
    }
    state.event += 1;
    state.log_index += 1;
    const node: u8 = @intCast(prng.uint_less_than(4));
    workload.invoked(&drawn, fx.invocation(node, state.log_index, state.event));
    model.ops[model.len] = .{
        .command = drawn,
        .node = node,
        .log_index = state.log_index,
        .state = .open,
        .invoke = state.event,
        .complete = null,
        .result = 0,
    };
    model.len += 1;
    totals.invoked += 1;
}

fn apply_step(
    rig: *fx.WorkloadRig,
    model: *Model,
    prng: *Prng,
    state: *Clock,
    totals: *WorkloadTotals,
) void {
    const op = model.pick_open(prng) orelse return;
    state.event += 1;
    const result = prng.uint_less_than(5);
    switch (prng.uint_less_than(100)) {
        0...54 => { // the proposer applies its own entry
            const record = fx.record_of(op.log_index, op.command, result);
            rig.workload.applied(op.node, &record, state.event);
            op.state = .done;
            op.complete = state.event;
            op.result = result;
            totals.completed += 1;
        },
        55...69 => { // another command won the index
            var rival = op.command;
            rival.op_id +%= 1;
            const record = fx.record_of(op.log_index, rival, result);
            rig.workload.applied(op.node, &record, state.event);
            model.retire(op);
            totals.lost_entry += 1;
        },
        70...79 => { // a no-op won the index
            const record = fx.record_of(op.log_index, null, 0);
            rig.workload.applied(op.node, &record, state.event);
            model.retire(op);
            totals.lost_entry += 1;
        },
        80...89 => { // a follower applies it: no change
            const record = fx.record_of(op.log_index, op.command, result);
            rig.workload.applied((op.node + 1) % 4, &record, state.event);
            totals.no_change_applies += 1;
        },
        else => { // the proposer applies some other index: no change
            const record = fx.record_of(op.log_index + 1000, op.command, result);
            rig.workload.applied(op.node, &record, state.event);
            totals.no_change_applies += 1;
        },
    }
}

fn workload_run(seed: u64, totals: *WorkloadTotals) !void {
    var prng = Prng.init(seed ^ 0x5eed);
    const options: Workload.Options = .{
        .clients_count = @intCast(1 + prng.uint_less_than(4)),
        .keys_count = @intCast(1 + prng.uint_less_than(4)),
        .put_percent = switch (prng.uint_less_than(4)) {
            0 => 0,
            1 => 100,
            else => @intCast(10 + prng.uint_less_than(80)),
        },
        .op_interval_ms_max = @intCast(1 + prng.uint_less_than(30)),
        .fault = .none,
    };
    const history_ops_max: u32 = @intCast(5 + prng.uint_less_than(40));
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, history_ops_max, seed);
    defer rig.deinit(gpa);

    var model: Model = .{};
    var state: Clock = .{
        .now = 0,
        .event = 0,
        .log_index = 1,
    };
    for (0..steps_count) |_| {
        switch (prng.uint_less_than(100)) {
            0...44 => try draw_step(&rig, &model, &prng, options, history_ops_max, &state, totals),
            45...84 => apply_step(&rig, &model, &prng, &state, totals),
            else => {
                const node: u8 = @intCast(prng.uint_less_than(4));
                rig.workload.crashed(node);
                for (model.ops[0..model.len]) |*op| {
                    if (op.state == .open and op.node == node) {
                        model.retire(op);
                        totals.crashed_ops += 1;
                    }
                }
            },
        }
        try expect_agree(&rig.workload, &model);
    }

    // The real consumer accepts the shape: its asserts cover one outstanding operation per
    // client, strictly increasing events, keys in range and no put of 0. The values here are
    // random, so the verdict itself is any of the three answers but a crash.
    var checker: linearizability.HistoryChecker = undefined;
    try checker.init(gpa, .{
        .history_ops_max = history_ops_max,
        .keys_max = options.keys_count,
        .search_steps_max = 100_000,
    });
    defer checker.deinit(gpa);
    checker.check(rig.workload.history()) catch |err| switch (err) {
        error.Linearizability, error.CheckInconclusive => {},
        error.HistoryTooLong => return error.TestUnexpectedResult,
    };
}

test "workload model: seeded draws, invokes, applies and crashes match the reference list" {
    var totals: WorkloadTotals = .{};
    for (0..seeds_count) |seed| try workload_run(seed, &totals);
    // Vacuity: every branch ran.
    try testing.expect(totals.invoked > seeds_count * 3);
    try testing.expect(totals.rejected > seeds_count);
    try testing.expect(totals.completed > seeds_count);
    try testing.expect(totals.lost_entry > seeds_count / 2);
    try testing.expect(totals.crashed_ops > seeds_count / 4);
    try testing.expect(totals.no_change_applies > seeds_count / 2);
    try testing.expect(totals.all_busy_draws > seeds_count / 4);
    try testing.expect(totals.history_full > seeds_count / 4);
}

test "workload model: a seed replays to the same history" {
    var first_totals: WorkloadTotals = .{};
    var second_totals: WorkloadTotals = .{};
    try workload_run(77, &first_totals);
    try workload_run(77, &second_totals);
    try testing.expectEqual(first_totals, second_totals);
}
