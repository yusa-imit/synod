//! Tests for `sim/workload.zig` (plan 004 item 10, ADR-008 "Workload"): the command codec, the
//! `KvStateMachine` and the `Workload` bookkeeping, without a `Simulation`. The seeded
//! model-based tests are in `workload_model_test.zig`, the cluster-level ones in
//! `simulation_workload_test.zig`.
//!
//! Choices where ADR-008 is silent (the implementation may argue, not drift silently):
//!   - `KvStateMachine.init(gpa, .{ keys_count, applied_max })` / `deinit(gpa)` allocate the
//!     value table and the record buffer; `check_invariants() InvariantError!void` exists on
//!     `KvStateMachine` and on `Workload`.
//!   - `decode` checks the length first; the other `DecodeError`s are provoked here with a
//!     re-sealed checksum so the order of the field checks is not pinned.
//!   - `apply` records every entry. A `conf_change` entry, an empty or undecodable `normal`
//!     entry and a decoded command whose key is >= `keys_count` all get `command = null` and
//!     `result = 0` and leave the state alone (the typed "bad key" outcome: it is never handed
//!     to the history checker, the proposer's operation just never completes).
//!   - `reset` zeroes every key and voids the undrained records (the machine is volatile).
//!   - `Workload.next_command(now_ms)` draws the next due time, `[now_ms + 1, now_ms +
//!     op_interval_ms_max]`, even when it returns null (every client busy); the first due time
//!     is `[1, op_interval_ms_max]`. A client whose operation went pending is retired: its
//!     index is never used again, the slot gets a fresh index.
//!   - A crashed proposer's operations stay pending for good, even if a restarted node later
//!     applies the same entry.
//!   - `ops_pending == ops_invoked - ops_completed`.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const fx = @import("workload_fixtures.zig");
const invariants = @import("invariants.zig");
const linearizability = @import("linearizability.zig");
const workload_module = @import("workload.zig");

const Command = workload_module.Command;
const KvStateMachine = workload_module.KvStateMachine;
const Workload = workload_module.Workload;
const command_bytes = workload_module.command_bytes;
const decode = workload_module.decode;
const encode = workload_module.encode;

const gpa = testing.allocator;

// ---- codec ----------------------------------------------------------------------------------

fn encoded(command: *const Command) [command_bytes]u8 {
    var out: [command_bytes]u8 = undefined;
    encode(command, &out);
    return out;
}

/// Writes the checksum of bytes 0..20 into bytes 20..24, so a test can break one field only.
fn seal(bytes: *[command_bytes]u8) void {
    std.mem.writeInt(u32, bytes[20..24], std.hash.Crc32.hash(bytes[0..20]), .little);
}

test "codec: the contract constants are 24 bytes and version 1" {
    try testing.expectEqual(@as(u32, 24), workload_module.command_bytes);
    try testing.expectEqual(@as(u8, 1), workload_module.command_version);
}

test "codec: encode then decode returns the command at every field boundary" {
    const kinds = [_]workload_module.Kind{ .put, .get };
    const clients = [_]u16{ 0, 1, std.math.maxInt(u16) };
    const keys = [_]u16{ 0, 1, std.math.maxInt(u16) };
    const values = [_]u64{ 0, 1, 0x0102030405060708, std.math.maxInt(u64) };
    const op_ids = [_]u32{ 0, 1, std.math.maxInt(u32) };
    var count: u32 = 0;
    for (kinds) |kind| for (clients) |client| for (keys) |key| for (values) |value| {
        for (op_ids) |op_id| {
            const command: Command = .{
                .kind = kind,
                .client_index = client,
                .key = key,
                .value = value,
                .op_id = op_id,
            };
            const bytes = encoded(&command);
            try testing.expectEqual(command, try decode(&bytes));
            count += 1;
        }
    };
    try testing.expectEqual(@as(u32, 2 * 3 * 3 * 4 * 3), count);
}

