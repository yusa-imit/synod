//! Seeded model-based tests for `sim/network.zig` (ADR-008; Tiger Style, the library form of
//! simulation testing). Two runs per seed over 200 seeds:
//!
//! - The exact run uses a fixed delay and no loss or duplication, so a naive FIFO list is a
//!   complete reference: every `pop_due` result, `next_due_ms`, `in_flight`, the reachability
//!   matrix and all seven counters are compared with it after every step.
//! - The random run turns loss, duplication and a delay range on. No reference can predict
//!   those draws, so it checks what must hold whatever they are: every delivery equals what was
//!   sent, nothing is delivered more often than it was duplicated, counters never run backwards
//!   and `sent + duplicated == delivered + dropped_* + in_flight` after every step.
//!
//! `check_invariants()` runs after every step of both. The test's own draws come from the
//! workload stream of `sim/prng.zig`, the network's from its network stream.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const fx = @import("fixtures.zig");
const network_module = @import("network.zig");
const prng_module = @import("prng.zig");

const Network = network_module.Network;
const Prng = prng_module.Prng;
const Rig = fx.Rig;
const Spec = fx.Spec;
const Stats = Network.Stats;

const seeds_count = 200;
const steps_count = 80;

// -- The exact run: a FIFO reference ------------------------------------------------------

const exact_nodes = 4;
const exact_capacity = 6;

const Pending = struct { due_ms: u64, spec: Spec };

const Reference = struct {
    delay_ms: u32,
    queue: [exact_capacity]Pending,
    len: u32,
    cut: [exact_nodes][exact_nodes]bool,
    counters: Stats,

    fn init(delay_ms: u32) Reference {
        return .{
            .delay_ms = delay_ms,
            .queue = undefined,
            .len = 0,
            .cut = @splat(@splat(false)),
            .counters = std.mem.zeroes(Stats),
        };
    }

    fn send(ref: *Reference, spec: Spec, now_ms: u64) void {
        ref.counters.sent += 1;
        if (ref.len == exact_capacity) {
            ref.counters.dropped_full += 1;
            return;
        }
        ref.queue[ref.len] = .{ .due_ms = now_ms + ref.delay_ms, .spec = spec };
        ref.len += 1;
    }

    /// The next deliverable due message: cut ones are consumed and counted on the way.
    fn pop(ref: *Reference, now_ms: u64) ?Spec {
        while (ref.len > 0 and ref.queue[0].due_ms <= now_ms) {
            const head = ref.queue[0];
            ref.len -= 1;
            std.mem.copyForwards(Pending, ref.queue[0..ref.len], ref.queue[1 .. ref.len + 1]);
            if (ref.cut[head.spec.from - 1][head.spec.to - 1]) {
                ref.counters.dropped_cut += 1;
                continue;
            }
            ref.counters.delivered += 1;
            return head.spec;
        }
        return null;
    }

    fn drop_down(ref: *Reference) void {
        ref.counters.delivered -= 1;
        ref.counters.dropped_down += 1;
    }

    fn heal(ref: *Reference) void {
        ref.cut = @splat(@splat(false));
    }

    fn partition(ref: *Reference, side_a: []const u8, side_b: []const u8) void {
        ref.heal();
        for (side_a) |a| {
            for (side_b) |b| {
                ref.cut[a][b] = true;
                ref.cut[b][a] = true;
            }
        }
    }
};

