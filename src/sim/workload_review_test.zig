//! Tests for the review findings of the KV workload (plan 004 item 10): data that reaches the
//! state machine through the log is never asserted on, and the two `check_invariants` are shown
//! to fire.
//!
//! Choices where ADR-008 is silent (the implementation may argue, not drift silently):
//!   - An entry that claims to be a workload command, a `normal` entry of exactly
//!     `command_bytes` bytes starting with `"kv"`, and then fails to decode, carries a key
//!     outside the table or puts 0, is corrupt: `Applied.corrupt` is true, `command` is null,
//!     `result` is 0 and the state is untouched. The record makes `check_invariants` of the
//!     machine return `KvInvariant` and `Workload.applied` return `WorkloadInvariant`.
//!   - Every other entry without a command (a no-op, a `conf_change`, seeded proposal junk) is
//!     foreign, not corrupt: `command` null, `corrupt` false.
//!   - `Workload.applied` returns `WorkloadInvariant` when the record is corrupt, when the
//!     command of the operation's own entry names another client, or when it is applied at an
//!     event not after the invoke event.
//!
//! Allocation: `std.testing.allocator` and `std.testing.io` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("workload_fixtures.zig");
const simulation_module = @import("simulation.zig");
const types = @import("../types.zig");
const workload_module = @import("workload.zig");

const Command = workload_module.Command;
const KvStateMachine = workload_module.KvStateMachine;
const Options = simulation_module.Options;
const Simulation = simulation_module.Simulation;
const command_bytes = workload_module.command_bytes;

const io = testing.io;
const gpa = testing.allocator;

fn encoded(command: *const Command) [command_bytes]u8 {
    var out: [command_bytes]u8 = undefined;
    workload_module.encode(command, &out);
    return out;
}

fn seal(bytes: *[command_bytes]u8) void {
    std.mem.writeInt(u32, bytes[20..24], std.hash.Crc32.hash(bytes[0..20]), .little);
}

/// Applies a `normal` entry of `data` at `index` and returns its one record, drained.
fn apply_data(rig: *fx.KvRig, index: u64, data: []const u8) !fx.Applied {
    const entry = fx.raw_entry(index, .normal, data);
    try rig.kv.apply(&entry);
    if (rig.kv.len != 1) return error.TestUnexpectedResult;

    const record = rig.kv.records[0];
    try testing.expectEqual(@as(?Command, null), record.command);
    try testing.expectEqual(@as(u64, 0), record.result);
    return record;
}

/// Applies corrupt `data`: the record is flagged, `check_invariants` says so, a drain clears it.
fn expect_corrupt(rig: *fx.KvRig, data: []const u8, index: u64) !void {
    const record = try apply_data(rig, index, data);
    try testing.expect(record.corrupt);
    try testing.expectError(error.KvInvariant, rig.kv.check_invariants());
    _ = rig.kv.drain();
    try rig.kv.check_invariants();
}

fn expect_foreign(rig: *fx.KvRig, kind: types.EntryKind, data: []const u8, index: u64) !void {
    const entry = fx.raw_entry(index, kind, data);
    try rig.kv.apply(&entry);
    try testing.expectEqual(@as(u32, 1), rig.kv.len);
    try testing.expectEqual(@as(?Command, null), rig.kv.records[0].command);
    try testing.expect(!rig.kv.records[0].corrupt);
    try rig.kv.check_invariants();
    _ = rig.kv.drain();
}

// ---- data that reaches the state machine ----------------------------------------------------

test "kv: a put of value 0 is corrupt data, not an assertion, and leaves the register alone" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);
    _ = try rig.apply_command(2, fx.put(1, 0, 7, 1));

    const zero = encoded(&fx.put(1, 0, 0, 2)); // `encode` accepts it and the checksum is valid
    try expect_corrupt(&rig, &zero, 3);
    const read = try rig.apply_command(4, fx.get(1, 0, 3));
    try testing.expectEqual(@as(u64, 7), read.result);
}