test "codec: the layout is magic, version, kind, little-endian fields, then crc32 of bytes 0..20" {
    const command: Command = .{
        .kind = .put,
        .client_index = 0x0102,
        .key = 0x0304,
        .value = 0x1112131415161718,
        .op_id = 0x21222324,
    };
    const expected_head = [20]u8{
        'k', 'v', 1, 1, // magic, version, kind put
        0x02, 0x01, 0x04, 0x03, // client, key
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, // value
        0x24, 0x23, 0x22, 0x21, // op_id
    };
    const bytes = encoded(&command);
    try testing.expectEqualSlices(u8, &expected_head, bytes[0..20]);
    const crc = std.hash.Crc32.hash(&expected_head);
    try testing.expectEqual(crc, std.mem.readInt(u32, bytes[20..24], .little));

    const read = fx.get(9, 2, 5);
    const read_bytes = encoded(&read);
    try testing.expectEqual(@as(u8, 2), read_bytes[3]); // kind get
}

test "decode: every length but 24 is CommandLength, down to empty and up past the limit" {
    const bytes = encoded(&fx.put(1, 2, 3, 4));
    var storage: [command_bytes + 8]u8 = @splat(0);
    @memcpy(storage[0..command_bytes], &bytes);
    for (0..storage.len + 1) |len| {
        if (len == command_bytes) continue;
        try testing.expectError(error.CommandLength, decode(storage[0..len]));
    }
    try testing.expectEqual(fx.put(1, 2, 3, 4), try decode(storage[0..command_bytes]));
}

test "decode: a wrong magic is CommandMagic even when the checksum is valid" {
    for ([_]usize{ 0, 1 }) |at| {
        for ([_]u8{ 0, 'K', 'V', 'x', 0xff }) |byte| {
            var bytes = encoded(&fx.put(1, 2, 3, 4));
            if (bytes[at] == byte) continue;
            bytes[at] = byte;
            seal(&bytes);
            try testing.expectError(error.CommandMagic, decode(&bytes));
        }
    }
}

test "decode: an unknown version is CommandVersion even when the checksum is valid" {
    for ([_]u8{ 0, 2, 3, 0xff }) |version| {
        var bytes = encoded(&fx.get(1, 2, 4));
        bytes[2] = version;
        seal(&bytes);
        try testing.expectError(error.CommandVersion, decode(&bytes));
    }
}

test "decode: a kind outside put and get is CommandKind even when the checksum is valid" {
    for ([_]u8{ 0, 3, 4, 0x80, 0xff }) |kind| {
        var bytes = encoded(&fx.put(1, 2, 3, 4));
        bytes[3] = kind;
        seal(&bytes);
        try testing.expectError(error.CommandKind, decode(&bytes));
    }
}

test "decode: a changed payload or checksum byte is CommandChecksum" {
    // Offsets 4..24 hold client, key, value, op_id and the crc: no field check can fire first.
    for (4..command_bytes) |at| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |flip| {
            var bytes = encoded(&fx.put(0x0102, 0x0304, 0x1112131415161718, 0x21222324));
            bytes[at] ^= flip;
            try testing.expectError(error.CommandChecksum, decode(&bytes));
        }
    }
}

test "decode: no single flipped bit of a valid encoding is accepted" {
    const original = encoded(&fx.put(5, 6, 7, 8));
    var rejected: u32 = 0;
    for (0..command_bytes * 8) |bit| {
        var bytes = original;
        bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        if (decode(&bytes)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {
            rejected += 1;
        }
    }
    try testing.expectEqual(@as(u32, command_bytes * 8), rejected);
}

test "codec: fuzz: decode never crashes and accepts only canonical encodings" {
    try testing.fuzz({}, fuzz_decode, .{});
}

fn fuzz_decode(context: void, smith: *testing.Smith) anyerror!void {
    _ = context;
    var buffer: [command_bytes + 8]u8 = undefined;
    const len = smith.slice(&buffer);
    if (decode(buffer[0..len])) |command| {
        // Accepted: it was exactly one canonical encoding.
        try testing.expectEqual(@as(usize, command_bytes), len);
        const again = encoded(&command);
        try testing.expectEqualSlices(u8, buffer[0..command_bytes], &again);
    } else |_| {}

    const command: Command = .{
        .kind = if (smith.value(bool)) .put else .get,
        .client_index = smith.value(u16),
        .key = smith.value(u16),
        .value = smith.value(u64),
        .op_id = smith.value(u32),
    };
    var bytes = encoded(&command);
    try testing.expectEqual(command, try decode(&bytes));
    const at = smith.valueRangeAtMost(u8, 0, command_bytes - 1);
    bytes[at] ^= smith.valueRangeAtMost(u8, 1, 255);
    try testing.expect(std.meta.isError(decode(&bytes)));
}

// ---- KvStateMachine -------------------------------------------------------------------------

test "kv: a put stores its value, a get reads it back, an unset key reads 0" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);

    const unset = try rig.apply_command(2, fx.get(1, 3, 1));
    try testing.expectEqual(@as(u64, 0), unset.result);
    const stored = try rig.apply_command(3, fx.put(1, 3, 77, 2));
    try testing.expectEqual(@as(u64, 77), stored.result);
    const read = try rig.apply_command(4, fx.get(2, 3, 3));
    try testing.expectEqual(@as(u64, 77), read.result);
    const other = try rig.apply_command(5, fx.get(2, 2, 4));
    try testing.expectEqual(@as(u64, 0), other.result); // keys are independent
    const overwritten = try rig.apply_command(6, fx.put(2, 3, 78, 5));
    try testing.expectEqual(@as(u64, 78), overwritten.result);
    const again = try rig.apply_command(7, fx.get(1, 3, 6));
    try testing.expectEqual(@as(u64, 78), again.result);
    try rig.kv.check_invariants();
}

