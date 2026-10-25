//! Test support for the `sim/workload*_test.zig` files (plan 004 item 10): command and entry
//! builders, the one construction path for a `KvStateMachine` (`KvRig`) and a `Workload`
//! (`WorkloadRig`), and a few shape helpers. Nothing here is public API.
//!
//! Allocation: only through the `gpa` the caller passes (`std.testing.allocator`), so a leak
//! fails the calling test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const prng_module = @import("prng.zig");
const workload_module = @import("workload.zig");

pub const Applied = workload_module.KvStateMachine.Applied;
pub const Command = workload_module.Command;
pub const Entry = types.Entry;
pub const Index = types.Index;
pub const Invocation = workload_module.Invocation;
pub const KvStateMachine = workload_module.KvStateMachine;
pub const Operation = workload_module.Operation;
pub const Prng = prng_module.Prng;
pub const Workload = workload_module.Workload;
pub const command_bytes = workload_module.command_bytes;

pub fn put(client: u16, key: u16, value: u64, op_id: u32) Command {
    return .{ .kind = .put, .client_index = client, .key = key, .value = value, .op_id = op_id };
}

pub fn get(client: u16, key: u16, op_id: u32) Command {
    return .{ .kind = .get, .client_index = client, .key = key, .value = 0, .op_id = op_id };
}

/// A normal log entry at `index` (term 1) whose data is `command` encoded into `storage`.
pub fn entry_of(index: u64, command: *const Command, storage: *[command_bytes]u8) Entry {
    workload_module.encode(command, storage);
    return .{
        .index = @enumFromInt(index),
        .term = @enumFromInt(1),
        .kind = .normal,
        .data = storage,
    };
}

/// A log entry of any kind and bytes.
pub fn raw_entry(index: u64, kind: types.EntryKind, data: []const u8) Entry {
    return .{ .index = @enumFromInt(index), .term = @enumFromInt(1), .kind = kind, .data = data };
}

/// The `Applied` a node would hand `Workload.applied` for `command` at `index`.
pub fn record_of(index: u64, command: ?Command, result: u64) Applied {
    return .{
        .index = @enumFromInt(index),
        .entry_fingerprint = index * 31 + 7,
        .command = command,
        .result = result,
    };
}

pub fn invocation(node: u8, index: u64, event: u64) Invocation {
    return .{ .node_index = node, .log_index = @enumFromInt(index), .event_index = event };
}

/// A `KvStateMachine` in place.
pub const KvRig = struct {
    kv: KvStateMachine,

    pub fn init(rig: *KvRig, gpa: Allocator, keys_count: u16, applied_max: u32) !void {
        try rig.kv.init(gpa, .{ .keys_count = keys_count, .applied_max = applied_max });
    }

    pub fn deinit(rig: *KvRig, gpa: Allocator) void {
        rig.kv.deinit(gpa);
    }

    /// Applies `command` as the entry at `index` and returns the one record it produced.
    pub fn apply_command(rig: *KvRig, index: u64, command: Command) !Applied {
        var storage: [command_bytes]u8 = undefined;
        const entry = entry_of(index, &command, &storage);
        try rig.kv.apply(&entry);
        const records = rig.kv.drain();
        if (records.len != 1) return error.TestUnexpectedResult;
        return records[0];
    }
};

pub const options_default: Workload.Options = .{
    .clients_count = 3,
    .keys_count = 4,
    .put_percent = 50,
    .op_interval_ms_max = 20,
    .fault = .none,
};

/// A `Workload` in place.
pub const WorkloadRig = struct {
    workload: Workload,

    pub fn init(
        rig: *WorkloadRig,
        gpa: Allocator,
        options: Workload.Options,
        history_ops_max: u32,
        seed: u64,
    ) !void {
        try rig.workload.init(gpa, options, history_ops_max, Prng.init(seed));
    }

    pub fn deinit(rig: *WorkloadRig, gpa: Allocator) void {
        rig.workload.deinit(gpa);
    }

    /// Waits for the next due time and draws the command due there; null when every client is
    /// busy. Fails when no command can ever be due.
    pub fn draw(rig: *WorkloadRig) !?Command {
        const due_ms = rig.workload.next_due_ms() orelse return error.TestUnexpectedResult;
        return rig.workload.next_command(due_ms);
    }

    /// `draw`, but a null draw is a failure of the test.
    pub fn draw_some(rig: *WorkloadRig) !Command {
        return (try rig.draw()) orelse error.TestUnexpectedResult;
    }
};

/// Whether `ops` contain two operations of one client where an earlier one never completed
/// (the shape `HistoryChecker` asserts against).
pub fn client_reused_after_pending(ops: []const Operation) bool {
    for (ops, 0..) |earlier, at| {
        if (earlier.complete_event != null) continue;
        for (ops[at + 1 ..]) |later| {
            if (later.client_index == earlier.client_index) return true;
        }
    }
    return false;
}

/// The workload's counters are exactly `invoked`, `completed`, `pending`.
pub fn expect_stats(
    workload: *const Workload,
    invoked: u32,
    completed: u32,
    pending: u32,
) !void {
    const want: Workload.Stats = .{
        .ops_invoked = invoked,
        .ops_completed = completed,
        .ops_pending = pending,
    };
    try std.testing.expectEqual(want, workload.stats());
}