test "kv: a command that fails its checksum, version, kind or key range is corrupt" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);
    const valid = encoded(&fx.put(1, 0, 7, 1));

    var torn = valid;
    torn[10] ^= 0x01;
    try expect_corrupt(&rig, &torn, 2);
    var version = valid;
    version[2] += 1;
    seal(&version);
    try expect_corrupt(&rig, &version, 3);
    var kind = valid;
    kind[3] = 9;
    seal(&kind);
    try expect_corrupt(&rig, &kind, 4);
    for ([_]u16{ 4, std.math.maxInt(u16) }, 5..) |key, index| {
        const out_of_range = encoded(&fx.get(1, key, 2));
        try expect_corrupt(&rig, &out_of_range, index);
    }
    const put_out = encoded(&fx.put(1, 4, 9, 2));
    try expect_corrupt(&rig, &put_out, 7);
    const read = try rig.apply_command(8, fx.get(1, 0, 3));
    try testing.expectEqual(@as(u64, 0), read.result); // none of them wrote anything
}

test "kv: a no-op, a conf_change and junk of other shapes are foreign, not corrupt" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);
    const valid = encoded(&fx.put(1, 0, 7, 1));

    try expect_foreign(&rig, .normal, "", 2); // a new leader's no-op
    try expect_foreign(&rig, .conf_change, &valid, 3);
    try expect_foreign(&rig, .normal, valid[0 .. command_bytes - 1], 4); // short
    var long: [command_bytes + 1]u8 = @splat(0);
    @memcpy(long[0..command_bytes], &valid);
    try expect_foreign(&rig, .normal, &long, 5);
    var proposal: [command_bytes]u8 = @splat(0); // what a seeded proposal looks like
    proposal[0] = 107;
    try expect_foreign(&rig, .normal, &proposal, 6);
    var no_magic = valid;
    no_magic[0] = 'x';
    try expect_foreign(&rig, .normal, &no_magic, 7);
}

test "workload: a corrupt record is WorkloadInvariant, whatever it sits on" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 51);
    defer rig.deinit(gpa);
    const command = try rig.draw_some();
    try rig.workload.applied(0, &fx.record_of(9, null, 0), 3); // nothing outstanding yet
    var corrupt = fx.record_of(9, null, 0);
    corrupt.corrupt = true;
    try testing.expectError(error.WorkloadInvariant, rig.workload.applied(0, &corrupt, 4));

    rig.workload.invoked(&command, fx.invocation(0, 2, 10));
    corrupt.index = @enumFromInt(2);
    try testing.expectError(error.WorkloadInvariant, rig.workload.applied(0, &corrupt, 11));
    try rig.workload.check_invariants();
}

// ---- Workload.applied on log content ---------------------------------------------------------

test "workload: the operation's own entry naming another client is WorkloadInvariant" {
    var options = fx.options_default;
    options.clients_count = 2;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 52);
    defer rig.deinit(gpa);
    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(0, 2, 10));

    var forged = command;
    forged.client_index = command.client_index +% 1;
    const record = fx.record_of(2, forged, 1);
    try testing.expectError(error.WorkloadInvariant, rig.workload.applied(0, &record, 11));
    try testing.expectEqual(@as(?u64, null), rig.workload.history()[0].complete_event);
    try fx.expect_stats(&rig.workload, 1, 0, 1);

    const honest = fx.record_of(2, command, 1); // the honest apply still completes it
    try rig.workload.applied(0, &honest, 11);
    try testing.expectEqual(@as(?u64, 11), rig.workload.history()[0].complete_event);
}

test "workload: an apply at or before the invoke event is WorkloadInvariant" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 53);
    defer rig.deinit(gpa);
    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(0, 2, 10));
    const record = fx.record_of(2, command, 1);
    for ([_]u64{ 0, 9, 10 }) |event| {
        try testing.expectError(error.WorkloadInvariant, rig.workload.applied(0, &record, event));
    }
    try testing.expectEqual(@as(u32, 0), rig.workload.stats().ops_completed);
    try rig.workload.applied(0, &record, 11); // one event later is the earliest legal apply
    try testing.expectEqual(@as(?u64, 11), rig.workload.history()[0].complete_event);
}