test "kv: a record carries index, entry fingerprint, decoded command and result" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);

    const command = fx.put(9, 1, 1234, 77);
    var storage: [command_bytes]u8 = undefined;
    const entry = fx.entry_of(11, &command, &storage);
    try rig.kv.apply(&entry);
    const records = rig.kv.drain();
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqual(entry.index, records[0].index);
    try testing.expectEqual(invariants.fingerprint(&entry), records[0].entry_fingerprint);
    try testing.expectEqual(@as(?Command, command), records[0].command);
    try testing.expectEqual(@as(u64, 1234), records[0].result);
}

test "kv: the fingerprint tells two commands at one index apart" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);

    const first = try rig.apply_command(2, fx.put(1, 0, 5, 1));
    const second = try rig.apply_command(2, fx.put(1, 0, 6, 2));
    try testing.expect(first.entry_fingerprint != second.entry_fingerprint);
}

test "kv: no-op, conf_change and undecodable entries are recorded without a command" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 16);
    defer rig.deinit(gpa);
    _ = try rig.apply_command(2, fx.put(1, 0, 5, 1));

    const valid = encoded(&fx.put(1, 0, 99, 2));
    var torn = valid;
    torn[10] ^= 0x01;
    const entries = [_]struct { kind: @import("../types.zig").EntryKind, data: []const u8 }{
        .{ .kind = .normal, .data = "" }, // a new leader's no-op
        .{ .kind = .conf_change, .data = &valid }, // a valid command inside a membership entry
        .{ .kind = .normal, .data = &torn }, // bad checksum
        .{ .kind = .normal, .data = valid[0 .. command_bytes - 1] }, // short
        .{ .kind = .normal, .data = "not a command at all, but 24" }, // long
    };
    for (entries, 3..) |spec, index| {
        const entry = fx.raw_entry(index, spec.kind, spec.data);
        const entry_fingerprint = invariants.fingerprint(&entry);
        try rig.kv.apply(&entry);
        const records = rig.kv.drain();
        try testing.expectEqual(@as(usize, 1), records.len);
        try testing.expectEqual(entry.index, records[0].index);
        try testing.expectEqual(entry_fingerprint, records[0].entry_fingerprint);
        try testing.expectEqual(@as(?Command, null), records[0].command);
        try testing.expectEqual(@as(u64, 0), records[0].result);
    }
    // None of them touched the register: the original put is still the value.
    const read = try rig.apply_command(20, fx.get(1, 0, 3));
    try testing.expectEqual(@as(u64, 5), read.result);
    try rig.kv.check_invariants();
}

test "kv: a key at keys_count is recorded without a command, keys_count - 1 is served" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);

    const last = try rig.apply_command(2, fx.put(1, 3, 41, 1));
    try testing.expectEqual(@as(u64, 41), last.result);
    try testing.expect(last.command != null);

    for ([_]u16{ 4, 5, std.math.maxInt(u16) }, 3..) |key, index| {
        const bad = try rig.apply_command(index, fx.put(1, key, 42, 2));
        try testing.expectEqual(@as(?Command, null), bad.command);
        try testing.expectEqual(@as(u64, 0), bad.result);
        const bad_get = try rig.apply_command(index + 10, fx.get(1, key, 3));
        try testing.expectEqual(@as(?Command, null), bad_get.command);
    }
    for (0..3) |key| { // no real key was written by the refused commands
        const read = try rig.apply_command(40 + key, fx.get(1, @intCast(key), 9));
        try testing.expectEqual(@as(u64, 0), read.result);
    }
    const kept = try rig.apply_command(50, fx.get(1, 3, 10));
    try testing.expectEqual(@as(u64, 41), kept.result);
}

