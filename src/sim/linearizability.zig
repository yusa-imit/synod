//! synod.sim.linearizability — the history checker of the simulator (ADR-008, "Linearizability";
//! plan 004 item 9): decides whether a client-visible history of `put`/`get` operations on a
//! set of single-value registers (one per key, initially 0) is linearizable.
//!
//! Method: Wing–Gong search, split per key (P-compositionality: registers are independent, so a
//! history is linearizable iff each key's sub-history is). For one key the search extends a
//! linearization one operation at a time. An operation may go next when no still-unplaced
//! completed operation finished before it was invoked and, for a `get`, when its value equals
//! the register. Dead ends backtrack. A pending put (`complete_event == null`) may be placed
//! anywhere after its invoke or never; a pending get is dropped. The search is an explicit
//! stack of `history_ops_max` frames (no recursion) and has no memo cache.
//!
//! Limits: `history.len > history_ops_max` is `HistoryTooLong`, decided before any work. Each
//! placement is one search step; running past `search_steps_max` (summed over all keys of one
//! `check` call) is `CheckInconclusive`, never a pass.
//!
//! Allocation: `init` only (`O(history_ops_max)`: 5 bytes per operation); `check` never
//! allocates and keeps no state between calls.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) { put = 1, get = 2 };

/// One client operation. Events are positions in one total order; `complete_event == null`
/// means the operation never returned (pending).
pub const Operation = struct {
    client_index: u16,
    kind: Kind,
    key: u16,
    value: u64, // put: written; get: returned; 0 = never written
    invoke_event: u64,
    complete_event: ?u64,
};

pub const CheckError = error{ Linearizability, CheckInconclusive, HistoryTooLong };

/// Largest history whose "one outstanding operation per client" rule is asserted (the check
/// is quadratic, so it is skipped beyond this bound).
const client_check_ops_max: u32 = 256;

/// The search state of one operation of the history being checked.
const Mark = enum(u8) {
    open, // not placed in the current linearization
    taken, // placed in the current linearization
    settled, // its key is decided
};

pub const HistoryChecker = struct {
    pub const Options = struct { history_ops_max: u32, keys_max: u16, search_steps_max: u64 };

    options: Options,
    /// The search stack: `frames[d]` is the history index placed at depth `d`.
    frames: []u32,
    /// One mark per history index.
    marks: []Mark,

    /// Allocates the search stack and marks, `O(history_ops_max)`.
    /// Precondition: `options.history_ops_max > 0` and `options.keys_max > 0`.
    pub fn init(checker: *HistoryChecker, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.history_ops_max > 0);
        assert(options.keys_max > 0);
        const frames = try gpa.alloc(u32, options.history_ops_max);
        errdefer gpa.free(frames);

        const marks = try gpa.alloc(Mark, options.history_ops_max);
        checker.* = .{ .options = options, .frames = frames, .marks = marks };
    }

    /// Frees what `init` allocated with the same `gpa`; `checker` is invalid afterwards.
    pub fn deinit(checker: *HistoryChecker, gpa: Allocator) void {
        assert(checker.frames.len == checker.options.history_ops_max);
        assert(checker.marks.len == checker.options.history_ops_max);
        gpa.free(checker.marks);
        gpa.free(checker.frames);
        checker.* = undefined;
    }

    /// Decides `history`. Never allocates; the checker may be reused for any later history.
    /// Precondition (asserted): every key is `< options.keys_max`, every completed operation
    /// completes after it was invoked (invoke and complete are distinct, strictly increasing
    /// event numbers), and a client has at most one outstanding operation; a pending operation
    /// stays outstanding, so a workload retires a client index when its operation goes pending
    /// and a put never writes 0 (the initial register). Out-of-range keys from decoded log
    /// entries are the workload's typed error, never passed here.
    /// Returns `HistoryTooLong` before any work if `history.len > history_ops_max`,
    /// `Linearizability` if some key has no valid linearization, `CheckInconclusive` if the
    /// search ran out of `search_steps_max` steps (summed over keys).
    pub fn check(checker: *HistoryChecker, history: []const Operation) CheckError!void {
        assert(checker.frames.len == checker.options.history_ops_max);
        assert(checker.marks.len == checker.options.history_ops_max);
        if (history.len > checker.options.history_ops_max) return error.HistoryTooLong;

        assert_well_formed(checker.options, history);
        @memset(checker.marks[0..history.len], .open);
        var steps: u64 = 0;
        for (history, 0..) |op, index| {
            if (checker.marks[index] == .settled) continue;

            try checker.search_key(history, op.key, &steps);
        }
        assert(steps <= checker.options.search_steps_max);
        for (checker.marks[0..history.len]) |mark| assert(mark == .settled);
    }

    /// Searches a linearization of the operations of `key`, adding its placements to `steps`,
    /// and marks every operation of `key` settled on success.
    fn search_key(
        checker: *HistoryChecker,
        history: []const Operation,
        key: u16,
        steps: *u64,
    ) CheckError!void {
        const steps_max = checker.options.search_steps_max;
        assert(key < checker.options.keys_max);
        assert(steps.* <= steps_max);
        const marks = checker.marks[0..history.len];
        var remaining = completed_count(history, key); // Completed ops still to place.
        var depth: u32 = 0;
        var from: u32 = 0; // Next candidate to try at this depth, as a history index.
        // Each iteration places (at most `steps_max - steps` times) or unplaces (at most as
        // often as placed) one operation, or ends the search: the bound is never reached.
        const iterations_max = (steps_max - steps.*) *| 2 +| 2;
        var iteration: u64 = 0;
        while (iteration < iterations_max) : (iteration += 1) {
            if (remaining == 0) break;

            const register = register_after(history, checker.frames[0..depth]);
            if (next_candidate(history, marks, key, from, register)) |index| {
                steps.* += 1;
                if (steps.* > steps_max) return error.CheckInconclusive;

                marks[index] = .taken;
                checker.frames[depth] = index;
                depth += 1;
                from = 0;
                if (history[index].complete_event != null) remaining -= 1;
            } else {
                if (depth == 0) return error.Linearizability;

                depth -= 1;
                const index = checker.frames[depth];
                marks[index] = .open;
                from = index + 1;
                if (history[index].complete_event != null) remaining += 1;
            }
        } else unreachable; // Proved by the iteration bound above.
        for (history, marks) |op, *mark| {
            if (op.key == key) mark.* = .settled;
        }
        assert(remaining == 0);
    }
};