test "simulation: a tampered operation fails the run with WorkloadInvariant and its seed" {
    var options = Options.quiet(61, 3);
    options.workload = fx.options_default;
    options.history_ops_max = 64;
    options.raft.log_entries_max = 128;
    options.raft.log_bytes_max = 128 * command_bytes;
    var simulation: Simulation = undefined;
    try simulation.init(io, gpa, &options);
    defer simulation.deinit(io, gpa);

    for (0..100_000) |_| {
        if (simulation.workload.history().len > 0) break;

        try simulation.step(io);
    } else return error.TestUnexpectedResult;
    // The first operation is invoked and cannot have applied yet; make its invoke "late".
    simulation.workload.ops[0].invoke_event = std.math.maxInt(u64);
    try testing.expectEqual(@as(?u64, null), simulation.workload.ops[0].complete_event);
    for (0..100_000) |_| {
        simulation.step(io) catch |err| switch (err) {
            error.WorkloadInvariant => {
                const report = simulation.report();
                try testing.expectEqual(@as(u64, 61), report.seed);
                try testing.expectEqual(error.WorkloadInvariant, report.violation);
                return;
            },
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

// ---- the invariant checks fire ---------------------------------------------------------------

test "kv: check_invariants returns KvInvariant for a bad len, key, index or table" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 4);
    defer rig.deinit(gpa);
    _ = try rig.apply_command(2, fx.put(1, 0, 7, 1));
    try rig.kv.check_invariants();

    const kv = &rig.kv;
    const records_all = kv.records;
    kv.len = 5; // past the buffer
    try testing.expectError(error.KvInvariant, kv.check_invariants());
    kv.len = 0;

    _ = try rig.apply_command(3, fx.put(1, 1, 8, 2)); // drained: len is 0 again
    const bytes = encoded(&fx.put(1, 1, 9, 3));
    const entry = fx.raw_entry(4, .normal, &bytes);
    try kv.apply(&entry);
    try kv.check_invariants();
    kv.records[0].command.?.key = 4; // a key past the table
    try testing.expectError(error.KvInvariant, kv.check_invariants());
    kv.records[0].command.?.key = 3;
    try kv.check_invariants();
    kv.records[0].index = types.Index.zero;
    try testing.expectError(error.KvInvariant, kv.check_invariants());
    kv.records[0].index = @enumFromInt(4);
    try kv.check_invariants();

    const values_all = kv.values;
    kv.values = values_all[0..0];
    try testing.expectError(error.KvInvariant, kv.check_invariants());
    kv.values = values_all;
    kv.records = records_all;
    try kv.check_invariants();
}

/// A workload with two invoked operations, the first completed: the shape every case corrupts.
fn two_ops(rig: *fx.WorkloadRig) !void {
    var options = fx.options_default;
    options.clients_count = 2;
    try rig.init(gpa, options, 8, 54);
    errdefer rig.deinit(gpa);

    const first = try rig.draw_some();
    rig.workload.invoked(&first, fx.invocation(0, 2, 10));
    try rig.workload.applied(0, &fx.record_of(2, first, 1), 12);
    const second = try rig.draw_some();
    rig.workload.invoked(&second, fx.invocation(0, 3, 20));
    try rig.workload.check_invariants();
}

test "workload: check_invariants returns WorkloadInvariant for each broken invariant" {
    var rig: fx.WorkloadRig = undefined;
    try two_ops(&rig);
    defer rig.deinit(gpa);
    const workload = &rig.workload;

    workload.len = 9; // past history_ops_max
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    workload.len = 2;

    workload.ops[0].key = 4; // keys_count of the defaults
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    workload.ops[0].key = 0;

    const end = workload.ops[0].complete_event;
    for ([_]u64{ 10, 5 }) |bad| { // complete at, and before, invoke
        workload.ops[0].complete_event = bad;
        try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    }
    workload.ops[0].complete_event = end;

    workload.completed = 2; // disagrees with the records
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    workload.completed = 1;

    try rig.workload.check_invariants();
}

test "workload: check_invariants refuses a busy slot with a bad operation" {
    var rig: fx.WorkloadRig = undefined;
    try two_ops(&rig);
    defer rig.deinit(gpa);
    const workload = &rig.workload;
    const busy = for (workload.slots) |*slot| {
        if (slot.state == .busy) break slot;
    } else return error.TestUnexpectedResult;

    const op_at = busy.op;
    busy.op = workload.len; // past the history
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    busy.op = 0; // a completed operation
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    busy.op = op_at;

    workload.ops[op_at].client_index +%= 1; // another client's operation
    try testing.expectError(error.WorkloadInvariant, workload.check_invariants());
    workload.ops[op_at].client_index -%= 1;
    try workload.check_invariants();
}
