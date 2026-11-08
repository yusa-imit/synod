//! Tests for `raft.membership` (plan 005 item 7, ADR-009): the `ConfChange` codec and the joint
//! quorum rules. Expected bytes are built by hand from the documented layout (`raw`), never by
//! calling `encode`; quorum expectations come from a brute-force subset reference written here
//! from the Raft definition (a majority of each set, learners never), not from the implementation.
//! The module is pure and allocation-free, so the only allocations are the output buffers these
//! tests make, which `std.testing.allocator` checks for leaks.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const membership = @import("membership.zig");
const types = @import("../types.zig");

const ConfChange = types.ConfChange;
const Configuration = types.Configuration;
const NodeId = types.NodeId;
const Matches = membership.Matches;
const Crc32 = std.hash.Crc32;

const conf_ids_max = membership.conf_ids_max;
const decode = membership.decode;
const encode = membership.encode;
const encoded_bytes = membership.encoded_bytes;
const quorum_index = membership.quorum_index;
const quorum_reached = membership.quorum_reached;

const node_id = fixtures.node_id;

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// A comptime list of node ids, e.g. `ids(&.{ 1, 2, 3 })`, in static storage.
fn ids(comptime values: []const u64) []const NodeId {
    const Holder = struct {
        const list: [values.len]NodeId = blk: {
            var out: [values.len]NodeId = undefined;
            for (values, 0..) |value, i| out[i] = @enumFromInt(value);
            break :blk out;
        };
    };
    return &Holder.list;
}

fn conf(
    comptime voters: []const u64,
    comptime outgoing: []const u64,
    comptime learners: []const u64,
) Configuration {
    return .{ .voters = ids(voters), .voters_outgoing = ids(outgoing), .learners = ids(learners) };
}

/// Hand-built wire bytes from the documented layout: magic, version, kind, three counts, the ids
/// (voters, outgoing, learners) as u64 LE, then the CRC-32 of everything before it as u32 LE.
fn raw(
    buf: []u8,
    kind: u8,
    voters: []const u64,
    outgoing: []const u64,
    learners: []const u64,
) []u8 {
    @memcpy(buf[0..4], "SYCC");
    buf[4] = 1;
    buf[5] = kind;
    buf[6] = @intCast(voters.len);
    buf[7] = @intCast(outgoing.len);
    buf[8] = @intCast(learners.len);
    var at: usize = 9;
    for ([_][]const u64{ voters, outgoing, learners }) |list| {
        for (list) |id| {
            std.mem.writeInt(u64, buf[at..][0..8], id, .little);
            at += 8;
        }
    }
    return seal(buf, at);
}

/// Appends the CRC-32 of `buf[0..at]` and returns the full message.
fn seal(buf: []u8, at: usize) []u8 {
    std.mem.writeInt(u32, buf[at..][0..4], Crc32.hash(buf[0..at]), .little);
    return buf[0 .. at + 4];
}

fn expect_err(comptime want: anyerror, bytes: []const u8) !void {
    var storage: [conf_ids_max]NodeId = undefined;
    try testing.expectError(want, decode(bytes, &storage));
}

fn expect_ids(want: []const NodeId, got: []const NodeId) !void {
    try testing.expectEqualSlices(NodeId, want, got);
}

fn expect_change_eql(want: *const ConfChange, got: *const ConfChange) !void {
    try testing.expectEqual(std.meta.activeTag(want.*), std.meta.activeTag(got.*));
    const w = switch (want.*) {
        inline else => |c| c,
    };
    const g = switch (got.*) {
        inline else => |c| c,
    };
    try expect_ids(w.voters, g.voters);
    try expect_ids(w.voters_outgoing, g.voters_outgoing);
    try expect_ids(w.learners, g.learners);
}

fn kind_byte(change: *const ConfChange) u8 {
    return switch (change.*) {
        .enter_joint => 1,
        .leave_joint => 2,
    };
}

fn lists_of(change: *const ConfChange) Configuration {
    return switch (change.*) {
        inline else => |c| c,
    };
}