test "kv: applying into a full buffer is StateMachineFailed and changes nothing" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 2);
    defer rig.deinit(gpa);

    var storage: [3][command_bytes]u8 = undefined;
    const commands = [_]Command{ fx.put(1, 0, 10, 1), fx.put(1, 1, 11, 2), fx.put(1, 0, 12, 3) };
    const first = fx.entry_of(2, &commands[0], &storage[0]);
    const second = fx.entry_of(3, &commands[1], &storage[1]);
    const third = fx.entry_of(4, &commands[2], &storage[2]);
    try rig.kv.apply(&first);
    try rig.kv.apply(&second);
    try testing.expectError(error.StateMachineFailed, rig.kv.apply(&third));
    try testing.expectError(error.StateMachineFailed, rig.kv.apply(&third)); // still full

    const drained = rig.kv.drain();
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqual(@as(u64, 10), drained[0].result);
    try testing.expectEqual(@as(u64, 11), drained[1].result);

    // The refused put (12 at key 0) was not applied, and a drained buffer takes entries again.
    const read = try rig.apply_command(5, fx.get(1, 0, 4));
    try testing.expectEqual(@as(u64, 10), read.result);
    try rig.kv.check_invariants();
}

test "kv: drain returns the records in apply order once, then nothing" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 8);
    defer rig.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rig.kv.drain().len);

    var storage: [3][command_bytes]u8 = undefined;
    const commands = [_]Command{ fx.put(1, 0, 10, 1), fx.get(2, 0, 2), fx.put(3, 1, 30, 3) };
    for (&commands, 0..) |*command, at| {
        const entry = fx.entry_of(2 + at, command, &storage[at]);
        try rig.kv.apply(&entry);
    }
    const records = rig.kv.drain();
    try testing.expectEqual(@as(usize, 3), records.len);
    for (records, commands, 2..) |record, command, index| {
        try testing.expectEqual(@as(u64, index), @intFromEnum(record.index));
        try testing.expectEqual(@as(?Command, command), record.command);
    }
    try testing.expectEqual(@as(usize, 0), rig.kv.drain().len);
}

test "kv: reset sets every key back to 0 and voids undrained records" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    for (0..3) |key| {
        const op_id: u32 = @intCast(1 + key);
        _ = try rig.apply_command(2 + key, fx.put(1, @intCast(key), 100 + key, op_id));
    }
    var storage: [command_bytes]u8 = undefined;
    const pending = fx.put(1, 0, 555, 9);
    const entry = fx.entry_of(9, &pending, &storage);
    try rig.kv.apply(&entry); // undrained

    rig.kv.reset();
    try testing.expectEqual(@as(usize, 0), rig.kv.drain().len);
    for (0..3) |key| {
        const read = try rig.apply_command(20 + key, fx.get(1, @intCast(key), 20));
        try testing.expectEqual(@as(u64, 0), read.result);
    }
    try rig.kv.check_invariants();
}

test "kv: reset frees a full buffer" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 2, 1);
    defer rig.deinit(gpa);

    var storage: [command_bytes]u8 = undefined;
    const command = fx.put(1, 0, 5, 1);
    const entry = fx.entry_of(2, &command, &storage);
    try rig.kv.apply(&entry);
    try testing.expectError(error.StateMachineFailed, rig.kv.apply(&entry));
    rig.kv.reset();
    try rig.kv.apply(&entry);
    try testing.expectEqual(@as(usize, 1), rig.kv.drain().len);
}

test "kv: through the StateMachine interface apply works and snapshot, restore fail" {
    var rig: fx.KvRig = undefined;
    try rig.init(gpa, 4, 4);
    defer rig.deinit(gpa);
    const machine = rig.kv.as_state_machine();

    var storage: [command_bytes]u8 = undefined;
    const command = fx.put(1, 2, 31, 1);
    const entry = fx.entry_of(2, &command, &storage);
    try machine.apply(&entry);
    const records = rig.kv.drain();
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqual(@as(u64, 31), records[0].result);

    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.StateMachineFailed, machine.snapshot(&writer));
    var reader = std.Io.Reader.fixed(&buffer);
    try testing.expectError(error.StateMachineFailed, machine.restore(&reader));
    // The refused snapshot and restore changed no state.
    const read = try rig.apply_command(3, fx.get(1, 2, 2));
    try testing.expectEqual(@as(u64, 31), read.result);
}

