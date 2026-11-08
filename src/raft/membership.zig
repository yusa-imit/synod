//! Joint-consensus membership, pure (plan 005 item 7, ADR-009): the `ConfChange` entry codec and
//! the quorum rules over a `Configuration`. No allocation, no state, no I/O.
//!
//! Layout, little-endian: magic `SYCC` | version u8 | kind u8 (1 enter, 2 leave) | voter,
//! outgoing and learner counts u8 each | ids u64 (voters, outgoing, learners) | crc32 u32 over
//! every byte before it. `decode` checks length, magic, version, exact length, checksum, kind and
//! only then `ConfChange.validate`, so a corrupt peer entry is a typed error, never an assert.
//! A quorum is a majority of `voters` and, when joint, of `voters_outgoing`; learners count in
//! neither. Cost: an encode or decode touches at most `conf_bytes_max` bytes; a quorum check is
//! O(voters_max^2) over stack data.

const std = @import("std");
const assert = std.debug.assert;
const types = @import("../types.zig");

const ConfChange = types.ConfChange;
const ConfError = types.ConfError;
const Configuration = types.Configuration;
const NodeId = types.NodeId;

pub const conf_magic = "SYCC".*;
pub const conf_version: u8 = 1;
pub const conf_ids_max: u32 = 2 * types.voters_max + types.learners_max;
pub const conf_bytes_max: u32 = header_bytes + 8 * conf_ids_max;

/// Magic, version, kind and three counts.
const prefix_bytes: u32 = 4 + 1 + 1 + 3;
const checksum_bytes: u32 = 4;
const header_bytes: u32 = prefix_bytes + checksum_bytes;

const kind_enter: u8 = 1;
const kind_leave: u8 = 2;

pub const ConfDecodeError = error{ ConfLength, ConfMagic, ConfVersion, ConfKind, ConfChecksum };

/// Per-voter match indexes, aligned with `Configuration.voters` and `voters_outgoing`.
pub const Matches = struct { voters: []const u64, voters_outgoing: []const u64 };

comptime {
    assert(header_bytes == 13);
    assert(conf_bytes_max == 397);
    assert(types.voters_max <= std.math.maxInt(u8));
    assert(types.learners_max <= std.math.maxInt(u8));
}

/// Strictly more than half of `size`. Precondition: `0 < size <= voters_max`.
pub fn majority(size: u32) u32 {
    assert(size > 0);
    assert(size <= types.voters_max);
    const result = @divFloor(size, 2) + 1;
    assert(result <= size);
    return result;
}

/// Bytes `encode` writes for `change`: 13 plus 8 per id. `change` must be valid.
pub fn encoded_bytes(change: *const ConfChange) u32 {
    const configuration = configuration_of(change);
    const ids: u32 = @intCast(configuration.voters.len + configuration.voters_outgoing.len +
        configuration.learners.len);
    assert(ids <= conf_ids_max);
    return header_bytes + 8 * ids;
}

/// Writes `change` to `out` and returns the byte count. Preconditions: `change` validates and
/// `out.len >= encoded_bytes(change)`.
pub fn encode(change: *const ConfChange, out: []u8) u32 {
    assert(if (change.validate()) true else |_| false);
    const total = encoded_bytes(change);
    assert(out.len >= total);
    const configuration = configuration_of(change);
    @memcpy(out[0..4], &conf_magic);
    out[4] = conf_version;
    out[5] = switch (change.*) {
        .enter_joint => kind_enter,
        .leave_joint => kind_leave,
    };
    out[6] = @intCast(configuration.voters.len);
    out[7] = @intCast(configuration.voters_outgoing.len);
    out[8] = @intCast(configuration.learners.len);

    var at: usize = prefix_bytes;
    const lists = [_][]const NodeId{
        configuration.voters,
        configuration.voters_outgoing,
        configuration.learners,
    };
    for (lists) |list| {
        for (list) |id| {
            std.mem.writeInt(u64, out[at..][0..8], @intFromEnum(id), .little);
            at += 8;
        }
    }
    assert(at + checksum_bytes == total);
    const crc = std.hash.Crc32.hash(out[0..at]);
    std.mem.writeInt(u32, out[at..][0..4], crc, .little);
    return total;
}