/// Encodes `change` into a buffer from the testing allocator, checks it equals the hand-built
/// bytes, decodes it back and checks the round trip and that the slices point into `ids`.
fn expect_round_trip(change: *const ConfChange) !void {
    const lists = lists_of(change);
    const count = lists.voters.len + lists.voters_outgoing.len + lists.learners.len;
    const want_len: u32 = @intCast(13 + 8 * count);

    const out = try testing.allocator.alloc(u8, want_len + 5);
    defer testing.allocator.free(out);
    @memset(out, 0xAA);

    try testing.expectEqual(want_len, encoded_bytes(change));
    try testing.expectEqual(want_len, encode(change, out));
    try testing.expect(std.mem.allEqual(u8, out[want_len..], 0xAA)); // nothing past the message

    var u_voters: [membership.conf_ids_max]u64 = undefined;
    var u_outgoing: [membership.conf_ids_max]u64 = undefined;
    var u_learners: [membership.conf_ids_max]u64 = undefined;
    const want = try testing.allocator.alloc(u8, want_len);
    defer testing.allocator.free(want);
    for (lists.voters, 0..) |id, i| u_voters[i] = @intFromEnum(id);
    for (lists.voters_outgoing, 0..) |id, i| u_outgoing[i] = @intFromEnum(id);
    for (lists.learners, 0..) |id, i| u_learners[i] = @intFromEnum(id);
    const built = raw(
        want,
        kind_byte(change),
        u_voters[0..lists.voters.len],
        u_outgoing[0..lists.voters_outgoing.len],
        u_learners[0..lists.learners.len],
    );
    try testing.expectEqualSlices(u8, built, out[0..want_len]);

    var storage: [conf_ids_max]NodeId = undefined;
    const decoded = try decode(out[0..want_len], &storage);
    try expect_change_eql(change, &decoded);
    try decoded.validate();

    const got = lists_of(&decoded);
    var base: usize = 0;
    inline for (.{ got.voters, got.voters_outgoing, got.learners }) |list| {
        if (list.len > 0) {
            try testing.expectEqual(@intFromPtr(&storage[base]), @intFromPtr(list.ptr));
        }
        base += list.len;
    }
}

// ---------------------------------------------------------------------------------------------
// Constants and majority
// ---------------------------------------------------------------------------------------------

test "membership: constants match the ADR layout" {
    try testing.expectEqualSlices(u8, "SYCC", &membership.conf_magic);
    try testing.expectEqual(@as(u8, 1), membership.conf_version);
    try testing.expectEqual(@as(u32, 48), membership.conf_ids_max);
    try testing.expectEqual(@as(u32, 397), membership.conf_bytes_max);
}

test "membership: majority is strictly more than half" {
    const cases = [_][2]u32{
        .{ 1, 1 }, .{ 2, 2 }, .{ 3, 2 }, .{ 4, 3 }, .{ 5, 3 }, .{ 8, 5 }, .{ 15, 8 }, .{ 16, 9 },
    };
    for (cases) |case| try testing.expectEqual(case[1], membership.majority(case[0]));
}

// ---------------------------------------------------------------------------------------------
// quorum_reached: joint table
// ---------------------------------------------------------------------------------------------

const QuorumCase = struct {
    name: []const u8,
    configuration: Configuration,
    granted: []const NodeId,
    want: bool,
};

fn q(name: []const u8, c: Configuration, granted: []const NodeId, want: bool) QuorumCase {
    return .{ .name = name, .configuration = c, .granted = granted, .want = want };
}

// Joint: new voters {3,4,5}, old voters {1,2,3}, learner {7}. Node 3 is in both sets.
const joint = conf(&.{ 3, 4, 5 }, &.{ 1, 2, 3 }, &.{7});
const three = conf(&.{ 1, 2, 3 }, &.{}, &.{});
const four = conf(&.{ 1, 2, 3, 4 }, &.{}, &.{});
const with_learners = conf(&.{ 1, 2, 3 }, &.{}, &.{ 7, 8, 9 });
const uneven = conf(&.{9}, &.{ 1, 2, 3, 4, 5 }, &.{});

const quorum_cases = [_]QuorumCase{
    q("new alone wins, old loses", joint, ids(&.{ 4, 5 }), false),
    q("old alone wins, new loses", joint, ids(&.{ 1, 2 }), false),
    q("both win with disjoint nodes", joint, ids(&.{ 1, 2, 4, 5 }), true),
    q("neither wins", joint, ids(&.{ 1, 4 }), false),
    q("nobody granted", joint, ids(&.{}), false),
    q("shared voter counts in both", joint, ids(&.{ 1, 3, 4 }), true),
    q("shared voter alone is not enough", joint, ids(&.{3}), false),
    q("everyone", joint, ids(&.{ 1, 2, 3, 4, 5 }), true),
    q("learner never counts", joint, ids(&.{ 1, 2, 3, 7 }), false),
    q("learner cannot tip a tie", joint, ids(&.{ 3, 5, 7, 9 }), false),
    q("ids outside both sets ignored", joint, ids(&.{ 1, 3, 4, 90, 91, 92 }), true),
    q("outsiders cannot make a majority", joint, ids(&.{ 3, 90, 91, 92, 93 }), false),
    q("order of granted is irrelevant", joint, ids(&.{ 5, 1, 4, 3 }), true),
    q("single set: majority of three", three, ids(&.{ 1, 3 }), true),
    q("single set: minority of three", three, ids(&.{2}), false),
    q("single set: half of four is not enough", four, ids(&.{ 1, 4 }), false),
    q("single set: three of four", four, ids(&.{ 1, 2, 4 }), true),
    q("size 1: the voter", conf(&.{5}, &.{}, &.{}), ids(&.{5}), true),
    q("size 1: someone else", conf(&.{5}, &.{}, &.{}), ids(&.{ 4, 6 }), false),
    q("size 2: one is not a majority", conf(&.{ 1, 2 }, &.{}, &.{}), ids(&.{1}), false),
    q("size 2: both", conf(&.{ 1, 2 }, &.{}, &.{}), ids(&.{ 1, 2 }), true),
    q("learners ignored in a settled set", with_learners, ids(&.{ 1, 7, 8, 9 }), false),
    q("learners do not hurt a real majority", with_learners, ids(&.{ 1, 2, 7 }), true),
    q("joint with identical sets", conf(&.{ 1, 2, 3 }, &.{ 1, 2, 3 }, &.{}), ids(&.{ 2, 3 }), true),
    q("joint, old set larger: new alone", uneven, ids(&.{ 9, 1, 2 }), false),
    q("joint, old set larger: both", uneven, ids(&.{ 9, 1, 2, 3 }), true),
};