// ---- Workload -------------------------------------------------------------------------------

test "workload: with no clients nothing is ever due and the history is empty" {
    var options = fx.options_default;
    options.clients_count = 0;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 1);
    defer rig.deinit(gpa);

    try testing.expectEqual(@as(?u64, null), rig.workload.next_due_ms());
    try testing.expectEqual(@as(usize, 0), rig.workload.history().len);
    try fx.expect_stats(&rig.workload, 0, 0, 0);
    try rig.workload.check_invariants();
}

test "workload: due times are drawn in [1, interval] from the start and after each draw" {
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, fx.options_default, 8, 11);
    defer rig.deinit(gpa);
    const interval_max: u64 = fx.options_default.op_interval_ms_max;

    var due_ms = rig.workload.next_due_ms() orelse return error.TestUnexpectedResult;
    try testing.expect(due_ms >= 1 and due_ms <= interval_max);
    var distinct_gaps: u32 = 0;
    var last_gap: u64 = 0;
    for (0..60) |_| {
        const maybe = rig.workload.next_command(due_ms);
        if (maybe) |command| rig.workload.rejected(&command);
        const next_ms = rig.workload.next_due_ms() orelse return error.TestUnexpectedResult;
        try testing.expect(next_ms >= due_ms + 1);
        try testing.expect(next_ms <= due_ms + interval_max);
        if (next_ms - due_ms != last_gap) distinct_gaps += 1;
        last_gap = next_ms - due_ms;
        due_ms = next_ms;
    }
    try testing.expect(distinct_gaps > 5); // seeded, not a fixed period
}

test "workload: a late draw schedules the next one after the time it was drawn" {
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, fx.options_default, 8, 12);
    defer rig.deinit(gpa);

    const late_ms: u64 = 10_000;
    try testing.expect(rig.workload.next_due_ms().? <= late_ms);
    const maybe = rig.workload.next_command(late_ms);
    if (maybe) |command| rig.workload.rejected(&command);
    const next_ms = rig.workload.next_due_ms().?;
    try testing.expect(next_ms > late_ms);
    try testing.expect(next_ms <= late_ms + fx.options_default.op_interval_ms_max);
}

test "workload: put_percent 100 draws only puts of a nonzero value, 0 only gets, keys in range" {
    inline for (.{ @as(u8, 100), @as(u8, 0) }) |percent| {
        var options = fx.options_default;
        options.put_percent = percent;
        options.keys_count = 4;
        var rig: fx.WorkloadRig = undefined;
        try rig.init(gpa, options, 4, 21);
        defer rig.deinit(gpa);

        var key_seen = [_]bool{false} ** 4;
        for (0..200) |_| {
            const command = try rig.draw_some();
            try testing.expectEqual(percent == 100, command.kind == .put);
            try testing.expect(command.key < 4);
            if (command.kind == .put) try testing.expect(command.value != 0);
            key_seen[command.key] = true;
            rig.workload.rejected(&command);
        }
        for (key_seen) |seen| try testing.expect(seen); // every key is drawn
    }
}

test "workload: put_percent 50 mixes both kinds" {
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, fx.options_default, 4, 22);
    defer rig.deinit(gpa);
    var puts: u32 = 0;
    for (0..400) |_| {
        const command = try rig.draw_some();
        if (command.kind == .put) puts += 1;
        rig.workload.rejected(&command);
    }
    try testing.expect(puts >= 120 and puts <= 280);
}

test "workload: a single key workload draws key 0 only" {
    var options = fx.options_default;
    options.keys_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 4, 23);
    defer rig.deinit(gpa);
    for (0..50) |_| {
        const command = try rig.draw_some();
        try testing.expectEqual(@as(u16, 0), command.key);
        rig.workload.rejected(&command);
    }
}

test "workload: operation ids are never reused, rejected commands included" {
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, fx.options_default, 4, 24);
    defer rig.deinit(gpa);

    var seen: [100]u32 = undefined;
    for (&seen, 0..) |*slot, at| {
        const command = try rig.draw_some();
        slot.* = command.op_id;
        for (seen[0..at]) |earlier| try testing.expect(earlier != command.op_id);
        rig.workload.rejected(&command);
    }
}

