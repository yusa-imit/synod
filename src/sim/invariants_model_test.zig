//! Seeded model-based test for `sim/invariants.zig` (plan 004 item 3). A trivial reference
//! model of an honest 3-node cluster (one canonical log, nodes holding prefixes of it, a
//! commit index that only rises to what a majority holds, one leader per term, in-order apply,
//! restarts that reset commit and applied) feeds the `Checker` observation by observation. An
//! honest history must never raise a violation and the stats must equal the model's own counts.
//! Then one planted lie per seed (second leader, flipped committed byte, cut leader log) must
//! be caught as a specific violation, and a seed replays bit for bit.
//!
//! The model never uses a `Checker` result to decide its next move, so the two share no logic.

const std = @import("std");
const testing = std.testing;
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const fx = @import("../raft/fixtures.zig");
const invariants = @import("invariants.zig");
const prng_module = @import("prng.zig");

const Checker = invariants.Checker;
const Entry = types.Entry;
const Observation = invariants.Observation;
const Prng = prng_module.Prng;

const nodes_count = 3;
const steps_max = 300;
const seeds_count = 200;
const log_cap = 24;
const terms_cap = 64;
const options: Checker.Options = .{
    .nodes_count = nodes_count,
    .log_entries_max = log_cap,
    .terms_max = terms_cap,
};

const Fault = enum { none, second_leader, flip_committed, cut_leader };

const Outcome = struct {
    stats: Checker.Stats = .{ .leader_terms = 0, .committed_max = 0 },
    applies: u32 = 0,
    restarts: u32 = 0,
    steps: u32 = 0,
};

/// The reference model: just arrays and counters, no cleverness.
const Model = struct {
    bytes: [log_cap]u8 = @splat(0),
    canon: [log_cap]Entry = undefined,
    canon_len: usize = 0,
    node_len: [nodes_count]usize = @splat(0),
    node_commit: [nodes_count]u64 = @splat(0),
    node_applied: [nodes_count]u64 = @splat(0),
    term: u64 = 0,
    leader: ?u8 = null,
    leader_seen_len: usize = 0, // What the checker last saw of the leader's log; 0 = nothing.
    committed: u64 = 0,
    reported_max: u64 = 0,
    leader_terms: u32 = 0,
    applies: u32 = 0,
    restarts: u32 = 0,

    fn elect(model: *Model, prng: *Prng) void {
        if (model.term >= terms_cap - 2) return;
        const start = prng.uint_less_than(nodes_count);
        for (0..nodes_count) |offset| {
            const node: u8 = @intCast((start + offset) % nodes_count);
            if (model.node_len[node] < model.committed) continue; // Would be incomplete.
            model.term += 1;
            model.leader = node;
            model.leader_seen_len = 0;
            model.node_len[node] = model.canon_len; // The new leader catches up to everything.
            model.leader_terms += 1;
            return;
        }
        unreachable; // A majority holds `committed`, so some node qualifies.
    }

    fn append(model: *Model) void {
        const leader = model.leader orelse return;
        if (model.canon_len == log_cap) return;
        const index = model.canon_len;
        model.bytes[index] = @truncate(model.term *% 31 +% index);
        model.canon[index] = fx.entry(index + 1, model.term, model.bytes[index..][0..1]);
        model.canon_len += 1;
        model.node_len[leader] = model.canon_len;
    }

    fn replicate(model: *Model, prng: *Prng) void {
        const node: u8 = @intCast(prng.uint_less_than(nodes_count));
        if (model.node_len[node] < model.canon_len) model.node_len[node] += 1;
    }

    fn advance_commit(model: *Model, prng: *Prng) void {
        const lens = model.node_len;
        const low = @min(lens[0], @min(lens[1], lens[2]));
        const high = @max(lens[0], @max(lens[1], lens[2]));
        const majority: u64 = lens[0] + lens[1] + lens[2] - low - high; // The middle one.
        model.committed = @max(model.committed, majority);
        const node = prng.uint_less_than(nodes_count);
        model.node_commit[node] = @min(model.node_len[node], model.committed);
    }

    fn apply_one(model: *Model, checker: *Checker, prng: *Prng) !void {
        const node: u8 = @intCast(prng.uint_less_than(nodes_count));
        if (model.node_applied[node] >= model.node_commit[node]) return;
        model.node_applied[node] += 1;
        const entry = model.canon[@intCast(model.node_applied[node] - 1)];
        try checker.applied(node, fx.idx(model.node_applied[node]), invariants.fingerprint(&entry));
        model.applies += 1;
    }

    fn restart(model: *Model, checker: *Checker, prng: *Prng) void {
        const node: u8 = @intCast(prng.uint_less_than(nodes_count));
        model.node_commit[node] = 0;
        model.node_applied[node] = 0;
        if (model.leader == node) {
            model.leader = null;
            model.leader_seen_len = 0;
        }
        checker.restarted(node);
        model.restarts += 1;
    }

    fn observations(model: *Model, out: *[nodes_count]Observation) void {
        for (out, 0..) |*slot, i| {
            const log = model.canon[0..model.node_len[i]];
            const is_leader = model.leader == @as(u8, @intCast(i));
            const role: raft.Role = if (is_leader) .leader else .follower;
            slot.* = .{ .node_index = @intCast(i), .status = .{
                .role = role,
                .term = fx.term(model.term),
                .vote = .none,
                .leader = .none,
                .commit_index = fx.idx(model.node_commit[i]),
                .applied_index = fx.idx(model.node_applied[i]),
                .last_index = fx.idx(log.len),
            }, .log = log };
            model.reported_max = @max(model.reported_max, model.node_commit[i]);
        }
    }
};

