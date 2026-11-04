//! TEMP.
const std = @import("std");
const testing = std.testing;
const simulation_module = @import("simulation.zig");
const workload_module = @import("workload.zig");

test "TEMP seed 12" {
    var opts = simulation_module.Options.sweep(12);
    opts.workload = .{
        .clients_count = 3,
        .keys_count = 4,
        .put_percent = 50,
        .op_interval_ms_max = 30,
        .fault = .none,
    };
    opts.history_ops_max = 256;
    opts.faults = .{
        .fault_interval_ms_max = 200,
        .crash_percent = 25,
        .torn_percent = 30,
        .down_ms_max = 300,
        .partition_percent = 30,
        .partition_ms_max = 800,
    };
    opts.raft.log_entries_max = 64;
    opts.raft.log_bytes_max = 64 * opts.raft.message_limits.entry_bytes_max;
    opts.raft.snapshot_entries_min = 16;
    opts.raft.snapshot_trailing = 4;
    opts.raft.message_limits.snapshot_bytes_max = workload_module.KvStateMachine.snapshot_bytes(4);
    var report: simulation_module.Report = undefined;
    _ = simulation_module.run_seed(testing.io, testing.allocator, &opts, 5_000, &report) catch {
        std.debug.print("TEMP seed12 violation={s} event={d} nodes={d}\n", .{ @errorName(report.violation), report.event_index, opts.nodes_count });
        return error.TestUnexpectedResult;
    };
}
