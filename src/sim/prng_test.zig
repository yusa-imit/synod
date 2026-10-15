//! Tests for `sim/prng.zig` (ADR-008, "Seeds"). Expected words were computed independently from
//! the published SplitMix64 algorithm (`state += 0x9E3779B97F4A7C15`, then the finalizer with
//! `0xBF58476D1CE4E5B9`, `0x94D049BB133111EB` and shifts 30, 27, 31), never read from the
//! implementation under test. `derive_seed` vectors follow the ADR formula
//! `mix64(root ^ mix64((stream << 32) | lane))`.

const std = @import("std");
const testing = std.testing;
const prng_module = @import("prng.zig");

const Prng = prng_module.Prng;
const Stream = prng_module.Stream;
const derive_seed = prng_module.derive_seed;

const seed_zero_words = [_]u64{
    0xe220a8397b1dcdaf, 0x6e789e6aa1b965f4, 0x06c45d188009454f, 0xf88bb8a8724c81ec,
};
const seed_1234567_words = [_]u64{
    0x599ed017fb08fc85, 0x2c73f08458540fa5, 0x883ebce5a3f27c77, 0x3fbef740e9177b3f,
};
/// `(word * 100) >> 64` for the first six words of seeds 0 and 1234567.
const seed_zero_percent = [_]u64{ 88, 43, 2, 97, 10, 32 };
const seed_1234567_percent = [_]u64{ 35, 17, 53, 24, 88, 42 };

test "prng: seed 0 yields the published SplitMix64 words in order" {
    var prng = Prng.init(0);
    for (seed_zero_words) |word| try testing.expectEqual(word, prng.next_u64());
}

test "prng: seed 1234567 yields the independently computed SplitMix64 words" {
    var prng = Prng.init(1234567);
    for (seed_1234567_words) |word| try testing.expectEqual(word, prng.next_u64());
}

test "prng: init stores the seed as the state and each draw adds the golden gamma" {
    var prng = Prng.init(77);
    try testing.expectEqual(@as(u64, 77), prng.state);
    _ = prng.next_u64();
    try testing.expectEqual(@as(u64, 77) +% 0x9e3779b97f4a7c15, prng.state);
}

test "prng: same seed replays the same stream and a different seed does not" {
    var a = Prng.init(5);
    var b = Prng.init(5);
    var c = Prng.init(6);
    var differs = false;
    for (0..64) |_| {
        const word = a.next_u64();
        try testing.expectEqual(word, b.next_u64());
        if (word != c.next_u64()) differs = true;
    }
    try testing.expect(differs);
}

test "prng: uint_less_than is multiply-high of exactly one draw" {
    var prng = Prng.init(0);
    try testing.expectEqual(@as(u64, 88), prng.uint_less_than(100));
    try testing.expectEqual(@as(u64, 43), prng.uint_less_than(100));
    try testing.expectEqual(seed_zero_words[2], prng.next_u64()); // Two draws were consumed.
    var wide = Prng.init(0);
    try testing.expectEqual(@as(u64, 883310814), wide.uint_less_than(1_000_000_007));
    var seven = Prng.init(0);
    try testing.expectEqual(@as(u64, 6), seven.uint_less_than(7));
}

test "prng: uint_less_than bound 1 is zero and still consumes one draw" {
    var prng = Prng.init(0);
    try testing.expectEqual(@as(u64, 0), prng.uint_less_than(1));
    try testing.expectEqual(seed_zero_words[1], prng.next_u64());
}

test "prng: uint_less_than stays below the bound for small, odd and huge bounds" {
    var prng = Prng.init(99);
    const bounds = [_]u64{ 1, 2, 3, 7, 100, 255, 256, 1 << 32, std.math.maxInt(u64) };
    for (bounds) |bound| {
        var highest: u64 = 0;
        for (0..2000) |_| {
            const value = prng.uint_less_than(bound);
            try testing.expect(value < bound);
            highest = @max(highest, value);
        }
        if (bound >= 100) try testing.expect(highest >= bound / 2); // Not stuck at zero.
    }
}

test "prng: uint_less_than reaches both ends of a small range" {
    var prng = Prng.init(1);
    var seen = [_]bool{false} ** 4;
    for (0..200) |_| seen[@intCast(prng.uint_less_than(4))] = true;
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, &seen);
}

test "prng: chance(0) never fires and chance(100) always fires, one draw each" {
    var prng = Prng.init(3);
    for (0..1000) |_| try testing.expect(!prng.chance(0));
    for (0..1000) |_| try testing.expect(prng.chance(100));
    var counted = Prng.init(3);
    for (0..2000) |_| _ = counted.next_u64();
    try testing.expectEqual(counted.state, prng.state); // 2000 chances == 2000 draws.
}

test "prng: chance(p) is uint_less_than(100) < p over the pinned word vectors" {
    for (seed_zero_percent, 0..) |roll, i| {
        try expect_chance_at(0, i, roll);
    }
    for (seed_1234567_percent, 0..) |roll, i| {
        try expect_chance_at(1234567, i, roll);
    }
}