/// Plants one lie in this step's observations; true when it did.
fn plant(
    model: *const Model,
    fault: Fault,
    observed: *[nodes_count]Observation,
    scratch: *[log_cap]Entry,
    flipped: *[1]u8,
) bool {
    switch (fault) {
        .none => return false,
        .second_leader => {
            const leader = model.leader orelse return false;
            const other = (leader + 1) % nodes_count;
            observed[other].status.role = .leader;
            return true;
        },
        .flip_committed => {
            for (0..nodes_count) |node| {
                if (model.node_commit[node] == 0) continue;
                const log = model.canon[0..model.node_len[node]];
                @memcpy(scratch[0..log.len], log);
                flipped[0] = model.bytes[0] ^ 0xff;
                scratch[0].data = flipped;
                observed[node].log = scratch[0..log.len];
                return true;
            }
            return false;
        },
        .cut_leader => {
            const leader = model.leader orelse return false;
            if (model.leader_seen_len == 0) return false;
            observed[leader].log = model.canon[0 .. model.leader_seen_len - 1];
            return true;
        },
    }
}

fn run(seed: u64, fault: Fault, injected: *bool, outcome: *Outcome) !void {
    var prng = Prng.init(seed);
    var checker: Checker = undefined;
    try checker.init(testing.allocator, options);
    defer checker.deinit(testing.allocator);
    var model: Model = .{};
    const inject_at = 40 + prng.uint_less_than(200);
    var scratch: [log_cap]Entry = undefined;
    var flipped: [1]u8 = undefined;
    injected.* = false;
    for (0..steps_max) |step| {
        outcome.steps = @intCast(step);
        const roll = prng.uint_less_than(100);
        if (roll < 10 or model.leader == null and roll < 60) {
            model.elect(&prng);
        } else if (roll < 35) {
            model.append();
        } else if (roll < 65) {
            model.replicate(&prng);
        } else if (roll < 80) {
            model.advance_commit(&prng);
        } else if (roll < 90) {
            try model.apply_one(&checker, &prng);
        } else if (roll < 95) {
            model.restart(&checker, &prng);
        }
        var observed: [nodes_count]Observation = undefined;
        model.observations(&observed);
        if (step >= inject_at and !injected.*) {
            injected.* = plant(&model, fault, &observed, &scratch, &flipped);
        }
        try checker.observe(&observed);
        if (model.leader != null) model.leader_seen_len = model.node_len[model.leader.?];
    }
    outcome.* = .{
        .stats = checker.stats(),
        .applies = model.applies,
        .restarts = model.restarts,
        .steps = steps_max,
    };
    try testing.expectEqual(model.leader_terms, outcome.stats.leader_terms);
    try testing.expectEqual(model.reported_max, outcome.stats.committed_max);
    for ([_]invariants.Property{
        .election_safety,
        .leader_append_only,
        .log_matching,
        .leader_completeness,
        .state_machine_safety,
    }) |property| try checker.check(property);
}

test "invariants model: honest seeded clusters never raise a violation and stats match" {
    var commits: u64 = 0;
    var applies: u64 = 0;
    var restarts: u64 = 0;
    var leaders: u64 = 0;
    for (0..seeds_count) |seed| {
        var injected = false;
        var outcome: Outcome = .{};
        try run(seed, .none, &injected, &outcome);
        try testing.expect(!injected);
        commits += outcome.stats.committed_max;
        applies += outcome.applies;
        restarts += outcome.restarts;
        leaders += outcome.stats.leader_terms;
    }
    // The run did real work: the checker saw commits, applies, restarts and elections.
    try testing.expect(commits >= seeds_count);
    try testing.expect(applies >= seeds_count);
    try testing.expect(restarts >= seeds_count);
    try testing.expect(leaders >= seeds_count);
}

test "invariants model: the same seed replays to the same stats" {
    for ([_]u64{ 1, 7, 99 }) |seed| {
        var injected = false;
        var first: Outcome = .{};
        var second: Outcome = .{};
        try run(seed, .none, &injected, &first);
        try run(seed, .none, &injected, &second);
        try testing.expectEqual(first, second);
    }
}

fn expect_planted(fault: Fault, allowed: []const anyerror) !void {
    var caught: u32 = 0;
    var first_seed: ?u64 = null;
    var first_error: anyerror = error.TestUnexpectedResult;
    for (0..seeds_count) |seed| {
        var injected = false;
        var outcome: Outcome = .{};
        if (run(seed, fault, &injected, &outcome)) |_| {
            // A planted lie that was injected must never slip through.
            try testing.expect(!injected);
        } else |err| {
            try testing.expect(injected); // An honest step never raises a violation.
            try testing.expect(std.mem.indexOfScalar(anyerror, allowed, err) != null);
            caught += 1;
            if (first_seed == null) {
                first_seed = seed;
                first_error = err;
            }
        }
    }
    try testing.expect(caught >= seeds_count / 2);
    var injected = false;
    var outcome: Outcome = .{};
    try testing.expectError(first_error, run(first_seed.?, fault, &injected, &outcome));
}

test "invariants model: a second leader in a term is caught as ElectionSafety" {
    try expect_planted(.second_leader, &.{error.ElectionSafety});
}

test "invariants model: a flipped committed byte is caught as log matching or state safety" {
    try expect_planted(.flip_committed, &.{ error.LogMatching, error.StateMachineSafety });
}

test "invariants model: a leader whose log is cut inside its term is caught" {
    try expect_planted(.cut_leader, &.{
        error.LeaderAppendOnly,
        error.LeaderCompleteness,
        error.StateMachineSafety,
    });
}