test "membership: quorum_reached table over joint and settled configurations" {
    for (quorum_cases) |case| {
        try testing.expectEqual(case.want, quorum_reached(&case.configuration, case.granted));
    }
}

// ---------------------------------------------------------------------------------------------
// quorum_index
// ---------------------------------------------------------------------------------------------

fn expect_index(want: u64, c: Configuration, voters: []const u64, outgoing: []const u64) !void {
    const matches: Matches = .{ .voters = voters, .voters_outgoing = outgoing };
    try testing.expectEqual(want, quorum_index(&c, &matches));
}

test "membership: quorum_index of a single set is the majority-th highest match" {
    try expect_index(5, three, &.{ 5, 3, 9 }, &.{});
    try expect_index(7, three, &.{ 7, 7, 1 }, &.{});
    try expect_index(0, three, &.{ 0, 0, 0 }, &.{});
    try expect_index(42, conf(&.{4}, &.{}, &.{}), &.{42}, &.{});
    const two = conf(&.{ 1, 2 }, &.{}, &.{});
    try expect_index(4, two, &.{ 9, 4 }, &.{});
    try expect_index(4, two, &.{ 4, 9 }, &.{});
}

test "membership: quorum_index of sixteen voters is the ninth highest" {
    const sixteen = comptime blk: {
        var list: [16]u64 = undefined;
        for (&list, 0..) |*id, i| id.* = i + 1;
        break :blk list;
    };
    const c = conf(&sixteen, &.{}, &.{});
    var matches: [16]u64 = undefined;
    for (&matches, 0..) |*m, i| m.* = (i + 1) * 10; // 10..160, ninth highest is 80
    try expect_index(80, c, &matches, &.{});
    std.mem.reverse(u64, &matches);
    try expect_index(80, c, &matches, &.{});
}

test "membership: quorum_index of a joint configuration is the lower of the two majorities" {
    // new {3,4,5} majority match 8; old {1,2,3} majority match 5.
    const c = conf(&.{ 3, 4, 5 }, &.{ 1, 2, 3 }, &.{});
    try expect_index(5, c, &.{ 10, 2, 8 }, &.{ 4, 6, 5 });
    // Now the new set is the laggard: new majority 3, old majority 10.
    try expect_index(3, c, &.{ 3, 1, 5 }, &.{ 9, 20, 10 });
    // Equal majorities.
    try expect_index(7, c, &.{ 7, 7, 0 }, &.{ 7, 9, 7 });
    // Different set sizes: new {9} matches 100, old of five has its third highest at 4.
    try expect_index(4, uneven, &.{100}, &.{ 1, 4, 9, 4, 2 });
}

test "membership: quorum_index of a settled set ignores learners" {
    try expect_index(4, conf(&.{ 1, 2, 3 }, &.{}, &.{ 7, 8 }), &.{ 2, 6, 4 }, &.{});
}

// ---------------------------------------------------------------------------------------------
// Codec: round trips
// ---------------------------------------------------------------------------------------------

test "membership: codec round trips enter_joint with learners" {
    const change: ConfChange = .{ .enter_joint = conf(&.{ 2, 4, 6 }, &.{ 1, 2, 3 }, &.{ 7, 9 }) };
    try change.validate();
    try testing.expectEqual(@as(u32, 13 + 8 * 8), encoded_bytes(&change));
    try expect_round_trip(&change);
}

test "membership: codec round trips enter_joint with empty learners" {
    const change: ConfChange = .{ .enter_joint = conf(&.{ 1, 2, 3 }, &.{ 3, 4 }, &.{}) };
    try change.validate();
    try testing.expectEqual(@as(u32, 13 + 8 * 5), encoded_bytes(&change));
    try expect_round_trip(&change);
}

