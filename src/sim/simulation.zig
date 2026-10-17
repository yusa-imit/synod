//! synod.sim.simulation — the deterministic event loop (ADR-008, "Simulation"; plan 004 item
//! 4): N `Driver`s over `MemoryStore`s, a `Network` as their `Transport`, one `VirtualClock`,
//! and a recording `StateMachine`, advanced one event per `step` with every invariant checked
//! after each event.
//!
//! Events: a delivery (the network's least `(at_ms, seq)` message, handed to its target's
//! `Driver.receive`) or a tick (every node's `Driver.poll` at the next multiple of `tick_ms`).
//! The next event is the earliest by time; at equal times a delivery precedes the tick (the
//! fixed order `deliver < tick`). Scripted proposals (`propose`) and partition changes through
//! `network` happen between events and are not events.
//!
//! Invariants: after every event each node's `check_invariants()`, the network's, and the
//! `Checker` (observations of all nodes, then the drained applied records) all hold. The first
//! failure is latched: it fills the `Report`, and a later `step` asserts. `EventsExhausted`
//! is latched too, but stepping again just returns it again.
//!
//! Allocation: `init` only. Per node: a `MemoryStore`, a recorder of `log_entries_max`
//! applied records and one buffer of `Driver.init_bytes_max(&config)` bytes backing a
//! `FixedBufferAllocator` that `Driver.init` uses; plus the `Network` and the `Checker`.
//! `step`, `run_until`, `propose` and every query allocate nothing. The simulation stores
//! neither `gpa` nor `io`; both are passed to each call that needs them.
//!
//! Determinism: one root `Options.seed`; the network and node `i` draw from their own
//! `prng.derive_seed` streams, so a seed replays bit for bit and a node's timer draws do not
//! depend on `nodes_count`. Scheduling draws nothing.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const driver_module = @import("../driver.zig");
const interfaces = @import("../interfaces.zig");
const raft = @import("../raft.zig");
const types = @import("../types.zig");
const clock_module = @import("clock.zig");
const crash_store_module = @import("crash_store.zig");
const invariants = @import("invariants.zig");
const network_module = @import("network.zig");
const prng_module = @import("prng.zig");
const sim_node_module = @import("sim_node.zig");

const Checker = invariants.Checker;
const CrashStore = crash_store_module.CrashStore;
const Driver = driver_module.Driver;
const Network = network_module.Network;
const NodeId = types.NodeId;
const Prng = prng_module.Prng;
const Recorder = sim_node_module.Recorder;
const Applied = sim_node_module.Applied;
const SimNode = sim_node_module.SimNode;
const VirtualClock = clock_module.VirtualClock;

/// The most nodes a simulation has; equal to the network's matrix size.
pub const nodes_max: u8 = 7;

/// Ticks one `Driver.poll` may run; a tick event polls every `tick_ms`, so one is enough.
const ticks_per_poll_max: u32 = 2;

/// Unsynced ops a node's `CrashStore` journal holds; a step makes at most three.
const journal_ops_max: u32 = 8;

/// A torn crash's armed failure fires on one of the next `[0, torn_calls_until_max)` calls.
const torn_calls_until_max: u64 = 2;

comptime {
    assert(nodes_max <= types.voters_max);
}

/// A fault the harness plants to prove the checkers bite. Item 5 adds
/// `lose_synced_hard_state`, item 10 `ack_uncommitted` (additive variants).
pub const Plant = enum(u8) {
    none = 1,
    forge_votes = 2,
    flip_data = 3,
    lose_synced_hard_state = 4,
};

/// Seeded fault draws (ADR-008 `Faults`, the crash subset of item 5; item 6 adds the partition
/// fields). Every `quiet` preset has all four at zero: no fault event ever fires.
pub const Faults = struct {
    /// A fault draw happens every `[1, fault_interval_ms_max]` ms; 0 disables fault draws.
    fault_interval_ms_max: u32,
    /// Percent of fault draws that crash a seeded up node (the rest do nothing yet).
    crash_percent: u8,
    /// Percent of crashes that are torn (`arm_failure` on the node's store).
    torn_percent: u8,
    /// A crashed node restarts `[1, down_ms_max]` ms later.
    down_ms_max: u32,

    pub const none: Faults = .{
        .fault_interval_ms_max = 0,
        .crash_percent = 0,
        .torn_percent = 0,
        .down_ms_max = 0,
    };
};

