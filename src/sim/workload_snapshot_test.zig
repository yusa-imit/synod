//! Red tests for the KV snapshot stream of `sim/workload.zig` (plan 005 item 6, ADR-009
//! "Simulator"): `KvStateMachine.snapshot` and `restore` replace the `StateMachineFailed` stubs.
//!
//! The stream (ADR-009, little-endian like the command codec): magic `"SKV1"`, version u8 (1),
//! keys u16, `keys` values u64, crc32 (`std.hash.Crc32`) of every byte before it. Its size is
//! `11 + 8 * keys`. The expected bytes below are built here from that layout, never by calling
//! the implementation.
//!
//! API these tests assume (ADR-009):
//!   - `KvStateMachine.snapshot_magic`, `snapshot_version: u8 = 1`,
//!     `snapshot_bytes(keys_count: u16) u32`, `digest(kv: *const KvStateMachine) u64`,
//!     `value(kv: *const KvStateMachine, key: u16) u64`.
//!   - `KvStateMachine.Fault = enum(u8) { none = 1, restore_drops_key = 2 }` and
//!     `Options.fault: Fault` (default `.none`).
//!
//! Choices where ADR-009 is silent (the implementation may argue, not drift silently):
//!   - A bad magic, version, key count (not this machine's `keys_count`) or crc32 is
//!     `StateMachineSnapshotInvalid`. A stream cut short is either that or `EndOfStream`
//!     (the reader ran dry); both are typed, neither is a crash.
//!   - A failed `restore` leaves the register file exactly as it was (the stream is verified
//!     whole before any register is written). `StateMachine.restore` documents "resets all
//!     state, then loads"; for a stream that fails, nothing is reset.
//!   - A snapshot into a writer one byte short of `snapshot_bytes` is `WriteFailed`.
//!   - `Fault.restore_drops_key`: a restore of a valid stream leaves the table different from
//!     the stream's (one register not restored); the stream itself is still accepted.
//!
//! Allocation: `std.testing.allocator` throughout; a leak fails the test.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const fx = @import("workload_fixtures.zig");
const workload_module = @import("workload.zig");

const KvStateMachine = workload_module.KvStateMachine;
const KvRig = fx.KvRig;

const gpa = testing.allocator;
const Prng = @import("prng.zig").Prng;
const keys_max_test = 6;
const stream_max = 11 + 8 * keys_max_test;

/// The stream the contract prescribes for `values`, written by hand into `out`.
fn stream_of(values: []const u64, out: []u8) []const u8 {
    const body = 7 + 8 * values.len;
    @memcpy(out[0..4], "SKV1");
    out[4] = 1;
    std.mem.writeInt(u16, out[5..7], @intCast(values.len), .little);
    for (values, 0..) |value, at| {
        std.mem.writeInt(u64, out[7 + 8 * at ..][0..8], value, .little);
    }
    std.mem.writeInt(u32, out[body..][0..4], std.hash.Crc32.hash(out[0..body]), .little);
    return out[0 .. body + 4];
}

/// Puts `values[k]` into register `k` through `apply`, skipping zeros (a put never writes 0).
fn load(rig: *KvRig, values: []const u64) !void {
    for (values, 0..) |value, key| {
        if (value == 0) continue;
        _ = try rig.apply_command(key + 1, fx.put(0, @intCast(key), value, @intCast(key)));
    }
    _ = rig.kv.drain();
}

fn expect_values(kv: *const KvStateMachine, want: []const u64) !void {
    for (want, 0..) |value, key| try testing.expectEqual(value, kv.value(@intCast(key)));
}

/// `restore(bytes)` on `kv`; the error or null.
fn restore_of(kv: *KvStateMachine, bytes: []const u8) ?anyerror {
    var reader = Io.Reader.fixed(bytes);
    kv.restore(&reader) catch |err| return err;
    return null;
}

fn expect_invalid(kv: *KvStateMachine, bytes: []const u8) !void {
    const err = restore_of(kv, bytes) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(anyerror, error.StateMachineSnapshotInvalid), err);
}