test "membership: codec round trips leave_joint with and without learners" {
    const bare: ConfChange = .{ .leave_joint = conf(&.{ 1, 2, 3 }, &.{}, &.{}) };
    try bare.validate();
    try testing.expectEqual(@as(u32, 13 + 8 * 3), encoded_bytes(&bare));
    try expect_round_trip(&bare);

    const learned: ConfChange = .{ .leave_joint = conf(&.{ 5, 6 }, &.{}, &.{ 1, 2, 3, 4 }) };
    try learned.validate();
    try testing.expectEqual(@as(u32, 13 + 8 * 6), encoded_bytes(&learned));
    try expect_round_trip(&learned);
}

test "membership: codec round trips ids that need all eight bytes" {
    const big: u64 = std.math.maxInt(u64);
    const change: ConfChange = .{ .leave_joint = .{
        .voters = &.{ node_id(1), node_id(0x0102030405060708), node_id(big) },
        .voters_outgoing = &.{},
        .learners = &.{},
    } };
    try expect_round_trip(&change);
}

test "membership: codec round trips the maximum change and its size is conf_bytes_max" {
    const all = comptime blk: {
        var list: [types.voters_max]u64 = undefined;
        for (&list, 0..) |*id, i| id.* = i + 1;
        break :blk list;
    };
    const learners = comptime blk: {
        var list: [types.learners_max]u64 = undefined;
        for (&list, 0..) |*id, i| id.* = 100 + i;
        break :blk list;
    };
    const change: ConfChange = .{ .enter_joint = .{
        .voters = ids(&all),
        .voters_outgoing = ids(&all),
        .learners = ids(&learners),
    } };
    try change.validate();
    try testing.expectEqual(membership.conf_bytes_max, encoded_bytes(&change));
    try expect_round_trip(&change);
}

test "membership: encode writes the documented bytes" {
    const change: ConfChange = .{ .enter_joint = conf(&.{ 2, 3 }, &.{1}, &.{9}) };
    var want_buf: [13 + 8 * 4]u8 = undefined;
    const want = raw(&want_buf, 1, &.{ 2, 3 }, &.{1}, &.{9});
    var out: [13 + 8 * 4]u8 = undefined;
    try testing.expectEqual(@as(u32, 45), encode(&change, &out));
    try testing.expectEqualSlices(u8, want, &out);
    // Spot-check the fixed header independently of `raw`.
    try testing.expectEqualSlices(u8, "SYCC", out[0..4]);
    try testing.expectEqual(@as(u8, 1), out[4]);
    try testing.expectEqual(@as(u8, 1), out[5]);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 1 }, out[6..9]);
    try testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, out[9..17], .little));
}

test "membership: decode of hand-built bytes yields the same lists" {
    var buf: [13 + 8 * 6]u8 = undefined;
    const bytes = raw(&buf, 2, &.{ 4, 8 }, &.{}, &.{ 1, 2, 3, 9 });
    var storage: [conf_ids_max]NodeId = undefined;
    const change = try decode(bytes, &storage);
    try testing.expectEqual(std.meta.Tag(ConfChange).leave_joint, std.meta.activeTag(change));
    try expect_ids(ids(&.{ 4, 8 }), change.leave_joint.voters);
    try expect_ids(&.{}, change.leave_joint.voters_outgoing);
    try expect_ids(ids(&.{ 1, 2, 3, 9 }), change.leave_joint.learners);
}

// ---------------------------------------------------------------------------------------------
// Codec: every ConfDecodeError
// ---------------------------------------------------------------------------------------------

test "membership: decode shorter than the fixed part is ConfLength" {
    var buf: [13 + 8 * 3]u8 = undefined;
    const good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    for (0..13) |len| {
        try expect_err(error.ConfLength, good[0..len]);
    }
}

test "membership: decode with a length that disagrees with the counts is ConfLength" {
    var buf: [13 + 8 * 3 + 16]u8 = undefined;
    const good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    var storage: [conf_ids_max]NodeId = undefined;
    try testing.expectEqual(@as(usize, 37), good.len);
    _ = try decode(good, &storage); // the control: exact length decodes
    // Truncated by one and by a whole id (still >= 13), and padded by one and by a whole id.
    try expect_err(error.ConfLength, good[0 .. good.len - 1]);
    try expect_err(error.ConfLength, good[0 .. good.len - 8]);
    @memset(buf[good.len..], 0);
    try expect_err(error.ConfLength, buf[0 .. good.len + 1]);
    try expect_err(error.ConfLength, buf[0 .. good.len + 8]);
}