/// Item 4 carries only what it implements; items 5 and 10 add `faults`, `workload`,
/// `history_ops_max` and `search_steps_max`, set by `quiet` and `sweep` (additive fields).
pub const Options = struct {
    seed: u64,
    nodes_count: u8,
    /// The tick period: ticks fire at `tick_ms`, `2 * tick_ms`, ... of virtual time.
    tick_ms: u32,
    /// `id == .none` (asserted); node slot `i` gets id `i + 1`.
    raft: raft.Config,
    network: Network.Model,
    faults: Faults,
    /// Events a simulation may run before `EventsExhausted`.
    events_max: u64,
    /// Terms the checker tracks before `TermsExhausted`.
    terms_max: u32,
    plant: Plant,

    /// A healthy, lossless, fault-free cluster of `nodes_count` nodes: delays 1..10 ms,
    /// 10 ms ticks, election timeout 100..200 ms, heartbeat 30 ms, 64-entry logs of at most
    /// 8 data bytes per entry, 4 entries per message.
    pub fn quiet(seed: u64, nodes_count: u8) Options {
        assert(nodes_count >= 2);
        assert(nodes_count <= nodes_max);
        return .{
            .seed = seed,
            .nodes_count = nodes_count,
            .tick_ms = 10,
            .raft = .{
                .id = .none,
                .protocol_version = types.protocol_version_current,
                .election_ticks = 10,
                .heartbeat_ticks = 3,
                .voters_max = nodes_count,
                .learners_max = 0,
                .inflight_max = 4,
                .log_entries_max = 64,
                .log_bytes_max = 64 * 8,
                .message_limits = .{
                    .entries_max = 4,
                    .entry_bytes_max = 8,
                    .snapshot_bytes_max = 0,
                },
            },
            .network = .{
                .messages_max = 64,
                .delay_ms_min = 1,
                .delay_ms_max = 10,
                .loss_percent = 0,
                .duplicate_percent = 0,
            },
            .faults = Faults.none,
            .events_max = 200_000,
            .terms_max = 256,
            .plant = .none,
        };
    }

    /// 3 nodes (even seed) or 5 (odd seed), a lossy, duplicating, slower network.
    pub fn sweep(seed: u64) Options {
        var options = quiet(seed, if (seed % 2 == 0) 3 else 5);
        options.network.delay_ms_max = 15;
        options.network.loss_percent = 5;
        options.network.duplicate_percent = 5;
        assert(options.network.delay_ms_max >= options.network.delay_ms_min);
        assert(options.network.loss_percent <= 100);
        return options;
    }
};

/// What a run did; two runs of one seed agree on every field, `digest` included.
pub const Stats = struct {
    events: u64,
    leader_terms: u32,
    committed_max: u64,
    applied: u64,
    crashes: u32,
    torn_crashes: u32,
    restarts: u32,
    network: Network.Stats,
    /// A hash of the network trace, the event count, the clock, every applied entry's
    /// fingerprint in apply order, and every node's final status (amends ADR-008: the log
    /// itself is covered through those, so `stats()` stays O(nodes)).
    digest: u64,
};

/// Limits of the harness itself; not safety violations.
pub const LimitError = error{ EventsExhausted, TermsExhausted };

/// Everything a node, its store or its state machine can report through a `Driver`.
pub const NodeError = raft.InvariantError || raft.InitError || raft.ReceiveError ||
    raft.ProposeError || Network.InvariantError || interfaces.LogStore.WriteError ||
    interfaces.LogStore.ReadError || interfaces.StateMachine.ApplyError ||
    CrashStore.InvariantError;

pub const Error = invariants.Violation || LimitError || NodeError;

/// Where a run stopped; `seed` alone replays it.
pub const Report = struct { seed: u64, event_index: u64, violation: Error };

/// What the next event is and when it happens. At equal times the order is the declaration
/// order: `deliver < tick < restart < fault`. `slot` is the node of a `restart`.
const Event = struct {
    kind: enum(u8) { deliver, tick, restart, fault },
    time_ms: u64,
    slot: u8,
};