// ---- layout and size -----------------------------------------------------------------------

test "kv snapshot: snapshot_bytes is 11 plus 8 per key" {
    try testing.expectEqual(@as(u32, 19), KvStateMachine.snapshot_bytes(1));
    try testing.expectEqual(@as(u32, 43), KvStateMachine.snapshot_bytes(4));
    try testing.expectEqual(@as(u32, 11 + 8 * 65535), KvStateMachine.snapshot_bytes(65535));
    try testing.expectEqualStrings("SKV1", &KvStateMachine.snapshot_magic);
    try testing.expectEqual(@as(u8, 1), KvStateMachine.snapshot_version);
}

test "kv snapshot: the stream is magic, version, key count, values, crc32 in that order" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    const values = [_]u64{ 5, 0, 0x0102030405060708 };
    try load(&rig, &values);

    var buffer: [stream_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try rig.kv.snapshot(&writer);
    var want_storage: [stream_max]u8 = undefined;
    const want = stream_of(&values, &want_storage);
    try testing.expectEqual(@as(usize, KvStateMachine.snapshot_bytes(3)), want.len);
    try testing.expectEqualSlices(u8, want, writer.buffered());
}

test "kv snapshot: a fresh machine snapshots all zero registers" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 2, 4);
    defer rig.deinit(gpa);
    var buffer: [stream_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try rig.kv.snapshot(&writer);
    var want_storage: [stream_max]u8 = undefined;
    try testing.expectEqualSlices(u8, stream_of(&.{ 0, 0 }, &want_storage), writer.buffered());
}

test "kv snapshot: taking a snapshot changes neither the registers nor the undrained records" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 2, 4);
    defer rig.deinit(gpa);
    var storage: [workload_module.command_bytes]u8 = undefined;
    const entry = fx.entry_of(1, &fx.put(0, 1, 9, 1), &storage);
    try rig.kv.apply(&entry);
    const digest_before = rig.kv.digest();
    var buffer: [stream_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try rig.kv.snapshot(&writer);
    try testing.expectEqual(digest_before, rig.kv.digest());
    try testing.expectEqual(@as(u32, 1), rig.kv.len);
    try rig.kv.check_invariants();
}

// ---- boundaries ----------------------------------------------------------------------------

test "kv snapshot: one key, a buffer of exactly 19 bytes fits and 18 is WriteFailed" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 1, 4);
    defer rig.deinit(gpa);
    try load(&rig, &.{77});
    const size = KvStateMachine.snapshot_bytes(1);
    var buffer: [32]u8 = undefined;

    var exact = Io.Writer.fixed(buffer[0..size]);
    try rig.kv.snapshot(&exact);
    try testing.expectEqual(@as(usize, size), exact.end);
    var want_storage: [stream_max]u8 = undefined;
    try testing.expectEqualSlices(u8, stream_of(&.{77}, &want_storage), exact.buffered());

    var short = Io.Writer.fixed(buffer[0 .. size - 1]);
    try testing.expectError(error.WriteFailed, rig.kv.snapshot(&short));
    try rig.kv.check_invariants();
    try expect_values(&rig.kv, &.{77});
}

test "kv snapshot: a buffer one byte short is WriteFailed for every key count" {
    inline for (.{ 1, 2, 4, keys_max_test }) |keys| {
        var rig: KvRig = undefined;
        try rig.init(gpa, keys, 4);
        defer rig.deinit(gpa);
        var buffer: [stream_max]u8 = undefined;
        const size = KvStateMachine.snapshot_bytes(keys);
        var writer = Io.Writer.fixed(buffer[0 .. size - 1]);
        try testing.expectError(error.WriteFailed, rig.kv.snapshot(&writer));
        var fits = Io.Writer.fixed(buffer[0..size]);
        try rig.kv.snapshot(&fits);
        try testing.expectEqual(@as(usize, size), fits.end);
    }
}

