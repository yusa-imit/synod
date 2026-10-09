//! synod.raft.progress — the leader's per-follower replication tracker (thesis §3.5, §10.2.1):
//! how far a follower is known to match, where to send next, and how many `AppendRequest`s are
//! unacknowledged. Internal to `raft`; `Node` owns the map of these, this file owns the rules.
//!
//! Invariants: `match < next` and `next >= 1`; `inflight_count <= inflight_max`; in `.probe`
//! at most one request is in flight. Every mutator keeps them and `check_invariants` states them.
//!
//! No-allocation contract: `Progress` is a plain value of exactly 32 bytes; nothing here takes an
//! allocator, stores a pointer, or grows. Cost sketch: every function is O(1) with no loops.

/// `.probe`: the follower's log position is unknown, send one request at a time.
/// `.replicate`: the position is known, pipeline up to `inflight_max` requests.
pub const State = enum(u8) { probe, replicate };

pub const Progress = struct {
    match: Index,
    next: Index,
    state: State,
    inflight_count: u32,
    inflight_max: u32,

    pub const InvariantError = error{ InvariantProgressOrder, InvariantInflightOverflow };

    /// A fresh tracker for a follower of a leader whose log ends at `leader_last_index`: nothing
    /// is known to match, `next` is the entry after the leader's last, and it starts probing.
    /// Preconditions: `inflight_max >= 1`; `leader_last_index < maxInt(u64)` so `next` exists.
    pub fn init(leader_last_index: Index, inflight_max: u32) Progress {
        assert(inflight_max >= 1);
        assert(@intFromEnum(leader_last_index) < std.math.maxInt(u64));

        const p: Progress = .{
            .match = .zero,
            .next = leader_last_index.next(),
            .state = .probe,
            .inflight_count = 0,
            .inflight_max = inflight_max,
        };
        assert(@intFromEnum(p.next) > @intFromEnum(p.match));
        assert(p.inflight_count == 0);
        return p;
    }

    /// Whether the leader may send another `AppendRequest` now: in `.probe` only when nothing
    /// is in flight, in `.replicate` while fewer than `inflight_max` are. Pure; no precondition
    /// beyond a valid `p`.
    pub fn can_send(p: *const Progress) bool {
        assert(p.inflight_max >= 1);
        assert(p.inflight_count <= p.inflight_max);

        return switch (p.state) {
            .probe => p.inflight_count == 0,
            .replicate => p.inflight_count < p.inflight_max,
        };
    }

    /// Records that a request ending at `last_sent` went out (`last_sent == next - 1` for an
    /// empty heartbeat). Counts it in flight; in `.replicate` moves `next` past `last_sent`
    /// (never lowers it), in `.probe` leaves `next` alone until a response arrives.
    /// Preconditions: `can_send()`; `next - 1 <= last_sent < maxInt(u64)`.
    pub fn on_send(p: *Progress, last_sent: Index) void {
        assert(p.can_send());
        assert(@intFromEnum(last_sent) >= @intFromEnum(p.next) - 1);
        assert(@intFromEnum(last_sent) < std.math.maxInt(u64));

        p.inflight_count += 1;
        switch (p.state) {
            .probe => {},
            .replicate => p.next = last_sent.next(),
        }
        assert(p.inflight_count <= p.inflight_max);
        assert(@intFromEnum(p.next) > @intFromEnum(p.match));
    }

    /// The follower accepted through `matched`. Frees one in-flight slot (saturating, so a
    /// duplicate response cannot underflow), raises `match` to `matched` if higher, keeps
    /// `next > match` without lowering an optimistic `next`, and enters `.replicate`. Returns
    /// whether `match` advanced. Precondition: `matched < maxInt(u64)`.
    ///
    /// The node (plan item 2B-i) must enforce before calling, because `Message.validate` does
    /// not and peer data must never reach the assert: it resolves `prev_log_index` and the last
    /// index sent from its own record of the round, delivers at most one response per round,
    /// and requires `prev_log_index <= matched <= last index of that request` and
    /// `matched < maxInt(u64)`.
    pub fn on_accepted(p: *Progress, matched: Index) bool {
        assert(@intFromEnum(matched) < std.math.maxInt(u64));
        assert(p.inflight_count <= p.inflight_max);

        const match_before = p.match;
        p.inflight_count -|= 1;
        p.match = @enumFromInt(@max(@intFromEnum(p.match), @intFromEnum(matched)));
        p.next = @enumFromInt(@max(@intFromEnum(p.next), @intFromEnum(p.match) + 1));
        p.state = .replicate;

        assert(@intFromEnum(p.next) > @intFromEnum(p.match));
        assert(@intFromEnum(p.match) >= @intFromEnum(match_before));
        return @intFromEnum(p.match) > @intFromEnum(match_before);
    }

    /// Where to resume after a rejection of a request whose `prev_log_index` was `prev_log_index`:
    /// the follower's conflict index clamped to at most `prev_log_index`, or `prev_log_index`
    /// itself when the follower's log was shorter (`conflict.index == .zero`, no hint).
    /// Precondition: `prev_log_index >= 1`. The result is in `[1, prev_log_index]`.
    pub fn backtrack_hint(conflict: Conflict, prev_log_index: Index) Index {
        const prev = @intFromEnum(prev_log_index);
        assert(prev >= 1);

        const at = @intFromEnum(conflict.index);
        const result = if (at == 0) prev else @min(at, prev);
        assert(result >= 1);
        assert(result <= prev);
        return @enumFromInt(result);
    }

    /// The follower rejected a request with `prev_log_index`, carrying `conflict`. A stale
    /// rejection changes nothing and returns false: `prev_log_index <= match` (this includes
    /// zero), `prev_log_index >= next` (every live request had `prev_log_index <= next - 1`),
    /// or in `.probe` not the live request `prev_log_index == next - 1`. Otherwise `next`
    /// becomes `max(match + 1, backtrack_hint)`, the state `.probe`, the window is discarded,
    /// and the result is true. Any `prev_log_index` is accepted, including zero.
    ///
    /// The node (plan item 2B-i) must, before calling: resolve `prev_log_index` from its own
    /// record of the round (never from the peer's message), and deliver at most one response
    /// per round.
    pub fn on_rejected(p: *Progress, conflict: Conflict, prev_log_index: Index) bool {
        const prev = @intFromEnum(prev_log_index);
        assert(@intFromEnum(p.next) >= 1);
        assert(p.inflight_count <= p.inflight_max);

        if (prev <= @intFromEnum(p.match)) return false;
        if (prev >= @intFromEnum(p.next)) return false;
        if (p.state == .probe and prev != @intFromEnum(p.next) - 1) return false;
        assert(prev >= 1); // prev > match >= 0, so backtrack_hint's precondition holds.

        const hint = @intFromEnum(backtrack_hint(conflict, prev_log_index));
        p.next = @enumFromInt(@max(@intFromEnum(p.match) + 1, hint));
        p.state = .probe;
        p.inflight_count = 0;

        assert(@intFromEnum(p.next) > @intFromEnum(p.match));
        assert(p.can_send());
        return true;
    }

    /// A probe or heartbeat round expired with no response. Without this, lost messages would
    /// keep the window full forever. Discards the window and goes back to `.probe` at
    /// `match + 1`, so `can_send()` is true again. Valid in any state, idempotent.
    pub fn on_timeout(p: *Progress) void {
        assert(is_valid(p)); // Caller contract: `p` is a valid tracker.
        assert(p.inflight_count <= p.inflight_max);

        p.state = .probe;
        p.inflight_count = 0;
        p.next = p.match.next();

        assert(is_valid(p)); // match < match + 1 and nothing in flight.
        assert(p.can_send());
    }

    fn is_valid(p: *const Progress) bool {
        assert(p.inflight_max >= 1);
        assert(@intFromEnum(p.match) < std.math.maxInt(u64)); // A valid match has a next above it.

        p.check_invariants() catch return false;
        return true;
    }

    /// Returns the first violated invariant: `InvariantProgressOrder` when `next` is zero or
    /// not above `match`, `InvariantInflightOverflow` when more requests are in flight than the
    /// window (or than one while probing) allows.
    pub fn check_invariants(p: *const Progress) InvariantError!void {
        assert(p.inflight_max >= 1);

        if (p.next == Index.zero) return error.InvariantProgressOrder;
        if (@intFromEnum(p.match) >= @intFromEnum(p.next)) return error.InvariantProgressOrder;
        if (p.inflight_count > p.inflight_max) return error.InvariantInflightOverflow;
        if (p.state == .probe and p.inflight_count > 1) return error.InvariantInflightOverflow;

        assert(@intFromEnum(p.next) > @intFromEnum(p.match)); // Every rule above passed.
        assert(p.state == .replicate or p.inflight_count <= 1);
    }
};

const std = @import("std");
const assert = std.debug.assert;
const types = @import("../types.zig");

const Conflict = types.Conflict;
const Index = types.Index;

comptime {
    assert(@sizeOf(Progress) == 32); // Two u64 indexes, two u32 counters, the state, padding.
}
