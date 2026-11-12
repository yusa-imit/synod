//! Red tests for joint consensus in the node, follower and restore side (plan 005 item 8, ADR-009
//! "Joint consensus"): a configuration takes effect when its `conf_change` entry is appended
//! (follower, restore, leader alike) and rolls back on truncate, by rescanning `(base, from)`
//! backward for the last `conf_change` entry, else the configuration as of the base; a node that
//! is not a voter of its own configuration never grants a vote or pre-vote and never campaigns;
//! corrupt conf bytes from a peer or the store are typed `Conf*` errors, never asserts.
//!
//! Assumed API that does not exist yet (the red reason): configuration changes on append,
//! truncate and restore, `Status.configuration_index`, and decoding of node-held conf entries.
//! Names assumed: `Node.configuration_current() Configuration`, `Status.configuration_index`.
//! After a rollback to the base, `configuration_index` is only required to be at most the commit
//! index (the ADR does not say whether it reads zero or the base index).
//!
//! Expected values come from the ADR and the reference models below, never from the node.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const membership = @import("membership.zig");
const node_module = @import("node.zig");
const types = @import("../types.zig");

const ConfBytes = fixtures.ConfBytes;
const Configuration = types.Configuration;
const Effects = node_module.Effects;
const Entry = types.Entry;
const Frozen = fixtures.Frozen;
const NodeId = types.NodeId;
const Restore = node_module.Restore;
const Rig = fixtures.Rig;
const Role = node_module.Role;

const conf_of = fixtures.conf_of;
const count_effects = fixtures.count_effects;
const entry = fixtures.entry;
const expect_ack = fixtures.expect_ack;
const expect_configuration = fixtures.expect_configuration;
const idx = fixtures.idx;
const node_id = fixtures.node_id;
const receive_checked = fixtures.receive_checked;
const request_of = fixtures.append_request;
const step_checked = fixtures.step_checked;
const term = fixtures.term;

const cfg = fixtures.config_conf;
const fresh3 = fixtures.restore_of(.empty, &.{});
const ids1 = [_]NodeId{node_id(1)};
const ids3 = fixtures.voters;
const ids23 = [_]NodeId{ node_id(2), node_id(3) };
const ids234 = [_]NodeId{ node_id(2), node_id(3), node_id(4) };
const ids4 = [_]NodeId{ node_id(1), node_id(2), node_id(3), node_id(4) };
const ids5 = fixtures.voters5;

fn start(rig: *Rig, restore: *const Restore) !void {
    try rig.init_fixed(testing.allocator, cfg, restore, 0); // Timeout t = 10.
}

fn expect_index(rig: *const Rig, want: u64) !void {
    try testing.expectEqual(idx(want), rig.node.status().configuration_index);
}

/// Node 1 is up to date for a candidate whose log ends at (`last`, `last_term`).
fn no_grant(effects: Effects) !void {
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .request_vote_response => |reply| try testing.expect(!reply.granted),
            .pre_vote_response => |reply| try testing.expect(!reply.granted),
            else => {},
        },
        else => {},
    };
}

fn grants(effects: Effects) bool {
    for (effects.items) |effect| switch (effect) {
        .send => |message| switch (message) {
            .request_vote_response => |reply| if (reply.granted) return true,
            .pre_vote_response => |reply| if (reply.granted) return true,
            else => {},
        },
        else => {},
    };
    return false;
}

// ---- adopt on append -----------------------------------------------------------------------

test "follower: enter_joint is adopted when appended, before it commits" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var bytes: ConfBytes = .{};
    const batch = [_]Entry{bytes.entry(1, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) })};
    const message = request_of(2, 1, 0, 0, 0, &batch);

    const effects = try receive_checked(&rig, &message);

    try expect_ack(effects, 2, 1);
    try expect_configuration(conf_of(&ids4, &ids3, &.{}), rig.node.configuration_current());
    try expect_index(&rig, 1);
    try testing.expectEqual(idx(0), rig.node.status().commit_index);
}