fn commands_eql(a: []const Command, b: []const Command) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

test "workload: the same seed draws the same commands and another seed does not" {
    var first: [40]Command = undefined;
    var again: [40]Command = undefined;
    var other: [40]Command = undefined;
    const seeds = [_]u64{ 5, 5, 6 };
    inline for (.{ &first, &again, &other }, 0..) |out, which| {
        var rig: fx.WorkloadRig = undefined;
        try rig.init(gpa, fx.options_default, 4, seeds[which]);
        defer rig.deinit(gpa);
        for (out) |*slot| {
            slot.* = try rig.draw_some();
            rig.workload.rejected(slot);
        }
    }
    try testing.expect(commands_eql(&first, &again));
    try testing.expect(!commands_eql(&first, &other));
}

test "workload: a client has one operation outstanding, completion frees it" {
    var options = fx.options_default;
    options.clients_count = 2;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 16, 31);
    defer rig.deinit(gpa);

    const first = try rig.draw_some();
    rig.workload.invoked(&first, fx.invocation(0, 2, 10));
    const second = try rig.draw_some();
    rig.workload.invoked(&second, fx.invocation(1, 3, 11));
    try testing.expect(first.client_index != second.client_index);
    try testing.expectEqual(@as(?Command, null), try rig.draw()); // both clients busy
    try testing.expectEqual(@as(?Command, null), try rig.draw()); // and the draw is consumed

    const record = fx.record_of(2, first, 0);
    rig.workload.applied(0, &record, 12);
    const third = try rig.draw_some();
    try testing.expect(third.client_index != second.client_index); // that one is still busy
    try testing.expect(third.op_id != first.op_id);
    try rig.workload.check_invariants();
}

test "workload: invoke and completion are recorded with their events" {
    var options = fx.options_default;
    options.put_percent = 100;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 4, 32);
    defer rig.deinit(gpa);

    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(2, 7, 100));
    try testing.expectEqual(@as(usize, 1), rig.workload.history().len);
    const open = rig.workload.history()[0];
    try testing.expectEqual(command.client_index, open.client_index);
    try testing.expectEqual(command.kind, open.kind);
    try testing.expectEqual(command.key, open.key);
    try testing.expectEqual(command.value, open.value);
    try testing.expectEqual(@as(u64, 100), open.invoke_event);
    try testing.expectEqual(@as(?u64, null), open.complete_event);
    try fx.expect_stats(&rig.workload, 1, 0, 1);

    const record = fx.record_of(7, command, command.value);
    rig.workload.applied(2, &record, 104);
    const done = rig.workload.history()[0];
    try testing.expectEqual(@as(?u64, 104), done.complete_event);
    try testing.expectEqual(command.value, done.value);
    try fx.expect_stats(&rig.workload, 1, 1, 0);
}

test "workload: a get completes with the value the proposer's state machine returned" {
    var options = fx.options_default;
    options.put_percent = 0;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 4, 33);
    defer rig.deinit(gpa);

    const results = [_]u64{ 0, 424242 };
    for (results, 0..) |result, round| {
        const command = try rig.draw_some();
        rig.workload.invoked(&command, fx.invocation(1, 5 + round, 10 + round * 10));
        const record = fx.record_of(5 + round, command, result);
        rig.workload.applied(1, &record, 15 + round * 10);
        const done = rig.workload.history()[round];
        try testing.expectEqual(result, done.value);
        try testing.expectEqual(@as(?u64, 15 + round * 10), done.complete_event);
        try testing.expectEqual(workload_module.Kind.get, done.kind);
    }
}

test "workload: an apply on another node or at another index leaves the operation outstanding" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 4, 34);
    defer rig.deinit(gpa);

    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(0, 6, 10));
    const elsewhere = fx.record_of(6, command, 1);
    rig.workload.applied(1, &elsewhere, 11); // a follower applied it: not the proposer
    const earlier = fx.record_of(5, command, 1);
    rig.workload.applied(0, &earlier, 12);
    const later = fx.record_of(7, command, 1);
    rig.workload.applied(0, &later, 13);
    try testing.expectEqual(@as(?u64, null), rig.workload.history()[0].complete_event);
    try testing.expectEqual(@as(u32, 0), rig.workload.stats().ops_completed);
    try testing.expectEqual(@as(?Command, null), try rig.draw()); // still busy

    const proposer = fx.record_of(6, command, 1);
    rig.workload.applied(0, &proposer, 14);
    try testing.expectEqual(@as(?u64, 14), rig.workload.history()[0].complete_event);
}

