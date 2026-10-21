//! synod.sim.workload_hooks — the glue between `Simulation` and `Workload`, split out of
//! `simulation.zig` (plan 004 item 10): the workload's option validation, the plant-to-fault
//! mapping, and one command event (draw a command, pick a leader, propose, tell the workload
//! how it went).
//!
//! A command that fails in the store after the node may already have logged it (a torn crash
//! armed on the store) is recorded as invoked before the failure is handed back: the entry can
//! survive the crash and commit later, and a history without it would make a read of its value
//! look like a lie. The crash then leaves the operation pending.
//!
//! Allocation: none.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const driver_module = @import("../driver.zig");
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const prng_module = @import("prng.zig");
const sim_node_module = @import("sim_node.zig");
const workload_module = @import("workload.zig");

const Driver = driver_module.Driver;
const Index = types.Index;
const Prng = prng_module.Prng;
const SimNode = sim_node_module.SimNode;
const Workload = workload_module.Workload;

pub const OptionsError = error{WorkloadInvalid};

/// What `Driver.propose` can return.
pub const ProposeFailure = raft.ProposeError || Driver.Fault;

/// How one command event went.
pub const Outcome = union(enum) {
    /// Every client was busy, or no node believes it leads: nothing was proposed.
    idle,
    /// A leader accepted the command: its operation is invoked.
    proposed,
    /// The leader refused it (`ProposeNotLeader`, `ProposeLogFull`): no record.
    rejected,
    /// The node `slot` failed with `err`: the caller decides whether that is a crash.
    failed: struct { slot: u8, err: ProposeFailure },
};

/// Refuses workload settings that could never run, before the simulation allocates.
pub fn validate(
    spec: Workload.Options,
    history_ops_max: u32,
    search_steps_max: u64,
    entry_bytes_max: u32,
) OptionsError!void {
    if (history_ops_max == 0) return error.WorkloadInvalid;

    if (search_steps_max == 0) return error.WorkloadInvalid;

    if (spec.keys_count == 0) return error.WorkloadInvalid;

    if (spec.put_percent > 100) return error.WorkloadInvalid;

    if (spec.clients_count == 0) return;

    if (spec.op_interval_ms_max == 0) return error.WorkloadInvalid;

    if (entry_bytes_max < workload_module.command_bytes) return error.WorkloadInvalid;
}

/// One command event at virtual time `now_ms`, which is event number `event_index`: draws the
/// next command, hands it to a seeded node that believes it leads and reports to `workload`.
/// Precondition: `workload.next_due_ms()` is at most `now_ms`.
pub fn command_event(
    io: Io,
    workload: *Workload,
    nodes: []SimNode,
    prng: *Prng,
    now_ms: u64,
    event_index: u64,
) Outcome {
    var leaders: [8]u8 = undefined;
    assert(nodes.len >= 2);
    assert(nodes.len <= leaders.len);
    assert(event_index > 0);
    const command = workload.next_command(now_ms) orelse return .idle;

    var leaders_count: u8 = 0;
    for (nodes, 0..) |*sim_node, slot| {
        if (sim_node.down) continue;

        if (sim_node.driver.node.status().role != .leader) continue;

        leaders[leaders_count] = @intCast(slot);
        leaders_count += 1;
    }
    if (leaders_count == 0) {
        workload.rejected(&command);
        return .rejected;
    }
    const slot = leaders[@intCast(prng.uint_less_than(leaders_count))];
    const last_index = nodes[slot].driver.node.status().last_index;
    var bytes: [workload_module.command_bytes]u8 = undefined;
    workload_module.encode(&command, &bytes);
    nodes[slot].driver.propose(io, &bytes) catch |err| switch (err) {
        error.ProposeNotLeader, error.ProposeLogFull => {
            workload.rejected(&command);
            return .rejected;
        },
        else => {
            const logged: Index = @enumFromInt(@intFromEnum(last_index) + 1);
            invoke(workload, &command, slot, logged, event_index);
            return .{ .failed = .{ .slot = slot, .err = err } };
        },
    };
    const status = nodes[slot].driver.node.status();
    invoke(workload, &command, slot, status.last_index, event_index);
    return .proposed;
}

fn invoke(
    workload: *Workload,
    command: *const workload_module.Command,
    slot: u8,
    log_index: Index,
    event_index: u64,
) void {
    assert(log_index != Index.zero);
    assert(event_index > 0);
    workload.invoked(command, .{
        .node_index = slot,
        .log_index = log_index,
        .event_index = event_index,
    });
}