test "follower: leave_joint after enter_joint settles the configuration at the later index" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var first: ConfBytes = .{};
    var second: ConfBytes = .{};
    const batch = [_]Entry{
        first.entry(1, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) }),
        second.entry(2, 1, .{ .leave_joint = conf_of(&ids4, &.{}, &.{}) }),
    };
    const message = request_of(2, 1, 0, 0, 0, &batch);

    const effects = try receive_checked(&rig, &message);

    try expect_ack(effects, 2, 2);
    try expect_configuration(conf_of(&ids4, &.{}, &.{}), rig.node.configuration_current());
    try expect_index(&rig, 2);
}

test "follower: a normal entry that looks like a conf change never changes the configuration" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var bytes: ConfBytes = .{};
    const look_alike = bytes.entry(1, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) });
    const batch = [_]Entry{entry(1, 1, look_alike.data)};
    const message = request_of(2, 1, 0, 0, 0, &batch);

    const effects = try receive_checked(&rig, &message);

    try expect_ack(effects, 2, 1);
    try expect_configuration(conf_of(&ids3, &.{}, &.{}), rig.node.configuration_current());
    try expect_index(&rig, 0);
}

// ---- rollback on truncate ------------------------------------------------------------------

test "follower: truncating an uncommitted enter_joint restores the old configuration" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var bytes: ConfBytes = .{};
    const batch = [_]Entry{
        entry(1, 1, "a"),
        bytes.entry(2, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) }),
    };
    const first = request_of(2, 1, 0, 0, 1, &batch);
    _ = try receive_checked(&rig, &first);
    try expect_index(&rig, 2);

    const replacement = [_]Entry{entry(2, 2, "z")};
    const second = request_of(3, 2, 1, 1, 1, &replacement);
    const effects = try receive_checked(&rig, &second);

    try expect_ack(effects, 3, 2);
    try testing.expectEqual(@as(u32, 1), count_effects(effects, .truncate));
    try expect_configuration(conf_of(&ids3, &.{}, &.{}), rig.node.configuration_current());
    try testing.expect(rig.node.status().configuration_index.order(idx(1)) != .gt);
}

test "follower: truncation rescans backward and lands on the last surviving conf entry" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var enter: ConfBytes = .{};
    var leave: ConfBytes = .{};
    const batch = [_]Entry{
        entry(1, 1, "a"),
        enter.entry(2, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) }),
        leave.entry(3, 1, .{ .leave_joint = conf_of(&ids4, &.{}, &.{}) }),
    };
    const first = request_of(2, 1, 0, 0, 1, &batch);
    _ = try receive_checked(&rig, &first);
    try expect_index(&rig, 3);
    try expect_configuration(conf_of(&ids4, &.{}, &.{}), rig.node.configuration_current());

    // Drop only leave_joint: the joint configuration of index 2 is back.
    const drop_leave = [_]Entry{entry(3, 2, "y")};
    const second = request_of(3, 2, 2, 1, 1, &drop_leave);
    _ = try receive_checked(&rig, &second);
    try expect_configuration(conf_of(&ids4, &ids3, &.{}), rig.node.configuration_current());
    try expect_index(&rig, 2);

    // Drop enter_joint too: the configuration of the base.
    const drop_enter = [_]Entry{entry(2, 3, "w")};
    const third = request_of(2, 3, 1, 1, 1, &drop_enter);
    _ = try receive_checked(&rig, &third);
    try expect_configuration(conf_of(&ids3, &.{}, &.{}), rig.node.configuration_current());
    try testing.expect(rig.node.status().configuration_index.order(idx(1)) != .gt);
}