test "membership: decode of exactly the fixed part with nonzero counts is ConfLength" {
    var buf: [13 + 8]u8 = undefined;
    const good = raw(&buf, 2, &.{1}, &.{}, &.{});
    // Drop the id but keep the counts and a fresh checksum: 13 bytes, counts say one id.
    var short: [13]u8 = undefined;
    @memcpy(short[0..9], good[0..9]);
    _ = seal(&short, 9);
    try expect_err(error.ConfLength, &short);
}

test "membership: decode with a wrong magic byte is ConfMagic" {
    var buf: [13 + 8 * 3]u8 = undefined;
    for (0..4) |at| {
        const good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
        good[at] ^= 0x20;
        try expect_err(error.ConfMagic, good);
    }
}

test "membership: decode with an unknown version is ConfVersion" {
    var buf: [13 + 8 * 3]u8 = undefined;
    for ([_]u8{ 0, 2, 255 }) |version| {
        const good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
        good[4] = version;
        _ = seal(good, good.len - 4); // a valid checksum does not save it
        try expect_err(error.ConfVersion, good);
    }
}

test "membership: decode checks length, magic, version, length, checksum, kind in that order" {
    var buf: [13 + 8 * 3]u8 = undefined;
    // Bad magic and bad version together: magic first.
    var good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    good[0] = 'X';
    good[4] = 9;
    try expect_err(error.ConfMagic, good);
    // Bad version and wrong length together: version first.
    good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    good[4] = 9;
    try expect_err(error.ConfVersion, good[0 .. good.len - 3]);
    // Bad magic and wrong length together: magic first.
    good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    good[1] = 'X';
    try expect_err(error.ConfMagic, good[0 .. good.len - 3]);
    // Bad kind with a stale checksum: checksum first.
    good = raw(&buf, 2, &.{ 1, 2, 3 }, &.{}, &.{});
    good[5] = 7;
    try expect_err(error.ConfChecksum, good);
    // Bad kind with a valid checksum and a structurally invalid body: kind before validation.
    good = raw(&buf, 0, &.{ 3, 2, 1 }, &.{}, &.{});
    try expect_err(error.ConfKind, good);
}

fn expected_flip_error(at: usize) anyerror {
    if (at < 4) return error.ConfMagic;
    if (at == 4) return error.ConfVersion;
    if (at >= 6 and at <= 8) return error.ConfLength; // a count changed, so the length is wrong
    return error.ConfChecksum; // kind (5), ids, and the crc bytes themselves
}

test "membership: a flipped byte at any position of an encoded change is rejected" {
    const change: ConfChange = .{ .enter_joint = conf(&.{ 2, 4, 6 }, &.{ 1, 2, 3 }, &.{ 7, 9 }) };
    const len = encoded_bytes(&change);
    try testing.expectEqual(@as(u32, 77), len);
    var out: [conf_bytes_max_for_test]u8 = undefined;
    try testing.expectEqual(len, encode(&change, &out));
    var storage: [conf_ids_max]NodeId = undefined;
    _ = try decode(out[0..len], &storage); // the control

    for (0..len) |at| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |flip| {
            var copy: [conf_bytes_max_for_test]u8 = out;
            copy[at] ^= flip;
            try testing.expectError(expected_flip_error(at), decode(copy[0..len], &storage));
        }
    }
}

const conf_bytes_max_for_test = 397;

test "membership: moving a list count with a stale checksum is ConfChecksum" {
    var buf: [13 + 8 * 4]u8 = undefined;
    const good = raw(&buf, 1, &.{ 1, 2 }, &.{ 3, 4 }, &.{}); // length unchanged below
    good[6] = 3;
    good[7] = 1;
    try expect_err(error.ConfChecksum, good);
}

test "membership: a recomputed checksum over a moved count reaches validation" {
    var buf: [13 + 8 * 4]u8 = undefined;
    var storage: [conf_ids_max]NodeId = undefined;
    const good = raw(&buf, 1, &.{ 1, 2 }, &.{ 3, 4 }, &.{});
    good[6] = 3;
    good[7] = 1; // voters {1,2,3}, outgoing {4}: sorted, so this is a different valid change
    _ = seal(good, good.len - 4);
    const change = try decode(good, &storage);
    try expect_ids(ids(&.{ 1, 2, 3 }), change.enter_joint.voters);
    try expect_ids(ids(&.{4}), change.enter_joint.voters_outgoing);
    good[6] = 1;
    good[7] = 3; // voters {1}, outgoing {2,3,4}
    _ = seal(good, good.len - 4);
    const other = try decode(good, &storage);
    try expect_ids(ids(&.{1}), other.enter_joint.voters);
    try expect_ids(ids(&.{ 2, 3, 4 }), other.enter_joint.voters_outgoing);
}

