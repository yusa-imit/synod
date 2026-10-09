//! Tests for `raft.progress.Progress` (plan 003 item 2C): the per-follower replication tracker.
//! Positive contract, negative space (stale and duplicate responses, clamped hints), the index
//! boundaries, every `InvariantError` variant provoked by hand-corrupting a value, and one seeded
//! model-based test against a naive reference written here from Raft semantics, not from the
//! implementation. `Progress` is a plain value (no allocation), so there is nothing to leak.

const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const progress_module = @import("progress.zig");
const types = @import("../types.zig");

const Conflict = types.Conflict;
const Progress = progress_module.Progress;

const idx = fixtures.idx;
const term = fixtures.term;

/// A rejection hint at index `at` (`0` = the follower's log is shorter than `prev_log_index`).
fn hint(at: u64) Conflict {
    return .{ .index = idx(at), .term = if (at == 0) .zero else term(1) };
}

/// A progress in `.replicate` with match 6 and next 7 (leader last index 5, entry 6 acked).
fn replicating(window: u32) !Progress {
    var p = Progress.init(idx(5), window);
    p.on_send(idx(6));
    try testing.expect(p.on_accepted(idx(6)));
    try p.check_invariants();
    try testing.expectEqual(progress_module.State.replicate, p.state);
    return p;
}