test "follower: with no conf entry left above the base the snapshot's configuration returns" {
    const snapshot: types.Index = idx(5);
    var bytes: ConfBytes = .{};
    const log = [_]Entry{bytes.entry(6, 1, .{ .enter_joint = conf_of(&ids5, &ids4, &.{}) })};
    const restore: Restore = .{
        .hard_state = fixtures.hard_state_of(1, 0, 5),
        .snapshot = .{ .index = snapshot, .term = term(1) },
        .entries = &log,
        .configuration = conf_of(&ids4, &.{}, &.{}),
    };
    var rig: Rig = undefined;
    try start(&rig, &restore);
    defer rig.deinit(testing.allocator);
    try expect_configuration(conf_of(&ids5, &ids4, &.{}), rig.node.configuration_current());
    try expect_index(&rig, 6);

    const replacement = [_]Entry{entry(6, 2, "z")};
    const message = request_of(2, 2, 5, 1, 5, &replacement);
    const effects = try receive_checked(&rig, &message);

    try expect_ack(effects, 2, 6);
    try expect_configuration(conf_of(&ids4, &.{}, &.{}), rig.node.configuration_current());
    try testing.expect(rig.node.status().configuration_index.order(idx(5)) != .gt);
}

test "follower: a deposed leader rolls back its uncommitted enter_joint and stops leading" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    const won = try fixtures.elect_checked(&rig, &.{2});
    _ = try fixtures.accept(&rig, try fixtures.append_to(won, 2));
    const target = conf_of(&ids5, &.{}, &.{});
    _ = try step_checked(&rig, .{ .conf_change = &target });
    try expect_index(&rig, 2);
    try testing.expectEqual(@as(usize, 4), fixtures.leader_progress(&rig.node).len);

    const replacement = [_]Entry{entry(2, 2, "z")};
    const message = request_of(3, 2, 1, 1, 1, &replacement);
    const effects = try receive_checked(&rig, &message);

    try expect_ack(effects, 3, 2);
    try testing.expectEqual(Role.follower, rig.node.status().role);
    try expect_configuration(conf_of(&ids3, &.{}, &.{}), rig.node.configuration_current());
    try testing.expectEqual(@as(usize, 0), fixtures.leader_progress(&rig.node).len);
    const refused = rig.node.step(.{ .conf_change = &target });
    try testing.expectError(error.ConfChangeNotLeader, refused);
}

// ---- restore -------------------------------------------------------------------------------

test "restore: the last conf entry in the log, committed or not, is the starting configuration" {
    var enter: ConfBytes = .{};
    var leave: ConfBytes = .{};
    const log = [_]Entry{
        entry(1, 1, "a"),
        enter.entry(2, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) }),
        leave.entry(3, 1, .{ .leave_joint = conf_of(&ids4, &.{}, &.{}) }),
    };
    const cases = [_]struct { entries: []const Entry, commit: u64, want: Configuration, at: u64 }{
        .{ .entries = log[0..1], .commit = 0, .want = conf_of(&ids3, &.{}, &.{}), .at = 0 },
        .{ .entries = log[0..2], .commit = 0, .want = conf_of(&ids4, &ids3, &.{}), .at = 2 },
        .{ .entries = log[0..2], .commit = 2, .want = conf_of(&ids4, &ids3, &.{}), .at = 2 },
        .{ .entries = log[0..3], .commit = 2, .want = conf_of(&ids4, &.{}, &.{}), .at = 3 },
        .{ .entries = log[0..3], .commit = 3, .want = conf_of(&ids4, &.{}, &.{}), .at = 3 },
    };
    for (cases) |case| {
        const hard_state = fixtures.hard_state_of(1, 0, case.commit);
        const restore = fixtures.restore_of(hard_state, case.entries);
        var rig: Rig = undefined;
        try start(&rig, &restore);
        defer rig.deinit(testing.allocator);
        try expect_configuration(case.want, rig.node.configuration_current());
        try expect_index(&rig, case.at);
        try rig.node.check_invariants();
    }
}

