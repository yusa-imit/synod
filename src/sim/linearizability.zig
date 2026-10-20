//! synod.sim.linearizability — the history checker of the simulator (ADR-008, "Linearizability";
//! plan 004 item 9): decides whether a client-visible history of `put`/`get` operations on a
//! set of single-value registers (one per key, initially 0) is linearizable.
//!
//! RED STAGE SKELETON: types and signatures only. `check` is a stub that accepts every
//! history, so the tests in `linearizability_test.zig` fail until the search lands.
//!
//! Allocation: `init` only (`O(history_ops_max)`); `check` never allocates.

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

pub const HistoryChecker = struct {
    pub const Options = struct { history_ops_max: u32, keys_max: u16, search_steps_max: u64 };

    options: Options,
    frames: []u32,

    pub fn init(checker: *HistoryChecker, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.history_ops_max > 0);
        assert(options.keys_max > 0);
        const frames = try gpa.alloc(u32, options.history_ops_max);
        checker.* = .{ .options = options, .frames = frames };
    }

    pub fn deinit(checker: *HistoryChecker, gpa: Allocator) void {
        gpa.free(checker.frames);
        checker.* = undefined;
    }

    pub fn check(checker: *HistoryChecker, history: []const Operation) CheckError!void {
        if (history.len > checker.options.history_ops_max) return error.HistoryTooLong;
        var key: u32 = 0;
        while (key < 65535) : (key += 1) {
            var any = false;
            for (history) |op| if (op.key == key) {
                any = true;
            };
            if (!any) continue;
            if (!key_ok(history, @intCast(key))) return error.Linearizability;
        }
    }

    fn key_ok(history: []const Operation, key: u16) bool {
        var done: [16]Operation = undefined;
        var dl: usize = 0;
        var pend: [16]Operation = undefined;
        var pl: usize = 0;
        for (history) |op| {
            if (op.key != key) continue;
            if (op.complete_event != null) {
                done[dl] = op;
                dl += 1;
            } else if (op.kind == .put) {
                pend[pl] = op;
                pl += 1;
            }
        }
        var mask: usize = 0;
        while (mask < (@as(usize, 1) << @intCast(pl))) : (mask += 1) {
            var order: [16]Operation = undefined;
            @memcpy(order[0..dl], done[0..dl]);
            var n = dl;
            for (0..pl) |b| {
                if ((mask >> @intCast(b)) & 1 == 0) continue;
                order[n] = pend[b];
                n += 1;
            }
            if (perm(order[0..n], 0)) return true;
        }
        return false;
    }

    fn perm(order: []Operation, d: usize) bool {
        if (d == order.len) return valid(order);
        for (d..order.len) |i| {
            std.mem.swap(Operation, &order[d], &order[i]);
            const f = perm(order, d + 1);
            std.mem.swap(Operation, &order[d], &order[i]);
            if (f) return true;
        }
        return false;
    }

    fn valid(order: []const Operation) bool {
        for (order, 0..) |a, i| for (order[i + 1 ..]) |b| {
            if (b.complete_event) |e| if (e < a.invoke_event) return false;
        };
        var reg: u64 = 0;
        for (order) |op| switch (op.kind) {
            .put => reg = op.value,
            .get => if (op.value != reg) return false,
        };
        return true;
    }
};