test "progress: init starts in probe with match zero, next after the leader log" {
    var p = Progress.init(idx(5), 3);
    try p.check_invariants();
    try testing.expectEqual(idx(0), p.match);
    try testing.expectEqual(idx(6), p.next);
    try testing.expectEqual(progress_module.State.probe, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expectEqual(@as(u32, 3), p.inflight_max);

    const empty = Progress.init(.zero, 1); // An empty leader log: next is the first index.
    try empty.check_invariants();
    try testing.expectEqual(idx(1), empty.next);
    try testing.expectEqual(idx(0), empty.match);
}

test "progress: probe can send only while nothing is in flight" {
    var p = Progress.init(idx(5), 4);
    try testing.expect(p.can_send());
    p.on_send(idx(5));
    try p.check_invariants();
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
    try testing.expect(!p.can_send()); // One in flight blocks, however large the window.
}

test "progress: replicate can send exactly while inflight is below the window" {
    var p = try replicating(3);
    p.inflight_count = 2; // inflight_max - 1
    try testing.expect(p.can_send());
    p.inflight_count = 3; // inflight_max
    try testing.expect(!p.can_send());
    p.inflight_count = 0;
    try testing.expect(p.can_send());
}

test "progress: probe on_send counts the request but leaves next unchanged" {
    var p = Progress.init(idx(5), 4);
    p.on_send(idx(9)); // An optimistic bump would put next at 10.
    try p.check_invariants();
    try testing.expectEqual(idx(6), p.next);
    try testing.expectEqual(idx(0), p.match);
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
    try testing.expectEqual(progress_module.State.probe, p.state);
}

test "progress: replicate on_send advances next past the last sent entry" {
    var p = try replicating(4);
    try testing.expectEqual(idx(7), p.next);
    p.on_send(idx(9));
    try p.check_invariants();
    try testing.expectEqual(idx(10), p.next);
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
    p.on_send(idx(12)); // A second request pipelined further out.
    try p.check_invariants();
    try testing.expectEqual(idx(13), p.next);
    try testing.expectEqual(@as(u32, 2), p.inflight_count);
}

test "progress: a heartbeat in replicate counts in flight but leaves next where it was" {
    var p = try replicating(4);
    const before = p.next;
    p.on_send(idx(@intFromEnum(before) - 1)); // Empty request: last_sent = next - 1.
    try p.check_invariants();
    try testing.expectEqual(before, p.next);
    try testing.expectEqual(@as(u32, 1), p.inflight_count);
    try testing.expectEqual(idx(6), p.match);
}

test "progress: a window of one allows a single request until a response frees the slot" {
    var p = try replicating(1);
    try testing.expect(p.can_send());
    p.on_send(idx(7));
    try p.check_invariants();
    try testing.expect(!p.can_send());
    try testing.expect(p.on_accepted(idx(7)));
    try p.check_invariants();
    try testing.expect(p.can_send());
}

test "progress: a window of four fills after four sends and reopens one slot per response" {
    var p = try replicating(4);
    var last: u64 = 7;
    while (last < 11) : (last += 1) {
        try testing.expect(p.can_send());
        p.on_send(idx(last));
        try p.check_invariants();
    }
    try testing.expectEqual(@as(u32, 4), p.inflight_count);
    try testing.expect(!p.can_send());
    try testing.expectEqual(idx(11), p.next);

    try testing.expect(p.on_accepted(idx(7)));
    try testing.expectEqual(@as(u32, 3), p.inflight_count);
    try testing.expect(p.can_send());
    try p.check_invariants();
}

test "progress: an accepted response advances match, raises next, and enters replicate" {
    var p = Progress.init(idx(5), 4);
    p.on_send(idx(7));
    try testing.expect(p.on_accepted(idx(7)));
    try p.check_invariants();
    try testing.expectEqual(idx(7), p.match);
    try testing.expectEqual(idx(8), p.next);
    try testing.expectEqual(progress_module.State.replicate, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
}

test "progress: an accepted response behind match returns false and changes match nothing" {
    var p = try replicating(4); // match 6
    p.on_send(idx(8));
    const before_next = p.next;

    try testing.expect(!p.on_accepted(idx(6))); // Equal to match: not an advance.
    try testing.expectEqual(idx(6), p.match);
    try testing.expect(!p.on_accepted(idx(3))); // Late and below match.
    try testing.expectEqual(idx(6), p.match);
    try testing.expectEqual(before_next, p.next);
    try p.check_invariants();
}

test "progress: on_accepted never lowers next below an optimistic send" {
    var p = try replicating(4);
    p.on_send(idx(20)); // next runs ahead to 21
    try testing.expect(p.on_accepted(idx(10)));
    try p.check_invariants();
    try testing.expectEqual(idx(10), p.match);
    try testing.expectEqual(idx(21), p.next);
}

test "progress: a response frees exactly one inflight slot" {
    var p = try replicating(5);
    p.on_send(idx(7));
    p.on_send(idx(8));
    p.on_send(idx(9));
    try testing.expectEqual(@as(u32, 3), p.inflight_count);
    try testing.expect(p.on_accepted(idx(7)));
    try testing.expectEqual(@as(u32, 2), p.inflight_count);
    try p.check_invariants();
}

test "progress: duplicate responses saturate inflight at zero instead of underflowing" {
    var p = try replicating(2);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expect(!p.on_accepted(idx(6)));
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expect(!p.on_accepted(idx(6)));
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try p.check_invariants();
}

test "progress: an accepted zero on an empty log never advances but still enters replicate" {
    var p = Progress.init(.zero, 2);
    p.on_send(.zero); // Heartbeat: last_sent = next - 1 = 0.
    try testing.expect(!p.on_accepted(.zero));
    try p.check_invariants();
    try testing.expectEqual(idx(0), p.match);
    try testing.expectEqual(idx(1), p.next);
    try testing.expectEqual(progress_module.State.replicate, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
}

test "progress: backtrack_hint uses the conflict index, steps back one on a shorter log" {
    const cases = [_]struct { conflict: u64, prev: u64, want: u64 }{
        .{ .conflict = 4, .prev = 10, .want = 4 }, // Fast backtrack to the conflicting term.
        .{ .conflict = 0, .prev = 10, .want = 10 }, // Shorter log: unknown hint, prev itself.
        .{ .conflict = 15, .prev = 10, .want = 10 }, // Hint beyond prev is clamped to prev.
        .{ .conflict = 10, .prev = 10, .want = 10 }, // Equal is its own clamp.
        .{ .conflict = 1, .prev = 10, .want = 1 }, // Lowest real index.
        .{ .conflict = 0, .prev = 1, .want = 1 }, // Boundary: result stays >= 1.
        .{ .conflict = 7, .prev = 1, .want = 1 },
    };
    for (cases) |case| {
        const got = Progress.backtrack_hint(hint(case.conflict), idx(case.prev));
        try testing.expectEqual(idx(case.want), got);
    }
}

test "progress: a rejection backtracks next to the conflict hint and falls back to probe" {
    var p = Progress.init(idx(10), 4); // next 11, probe
    p.on_send(idx(10));
    try testing.expect(p.on_rejected(hint(4), idx(10)));
    try p.check_invariants();
    try testing.expectEqual(idx(4), p.next);
    try testing.expectEqual(idx(0), p.match);
    try testing.expectEqual(progress_module.State.probe, p.state);
}

test "progress: a rejection from a shorter follower log steps next back by one" {
    var p = Progress.init(idx(10), 4);
    p.on_send(idx(10));
    try testing.expect(p.on_rejected(hint(0), idx(10)));
    try p.check_invariants();
    try testing.expectEqual(idx(10), p.next);
}

test "progress: a hint above prev_log_index is clamped, never moving next forward" {
    var p = Progress.init(idx(10), 4);
    p.on_send(idx(10));
    try testing.expect(p.on_rejected(hint(15), idx(10)));
    try p.check_invariants();
    try testing.expectEqual(idx(10), p.next);
}

test "progress: a rejection never takes next to or below the acknowledged match" {
    var p = try replicating(4); // match 6
    p.on_send(idx(9));
    p.on_send(idx(12));
    try testing.expect(p.on_rejected(hint(2), idx(9))); // Hint 2 is far below match.
    try p.check_invariants();
    try testing.expectEqual(idx(7), p.next); // match + 1
    try testing.expectEqual(idx(6), p.match);
}

test "progress: a rejection in replicate resets to probe and discards the inflight window" {
    var p = try replicating(4);
    p.on_send(idx(9));
    p.on_send(idx(12));
    try testing.expectEqual(@as(u32, 2), p.inflight_count);
    try testing.expect(p.on_rejected(hint(8), idx(9))); // prev 9 != next - 1: replicate skips it.
    try p.check_invariants();
    try testing.expectEqual(progress_module.State.probe, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
    try testing.expectEqual(idx(8), p.next);
    try testing.expect(p.can_send()); // Probe with nothing in flight may send again.
}

test "progress: a rejection for an index at or below match is stale and changes nothing" {
    var p = try replicating(4); // match 6
    p.on_send(idx(9));
    const before = p;
    try testing.expect(!p.on_rejected(hint(3), idx(6))); // prev == match
    try testing.expectEqual(before, p);
    try testing.expect(!p.on_rejected(hint(0), idx(2))); // prev < match
    try testing.expectEqual(before, p);
    try p.check_invariants();
}

test "progress: in probe a rejection whose prev is not next - 1 is stale and changes nothing" {
    var p = Progress.init(idx(10), 4); // next 11, so the live request had prev 10
    p.on_send(idx(10));
    const before = p;
    try testing.expect(!p.on_rejected(hint(3), idx(7))); // An older, superseded request.
    try testing.expectEqual(before, p);
    try testing.expect(!p.on_rejected(hint(3), idx(11))); // From the future: also not live.
    try testing.expectEqual(before, p);
    try p.check_invariants();
}

test "progress: a rejection with prev_log_index zero is stale in probe and in replicate" {
    var p = Progress.init(.zero, 2); // Empty leader log: next 1, the live request has prev 0.
    p.on_send(.zero);
    const before = p;
    try testing.expect(!p.on_rejected(hint(0), .zero));
    try testing.expectEqual(before, p);
    try testing.expect(!p.on_rejected(hint(5), .zero));
    try testing.expectEqual(before, p);
    try p.check_invariants();

    var q = try replicating(4);
    q.on_send(idx(9));
    const q_before = q;
    try testing.expect(!q.on_rejected(hint(0), .zero));
    try testing.expectEqual(q_before, q);
    try q.check_invariants();
}

test "progress: in replicate a rejection with prev at or above next can never be live" {
    var p = try replicating(4); // match 6, next 7
    const before = p;
    try testing.expect(!p.on_rejected(hint(15), idx(20))); // Late, far beyond next.
    try testing.expectEqual(before, p);
    try testing.expect(!p.on_rejected(hint(0), idx(20)));
    try testing.expectEqual(before, p);
    try testing.expect(!p.on_rejected(hint(3), idx(7))); // prev == next: still not live.
    try testing.expectEqual(before, p);
    try testing.expectEqual(idx(7), p.next);
    try p.check_invariants();
}

test "progress: on_timeout restarts a stalled replicate window at match + 1" {
    var p = try replicating(3); // match 6
    p.on_send(idx(8));
    p.on_send(idx(10));
    p.on_send(idx(12));
    try testing.expect(!p.can_send()); // Window full, every response lost.
    p.on_timeout();
    try p.check_invariants();
    try testing.expect(p.can_send());
    try testing.expectEqual(idx(7), p.next);
    try testing.expectEqual(idx(6), p.match);
    try testing.expectEqual(progress_module.State.probe, p.state);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);
}

test "progress: on_timeout from probe with one request in flight reopens sending" {
    var p = Progress.init(idx(5), 4);
    p.on_send(idx(5));
    try testing.expect(!p.can_send());
    p.on_timeout();
    try p.check_invariants();
    try testing.expect(p.can_send());
    try testing.expectEqual(idx(1), p.next); // match 0 + 1: probe restarts from the start.
    try testing.expectEqual(idx(0), p.match);
    try testing.expectEqual(@as(u32, 0), p.inflight_count);

    p.on_timeout(); // Idempotent when nothing is in flight.
    try p.check_invariants();
    try testing.expectEqual(idx(1), p.next);
}

test "progress: a repeated rejection of the same request is stale the second time" {
    var p = Progress.init(idx(10), 4);
    p.on_send(idx(10));
    try testing.expect(p.on_rejected(hint(4), idx(10))); // next becomes 4, so live prev is 3
    const after_first = p;
    try testing.expect(!p.on_rejected(hint(4), idx(10)));
    try testing.expectEqual(after_first, p);
}

test "progress: a rejection at prev_log_index 1 puts next at the first index with match below it" {
    var p = Progress.init(idx(1), 2); // next 2
    p.on_send(idx(1));
    try testing.expect(p.on_rejected(hint(0), idx(1)));
    try p.check_invariants();
    try testing.expectEqual(idx(1), p.next);
    try testing.expectEqual(idx(0), p.match);

    var q = Progress.init(idx(1), 2);
    q.on_send(idx(1));
    try testing.expect(q.on_rejected(hint(1), idx(1)));
    try testing.expectEqual(idx(1), q.next);
    try q.check_invariants();
}

test "progress: indexes near the largest u64 neither overflow nor break the order" {
    const top: u64 = std.math.maxInt(u64);
    var p = Progress.init(idx(top - 3), 4); // next = top - 2
    try p.check_invariants();
    try testing.expectEqual(idx(top - 2), p.next);
    p.on_send(idx(top - 2));
    try testing.expect(p.on_accepted(idx(top - 2)));
    try p.check_invariants();
    try testing.expectEqual(idx(top - 2), p.match);
    try testing.expectEqual(idx(top - 1), p.next);

    p.on_send(idx(top - 1)); // Replicate: next = top, the largest representable.
    try p.check_invariants();
    try testing.expectEqual(idx(top), p.next);

    try testing.expect(p.on_rejected(hint(top - 1), idx(top - 1)));
    try p.check_invariants();
    try testing.expectEqual(idx(top - 1), p.next);
}

test "progress: next at or below match is InvariantProgressOrder, a zero next too" {
    var p = try replicating(2); // match 6, next 7
    p.next = idx(6); // next == match
    try testing.expectError(error.InvariantProgressOrder, p.check_invariants());
    p.next = idx(3); // next < match
    try testing.expectError(error.InvariantProgressOrder, p.check_invariants());
    p.next = .zero;
    try testing.expectError(error.InvariantProgressOrder, p.check_invariants());

    var fresh = Progress.init(.zero, 2);
    fresh.next = .zero; // match 0, next 0: both rules at once
    try testing.expectError(error.InvariantProgressOrder, fresh.check_invariants());
    fresh.next = idx(1);
    try fresh.check_invariants(); // match 0 < next 1 is the smallest valid pair
}

test "progress: inflight above the window is InvariantInflightOverflow, at the window is fine" {
    var p = try replicating(3);
    p.inflight_count = 3;
    try p.check_invariants();
    p.inflight_count = 4;
    try testing.expectError(error.InvariantInflightOverflow, p.check_invariants());
}

test "progress: more than one request in flight while probing is InvariantInflightOverflow" {
    var p = Progress.init(idx(5), 4);
    p.inflight_count = 1;
    try p.check_invariants();
    p.inflight_count = 2; // Within the window of 4, but probe allows one.
    try testing.expectError(error.InvariantInflightOverflow, p.check_invariants());
}

/// The reference: plain u64 arithmetic straight from Raft semantics. A follower's "next" is the
/// first entry the leader will send; "match" is what it has acknowledged; probing is one-at-a-time.
const Reference = struct {
    acked: u64,
    to_send: u64,
    pipelined: bool,
    outstanding: u64,
    window: u64,

    fn init(leader_last: u64, window: u64) Reference {
        return .{
            .acked = 0,
            .to_send = leader_last + 1,
            .pipelined = false,
            .outstanding = 0,
            .window = window,
        };
    }

    fn may_send(r: Reference) bool {
        if (r.pipelined) return r.outstanding < r.window;
        return r.outstanding == 0;
    }

    fn sent(r: *Reference, last: u64) void {
        r.outstanding += 1;
        if (r.pipelined) r.to_send = last + 1;
    }

    fn accepted(r: *Reference, through: u64) bool {
        if (r.outstanding > 0) r.outstanding -= 1;
        const advanced = through > r.acked;
        if (advanced) r.acked = through;
        if (r.to_send <= r.acked) r.to_send = r.acked + 1;
        r.pipelined = true;
        return advanced;
    }

    /// A probe or heartbeat round expired with no response: forget the window, resend from acked.
    fn timed_out(r: *Reference) void {
        r.pipelined = false;
        r.outstanding = 0;
        r.to_send = r.acked + 1;
    }

    fn rejected(r: *Reference, hint_at: u64, prev: u64) bool {
        if (prev <= r.acked) return false; // The follower already holds more than prev.
        if (prev >= r.to_send) return false; // Every live request had prev <= to_send - 1.
        if (!r.pipelined and prev + 1 != r.to_send) return false; // Not the live request.
        var target = prev; // A shorter log gives no hint: step back to prev itself.
        if (hint_at != 0 and hint_at < prev) target = hint_at;
        if (target <= r.acked) target = r.acked + 1;
        r.to_send = target;
        r.pipelined = false;
        r.outstanding = 0;
        return true;
    }
};

const Request = struct { prev: u64, last: u64 };

/// A follower log that agrees with the leader through `agree` and holds `length` entries in all.
const Follower = struct {
    agree: u64,
    length: u64,
};

fn expect_same(p: *const Progress, r: *const Reference) !void {
    try testing.expectEqual(r.acked, @intFromEnum(p.match));
    try testing.expectEqual(r.to_send, @intFromEnum(p.next));
    try testing.expectEqual(r.pipelined, p.state == .replicate);
    try testing.expectEqual(r.outstanding, @as(u64, p.inflight_count));
    try testing.expectEqual(r.window, @as(u64, p.inflight_max));
    try p.check_invariants();
}

const Tally = struct {
    advanced: u32 = 0,
    rejected_live: u32 = 0,
    rejected_stale: u32 = 0,
    timed_out: u32 = 0,
};

/// One seeded run of `op_count` operations; returns what happened so the caller can check that
/// the stream was not vacuous.
fn run_model(seed: u64, op_count: u32, tally: *Tally) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var leader_last = random.intRangeAtMost(u64, 0, 20);
    const window = random.intRangeAtMost(u32, 1, 5);
    var follower = Follower{ .agree = random.intRangeAtMost(u64, 0, leader_last), .length = 0 };
    follower.length = follower.agree + random.intRangeAtMost(u64, 0, 5);
    var queue: [256]Request = undefined;
    var queued: usize = 0;

    var p = Progress.init(idx(leader_last), window);
    var r = Reference.init(leader_last, window);
    try expect_same(&p, &r);

    for (0..op_count) |_| {
        const roll = random.intRangeLessThan(u32, 0, 100);
        if (roll < 10) {
            leader_last += random.intRangeAtMost(u64, 1, 3);
        } else if (roll < 45) {
            try testing.expectEqual(r.may_send(), p.can_send());
            if (!p.can_send()) continue;
            const prev = r.to_send - 1;
            const last = random.intRangeAtMost(u64, prev, leader_last);
            p.on_send(idx(last));
            r.sent(last);
            queue[queued] = .{ .prev = prev, .last = last };
            queued += 1;
        } else if (roll < 85) {
            if (queued == 0) continue;
            const pick = random.uintLessThan(usize, queued);
            const request = queue[pick];
            if (random.intRangeLessThan(u32, 0, 10) != 0) { // 10%: redelivered later (duplicate).
                queued -= 1;
                queue[pick] = queue[queued];
            }
            if (request.prev <= follower.agree) {
                follower.agree = @max(follower.agree, request.last);
                follower.length = @max(follower.length, request.last);
                const got = p.on_accepted(idx(request.last));
                const want = r.accepted(request.last);
                try testing.expectEqual(want, got);
                tally.advanced += @intFromBool(got);
            } else {
                var at: u64 = if (request.prev > follower.length) 0 else follower.agree + 1;
                if (random.intRangeLessThan(u32, 0, 4) == 0) {
                    at = random.intRangeAtMost(u64, 0, request.prev + 3);
                }
                const got = p.on_rejected(hint(at), idx(request.prev));
                const want = r.rejected(at, request.prev);
                try testing.expectEqual(want, got);
                if (got) tally.rejected_live += 1 else tally.rejected_stale += 1;
            }
        } else if (roll < 93) { // The follower loses its tail (crash with a short disk).
            follower.agree = random.intRangeAtMost(u64, 0, follower.agree);
            follower.length = random.intRangeAtMost(u64, follower.agree, follower.length);
        } else if (roll < 97) { // The follower holds extra entries from a deposed leader.
            follower.length += random.intRangeAtMost(u64, 1, 3);
        } else { // A round expired with every message lost.
            p.on_timeout();
            r.timed_out();
            tally.timed_out += 1;
        }
        if (queued == queue.len) queued = 0; // Bound the in-test queue; lost packets are legal.
        try expect_same(&p, &r);
    }
}

test "progress: 200 seeded runs of 200 random operations match the reference at every step" {
    var tally = Tally{};
    for (0..200) |seed| try run_model(seed, 200, &tally);
    // The streams must exercise all three response paths or the comparison proves little.
    try testing.expect(tally.advanced > 100);
    try testing.expect(tally.rejected_live > 100);
    try testing.expect(tally.rejected_stale > 20);
    try testing.expect(tally.timed_out > 100);
}
