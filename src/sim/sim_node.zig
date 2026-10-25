//! synod.sim.sim_node — one simulated node's world, split out of `simulation.zig` (plan 004
//! item 5): its crash-losing store, the KV state machine (plan 004 item 10), its PRNG stream,
//! the fixed memory its `Driver` allocates from, and the crash bookkeeping (`down`,
//! `torn_pending`, `restart_at_ms`). Allocation: `Simulation.node_build` only; nothing here
//! allocates.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const driver_module = @import("../driver.zig");
const crash_store_module = @import("crash_store.zig");
const prng_module = @import("prng.zig");
const workload_module = @import("workload.zig");

const CrashStore = crash_store_module.CrashStore;
const Driver = driver_module.Driver;
const KvStateMachine = workload_module.KvStateMachine;
const Prng = prng_module.Prng;

/// One node's world: its store, state machine, PRNG, memory and driver.
pub const SimNode = struct {
    store: CrashStore,
    /// The node's state machine; its drained records feed the `Checker` and the `Workload`.
    kv: KvStateMachine,
    prng: Prng,
    buffer: []align(16) u8,
    fba: std.heap.FixedBufferAllocator,
    driver: Driver,
    /// Crashed: `driver` is deinitialised and must not be touched.
    down: bool,
    /// A torn crash is armed on the store; the node goes down when the failure fires.
    torn_pending: bool,
    /// When a seeded crash restarts the node; null for a scripted crash or an up node.
    restart_at_ms: ?u64,

    pub fn deinit(sim_node: *SimNode, io: Io, gpa: Allocator) void {
        assert(sim_node.buffer.len > 0);
        assert(sim_node.kv.records.len > 0);
        if (!sim_node.down) sim_node.driver.deinit(io, sim_node.fba.allocator());
        sim_node.kv.deinit(gpa);
        sim_node.store.deinit(gpa);
        gpa.free(sim_node.buffer);
        sim_node.* = undefined;
    }
};