pub const Simulation = struct {
    /// Public for scripted partitions (PRD §4.5).
    network: Network,
    /// Read-only from outside.
    virtual_clock: VirtualClock,
    options: Options,
    checker: Checker,
    nodes: [nodes_max]SimNode,
    /// Virtual time of the next tick event.
    tick_next_ms: u64,
    events: u64,
    applied_total: u64,
    applied_digest: u64,
    failed: ?Error,
    /// The seeded fault stream (`derive_seed(.faults)`), drawn only by fault events.
    faults_prng: Prng,
    /// Virtual time of the next fault draw; `maxInt(u64)` when faults are off.
    fault_next_ms: u64,
    crashes: u32,
    torn_crashes: u32,
    restarts: u32,

    /// In place: the simulation must not move afterwards. Builds the cluster from `options`
    /// (ADR-008 argument order: `io` then `gpa`). On error nothing is left allocated.
    pub fn init(
        simulation: *Simulation,
        io: Io,
        gpa: Allocator,
        options: *const Options,
    ) Error!void {
        assert(options.raft.id == .none);
        assert(options.nodes_count >= 2);
        assert(options.nodes_count <= nodes_max);
        assert(options.tick_ms > 0);
        assert(options.events_max < std.math.maxInt(u64));

        simulation.options = options.*;
        simulation.virtual_clock = VirtualClock.init(0);
        simulation.tick_next_ms = options.tick_ms;
        simulation.events = 0;
        simulation.applied_total = 0;
        simulation.applied_digest = 0;
        simulation.failed = null;
        simulation.crashes = 0;
        simulation.torn_crashes = 0;
        simulation.restarts = 0;
        simulation.faults_prng = Prng.init(prng_module.derive_seed(options.seed, .faults, 0));
        simulation.fault_next_ms = std.math.maxInt(u64);
        if (options.faults.fault_interval_ms_max > 0) {
            assert(options.faults.down_ms_max > 0);
            const interval_ms_max: u64 = options.faults.fault_interval_ms_max;
            simulation.fault_next_ms = 1 + simulation.faults_prng.uint_less_than(interval_ms_max);
        }

        const network_options: Network.Options = .{
            .nodes_count = options.nodes_count,
            .message_limits = options.raft.message_limits,
            .model = options.network,
            .fault = fault_of(options.plant),
        };
        const network_prng = Prng.init(prng_module.derive_seed(options.seed, .network, 0));
        try simulation.network.init(gpa, &network_options, &simulation.virtual_clock, network_prng);
        errdefer simulation.network.deinit(gpa);

        try simulation.checker.init(gpa, .{
            .nodes_count = options.nodes_count,
            .log_entries_max = options.raft.log_entries_max,
            .terms_max = options.terms_max,
        });
        errdefer simulation.checker.deinit(gpa);

        var built: u8 = 0;
        errdefer for (simulation.nodes[0..built]) |*sim_node| sim_node.deinit(io, gpa);

        for (0..options.nodes_count) |slot| {
            try simulation.node_build(io, gpa, @intCast(slot));
            built += 1;
        }
        assert(built == options.nodes_count);
        assert(simulation.events == 0);
    }

    /// Frees everything `init` allocated, with the same `gpa`.
    pub fn deinit(simulation: *Simulation, io: Io, gpa: Allocator) void {
        assert(simulation.options.nodes_count >= 2);
        assert(simulation.options.nodes_count <= nodes_max);
        const nodes = simulation.nodes[0..simulation.options.nodes_count];
        for (nodes) |*sim_node| sim_node.deinit(io, gpa);
        simulation.checker.deinit(gpa);
        simulation.network.deinit(gpa);
        simulation.* = undefined;
    }

    /// Runs the one event with the least `(time_ms, kind)`, then checks every node's
    /// `check_invariants()`, the network's, and the `Checker`. At `events_max` events
    /// already run it returns `EventsExhausted` without running one. Precondition: no earlier
    /// step latched a violation.
    pub fn step(simulation: *Simulation, io: Io) Error!void {
        assert(simulation.events <= simulation.options.events_max);
        simulation.failed_allowed();
        if (simulation.events == simulation.options.events_max) {
            return simulation.latch(error.EventsExhausted);
        }

        try simulation.event_step(io, simulation.event_next());
    }

    /// Steps while the next event is due at or before `time_ms`, then advances the clock to
    /// `time_ms`. Reaching `events_max` before that is `EventsExhausted`.
    /// Precondition: `time_ms` is not before `virtual_clock.time_ms`.
    pub fn run_until(simulation: *Simulation, io: Io, time_ms: u64) Error!void {
        assert(time_ms >= simulation.virtual_clock.time_ms);
        simulation.failed_allowed();
        if (simulation.failed) |failure| return failure; // Only `EventsExhausted`, latched.
        // Each pass runs one event or returns, and `step` refuses past `events_max`.
        for (0..simulation.options.events_max + 1) |_| {
            const event = simulation.event_next();
            if (event.time_ms > time_ms) {
                simulation.virtual_clock.advance_to(time_ms);
                return;
            }
            if (simulation.events == simulation.options.events_max) {
                return simulation.latch(error.EventsExhausted);
            }
            try simulation.event_step(io, event);
        }
        unreachable; // Proof: `events` grows per pass and the pass fails at `events_max`.
    }

    /// A scripted proposal to node `node_index` (ADR-008 amendment: item 10's workload makes
    /// proposals itself). Not an event: `stats().events` is unchanged. Runs the same checks as
    /// `step`. `ProposeNotLeader`, `ProposeTooLarge` and `ProposeLogFull` are returned, mutate
    /// nothing and latch nothing.
    pub fn propose(
        simulation: *Simulation,
        io: Io,
        node_index: u8,
        data: []const u8,
    ) Error!void {
        assert(node_index < simulation.options.nodes_count);
        assert(!simulation.nodes[node_index].down);
        simulation.failed_allowed();
        simulation.nodes[node_index].driver.propose(io, data) catch |err| switch (err) {
            error.ProposeNotLeader, error.ProposeTooLarge, error.ProposeLogFull => return err,
            else => simulation.node_fault(io, node_index, err) catch |fault| {
                return simulation.latch(fault);
            },
        };
        simulation.check_after() catch |err| return simulation.latch(err);
    }

    /// The first latched violation of `property` (item 9 adds the linearizability check).
    pub fn check(simulation: *Simulation, property: invariants.Property) Error!void {
        assert(simulation.options.nodes_count >= 2);
        switch (property) {
            .linearizability => {}, // No history before item 9: nothing can be violated.
            .election_safety,
            .leader_append_only,
            .log_matching,
            .leader_completeness,
            .state_machine_safety,
            => try simulation.checker.check(property),
        }
    }

    /// Scripted clean crash of node `node_index` (not an event): the driver is dropped and the
    /// store keeps every unsynced op (none, between events). It stays down until `restart`.
    /// Precondition: the node is up.
    pub fn crash(simulation: *Simulation, io: Io, node_index: u8) void {
        assert(node_index < simulation.options.nodes_count);
        assert(!simulation.nodes[node_index].down);
        const sim_node = &simulation.nodes[node_index];
        simulation.node_down(io, node_index, sim_node.store.unsynced_count(), false);
        assert(sim_node.restart_at_ms == null);
    }

    /// Restarts a crashed node (not an event): a fresh `Driver.init` over the same store and
    /// the node's reset memory; the `Checker` forgets its volatile state. Precondition: the
    /// node is down.
    pub fn restart(simulation: *Simulation, io: Io, node_index: u8) Error!void {
        assert(node_index < simulation.options.nodes_count);
        assert(simulation.nodes[node_index].down);
        simulation.node_restart(io, node_index) catch |err| return simulation.latch(err);
        assert(simulation.nodes[node_index].restart_at_ms == null);
    }

    /// Null when the node is down.
    pub fn status(simulation: *const Simulation, node_index: u8) ?raft.Status {
        assert(node_index < simulation.options.nodes_count);
        assert(simulation.options.nodes_count <= nodes_max);
        const sim_node = &simulation.nodes[node_index];
        if (sim_node.down) return null;
        return sim_node.driver.node.status();
    }

    pub fn stats(simulation: *const Simulation) Stats {
        assert(simulation.options.nodes_count >= 2);
        const checker_stats = simulation.checker.stats();
        const result: Stats = .{
            .events = simulation.events,
            .leader_terms = checker_stats.leader_terms,
            .committed_max = checker_stats.committed_max,
            .applied = simulation.applied_total,
            .crashes = simulation.crashes,
            .torn_crashes = simulation.torn_crashes,
            .restarts = simulation.restarts,
            .network = simulation.network.stats(),
            .digest = simulation.digest(),
        };
        assert(result.events <= simulation.options.events_max);
        return result;
    }

    /// Only after a step, `run_until` or `propose` returned a limit or violation error:
    /// carries `Options.seed`, the event count at that point and the error.
    pub fn report(simulation: *const Simulation) Report {
        assert(simulation.failed != null); // Caller contract, see above.
        assert(simulation.events <= simulation.options.events_max);
        return .{
            .seed = simulation.options.seed,
            .event_index = simulation.events,
            .violation = simulation.failed.?,
        };
    }

    /// Callers may continue only after no failure or a latched `EventsExhausted` (asserted:
    /// any other latched failure is a caller bug). `EventsExhausted` is simply stepped again.
    fn failed_allowed(simulation: *const Simulation) void {
        assert(simulation.events <= simulation.options.events_max);
        const failure = simulation.failed orelse return;
        assert(failure == error.EventsExhausted);
    }

    /// Records `err` as the failure of this run and returns it.
    fn latch(simulation: *Simulation, err: Error) Error {
        assert(simulation.events <= simulation.options.events_max);
        if (simulation.failed == null) simulation.failed = err;
        return err;
    }

    /// The earliest event by `(time_ms, kind)`: a delivery due by the next tick, the tick, the
    /// earliest scheduled restart, the next fault draw.
    fn event_next(simulation: *const Simulation) Event {
        const now_ms = simulation.virtual_clock.time_ms;
        var best: Event = .{ .kind = .tick, .time_ms = simulation.tick_next_ms, .slot = 0 };
        assert(best.time_ms >= now_ms);
        if (simulation.network.next_due_ms()) |due_ms| {
            if (due_ms <= best.time_ms) {
                best = .{ .kind = .deliver, .time_ms = @max(due_ms, now_ms), .slot = 0 };
            }
        }
        for (simulation.nodes[0..simulation.options.nodes_count], 0..) |*sim_node, slot| {
            const restart_ms = sim_node.restart_at_ms orelse continue;
            if (restart_ms < best.time_ms) {
                best = .{ .kind = .restart, .time_ms = restart_ms, .slot = @intCast(slot) };
            }
        }
        if (simulation.fault_next_ms < best.time_ms) {
            best = .{ .kind = .fault, .time_ms = simulation.fault_next_ms, .slot = 0 };
        }
        assert(best.time_ms >= now_ms);
        return best;
    }

    /// Advances the clock to `event`, runs it and checks everything; latches any failure.
    fn event_step(simulation: *Simulation, io: Io, event: Event) Error!void {
        assert(event.time_ms >= simulation.virtual_clock.time_ms);
        assert(simulation.events < simulation.options.events_max);
        simulation.virtual_clock.advance_to(event.time_ms);
        simulation.events += 1;
        simulation.event_run(io, event) catch |err| return simulation.latch(err);
        simulation.check_after() catch |err| return simulation.latch(err);
    }

    /// Runs `event`; the clock already stands at its time.
    fn event_run(simulation: *Simulation, io: Io, event: Event) Error!void {
        assert(simulation.virtual_clock.time_ms == event.time_ms);
        switch (event.kind) {
            .deliver => {
                // Null: the due message crossed a cut link and was consumed (`dropped_cut`).
                const message = simulation.network.pop_due() orelse return;
                const target = message.header().to;
                assert(target != .none);
                const slot: u8 = @intCast(@intFromEnum(target) - 1);
                assert(slot < simulation.options.nodes_count);
                if (simulation.nodes[slot].down) return simulation.network.drop_down();
                simulation.nodes[slot].driver.receive(io, message) catch |err| {
                    try simulation.node_fault(io, slot, err);
                };
            },
            .tick => {
                simulation.tick_next_ms += simulation.options.tick_ms;
                for (0..simulation.options.nodes_count) |slot| {
                    if (simulation.nodes[slot].down) continue;
                    simulation.nodes[slot].driver.poll(io) catch |err| {
                        try simulation.node_fault(io, @intCast(slot), err);
                    };
                }
            },
            .restart => try simulation.node_restart(io, event.slot),
            .fault => simulation.fault_draw(io),
        }
    }

    /// A node returned `err` from its driver. A store failure armed by a torn crash is the
    /// crash: the node fail-stops, keeping a seeded prefix of its unsynced ops. Anything else
    /// is returned.
    fn node_fault(simulation: *Simulation, io: Io, slot: u8, err: Error) Error!void {
        assert(slot < simulation.options.nodes_count);
        const sim_node = &simulation.nodes[slot];
        assert(!sim_node.down);
        switch (err) {
            error.StoreIoFailed => {},
            else => return err,
        }
        if (!sim_node.torn_pending) return err;
        const unsynced: u64 = sim_node.store.unsynced_count();
        const keep: u32 = @intCast(simulation.faults_prng.uint_less_than(unsynced + 1));
        simulation.node_down(io, slot, keep, true);
        simulation.restart_schedule(slot);
    }

    /// Takes node `slot` down: drops its driver, applies the crash to its store.
    fn node_down(simulation: *Simulation, io: Io, slot: u8, keep: u32, torn: bool) void {
        const sim_node = &simulation.nodes[slot];
        assert(!sim_node.down);
        assert(keep <= sim_node.store.unsynced_count());
        sim_node.driver.deinit(io, sim_node.fba.allocator());
        sim_node.store.crash(keep);
        sim_node.down = true;
        sim_node.torn_pending = false;
        sim_node.restart_at_ms = null;
        sim_node.recorder.len = 0; // The state machine is volatile.
        simulation.crashes += 1;
        if (torn) simulation.torn_crashes += 1;
    }

    /// Schedules the restart of a seeded crash `[1, down_ms_max]` ms from now.
    fn restart_schedule(simulation: *Simulation, slot: u8) void {
        const sim_node = &simulation.nodes[slot];
        assert(sim_node.down);
        const down_ms_max: u64 = simulation.options.faults.down_ms_max;
        assert(down_ms_max > 0);
        const delay_ms = 1 + simulation.faults_prng.uint_less_than(down_ms_max);
        sim_node.restart_at_ms = simulation.virtual_clock.time_ms + delay_ms;
    }

    /// A fresh `Driver.init` over the node's store and reset memory; tells the `Checker`.
    fn node_restart(simulation: *Simulation, io: Io, slot: u8) Error!void {
        const sim_node = &simulation.nodes[slot];
        assert(sim_node.down);
        assert(sim_node.store.unsynced_count() == 0);
        sim_node.fba.reset();
        var config = simulation.options.raft;
        config.id = @enumFromInt(@as(u64, slot) + 1);
        sim_node.restart_at_ms = null;
        simulation.driver_start(io, slot, &config) catch |err| switch (err) {
            // The planted store reverted a hard state below its own log: the node detects the
            // corruption and refuses to start, so it stays down for good. An honest store
            // never does this: that is a bug, returned.
            error.RestoreInconsistent => {
                if (simulation.options.plant == .lose_synced_hard_state) return;
                return err;
            },
            else => return err,
        };
        sim_node.down = false;
        simulation.checker.restarted(slot);
        simulation.restarts += 1;
    }

    /// One seeded fault draw: with `crash_percent` a seeded up node crashes, torn with
    /// `torn_percent` (the store's next `arm_failure` call fails and the node goes down then).
    fn fault_draw(simulation: *Simulation, io: Io) void {
        const faults = simulation.options.faults;
        assert(faults.fault_interval_ms_max > 0);
        const prng = &simulation.faults_prng;
        const interval_ms = 1 + prng.uint_less_than(faults.fault_interval_ms_max);
        simulation.fault_next_ms = simulation.virtual_clock.time_ms + interval_ms;
        if (!prng.chance(faults.crash_percent)) return;
        var up: [nodes_max]u8 = undefined;
        var up_count: u8 = 0;
        for (simulation.nodes[0..simulation.options.nodes_count], 0..) |*sim_node, slot| {
            if (sim_node.down) continue;
            up[up_count] = @intCast(slot);
            up_count += 1;
        }
        if (up_count == 0) return;
        const slot = up[@intCast(prng.uint_less_than(up_count))];
        const sim_node = &simulation.nodes[slot];
        if (prng.chance(faults.torn_percent)) {
            const calls_until: u32 = @intCast(prng.uint_less_than(torn_calls_until_max));
            if (sim_node.torn_pending) return;
            sim_node.torn_pending = true;
            sim_node.store.arm_failure(calls_until);
            return;
        }
        simulation.node_down(io, slot, sim_node.store.unsynced_count(), false);
        simulation.restart_schedule(slot);
    }

    /// The checks after every event: node and network invariants, the `Checker` over all
    /// nodes, then the drained applied records.
    fn check_after(simulation: *Simulation) Error!void {
        const count = simulation.options.nodes_count;
        var observations: [nodes_max]invariants.Observation = undefined;
        var up_count: u8 = 0;
        for (simulation.nodes[0..count], 0..) |*sim_node, slot| {
            try sim_node.store.check_invariants();
            if (sim_node.down) continue;
            try sim_node.driver.node.check_invariants();
            observations[up_count] = .{
                .node_index = @intCast(slot),
                .status = sim_node.driver.node.status(),
                .log = sim_node.driver.node.entries(),
            };
            up_count += 1;
        }
        try simulation.network.check_invariants();
        try simulation.checker.observe(observations[0..up_count]);
        for (simulation.nodes[0..count], 0..) |*sim_node, slot| {
            try simulation.drain(@intCast(slot), &sim_node.recorder);
        }
        assert(count <= nodes_max);
        simulation.failed_allowed();
    }

    /// Hands the recorded applies of node `slot` to the checker, in apply order.
    fn drain(simulation: *Simulation, slot: u8, recorder: *Recorder) Error!void {
        assert(slot < simulation.options.nodes_count);
        assert(recorder.len <= recorder.records.len);
        defer recorder.len = 0;

        for (recorder.records[0..recorder.len]) |record| {
            try simulation.checker.applied(slot, record.index, record.entry_fingerprint);
            simulation.applied_total += 1;
            const words = [3]u64{ slot, @intFromEnum(record.index), record.entry_fingerprint };
            simulation.applied_digest = std.hash.Wyhash.hash(
                simulation.applied_digest,
                std.mem.asBytes(&words),
            );
        }
    }

    /// The run's digest, see `Stats.digest`.
    fn digest(simulation: *const Simulation) u64 {
        const count = simulation.options.nodes_count;
        var hasher = std.hash.Wyhash.init(simulation.applied_digest);
        const head = [3]u64{
            simulation.network.trace_hash(),
            simulation.events,
            simulation.virtual_clock.time_ms,
        };
        hasher.update(std.mem.asBytes(&head));
        for (simulation.nodes[0..count]) |*sim_node| {
            if (sim_node.down) {
                const down_word = [1]u64{std.math.maxInt(u64)};
                hasher.update(std.mem.asBytes(&down_word));
                continue;
            }
            const node_status = sim_node.driver.node.status();
            const words = [7]u64{
                @intFromEnum(node_status.role),
                @intFromEnum(node_status.term),
                @intFromEnum(node_status.vote),
                @intFromEnum(node_status.leader),
                @intFromEnum(node_status.commit_index),
                @intFromEnum(node_status.applied_index),
                @intFromEnum(node_status.last_index),
            };
            hasher.update(std.mem.asBytes(&words));
        }
        const result = hasher.final();
        assert(count >= 2);
        return result;
    }

    /// Builds node `slot`: store, recorder, memory, driver. On error nothing of it is left.
    fn node_build(simulation: *Simulation, io: Io, gpa: Allocator, slot: u8) Error!void {
        assert(slot < simulation.options.nodes_count);
        var config = simulation.options.raft;
        config.id = @enumFromInt(@as(u64, slot) + 1);
        const sim_node = &simulation.nodes[slot];

        const buffer_bytes: usize = @intCast(Driver.init_bytes_max(&config));
        sim_node.buffer = try gpa.alignedAlloc(u8, .@"16", buffer_bytes);
        errdefer gpa.free(sim_node.buffer);

        const store_options: CrashStore.Options = .{
            .store = .{
                .entries_max = config.log_entries_max,
                .data_bytes_max = config.log_bytes_max,
                .snapshot_bytes_max = 0,
            },
            .journal_ops_max = journal_ops_max,
            .journal_bytes_max = config.log_bytes_max,
            .fault = store_fault_of(simulation.options.plant),
        };
        try sim_node.store.init(gpa, &store_options);
        errdefer sim_node.store.deinit(gpa);

        sim_node.recorder.records = try gpa.alloc(Applied, config.log_entries_max);
        errdefer gpa.free(sim_node.recorder.records);

        sim_node.recorder.len = 0;
        sim_node.down = false;
        sim_node.torn_pending = false;
        sim_node.restart_at_ms = null;
        sim_node.prng = Prng.init(prng_module.derive_seed(simulation.options.seed, .node, slot));
        sim_node.fba = std.heap.FixedBufferAllocator.init(sim_node.buffer);
        try simulation.driver_start(io, slot, &config);
        assert(sim_node.driver.node.status().role == .follower);
    }

    /// `Driver.init` for node `slot` over its (possibly non-empty) store.
    fn driver_start(
        simulation: *Simulation,
        io: Io,
        slot: u8,
        config: *const raft.Config,
    ) Error!void {
        assert(config.id != .none);
        assert(@intFromEnum(config.id) == @as(u64, slot) + 1);
        const sim_node = &simulation.nodes[slot];
        var voters: [nodes_max]NodeId = undefined;
        const count = simulation.options.nodes_count;
        for (voters[0..count], 0..) |*voter, at| voter.* = @enumFromInt(at + 1);
        const configuration: types.Configuration = .{
            .voters = voters[0..count],
            .voters_outgoing = &.{},
            .learners = &.{},
        };
        const deps: Driver.Deps = .{
            .store = sim_node.store.as_log_store(),
            .transport = simulation.network.as_transport(),
            .state_machine = interfaces.StateMachine.init(&sim_node.recorder),
            .clock = simulation.virtual_clock.as_clock(),
            .rng = sim_node.prng.as_rng(),
        };
        const driver_options: Driver.Options = .{
            .tick_ms = simulation.options.tick_ms,
            .ticks_per_poll_max = ticks_per_poll_max,
        };
        try sim_node.driver.init(
            io,
            sim_node.fba.allocator(),
            config.*,
            driver_options,
            &configuration,
            deps,
        );
    }
};