/// Checks `chance(roll)` is false and `chance(roll + 1)` true for the `i`-th draw of `seed`.
fn expect_chance_at(seed: u64, i: usize, roll: u64) !void {
    var below = Prng.init(seed);
    var above = Prng.init(seed);
    for (0..i) |_| {
        _ = below.next_u64();
        _ = above.next_u64();
    }
    try testing.expect(!below.chance(@intCast(roll)));
    try testing.expect(above.chance(@intCast(roll + 1)));
}

test "prng: chance(30) fires about 30 percent of the time" {
    var prng = Prng.init(2024);
    var fired: u32 = 0;
    for (0..10_000) |_| {
        if (prng.chance(30)) fired += 1;
    }
    try testing.expect(fired > 2700 and fired < 3300);
}

test "prng: as_rng draws are the Prng draws, in order" {
    var direct = Prng.init(0);
    var wrapped = Prng.init(0);
    const rng = wrapped.as_rng();
    for (seed_zero_words) |word| {
        try testing.expectEqual(word, rng.next_u64());
        try testing.expectEqual(word, direct.next_u64());
    }
    try testing.expectEqual(direct.state, wrapped.state);
}

test "prng: as_rng uint_less_than takes one draw from the wrapped generator" {
    var wrapped = Prng.init(0);
    const rng = wrapped.as_rng();
    try testing.expectEqual(@as(u64, 88), rng.uint_less_than(100));
    try testing.expectEqual(seed_zero_words[1], wrapped.next_u64());
}

test "prng: derive_seed matches the ADR formula on pinned vectors" {
    try testing.expectEqual(@as(u64, 0xedfea30cfbbf01c3), derive_seed(0, .network, 0));
    try testing.expectEqual(@as(u64, 0x3c21aba77ea87bae), derive_seed(0, .faults, 0));
    try testing.expectEqual(@as(u64, 0x6542405835aaa86b), derive_seed(0, .workload, 0));
    try testing.expectEqual(@as(u64, 0x1fdc03dbd5e0fbca), derive_seed(0, .node, 0));
    try testing.expectEqual(@as(u64, 0xdbf492b5a4d51913), derive_seed(42, .network, 0));
    try testing.expectEqual(@as(u64, 0xe701b93d643407da), derive_seed(42, .node, 2));
    try testing.expectEqual(@as(u64, 0x5bacdf9ad1fa1280), derive_seed(42, .node, 258));
    const max = std.math.maxInt(u64);
    try testing.expectEqual(
        @as(u64, 0xf2b1b918c7864b1a),
        derive_seed(max, .workload, std.math.maxInt(u32)),
    );
}

test "prng: derive_seed is a pure function of root, stream and lane" {
    const first = derive_seed(9, .faults, 3);
    try testing.expectEqual(first, derive_seed(9, .faults, 3));
    try testing.expect(first != derive_seed(10, .faults, 3));
    try testing.expect(first != derive_seed(9, .network, 3));
    try testing.expect(first != derive_seed(9, .faults, 4));
}

test "prng: derive_seed gives every stream and node lane of one root a distinct seed" {
    var seeds: [4 * 1024]u64 = undefined;
    var count: usize = 0;
    const streams = [_]Stream{ .network, .faults, .workload, .node };
    for (streams) |stream| {
        for (0..4) |generation| { // Node lane: (generation << 8) | node_index.
            for (0..256) |node_index| {
                const lane: u32 = @intCast((generation << 8) | node_index);
                seeds[count] = derive_seed(1234, stream, lane);
                count += 1;
            }
        }
    }
    try testing.expectEqual(seeds.len, count);
    std.mem.sort(u64, &seeds, {}, std.sort.asc(u64));
    for (seeds[1..], 0..) |seed, i| try testing.expect(seed != seeds[i]);
}

test "prng: node 2's first life draws the same words in any cluster size" {
    // Lane 2 is a function of the node index alone, so no node count can reach the seed.
    var in_three = Prng.init(derive_seed(7, .node, 2));
    var in_five = Prng.init(derive_seed(7, .node, 2));
    for (0..16) |_| try testing.expectEqual(in_three.next_u64(), in_five.next_u64());
    var restarted = Prng.init(derive_seed(7, .node, (1 << 8) | 2));
    var first_life = Prng.init(derive_seed(7, .node, 2));
    try testing.expect(restarted.next_u64() != first_life.next_u64());
}

test "prng: fuzz: uint_less_than respects any bound and chance never exceeds its percent" {
    try testing.fuzz({}, fuzz_prng, .{});
}

fn fuzz_prng(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const seed = smith.value(u64);
    const bound = smith.valueRangeAtMost(u64, 1, std.math.maxInt(u64));
    const percent = smith.valueRangeAtMost(u8, 0, 100);
    var prng = Prng.init(seed);
    var twin = Prng.init(seed);
    var model = seed; // An independent SplitMix64: the published algorithm, inlined.
    for (0..32) |_| {
        model +%= 0x9e3779b97f4a7c15;
        var mixed = model;
        mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
        mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
        mixed ^= mixed >> 31;
        const word = twin.next_u64();
        try testing.expectEqual(mixed, word);
        const expected: u64 = @intCast((@as(u128, word) * bound) >> 64);
        try testing.expectEqual(expected, prng.uint_less_than(bound));
    }
    var chance_prng = Prng.init(seed);
    if (percent == 0) try testing.expect(!chance_prng.chance(percent));
    if (percent == 100) try testing.expect(chance_prng.chance(percent));
}