const ExactRun = struct {
    rig: *Rig,
    ref: Reference,
    prng: Prng,
    serial: u64,

    fn step(run: *ExactRun) !void {
        const roll = run.prng.uint_less_than(100);
        if (roll < 45) {
            run.send();
        } else if (roll < 55) {
            run.cut_random();
        } else if (roll < 62) {
            run.rig.network.heal();
            run.ref.heal();
        } else if (roll < 70) {
            run.partition();
        } else if (roll < 82) {
            run.rig.advance(run.prng.uint_less_than(run.ref.delay_ms * 2 + 1));
        } else {
            try run.pop_all();
        }
        try run.agree();
    }

    fn pick_pair(run: *ExactRun) [2]u8 {
        const from: u8 = @intCast(run.prng.uint_less_than(exact_nodes));
        const offset: u8 = @intCast(run.prng.uint_less_than(exact_nodes - 1));
        return .{ from, (from + 1 + offset) % exact_nodes };
    }

    fn send(run: *ExactRun) void {
        const pair = run.pick_pair();
        run.serial += 1;
        const spec = fx.random_spec(&run.prng, pair[0] + 1, pair[1] + 1, run.serial);
        var scratch: [fx.entries_max]types.Entry = undefined;
        const message = spec.build(&scratch);
        run.rig.network.send(&message);
        run.ref.send(spec, run.rig.clock.time_ms);
    }

    fn cut_random(run: *ExactRun) void {
        const pair = run.pick_pair();
        run.rig.network.cut(.{ .from_index = pair[0], .to_index = pair[1] });
        run.ref.cut[pair[0]][pair[1]] = true;
    }

    fn partition(run: *ExactRun) void {
        const first: u8 = @intCast(run.prng.uint_less_than(exact_nodes));
        const second: u8 = (first + 1) % exact_nodes;
        run.rig.network.heal(); // set_partition on top of earlier cuts is not pinned.
        run.rig.network.set_partition(&.{first}, &.{ second, (second + 1) % exact_nodes });
        run.ref.partition(&.{first}, &.{ second, (second + 1) % exact_nodes });
    }

    fn pop_all(run: *ExactRun) !void {
        while (true) {
            const got = run.rig.network.pop_due();
            const want = run.ref.pop(run.rig.clock.time_ms);
            if (want == null) {
                try testing.expect(got == null);
                return;
            }
            var scratch: [fx.entries_max]types.Entry = undefined;
            const expected = want.?.build(&scratch);
            try testing.expect(got != null);
            try testing.expect(fx.message_eql(&expected, got.?));
            if (run.prng.chance(25)) {
                run.rig.network.drop_down();
                run.ref.drop_down();
            }
        }
    }

    fn agree(run: *ExactRun) !void {
        const network = &run.rig.network;
        try testing.expectEqualDeep(run.ref.counters, network.stats());
        try testing.expectEqual(run.ref.len, network.in_flight());
        const due: ?u64 = if (run.ref.len > 0) run.ref.queue[0].due_ms else null;
        try testing.expectEqual(due, network.next_due_ms());
        for (0..exact_nodes) |from| {
            for (0..exact_nodes) |to| {
                if (from == to) continue;
                const open = network.reachable(fx.link_of(from, to));
                try testing.expectEqual(!run.ref.cut[from][to], open);
            }
        }
        try network.check_invariants();
    }
};

fn run_exact(seed: u64) !void {
    const delay: u32 = @intCast(1 + seed % 7);
    var model = fx.base_model;
    model.messages_max = exact_capacity;
    model.delay_ms_min = delay;
    model.delay_ms_max = delay;
    var rig: Rig = undefined;
    try rig.init(testing.allocator, fx.options_of(exact_nodes, model, .none), seed);
    defer rig.deinit(testing.allocator);
    var run: ExactRun = .{
        .rig = &rig,
        .ref = Reference.init(delay),
        .prng = Prng.init(prng_module.derive_seed(seed, .workload, 0)),
        .serial = 0,
    };
    for (0..steps_count) |_| try run.step();
    rig.advance(1000); // Everything left is due: the model and the network flush alike.
    try run.pop_all();
    try run.agree();
    try testing.expectEqual(@as(u32, 0), rig.network.in_flight());
}

test "network model: 200 seeds agree with a FIFO reference after every step" {
    for (0..seeds_count) |seed| run_exact(seed) catch |err| {
        std.log.err("network model: exact run failed at seed {d}", .{seed});
        return err;
    };
}

// -- The random run: conservation and delivery laws ---------------------------------------

const random_steps = 120;

const Totals = struct { trace: u64, stats: Stats, popped: u64 };