// ---- restore -------------------------------------------------------------------------------

test "kv restore: a snapshot round trips every register and the digest" {
    var source: KvRig = undefined;
    try source.init(gpa, 4, 8);
    defer source.deinit(gpa);
    const values = [_]u64{ 11, 0, std.math.maxInt(u64), 4 };
    try load(&source, &values);
    var buffer: [stream_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try source.kv.snapshot(&writer);

    var target: KvRig = undefined;
    try target.init(gpa, 4, 8);
    defer target.deinit(gpa);
    try testing.expectEqual(@as(?anyerror, null), restore_of(&target.kv, writer.buffered()));
    try expect_values(&target.kv, &values);
    try testing.expectEqual(source.kv.digest(), target.kv.digest());
    try target.kv.check_invariants();
}

test "kv restore: a hand-built stream restores to its values, replacing older ones" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    try load(&rig, &.{ 1, 2, 3 });
    var storage: [stream_max]u8 = undefined;
    const bytes = stream_of(&.{ 0, 9, 0 }, &storage);
    try testing.expectEqual(@as(?anyerror, null), restore_of(&rig.kv, bytes));
    try expect_values(&rig.kv, &.{ 0, 9, 0 });
}

test "kv restore: through the StateMachine vtable the same bytes give the same table" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 2, 8);
    defer rig.deinit(gpa);
    const machine = rig.kv.as_state_machine();
    var storage: [stream_max]u8 = undefined;
    var reader = Io.Reader.fixed(stream_of(&.{ 6, 7 }, &storage));
    try machine.restore(&reader);
    try expect_values(&rig.kv, &.{ 6, 7 });

    var buffer: [stream_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try machine.snapshot(&writer);
    var again: [stream_max]u8 = undefined;
    try testing.expectEqualSlices(u8, stream_of(&.{ 6, 7 }, &again), writer.buffered());
}

test "kv restore: one key round trips" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 1, 4);
    defer rig.deinit(gpa);
    var storage: [stream_max]u8 = undefined;
    try testing.expectEqual(
        @as(?anyerror, null),
        restore_of(&rig.kv, stream_of(&.{42}, &storage)),
    );
    try expect_values(&rig.kv, &.{42});
}

// ---- negative space ------------------------------------------------------------------------

test "kv restore: a bad magic, version or key count is StateMachineSnapshotInvalid" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    try load(&rig, &.{ 1, 2, 3 });
    const digest_before = rig.kv.digest();
    var storage: [stream_max]u8 = undefined;
    const good = stream_of(&.{ 4, 5, 6 }, &storage);

    var bad_magic: [stream_max]u8 = undefined;
    @memcpy(bad_magic[0..good.len], good);
    bad_magic[0] = 'X';
    try expect_invalid(&rig.kv, bad_magic[0..good.len]);

    var bad_version: [stream_max]u8 = undefined;
    @memcpy(bad_version[0..good.len], good);
    bad_version[4] = 2;
    try expect_invalid(&rig.kv, bad_version[0..good.len]);

    var two_keys: [stream_max]u8 = undefined; // A valid stream (crc included) of another size.
    try expect_invalid(&rig.kv, stream_of(&.{ 4, 5 }, &two_keys));
    var four_keys: [stream_max]u8 = undefined;
    try expect_invalid(&rig.kv, stream_of(&.{ 4, 5, 6, 7 }, &four_keys));

    try testing.expectEqual(digest_before, rig.kv.digest()); // nothing was applied
    try expect_values(&rig.kv, &.{ 1, 2, 3 });
}

test "kv restore: flipping any single byte of a stream is rejected and changes nothing" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    try load(&rig, &.{ 1, 2, 3 });
    var storage: [stream_max]u8 = undefined;
    const good = stream_of(&.{ 4, 5, 6 }, &storage);
    for (0..good.len) |at| {
        var bytes: [stream_max]u8 = undefined;
        @memcpy(bytes[0..good.len], good);
        bytes[at] ^= 0x01;
        try expect_invalid(&rig.kv, bytes[0..good.len]);
        try expect_values(&rig.kv, &.{ 1, 2, 3 });
    }
}