test "membership: decode with an unknown kind and a valid checksum is ConfKind" {
    var buf: [13 + 8 * 3]u8 = undefined;
    for ([_]u8{ 0, 3, 4, 255 }) |kind| {
        const bytes = raw(&buf, kind, &.{ 1, 2, 3 }, &.{}, &.{});
        try expect_err(error.ConfKind, bytes);
    }
}

// ---------------------------------------------------------------------------------------------
// Codec: every ConfError surfaced by decode (valid checksum, invalid content)
// ---------------------------------------------------------------------------------------------

test "membership: decode surfaces ConfNodesUnsorted for unsorted, duplicate and zero ids" {
    var buf: [13 + 8 * 8]u8 = undefined;
    try expect_err(error.ConfNodesUnsorted, raw(&buf, 2, &.{ 2, 1 }, &.{}, &.{}));
    try expect_err(error.ConfNodesUnsorted, raw(&buf, 2, &.{ 1, 1 }, &.{}, &.{}));
    try expect_err(error.ConfNodesUnsorted, raw(&buf, 2, &.{ 0, 1 }, &.{}, &.{}));
    try expect_err(error.ConfNodesUnsorted, raw(&buf, 1, &.{ 1, 2 }, &.{ 5, 4 }, &.{}));
    try expect_err(error.ConfNodesUnsorted, raw(&buf, 2, &.{ 1, 2 }, &.{}, &.{ 9, 8 }));
}

test "membership: decode surfaces ConfVotersEmpty" {
    var buf: [13 + 8 * 2]u8 = undefined;
    try expect_err(error.ConfVotersEmpty, raw(&buf, 2, &.{}, &.{}, &.{5}));
    try expect_err(error.ConfVotersEmpty, raw(&buf, 1, &.{}, &.{1}, &.{}));
}

test "membership: decode surfaces ConfVotersTooMany and ConfLearnersTooMany" {
    var buf: [13 + 8 * 40]u8 = undefined;
    const seventeen = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 };
    try expect_err(error.ConfVotersTooMany, raw(&buf, 2, &seventeen, &.{}, &.{}));
    try expect_err(error.ConfVotersTooMany, raw(&buf, 1, &.{1}, &seventeen, &.{}));
    try expect_err(error.ConfLearnersTooMany, raw(&buf, 2, &.{100}, &.{}, &seventeen));
}

test "membership: decode surfaces ConfLearnerIsVoter" {
    var buf: [13 + 8 * 4]u8 = undefined;
    try expect_err(error.ConfLearnerIsVoter, raw(&buf, 2, &.{ 1, 2 }, &.{}, &.{2}));
    try expect_err(error.ConfLearnerIsVoter, raw(&buf, 1, &.{ 1, 2 }, &.{3}, &.{1}));
}

test "membership: decode surfaces ConfJointShape for enter without outgoing and leave with it" {
    var buf: [13 + 8 * 4]u8 = undefined;
    try expect_err(error.ConfJointShape, raw(&buf, 1, &.{ 1, 2 }, &.{}, &.{}));
    try expect_err(error.ConfJointShape, raw(&buf, 2, &.{ 1, 2 }, &.{3}, &.{}));
}

test "membership: counts that would overflow the id storage are an error, not a crash" {
    var big: [255]u64 = undefined;
    for (&big, 0..) |*id, i| id.* = i + 1;
    var buf: [13 + 8 * 3 * 255]u8 = undefined;
    var storage: [conf_ids_max]NodeId = undefined;
    const bytes = raw(&buf, 1, &big, &big, &big);
    if (decode(bytes, &storage)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ConfLength, error.ConfVotersTooMany, error.ConfLearnersTooMany => {},
        else => return err,
    }
}

// ---------------------------------------------------------------------------------------------
// enter_joint / leave_joint
// ---------------------------------------------------------------------------------------------

test "membership: enter_joint puts the target in voters and the current voters in outgoing" {
    const current = conf(&.{ 1, 2, 3 }, &.{}, &.{7});
    const target = conf(&.{ 3, 4, 5 }, &.{}, &.{ 8, 9 });
    const change = membership.enter_joint(&current, &target);
    try testing.expectEqual(std.meta.Tag(ConfChange).enter_joint, std.meta.activeTag(change));
    try expect_ids(ids(&.{ 3, 4, 5 }), change.enter_joint.voters);
    try expect_ids(ids(&.{ 1, 2, 3 }), change.enter_joint.voters_outgoing);
    try expect_ids(ids(&.{ 8, 9 }), change.enter_joint.learners);
    try change.validate();
}