const RandomRun = struct {
    rig: *Rig,
    prng: Prng,
    nodes: u8,
    duplicates_on: bool,
    specs: [random_steps]Spec,
    delivered_of: [random_steps]u8,
    sends: u64,
    popped: u64,
    downs: u64,
    last: Stats,

    fn step(run: *RandomRun) !void {
        const roll = run.prng.uint_less_than(100);
        if (roll < 50) {
            run.send();
        } else if (roll < 56) {
            const pair = run.pick_pair();
            run.rig.network.cut(.{ .from_index = pair[0], .to_index = pair[1] });
        } else if (roll < 60) {
            run.rig.network.heal();
        } else if (roll < 75) {
            run.rig.advance(run.prng.uint_less_than(12));
        } else {
            try run.pop_all();
        }
        try run.check();
    }

    fn pick_pair(run: *RandomRun) [2]u8 {
        const from: u8 = @intCast(run.prng.uint_less_than(run.nodes));
        const offset: u8 = @intCast(run.prng.uint_less_than(run.nodes - 1));
        return .{ from, (from + 1 + offset) % run.nodes };
    }

    fn send(run: *RandomRun) void {
        if (run.sends == random_steps) return; // Out of serials: skip the send.
        const pair = run.pick_pair();
        const serial = run.sends + 1;
        run.specs[run.sends] = fx.random_spec(&run.prng, pair[0] + 1, pair[1] + 1, serial);
        var scratch: [fx.entries_max]types.Entry = undefined;
        const message = run.specs[run.sends].build(&scratch);
        run.rig.network.send(&message);
        run.sends += 1;
    }

    fn pop_all(run: *RandomRun) !void {
        while (run.rig.network.pop_due()) |message| {
            const serial: usize = @intCast(@intFromEnum(message.header().term));
            try testing.expect(serial >= 1 and serial <= run.sends);
            var scratch: [fx.entries_max]types.Entry = undefined;
            const expected = run.specs[serial - 1].build(&scratch);
            try testing.expect(fx.message_eql(&expected, message));
            run.delivered_of[serial - 1] += 1;
            run.popped += 1;
            if (run.prng.chance(20)) {
                run.rig.network.drop_down();
                run.downs += 1;
            }
        }
    }

    /// Delivers everything still in flight, popping through `pop_all` so it is all counted.
    fn flush(run: *RandomRun) !void {
        var rounds: u32 = 0;
        while (run.rig.network.next_due_ms()) |due| {
            rounds += 1;
            try testing.expect(rounds < 1000);
            if (due > run.rig.clock.time_ms) run.rig.clock.advance_to(due);
            try run.pop_all();
            try run.check();
        }
        try testing.expectEqual(@as(u32, 0), run.rig.network.in_flight());
    }

    /// With nothing in flight each sent message was delivered at most `1 + duplicates` times.
    fn check_end(run: *const RandomRun) !void {
        const per_message_max: u8 = if (run.duplicates_on) 2 else 1;
        var delivered_or_down: u64 = 0;
        for (run.delivered_of[0..run.sends]) |count| {
            try testing.expect(count <= per_message_max);
            delivered_or_down += count;
        }
        try testing.expectEqual(run.popped, delivered_or_down);
        const stats = run.rig.network.stats();
        try testing.expectEqual(run.popped, stats.delivered + stats.dropped_down);
    }

    fn check(run: *RandomRun) !void {
        const network = &run.rig.network;
        const stats = network.stats();
        const dropped = stats.dropped_loss + stats.dropped_full + stats.dropped_cut +
            stats.dropped_down;
        try testing.expectEqual(run.sends, stats.sent);
        try testing.expectEqual(run.popped - run.downs, stats.delivered);
        try testing.expectEqual(run.downs, stats.dropped_down);
        try testing.expectEqual(stats.sent + stats.duplicated, stats.delivered + dropped +
            network.in_flight());
        try testing.expect(stats.sent >= run.last.sent);
        try testing.expect(stats.duplicated >= run.last.duplicated);
        try testing.expect(stats.dropped_loss >= run.last.dropped_loss);
        try testing.expect(stats.dropped_full >= run.last.dropped_full);
        try testing.expect(stats.dropped_cut >= run.last.dropped_cut);
        run.last = stats;
        try network.check_invariants();
    }
};