/// The number of completed operations of `key`.
fn completed_count(history: []const Operation, key: u16) u32 {
    assert(history.len <= std.math.maxInt(u32));
    var count: u32 = 0;
    for (history) |op| {
        if (op.key == key and op.complete_event != null) count += 1;
    }
    assert(count <= history.len);
    return count;
}

/// The register after placing `placed` (history indices, in order): the last put's value, or
/// 0 if none was placed.
fn register_after(history: []const Operation, placed: []const u32) u64 {
    assert(placed.len <= history.len);
    var depth = placed.len;
    while (depth > 0) {
        depth -= 1;
        const op = history[placed[depth]];
        if (op.kind == .put) return op.value;
    }
    return 0;
}

/// The first history index `>= from` that may be placed next for `key`, or null. An open
/// operation may go next when no open completed operation of the key finished before it was
/// invoked; a get must also return `register`; a pending get never goes (it is dropped).
fn next_candidate(
    history: []const Operation,
    marks: []const Mark,
    key: u16,
    from: u32,
    register: u64,
) ?u32 {
    assert(history.len == marks.len);
    assert(from <= history.len);
    var cutoff: u64 = std.math.maxInt(u64);
    for (history, marks) |op, mark| {
        if (op.key != key or mark != .open) continue;

        if (op.complete_event) |end| cutoff = @min(cutoff, end);
    }
    var index: u32 = from;
    while (index < history.len) : (index += 1) {
        const op = history[index];
        if (op.key != key or marks[index] != .open) continue;

        if (op.invoke_event > cutoff) continue;

        switch (op.kind) {
            .put => {
                if (op.complete_event != null) return index;
                if (pending_put_useful(history, marks, key, op.value, register)) return index;
            },
            .get => if (op.complete_event != null and op.value == register) return index,
        }
    }
    return null;
}

/// Whether placing a pending put of `value` can matter: it must change the register, and some
/// open completed get of `key` must return `value`. Otherwise leaving it out is equivalent
/// (a pending operation need not take effect), so the search skips it instead of trying every
/// position of every pending put, which would be factorial in the number of pending puts.
fn pending_put_useful(
    history: []const Operation,
    marks: []const Mark,
    key: u16,
    value: u64,
    register: u64,
) bool {
    assert(history.len == marks.len);
    if (value == register) return false;

    for (history, marks) |op, mark| {
        if (op.key != key or mark != .open or op.kind != .get) continue;

        if (op.complete_event != null and op.value == value) return true;
    }
    return false;
}

/// Asserts the caller contract: keys in range, completes after invokes, and (for histories of
/// at most `client_check_ops_max` operations) no client with two outstanding operations.
fn assert_well_formed(options: HistoryChecker.Options, history: []const Operation) void {
    assert(history.len <= options.history_ops_max);
    for (history) |op| {
        assert(op.key < options.keys_max);
        if (op.complete_event) |end| assert(end > op.invoke_event);
    }
    if (history.len > client_check_ops_max) return;

    for (history, 0..) |a, index| {
        for (history[index + 1 ..]) |b| {
            if (a.client_index != b.client_index) continue;

            const a_first = if (a.complete_event) |end| end < b.invoke_event else false;
            const b_first = if (b.complete_event) |end| end < a.invoke_event else false;
            assert(a_first or b_first);
        }
    }
}