test "kv restore: a wrong crc32 is rejected even when the body is well formed" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 2, 8);
    defer rig.deinit(gpa);
    var storage: [stream_max]u8 = undefined;
    const good = stream_of(&.{ 8, 9 }, &storage);
    var bytes: [stream_max]u8 = undefined;
    @memcpy(bytes[0..good.len], good);
    const crc = std.mem.readInt(u32, bytes[good.len - 4 ..][0..4], .little);
    std.mem.writeInt(u32, bytes[good.len - 4 ..][0..4], crc +% 1, .little);
    try expect_invalid(&rig.kv, bytes[0..good.len]);
    try expect_values(&rig.kv, &.{ 0, 0 });
}

test "kv restore: a stream cut at any length is a typed error and changes nothing" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 3, 8);
    defer rig.deinit(gpa);
    try load(&rig, &.{ 1, 2, 3 });
    var storage: [stream_max]u8 = undefined;
    const good = stream_of(&.{ 4, 5, 6 }, &storage);
    for (0..good.len) |len| {
        const err = restore_of(&rig.kv, good[0..len]) orelse return error.TestUnexpectedResult;
        const typed = err == error.StateMachineSnapshotInvalid or err == error.EndOfStream;
        try testing.expect(typed);
        try expect_values(&rig.kv, &.{ 1, 2, 3 });
    }
    // The same machine takes the whole stream afterwards: a failed restore leaves no residue.
    try testing.expectEqual(@as(?anyerror, null), restore_of(&rig.kv, good));
    try expect_values(&rig.kv, &.{ 4, 5, 6 });
}

test "kv restore: bytes after the crc32 are not part of the stream" {
    var rig: KvRig = undefined;
    try rig.init(gpa, 1, 4);
    defer rig.deinit(gpa);
    var storage: [stream_max + 4]u8 = @splat(0xAA);
    const good = stream_of(&.{5}, &storage);
    var reader = Io.Reader.fixed(storage[0 .. good.len + 4]);
    try rig.kv.restore(&reader);
    try expect_values(&rig.kv, &.{5});
    try testing.expectEqual(good.len, reader.seek); // exactly the stream was consumed
}

// ---- the planted fault ---------------------------------------------------------------------

test "kv restore: restore_drops_key accepts a valid stream and leaves a different table" {
    var rig: KvRig = undefined;
    try rig.kv.init(gpa, .{ .keys_count = 4, .applied_max = 4, .fault = .restore_drops_key });
    defer rig.deinit(gpa);
    var storage: [stream_max]u8 = undefined;
    const bytes = stream_of(&.{ 1, 2, 3, 4 }, &storage);
    try testing.expectEqual(@as(?anyerror, null), restore_of(&rig.kv, bytes));

    var honest: KvRig = undefined;
    try honest.init(gpa, 4, 4);
    defer honest.deinit(gpa);
    try testing.expectEqual(@as(?anyerror, null), restore_of(&honest.kv, bytes));
    try testing.expect(honest.kv.digest() != rig.kv.digest());
    var kept: u32 = 0;
    for (0..4) |key| {
        if (rig.kv.value(@intCast(key)) == honest.kv.value(@intCast(key))) kept += 1;
    }
    try testing.expect(kept >= 3); // it drops a key, it does not wipe the table
    try testing.expect(kept < 4);
}