/// Parses an entry's `data`. The returned lists point into `ids`. Errors are in the check order
/// of the module header.
pub fn decode(
    bytes: []const u8,
    ids: *[conf_ids_max]NodeId,
) (ConfDecodeError || ConfError)!ConfChange {
    if (bytes.len < header_bytes) return error.ConfLength;
    if (!std.mem.eql(u8, bytes[0..4], &conf_magic)) return error.ConfMagic;
    if (bytes[4] != conf_version) return error.ConfVersion;
    const counts = [3]u32{ bytes[6], bytes[7], bytes[8] };
    const ids_count = counts[0] + counts[1] + counts[2];
    if (ids_count > conf_ids_max) return error.ConfLength;
    if (bytes.len != header_bytes + 8 * ids_count) return error.ConfLength;
    const body = bytes.len - checksum_bytes;
    const crc = std.mem.readInt(u32, bytes[body..][0..4], .little);
    if (crc != std.hash.Crc32.hash(bytes[0..body])) return error.ConfChecksum;
    if (bytes[5] != kind_enter and bytes[5] != kind_leave) return error.ConfKind;

    for (0..ids_count) |i| {
        const raw = std.mem.readInt(u64, bytes[prefix_bytes + 8 * i ..][0..8], .little);
        ids[i] = @enumFromInt(raw);
    }
    const configuration: Configuration = .{
        .voters = ids[0..counts[0]],
        .voters_outgoing = ids[counts[0] .. counts[0] + counts[1]],
        .learners = ids[counts[0] + counts[1] .. ids_count],
    };
    const change: ConfChange = if (bytes[5] == kind_enter)
        .{ .enter_joint = configuration }
    else
        .{ .leave_joint = configuration };
    try change.validate();
    assert(encoded_bytes(&change) == bytes.len);
    return change;
}

/// `C_old,new`: `target`'s voters and learners, with `current`'s voters as the outgoing set.
pub fn enter_joint(current: *const Configuration, target: *const Configuration) ConfChange {
    assert(current.voters.len > 0);
    assert(target.voters.len > 0);
    assert(current.voters_outgoing.len == 0);
    assert(target.voters_outgoing.len == 0);
    return .{ .enter_joint = .{
        .voters = target.voters,
        .voters_outgoing = current.voters,
        .learners = target.learners,
    } };
}

/// `C_new`: the voters and learners of the joint `current`, with no outgoing set.
pub fn leave_joint(current: *const Configuration) ConfChange {
    assert(current.voters_outgoing.len > 0);
    return .{ .leave_joint = .{
        .voters = current.voters,
        .voters_outgoing = &.{},
        .learners = current.learners,
    } };
}

/// The highest index a quorum matches: the lower of the majority matches of `voters` and, when
/// joint, `voters_outgoing`. `matches` is aligned with the configuration's lists.
pub fn quorum_index(configuration: *const Configuration, matches: *const Matches) u64 {
    assert(configuration.voters.len > 0);
    assert(matches.voters.len == configuration.voters.len);
    assert(matches.voters_outgoing.len == configuration.voters_outgoing.len);
    var result = majority_match(matches.voters);
    if (matches.voters_outgoing.len > 0) {
        result = @min(result, majority_match(matches.voters_outgoing));
    }
    return result;
}

/// Whether `ids` (distinct node ids; others are ignored) hold a majority of `voters` and, when
/// joint, of `voters_outgoing`. A voter in both sets counts in both.
pub fn quorum_reached(configuration: *const Configuration, ids: []const NodeId) bool {
    assert(configuration.voters.len > 0);
    assert(ids.len <= conf_ids_max);
    if (count_in(configuration.voters, ids) < majority(@intCast(configuration.voters.len))) {
        return false;
    }
    if (configuration.voters_outgoing.len == 0) return true;
    const outgoing: u32 = @intCast(configuration.voters_outgoing.len);
    return count_in(configuration.voters_outgoing, ids) >= majority(outgoing);
}

fn configuration_of(change: *const ConfChange) *const Configuration {
    return switch (change.*) {
        .enter_joint => |*configuration| configuration,
        .leave_joint => |*configuration| configuration,
    };
}

fn count_in(set: []const NodeId, ids: []const NodeId) u32 {
    assert(set.len <= types.voters_max);
    var total: u32 = 0;
    for (set) |member| total += @intFromBool(std.mem.findScalar(NodeId, ids, member) != null);
    assert(total <= set.len);
    return total;
}

fn majority_match(matches: []const u64) u64 {
    assert(matches.len > 0);
    assert(matches.len <= types.voters_max);
    var sorted: [types.voters_max]u64 = undefined;
    @memcpy(sorted[0..matches.len], matches);
    std.mem.sort(u64, sorted[0..matches.len], {}, std.sort.desc(u64));
    const result = sorted[majority(@intCast(matches.len)) - 1];
    assert(result <= sorted[0]);
    return result;
}