test "restore: a snapshot's configuration is current when no conf entry sits above it" {
    const log = [_]Entry{entry(6, 1, "a")};
    const restore: Restore = .{
        .hard_state = fixtures.hard_state_of(1, 0, 5),
        .snapshot = .{ .index = idx(5), .term = term(1) },
        .entries = &log,
        .configuration = conf_of(&ids4, &.{}, &.{}),
    };
    var rig: Rig = undefined;
    try start(&rig, &restore);
    defer rig.deinit(testing.allocator);

    try expect_configuration(conf_of(&ids4, &.{}, &.{}), rig.node.configuration_current());
    try testing.expect(rig.node.status().configuration_index.order(idx(5)) != .gt);
}

test "restore: corrupt conf bytes in the log are a typed error and leak nothing" {
    var bytes: ConfBytes = .{};
    var bad = bytes.entry(1, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) });
    var damaged: [membership.conf_bytes_max]u8 = undefined;
    @memcpy(damaged[0..bad.data.len], bad.data);
    damaged[10] ^= 0xff; // An id byte: the checksum no longer matches.
    bad.data = damaged[0..bad.data.len];
    const log = [_]Entry{bad};
    const restore = fixtures.restore_of(fixtures.hard_state_of(1, 0, 0), &log);

    var rig: Rig = undefined;
    if (rig.init(testing.allocator, cfg, &restore, 1)) {
        rig.deinit(testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| try testing.expect(@as(anyerror, err) == error.ConfChecksum);
}

// ---- corrupt conf entries from a peer ------------------------------------------------------

test "follower: each corrupt conf entry from a peer is its typed error and changes nothing" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var good: ConfBytes = .{};
    const sound = good.entry(1, 1, .{ .enter_joint = conf_of(&ids4, &ids3, &.{}) });
    const len = sound.data.len;
    const Case = struct { at: usize, xor: u8, cut: usize, want: anyerror };
    const cases = [_]Case{
        .{ .at = 0, .xor = 0xff, .cut = 0, .want = error.ConfMagic },
        .{ .at = 4, .xor = 0x01, .cut = 0, .want = error.ConfVersion },
        .{ .at = 10, .xor = 0xff, .cut = 0, .want = error.ConfChecksum },
        .{ .at = 0, .xor = 0, .cut = 1, .want = error.ConfLength },
        .{ .at = 0, .xor = 0, .cut = len - 5, .want = error.ConfLength },
    };
    const frozen = Frozen.take(&rig.node);
    for (cases) |case| {
        var copy: [membership.conf_bytes_max]u8 = undefined;
        @memcpy(copy[0..len], sound.data);
        copy[case.at] ^= case.xor;
        const batch = [_]Entry{.{
            .index = idx(1),
            .term = term(1),
            .kind = .conf_change,
            .data = copy[0 .. len - case.cut],
        }};
        const message = request_of(2, 1, 0, 0, 0, &batch);
        try testing.expectError(case.want, rig.receive(&message));
        try frozen.expect_same(&rig.node);
    }
    // A valid checksum over a kind byte that is neither enter nor leave.
    var forged: [membership.conf_bytes_max]u8 = undefined;
    @memcpy(forged[0..len], sound.data);
    forged[5] = 9;
    const crc = std.hash.Crc32.hash(forged[0 .. len - 4]);
    std.mem.writeInt(u32, forged[len - 4 ..][0..4], crc, .little);
    const batch = [_]Entry{.{
        .index = idx(1),
        .term = term(1),
        .kind = .conf_change,
        .data = forged[0..len],
    }};
    const message = request_of(2, 1, 0, 0, 0, &batch);
    try testing.expectError(error.ConfKind, rig.receive(&message));
    try frozen.expect_same(&rig.node);
}

// ---- non-voters ----------------------------------------------------------------------------

test "non-voter: a learner never grants a vote or a pre-vote" {
    const restore = fixtures.restore_with(conf_of(&ids23, &.{}, &ids1), .empty, &.{});
    var rig: Rig = undefined;
    try start(&rig, &restore);
    defer rig.deinit(testing.allocator);

    const pre = fixtures.pre_vote_at(2, 1, 1, 0, 0);
    try no_grant(try receive_checked(&rig, &pre));
    const vote = fixtures.vote_request_at(2, 1, 1, 0, 0);
    try no_grant(try receive_checked(&rig, &vote));
    try testing.expectEqual(NodeId.none, rig.node.status().vote);
}