test "workload: a different entry at the operation's index leaves it pending, client retired" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 35);
    defer rig.deinit(gpa);

    const first = try rig.draw_some();
    rig.workload.invoked(&first, fx.invocation(0, 5, 10));
    var rival = first;
    rival.op_id = first.op_id +% 1; // another operation's entry won index 5
    const lost = fx.record_of(5, rival, 9);
    rig.workload.applied(0, &lost, 12);
    try testing.expectEqual(@as(?u64, null), rig.workload.history()[0].complete_event);
    try fx.expect_stats(&rig.workload, 1, 0, 1);

    // The one client is free again, under a fresh index; the old one stays outstanding.
    const second = try rig.draw_some();
    try testing.expect(second.client_index != first.client_index);
    rig.workload.invoked(&second, fx.invocation(0, 6, 20));
    try testing.expect(!fx.client_reused_after_pending(rig.workload.history()));
    try rig.workload.check_invariants();
}

test "workload: a no-op or membership entry at the operation's index leaves it pending too" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 36);
    defer rig.deinit(gpa);

    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(0, 3, 10));
    const no_command = fx.record_of(3, null, 0);
    rig.workload.applied(0, &no_command, 11);
    try testing.expectEqual(@as(?u64, null), rig.workload.history()[0].complete_event);
    const next = try rig.draw_some();
    try testing.expect(next.client_index != command.client_index);
}

test "workload: a crashed proposer's operations stay pending, other nodes' operations complete" {
    var options = fx.options_default;
    options.clients_count = 2;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 8, 37);
    defer rig.deinit(gpa);

    const doomed = try rig.draw_some();
    rig.workload.invoked(&doomed, fx.invocation(0, 4, 10));
    const survivor = try rig.draw_some();
    rig.workload.invoked(&survivor, fx.invocation(1, 5, 11));

    rig.workload.crashed(2); // a node with no operation: nothing changes
    try testing.expectEqual(@as(u32, 0), rig.workload.stats().ops_completed);
    rig.workload.crashed(0);

    // A restarted node 0 re-applying the very entry does not resurrect the operation.
    const reapplied = fx.record_of(4, doomed, 3);
    rig.workload.applied(0, &reapplied, 20);
    const done = fx.record_of(5, survivor, 3);
    rig.workload.applied(1, &done, 21);

    const history = rig.workload.history();
    try testing.expectEqual(@as(usize, 2), history.len);
    try testing.expectEqual(@as(?u64, null), history[0].complete_event);
    try testing.expectEqual(@as(?u64, 21), history[1].complete_event);
    try fx.expect_stats(&rig.workload, 2, 1, 1);
    const next = try rig.draw_some();
    try testing.expect(next.client_index != doomed.client_index);
    rig.workload.invoked(&next, fx.invocation(1, 6, 30));
    try testing.expect(!fx.client_reused_after_pending(rig.workload.history()));
    try rig.workload.check_invariants();
}

test "workload: a full history stops commands and completion does not make room" {
    var options = fx.options_default;
    options.clients_count = 4;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 3, 41);
    defer rig.deinit(gpa);

    var commands: [3]Command = undefined;
    for (&commands, 0..) |*command, at| {
        try testing.expect(rig.workload.next_due_ms() != null);
        command.* = try rig.draw_some();
        rig.workload.invoked(command, fx.invocation(0, 2 + at, 10 + at));
    }
    try testing.expectEqual(@as(?u64, null), rig.workload.next_due_ms());
    try testing.expectEqual(@as(usize, 3), rig.workload.history().len);

    const record = fx.record_of(2, commands[0], 0);
    rig.workload.applied(0, &record, 20);
    try testing.expectEqual(@as(u32, 1), rig.workload.stats().ops_completed);
    try testing.expectEqual(@as(u32, 3), rig.workload.stats().ops_invoked);
    try testing.expectEqual(@as(?u64, null), rig.workload.next_due_ms());
    try testing.expectEqual(@as(usize, 3), rig.workload.history().len);
}