test "membership: enter_joint with the same voters (learners only) is a legal change" {
    const current = conf(&.{ 1, 2, 3 }, &.{}, &.{});
    const target = conf(&.{ 1, 2, 3 }, &.{}, &.{ 4, 5 });
    const change = membership.enter_joint(&current, &target);
    try expect_ids(ids(&.{ 1, 2, 3 }), change.enter_joint.voters);
    try expect_ids(ids(&.{ 1, 2, 3 }), change.enter_joint.voters_outgoing);
    try expect_ids(ids(&.{ 4, 5 }), change.enter_joint.learners);
    try change.validate();
}

test "membership: leave_joint keeps the new voters and learners and drops outgoing" {
    const current = conf(&.{ 3, 4, 5 }, &.{ 1, 2, 3 }, &.{ 8, 9 });
    const change = membership.leave_joint(&current);
    try testing.expectEqual(std.meta.Tag(ConfChange).leave_joint, std.meta.activeTag(change));
    try expect_ids(ids(&.{ 3, 4, 5 }), change.leave_joint.voters);
    try expect_ids(&.{}, change.leave_joint.voters_outgoing);
    try expect_ids(ids(&.{ 8, 9 }), change.leave_joint.learners);
    try change.validate();
}

test "membership: leaving the joint configuration entered lands on the target" {
    const current = conf(&.{ 1, 2, 3 }, &.{}, &.{6});
    const target = conf(&.{ 2, 3, 4, 5 }, &.{}, &.{ 7, 8 });
    const entered = membership.enter_joint(&current, &target);
    const joint_configuration = entered.enter_joint;
    const left = membership.leave_joint(&joint_configuration);
    try testing.expectEqual(std.meta.Tag(ConfChange).leave_joint, std.meta.activeTag(left));
    try expect_ids(target.voters, left.leave_joint.voters);
    try expect_ids(target.learners, left.leave_joint.learners);
    try testing.expectEqual(@as(usize, 0), left.leave_joint.voters_outgoing.len);
    // And both survive the wire.
    try expect_round_trip(&entered);
    try expect_round_trip(&left);
}

// ---------------------------------------------------------------------------------------------
// Seeded model test against a brute-force subset reference
// ---------------------------------------------------------------------------------------------

const universe: u4 = 8; // node ids 1..8, bit i is node id i + 1
const model_iterations: u32 = 2000;

/// The ascending ids of the set bits of `mask`.
fn list_of(mask: u16, out: *[16]NodeId) []const NodeId {
    var n: usize = 0;
    for (0..16) |bit| {
        if (mask & (@as(u16, 1) << @intCast(bit)) == 0) continue;
        out[n] = @enumFromInt(bit + 1);
        n += 1;
    }
    return out[0..n];
}

/// Reference: `granted` is a quorum iff it holds strictly more than half of each non-empty set.
fn ref_quorum(granted: u16, voters: u16, outgoing: u16) bool {
    if (2 * @popCount(granted & voters) <= @popCount(voters)) return false;
    if (outgoing == 0) return true;
    return 2 * @popCount(granted & outgoing) > @popCount(outgoing);
}

/// Reference: the best, over every quorum subset of the members, of that subset's minimum match.
fn ref_index(voters: u16, outgoing: u16, match: *const [8]u64) u64 {
    const members = voters | outgoing;
    var best: u64 = 0;
    var subset: u16 = 1;
    while (subset < (@as(u16, 1) << universe)) : (subset += 1) {
        if (subset & ~members != 0) continue;
        if (!ref_quorum(subset, voters, outgoing)) continue;
        var low: u64 = std.math.maxInt(u64);
        for (0..universe) |bit| {
            if (subset & (@as(u16, 1) << @intCast(bit)) != 0) low = @min(low, match[bit]);
        }
        best = @max(best, low);
    }
    return best;
}

fn matches_of(mask: u16, match: *const [8]u64, out: *[16]u64) []const u64 {
    var n: usize = 0;
    for (0..universe) |bit| {
        if (mask & (@as(u16, 1) << @intCast(bit)) == 0) continue;
        out[n] = match[bit];
        n += 1;
    }
    return out[0..n];
}