test "non-voter: a node outside the configuration never grants either" {
    const outside = conf_of(&ids234, &.{}, &.{});
    const restore = fixtures.restore_with(outside, .empty, &.{});
    var rig: Rig = undefined;
    try start(&rig, &restore);
    defer rig.deinit(testing.allocator);

    const pre = fixtures.pre_vote_at(2, 1, 1, 0, 0);
    try testing.expect(!grants(try receive_checked(&rig, &pre)));
    const vote = fixtures.vote_request_at(2, 1, 1, 0, 0);
    try testing.expect(!grants(try receive_checked(&rig, &vote)));
    try testing.expectEqual(NodeId.none, rig.node.status().vote);
}

test "non-voter: neither a learner nor an outsider ever campaigns, however long it waits" {
    const configs = [_]Configuration{
        conf_of(&ids23, &.{}, &ids1),
        conf_of(&ids234, &.{}, &.{}),
    };
    for (configs) |cluster| {
        const restore = fixtures.restore_with(cluster, .empty, &.{});
        var rig: Rig = undefined;
        try start(&rig, &restore);
        defer rig.deinit(testing.allocator);
        for (0..45) |_| { // More than 2t = 20 ticks, thrice over.
            const effects = try step_checked(&rig, .tick);
            try testing.expectEqual(@as(usize, 0), effects.items.len);
        }
        try testing.expectEqual(Role.follower, rig.node.status().role);
        try testing.expectEqual(term(0), rig.node.status().term);
    }
}

test "non-voter: a voter that only the outgoing set names still campaigns" {
    const restore = fixtures.restore_with(conf_of(&ids234, &ids3, &.{}), .empty, &.{});
    var rig: Rig = undefined;
    try start(&rig, &restore);
    defer rig.deinit(testing.allocator);
    var effects: Effects = .{ .items = &.{} };
    for (0..10) |_| effects = try step_checked(&rig, .tick); // Timeout t = 10 ticks.

    try testing.expectEqual(Role.pre_candidate, rig.node.status().role);
    try testing.expectEqual(@as(u32, 3), count_effects(effects, .send)); // 2, 3, 4.
}

test "non-voter: a node removed by an appended leave_joint stops voting at once" {
    var rig: Rig = undefined;
    try start(&rig, &fresh3);
    defer rig.deinit(testing.allocator);
    var enter: ConfBytes = .{};
    const joint = [_]Entry{enter.entry(1, 1, .{ .enter_joint = conf_of(&ids234, &ids3, &.{}) })};
    const first = request_of(2, 1, 0, 0, 0, &joint);
    _ = try receive_checked(&rig, &first);

    // Still a voter through the outgoing set: a term-2 candidate with our log gets the vote.
    const vote = fixtures.vote_request_at(3, 1, 2, 1, 1);
    try testing.expect(grants(try receive_checked(&rig, &vote)));
    try testing.expectEqual(node_id(3), rig.node.status().vote);

    var leave: ConfBytes = .{};
    const settled = [_]Entry{leave.entry(2, 2, .{ .leave_joint = conf_of(&ids234, &.{}, &.{}) })};
    const second = request_of(3, 2, 1, 1, 0, &settled);
    _ = try receive_checked(&rig, &second);
    try expect_configuration(conf_of(&ids234, &.{}, &.{}), rig.node.configuration_current());

    const later = fixtures.vote_request_at(4, 1, 3, 2, 2);
    try no_grant(try receive_checked(&rig, &later));
    try testing.expect(rig.node.status().vote != node_id(4));
    for (0..45) |_| {
        const effects = try step_checked(&rig, .tick);
        try testing.expect(count_effects(effects, .send) == 0);
    }
    try testing.expectEqual(Role.follower, rig.node.status().role);
}

// ---- model ---------------------------------------------------------------------------------