test "kv snapshot: the fault flag does not change what snapshot writes" {
    var plain: KvRig = undefined;
    try plain.init(gpa, 2, 4);
    defer plain.deinit(gpa);
    var planted: KvRig = undefined;
    try planted.kv.init(gpa, .{ .keys_count = 2, .applied_max = 4, .fault = .restore_drops_key });
    defer planted.deinit(gpa);
    try load(&plain, &.{ 3, 4 });
    try load(&planted, &.{ 3, 4 });
    var a: [stream_max]u8 = undefined;
    var b: [stream_max]u8 = undefined;
    var writer_a = Io.Writer.fixed(&a);
    var writer_b = Io.Writer.fixed(&b);
    try plain.kv.snapshot(&writer_a);
    try planted.kv.snapshot(&writer_b);
    try testing.expectEqualSlices(u8, writer_a.buffered(), writer_b.buffered());
}

// ---- model and fuzz ------------------------------------------------------------------------

test "kv snapshot: seeded tables round trip through snapshot and restore" {
    var prng = Prng.init(0x5afe);
    for (0..64) |_| {
        const keys = 1 + @as(u16, @intCast(prng.uint_less_than(keys_max_test)));
        var values: [keys_max_test]u64 = undefined;
        for (values[0..keys]) |*value| value.* = if (prng.chance(50)) 0 else prng.next_u64();

        var source: KvRig = undefined;
        try source.init(gpa, keys, 4);
        defer source.deinit(gpa);
        for (values[0..keys], 0..) |value, key| {
            if (value == 0) continue;
            _ = try source.apply_command(key + 1, fx.put(0, @intCast(key), value, 1));
        }
        var buffer: [stream_max]u8 = undefined;
        var writer = Io.Writer.fixed(buffer[0..KvStateMachine.snapshot_bytes(keys)]);
        try source.kv.snapshot(&writer);
        var want: [stream_max]u8 = undefined;
        try testing.expectEqualSlices(u8, stream_of(values[0..keys], &want), writer.buffered());

        var target: KvRig = undefined;
        try target.init(gpa, keys, 4);
        defer target.deinit(gpa);
        try testing.expectEqual(@as(?anyerror, null), restore_of(&target.kv, writer.buffered()));
        try expect_values(&target.kv, values[0..keys]);
        try testing.expectEqual(source.kv.digest(), target.kv.digest());
    }
}

fn fuzz_restore(_: void, smith: *testing.Smith) anyerror!void {
    const keys: u16 = 2;
    var bytes: [stream_max]u8 = undefined;
    var storage: [stream_max]u8 = undefined;
    const good = stream_of(&.{ smith.value(u64), smith.value(u64) }, &storage);
    @memcpy(bytes[0..good.len], good);
    var len: usize = good.len;
    for (0..smith.valueRangeAtMost(u8, 0, 3)) |_| {
        if (smith.eos()) break;
        const at = smith.valueRangeAtMost(u8, 0, @intCast(@max(len, 1) - 1));
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => bytes[at] ^= smith.value(u8),
            1 => len = at,
            else => bytes[at] = smith.value(u8),
        }
    }

    var rig: KvRig = undefined;
    try rig.init(gpa, keys, 4);
    defer rig.deinit(gpa);
    try load(&rig, &.{ 1, 1 });
    const before = rig.kv.digest();
    // The oracle: the contract's own checks, on the same bytes.
    const body = 7 + 8 * keys;
    const canonical = len >= body + 4 and std.mem.eql(u8, bytes[0..4], "SKV1") and
        bytes[4] == 1 and std.mem.readInt(u16, bytes[5..7], .little) == keys and
        std.mem.readInt(u32, bytes[body..][0..4], .little) ==
            std.hash.Crc32.hash(bytes[0..body]);
    const err = restore_of(&rig.kv, bytes[0..len]);
    if (canonical) {
        try testing.expectEqual(@as(?anyerror, null), err);
        try testing.expectEqual(
            std.mem.readInt(u64, bytes[7..15], .little),
            rig.kv.value(0),
        );
    } else {
        try testing.expect(err != null);
        try testing.expectEqual(before, rig.kv.digest());
    }
    try rig.kv.check_invariants();
}

test "kv restore: fuzz: arbitrary bytes are accepted exactly when canonical, else change nothing" {
    try testing.fuzz({}, fuzz_restore, .{});
}