fn random_model(seed: u64) Network.Model {
    const losses = [_]u8{ 0, 10, 30, 60 };
    const duplicates = [_]u8{ 0, 20, 50, 100 };
    const delay_min: u32 = @intCast(1 + seed % 3);
    return .{
        .messages_max = @intCast(4 + seed % 13),
        .delay_ms_min = delay_min,
        .delay_ms_max = delay_min + @as(u32, @intCast(seed % 9)),
        .loss_percent = losses[seed % 4],
        .duplicate_percent = duplicates[(seed / 4) % 4],
    };
}

fn run_random(seed: u64) !Totals {
    const model = random_model(seed);
    const nodes: u8 = @intCast(3 + seed % 3);
    var rig: Rig = undefined;
    const seed_network = prng_module.derive_seed(seed, .network, 0);
    try rig.init(testing.allocator, fx.options_of(nodes, model, .none), seed_network);
    defer rig.deinit(testing.allocator);
    var run: RandomRun = .{
        .rig = &rig,
        .prng = Prng.init(prng_module.derive_seed(seed, .workload, 0)),
        .nodes = nodes,
        .duplicates_on = model.duplicate_percent > 0,
        .specs = undefined,
        .delivered_of = @splat(0),
        .sends = 0,
        .popped = 0,
        .downs = 0,
        .last = std.mem.zeroes(Stats),
    };
    for (0..random_steps) |_| try run.step();
    rig.network.heal();
    try run.flush();
    try run.check_end();
    return .{
        .trace = rig.network.trace_hash(),
        .stats = rig.network.stats(),
        .popped = run.popped,
    };
}

test "network model: 200 seeds keep the conservation identity and the delivery laws" {
    for (0..seeds_count) |seed| {
        _ = run_random(seed) catch |err| {
            std.log.err("network model: random run failed at seed {d}", .{seed});
            return err;
        };
    }
}

test "network model: a seed replays to the same stats, trace hash and delivery count" {
    for ([_]u64{ 0, 1, 7, 42, 199 }) |seed| {
        const first = try run_random(seed);
        const second = try run_random(seed);
        try testing.expectEqual(first.trace, second.trace);
        try testing.expectEqual(first.popped, second.popped);
        try testing.expectEqualDeep(first.stats, second.stats);
    }
}

test "network model: different seeds give different trace hashes" {
    var traces: [seeds_count]u64 = undefined;
    for (&traces, 0..) |*trace, seed| trace.* = (try run_random(seed)).trace;
    std.mem.sort(u64, &traces, {}, std.sort.asc(u64));
    var distinct: u32 = 1;
    for (traces[1..], 0..) |trace, i| {
        if (trace != traces[i]) distinct += 1;
    }
    try testing.expect(distinct >= seeds_count - 10);
    try testing.expect(traces[0] != 0 or traces[seeds_count - 1] != 0);
}

test "network model: the 200 seeds exercise every drop path and duplication" {
    var total = std.mem.zeroes(Stats);
    var with_delivery: u32 = 0;
    for (0..seeds_count) |seed| {
        const totals = try run_random(seed);
        total.sent += totals.stats.sent;
        total.delivered += totals.stats.delivered;
        total.duplicated += totals.stats.duplicated;
        total.dropped_loss += totals.stats.dropped_loss;
        total.dropped_full += totals.stats.dropped_full;
        total.dropped_cut += totals.stats.dropped_cut;
        total.dropped_down += totals.stats.dropped_down;
        if (totals.stats.delivered > 0) with_delivery += 1;
    }
    try testing.expect(total.delivered > 1000);
    try testing.expect(total.duplicated > 100);
    try testing.expect(total.dropped_loss > 100);
    try testing.expect(total.dropped_full > 20);
    try testing.expect(total.dropped_cut > 20);
    try testing.expect(total.dropped_down > 20);
    try testing.expect(with_delivery >= seeds_count * 9 / 10);
}

test "network model: fuzz: any seed keeps both models in agreement" {
    try testing.fuzz({}, fuzz_seed, .{});
}

fn fuzz_seed(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const seed = smith.value(u64);
    try run_exact(seed);
    const first = try run_random(seed);
    const second = try run_random(seed);
    try testing.expectEqual(first.trace, second.trace);
}