/// The reference log: one slot per entry, holding the configuration its conf entry carries.
const Ref = struct {
    terms: [24]u64 = undefined,
    confs: [24]?Configuration = undefined,
    len: usize = 0,

    /// The backward rescan, done the slow way: the last conf entry's configuration, else the base.
    fn current(ref: *const Ref) struct { config: Configuration, at: u64 } {
        var at = ref.len;
        while (at > 0) : (at -= 1) {
            if (ref.confs[at - 1]) |c| return .{ .config = c, .at = at };
        }
        return .{ .config = conf_of(&ids3, &.{}, &.{}), .at = 0 };
    }
};

/// Ascending ids from `candidates` whose coin lands heads; `forced` is always in.
fn pick(random: std.Random, candidates: []const u64, forced: u64, out: []NodeId) usize {
    var count: usize = 0;
    for (candidates) |id| {
        if (id != forced and !random.boolean()) continue;
        out[count] = node_id(id);
        count += 1;
    }
    return count;
}

fn run_model(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var big = cfg;
    big.log_entries_max = 32;
    big.log_bytes_max = 4096;
    var rig: Rig = undefined;
    try rig.init_fixed(testing.allocator, big, &fresh3, 0);
    defer rig.deinit(testing.allocator);
    var ref: Ref = .{};
    var storage: [8][membership.conf_bytes_max]u8 = undefined;
    // One slot per log position: the reference keeps slices into it.
    var lists: [24][3][8]NodeId = undefined;
    var at_term: u64 = 0;
    for (0..30) |_| {
        // Node 2 leads every term and is always a voter, so it is always a known sender.
        at_term += 1;
        const keep = random.uintLessThan(usize, ref.len + 1);
        const count = 1 + random.uintLessThan(usize, 3);
        if (keep + count > 20) continue;
        var batch: [3]Entry = undefined;
        for (0..count) |i| {
            const conf_kind = random.uintLessThan(u32, 3);
            const index = keep + 1 + i;
            if (conf_kind == 0) {
                batch[i] = entry(index, at_term, "n");
                ref.confs[keep + i] = null;
            } else {
                const voters_n = pick(random, &.{ 1, 2, 3, 4, 5 }, 2, &lists[keep + i][0]);
                const outgoing_n = pick(random, &.{ 1, 2, 3, 4, 5 }, 2, &lists[keep + i][1]);
                const learners_n = pick(random, &.{ 6, 7 }, 0, &lists[keep + i][2]);
                const enter = conf_kind == 1;
                const configuration: Configuration = .{
                    .voters = lists[keep + i][0][0..voters_n],
                    .voters_outgoing = if (enter) lists[keep + i][1][0..outgoing_n] else &.{},
                    .learners = lists[keep + i][2][0..learners_n],
                };
                const change: types.ConfChange = if (enter)
                    .{ .enter_joint = configuration }
                else
                    .{ .leave_joint = configuration };
                const n = membership.encode(&change, &storage[i]);
                batch[i] = .{
                    .index = idx(index),
                    .term = term(at_term),
                    .kind = .conf_change,
                    .data = storage[i][0..n],
                };
                ref.confs[keep + i] = configuration;
            }
            ref.terms[keep + i] = at_term;
        }
        const prev_term = if (keep == 0) 0 else ref.terms[keep - 1];
        const message = request_of(2, at_term, keep, prev_term, 0, batch[0..count]);
        const effects = try receive_checked(&rig, &message);
        ref.len = keep + count;
        try expect_ack(effects, 2, ref.len);

        const want = ref.current();
        try expect_configuration(want.config, rig.node.configuration_current());
        try testing.expectEqual(idx(want.at), rig.node.status().configuration_index);
    }
}

test "follower model: 100 seeds of appends and truncations match a backward-rescan reference" {
    for (0..100) |seed| run_model(seed) catch |err| {
        std.log.err("follower reconfigure model failed at seed {d}", .{seed});
        return err;
    };
}