test "workload: a rejected command leaves no record and gives its room back" {
    var options = fx.options_default;
    options.clients_count = 1;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 1, 42);
    defer rig.deinit(gpa);

    const refused = try rig.draw_some();
    rig.workload.rejected(&refused);
    try testing.expectEqual(@as(usize, 0), rig.workload.history().len);
    try fx.expect_stats(&rig.workload, 0, 0, 0);
    try testing.expect(rig.workload.next_due_ms() != null); // room for the one op is still there

    const accepted = try rig.draw_some(); // the one client is free again
    try testing.expect(accepted.op_id != refused.op_id);
    rig.workload.invoked(&accepted, fx.invocation(0, 2, 10));
    try testing.expectEqual(@as(?u64, null), rig.workload.next_due_ms());
    try testing.expectEqual(@as(usize, 1), rig.workload.history().len);
    try rig.workload.check_invariants();
}

test "workload: ack_uncommitted completes a put at invoke, after its invoke event" {
    var options = fx.options_default;
    options.put_percent = 100;
    options.fault = .ack_uncommitted;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 4, 51);
    defer rig.deinit(gpa);

    const command = try rig.draw_some();
    rig.workload.invoked(&command, fx.invocation(0, 3, 50));
    const op = rig.workload.history()[0];
    try testing.expect(op.complete_event != null);
    try testing.expect(op.complete_event.? > op.invoke_event);
    try testing.expectEqual(command.value, op.value);
    try fx.expect_stats(&rig.workload, 1, 1, 0);

    // The real apply, later, changes nothing about the lie.
    const record = fx.record_of(3, command, command.value);
    rig.workload.applied(0, &record, 90);
    try testing.expectEqual(op, rig.workload.history()[0]);
    try testing.expectEqual(@as(u32, 1), rig.workload.stats().ops_completed);
    try rig.workload.check_invariants();
}

test "workload: ack_uncommitted never acks a get, and fault none never acks a put" {
    var gets = fx.options_default;
    gets.put_percent = 0;
    gets.fault = .ack_uncommitted;
    var puts = fx.options_default;
    puts.put_percent = 100;
    puts.fault = .none;
    inline for (.{ gets, puts }) |options| {
        var rig: fx.WorkloadRig = undefined;
        try rig.init(gpa, options, 4, 52);
        defer rig.deinit(gpa);
        const command = try rig.draw_some();
        rig.workload.invoked(&command, fx.invocation(0, 3, 50));
        try testing.expectEqual(@as(?u64, null), rig.workload.history()[0].complete_event);
        try testing.expectEqual(@as(u32, 0), rig.workload.stats().ops_completed);
    }
}

test "workload: a scripted correct run passes the checker, a forged read fails it" {
    var options = fx.options_default;
    options.clients_count = 2;
    var rig: fx.WorkloadRig = undefined;
    try rig.init(gpa, options, 64, 61);
    defer rig.deinit(gpa);

    var server = [_]u64{0} ** 4; // a trivially sequential server on node 0
    var event: u64 = 0;
    for (0..40) |step| {
        const command = (try rig.draw()) orelse return error.TestUnexpectedResult;
        const index: u64 = 2 + step;
        event += 1;
        rig.workload.invoked(&command, fx.invocation(0, index, event));
        if (step % 10 == 9) {
            rig.workload.crashed(0); // the proposer dies before it applies
            continue;
        }
        if (command.kind == .put) server[command.key] = command.value;
        const record = fx.record_of(index, command, server[command.key]);
        event += 1;
        rig.workload.applied(0, &record, event);
    }
    try fx.expect_stats(&rig.workload, 40, 36, 4);

    const history = rig.workload.history();
    var checker: linearizability.HistoryChecker = undefined;
    try checker.init(gpa, .{
        .history_ops_max = 64,
        .keys_max = 4,
        .search_steps_max = 10_000_000,
    });
    defer checker.deinit(gpa);
    try checker.check(history);

    // Forge: a completed get returning a value no put ever wrote.
    var forged: [64]linearizability.Operation = undefined;
    @memcpy(forged[0..history.len], history);
    var tampered = false;
    for (forged[0..history.len]) |*op| {
        if (op.kind != .get or op.complete_event == null) continue;
        op.value = 0xdead_beef_dead_beef;
        tampered = true;
        break;
    }
    try testing.expect(tampered);
    try testing.expectError(error.Linearizability, checker.check(forged[0..history.len]));
}