/// The network fault a `Plant` stands for; the other plants do not touch the network.
fn fault_of(plant: Plant) Network.Fault {
    return switch (plant) {
        .none => .none,
        .forge_votes => .forge_votes,
        .flip_data => .flip_data,
        .lose_synced_hard_state => .none,
    };
}

/// The store fault a `Plant` stands for; the other plants leave the store honest.
fn store_fault_of(plant: Plant) CrashStore.Fault {
    return switch (plant) {
        .none, .forge_votes, .flip_data => .none,
        .lose_synced_hard_state => .lose_synced_hard_state,
    };
}

/// `init`, `run_until(duration_ms)`, `check` of the five properties, `deinit`; on an error the
/// `Report` is filled in (and `Stats` is lost). Item 9 adds the linearizability check.
pub fn run_seed(
    io: Io,
    gpa: Allocator,
    options: *const Options,
    duration_ms: u64,
    report: *Report,
) Error!Stats {
    assert(duration_ms > 0);
    assert(options.nodes_count >= 2);
    var simulation: Simulation = undefined;
    simulation.init(io, gpa, options) catch |err| {
        report.* = .{ .seed = options.seed, .event_index = 0, .violation = err };
        return err;
    };
    defer simulation.deinit(io, gpa);

    simulation.run_until(io, duration_ms) catch |err| {
        report.* = simulation.report();
        return err;
    };
    const properties = [_]invariants.Property{
        .election_safety,     .leader_append_only,   .log_matching,
        .leader_completeness, .state_machine_safety,
    };
    for (properties) |property| {
        simulation.check(property) catch |err| {
            report.* = .{
                .seed = options.seed,
                .event_index = simulation.events,
                .violation = err,
            };
            return err;
        };
    }
    return simulation.stats();
}
