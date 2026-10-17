//! synod.sim.sim_node — one simulated node's world, split out of `simulation.zig` (plan 004
//! item 5): its crash-losing store, the recording state machine, its PRNG stream, the fixed
//! memory its `Driver` allocates from, and the crash bookkeeping (`down`, `torn_pending`,
//! `restart_at_ms`). Allocation: `Simulation.node_build` only; nothing here allocates.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const driver_module = @import("../driver.zig");
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
const crash_store_module = @import("crash_store.zig");
const invariants = @import("invariants.zig");
const prng_module = @import("prng.zig");

const CrashStore = crash_store_module.CrashStore;
const Driver = driver_module.Driver;
const Entry = types.Entry;
const Index = types.Index;
const Prng = prng_module.Prng;

/// One applied entry as the recorder saw it.
pub const Applied = struct { index: Index, entry_fingerprint: u64 };

/// The simulation's `StateMachine`: it records `(index, fingerprint)` of every applied entry,
/// to be drained into the `Checker` after the event. Fixed capacity, never grows.
pub const Recorder = struct {
    records: []Applied,
    len: u32,

    pub fn apply(recorder: *Recorder, entry: *const Entry) interfaces.StateMachine.ApplyError!void {
        assert(recorder.len <= recorder.records.len);
        assert(entry.index != Index.zero);
        if (recorder.len == recorder.records.len) return error.StateMachineFailed;
        recorder.records[recorder.len] = .{
            .index = entry.index,
            .entry_fingerprint = invariants.fingerprint(entry),
        };
        recorder.len += 1;
    }

    /// Phase 3 takes no snapshots (ADR-008); a call is a harness fault.
    pub fn snapshot(
        recorder: *Recorder,
        writer: *Io.Writer,
    ) interfaces.StateMachine.SnapshotError!void {
        assert(recorder.len <= recorder.records.len);
        assert(writer.end <= writer.buffer.len);
        return error.StateMachineFailed;
    }

    /// Phase 3 restores no snapshots (ADR-008); a call is a harness fault.
    pub fn restore(
        recorder: *Recorder,
        reader: *Io.Reader,
    ) interfaces.StateMachine.RestoreError!void {
        assert(recorder.len <= recorder.records.len);
        assert(reader.seek <= reader.end);
        return error.StateMachineFailed;
    }
};

/// One node's world: its store, recorder, PRNG, memory and driver.
pub const SimNode = struct {
    store: CrashStore,
    recorder: Recorder,
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
        assert(sim_node.recorder.records.len > 0);
        if (!sim_node.down) sim_node.driver.deinit(io, sim_node.fba.allocator());
        gpa.free(sim_node.recorder.records);
        sim_node.store.deinit(gpa);
        gpa.free(sim_node.buffer);
        sim_node.* = undefined;
    }
};