fn model_run(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..model_iterations) |_| {
        const voters_mask = random.intRangeAtMost(u16, 1, 255);
        const outgoing_mask: u16 = if (random.boolean()) 0 else random.intRangeAtMost(u16, 1, 255);
        const learners_mask: u16 = random.int(u8) & ~voters_mask;
        var lv: [16]NodeId = undefined;
        var lo: [16]NodeId = undefined;
        var ll: [16]NodeId = undefined;
        const configuration: Configuration = .{
            .voters = list_of(voters_mask, &lv),
            .voters_outgoing = list_of(outgoing_mask, &lo),
            .learners = list_of(learners_mask, &ll),
        };
        try configuration.validate();

        // quorum_reached: random grants, including ids 9 and 10 outside every set.
        for (0..32) |_| {
            const granted_mask = random.int(u16) & 0x3ff;
            var lg: [16]NodeId = undefined;
            const granted = list_of(granted_mask, &lg);
            try testing.expectEqual(
                ref_quorum(granted_mask, voters_mask, outgoing_mask),
                quorum_reached(&configuration, granted),
            );
        }

        // quorum_index against the brute-force subset maximum.
        var match: [8]u64 = undefined;
        for (&match) |*m| m.* = random.uintAtMost(u64, 20);
        var mv: [16]u64 = undefined;
        var mo: [16]u64 = undefined;
        const matches: Matches = .{
            .voters = matches_of(voters_mask, &match, &mv),
            .voters_outgoing = matches_of(outgoing_mask, &match, &mo),
        };
        const got = quorum_index(&configuration, &matches);
        try testing.expectEqual(ref_index(voters_mask, outgoing_mask, &match), got);

        // Consistency: the nodes at or above the index carry a quorum; above it, none does.
        var at_or_above: u16 = 0;
        var above: u16 = 0;
        for (0..universe) |bit| {
            if (match[bit] >= got) at_or_above |= @as(u16, 1) << @intCast(bit);
            if (match[bit] > got) above |= @as(u16, 1) << @intCast(bit);
        }
        try testing.expect(ref_quorum(at_or_above, voters_mask, outgoing_mask));
        try testing.expect(!ref_quorum(above, voters_mask, outgoing_mask));
    }
}

test "membership: seeded model: quorum_reached and quorum_index match brute-force subsets" {
    for ([_]u64{ 1, 0x5eed, 0xc0ffee }) |seed| try model_run(seed);
}

// ---------------------------------------------------------------------------------------------
// Fuzz
// ---------------------------------------------------------------------------------------------

test "membership: fuzz: decode never crashes, accepts only canonical valid changes" {
    try testing.fuzz({}, fuzz_decode, .{});
}

fn fuzz_decode(_: void, smith: *testing.Smith) anyerror!void {
    var storage: [conf_ids_max]NodeId = undefined;

    // Arbitrary bytes: whatever happens, no crash; an accepted message re-encodes to itself.
    var noise: [membership.conf_bytes_max + 8]u8 = undefined;
    const noise_len = smith.slice(&noise);
    try check_decoded(noise[0..noise_len], &storage);

    // Structured bytes with a valid checksum, so the content checks run.
    var voters: [20]u64 = undefined;
    var outgoing: [20]u64 = undefined;
    var learners: [20]u64 = undefined;
    const nv = smith.valueRangeAtMost(u8, 0, 20);
    const no = smith.valueRangeAtMost(u8, 0, 20);
    const nl = smith.valueRangeAtMost(u8, 0, 20);
    for (voters[0..nv]) |*id| id.* = smith.valueRangeAtMost(u64, 0, 40);
    for (outgoing[0..no]) |*id| id.* = smith.valueRangeAtMost(u64, 0, 40);
    for (learners[0..nl]) |*id| id.* = smith.valueRangeAtMost(u64, 0, 40);
    var buf: [membership.conf_bytes_max + 8 * 12]u8 = undefined;
    const kind = smith.valueRangeAtMost(u8, 0, 3);
    const bytes = raw(&buf, kind, voters[0..nv], outgoing[0..no], learners[0..nl]);
    try check_decoded(bytes, &storage);

    // A valid change always round trips.
    var vmask: u16 = smith.value(u16);
    var omask: u16 = smith.value(u16);
    if (vmask == 0) vmask = 1;
    if (omask == 0) omask = 1;
    var lv: [16]NodeId = undefined;
    var lo: [16]NodeId = undefined;
    const sv = list_of(vmask, &lv);
    const so = list_of(omask, &lo);
    const enter: ConfChange = .{ .enter_joint = .{
        .voters = sv,
        .voters_outgoing = so,
        .learners = &.{},
    } };
    var out: [membership.conf_bytes_max]u8 = undefined;
    const len = encode(&enter, &out);
    try testing.expectEqual(encoded_bytes(&enter), len);
    const decoded = try decode(out[0..len], &storage);
    try expect_change_eql(&enter, &decoded);
}

fn check_decoded(bytes: []const u8, storage: *[conf_ids_max]NodeId) !void {
    if (decode(bytes, storage)) |change| {
        try change.validate();
        var out: [membership.conf_bytes_max]u8 = undefined;
        const len = encode(&change, &out);
        try testing.expectEqualSlices(u8, bytes, out[0..len]);
    } else |err| switch (err) {
        error.ConfLength,
        error.ConfMagic,
        error.ConfVersion,
        error.ConfKind,
        error.ConfChecksum,
        error.ConfVotersEmpty,
        error.ConfVotersTooMany,
        error.ConfLearnersTooMany,
        error.ConfNodesUnsorted,
        error.ConfLearnerIsVoter,
        error.ConfJointShape,
        => {},
    }
}
