//! synod.driver — Executes Effects against Transport / LogStore / StateMachine.
//!
//! Contract: docs/adr/0007-raft-node-contract.md, "Driver". The driver is the `std.Io`
//! boundary (ADR-002): it turns `Clock` time into whole ticks, feeds one `Input` to the pure
//! `raft.Node` per call, and runs the returned `Effects` in phase order: the persist phase
//! (`truncate`, `append`, `save_hard_state`), one `sync`, then `send`, then `apply`.
//!
//! Invariants: an `unsynced` flag is set by every persist effect and cleared by `sync`; it is
//! asserted clear before each send and apply, so a vote or ack never leaves before it is durable.
//! Phases are asserted non-decreasing as each effect executes. Any `Fault` stops the driver
//! (`stopped`); a stopped driver asserts on every later call and the only recovery is a fresh
//! `Driver.init` over the same store (ADR-006 crash model). A rejected `receive` or `propose`
//! (a `raft.StepError`) mutates nothing and does not stop the driver.
//!
//! Allocation: `init` allocates through the node and a scratch slice freed before it returns;
//! no method allocates afterwards, and the driver stores no allocator.
//!
//! Time: `init` reads the clock once as the tick baseline. `poll` converts elapsed milliseconds
//! into whole `tick_ms` ticks, carries the remainder, runs at most `ticks_per_poll_max`, and
//! drops the debt of a longer stall by resetting the baseline to now.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const interfaces = @import("interfaces.zig");
const raft = @import("raft.zig");
const types = @import("types.zig");

const Clock = interfaces.Clock;
const Configuration = types.Configuration;
const Effect = raft.Effect;
const Effects = raft.Effects;
const LogStore = interfaces.LogStore;
const Message = types.Message;
const Rng = interfaces.Rng;
const StateMachine = interfaces.StateMachine;
const Transport = interfaces.Transport;

/// True when an effect of `phase` may run given `unsynced` (a persist effect ran and no
/// `sync` has returned since). Sends and applies need a clear flag: every vote or ack leaves
/// only after it is durable. The driver asserts this before each send and apply.
pub fn phase_ready(unsynced: bool, phase: Effect.Phase) bool {
    return !unsynced or (phase != .send and phase != .apply);
}

/// True when `next` may follow `previous` in one `Effects` view (phases never decrease).
pub fn phase_ordered(previous: Effect.Phase, next: Effect.Phase) bool {
    return @intFromEnum(next) >= @intFromEnum(previous);
}

pub const Driver = struct {
    /// Read-only from outside: `node.status()`, `node.entries()`, `node.check_invariants()`.
    node: raft.Node,
    /// Set by the first `Fault`; every later call asserts it clear.
    stopped: bool,
    deps: Deps,
    options: Options,
    /// Clock reading, in milliseconds, up to which ticks have been delivered.
    last_tick_ms: u64,

    /// `tick_ms` is the logical tick length; at most `ticks_per_poll_max` ticks run per `poll`.
    pub const Options = struct { tick_ms: u32, ticks_per_poll_max: u32 };
    pub const Deps = struct {
        store: LogStore,
        transport: Transport,
        state_machine: StateMachine,
        clock: Clock,
        rng: Rng,
    };
    /// `LogStore.UpdateError` is a subset of `WriteError`.
    pub const Fault = LogStore.WriteError || StateMachine.ApplyError;

    /// Restores the node from `deps.store` (hard state and the whole log) and starts the tick
    /// clock. Precondition: `options.tick_ms > 0` and `options.ticks_per_poll_max > 0`.
    pub fn init(
        driver: *Driver,
        io: Io,
        gpa: Allocator,
        config: raft.Config,
        options: Options,
        configuration: *const Configuration,
        deps: Deps,
    ) (raft.InitError || LogStore.ReadError)!void {
        _ = io; // Reserved by ADR-002: the only place real I/O would enter.
        assert(options.tick_ms > 0);
        assert(options.ticks_per_poll_max > 0);

        const last: usize = @intCast(@intFromEnum(deps.store.last_index()));
        const scratch = try gpa.alloc(types.Entry, last);
        defer gpa.free(scratch);

        for (scratch, 1..) |*slot, index| slot.* = try deps.store.get(@enumFromInt(index));
        const restore: raft.Restore = .{
            .hard_state = try deps.store.load_hard_state(),
            .entries = scratch,
            .configuration = configuration.*,
        };
        try driver.node.init(gpa, config, &restore, deps.rng);

        driver.stopped = false;
        driver.deps = deps;
        driver.options = options;
        driver.last_tick_ms = deps.clock.now_ms();
        assert(!driver.stopped);
    }

    pub fn deinit(driver: *Driver, io: Io, gpa: Allocator) void {
        _ = io;
        driver.node.deinit(gpa);
    }

    /// Delivers `message` to the node and executes the effects. Precondition: not stopped.
    pub fn receive(
        driver: *Driver,
        io: Io,
        message: *const Message,
    ) (raft.ReceiveError || Fault)!void {
        _ = io;
        assert(!driver.stopped);
        const effects = driver.node.step(.{ .message = message }) catch |err| {
            // A message input cannot produce a `Propose*` error, so the cast only narrows.
            return @errorCast(err);
        };
        try driver.execute(effects);
        assert(!driver.stopped);
    }

    /// Proposes `data` to the node (leader only) and executes the effects.
    /// Precondition: not stopped.
    pub fn propose(
        driver: *Driver,
        io: Io,
        data: []const u8,
    ) (raft.ProposeError || Fault)!void {
        _ = io;
        assert(!driver.stopped);
        const effects = driver.node.step(.{ .propose = data }) catch |err| {
            // A propose input cannot produce a message error, so the cast only narrows.
            return @errorCast(err);
        };
        try driver.execute(effects);
        assert(!driver.stopped);
    }

    /// Turns elapsed clock time into ticks and steps the node once per tick.
    /// Precondition: not stopped, and the injected clock never runs backwards.
    pub fn poll(driver: *Driver, io: Io) Fault!void {
        _ = io;
        assert(!driver.stopped);
        const now_ms = driver.deps.clock.now_ms();
        assert(now_ms >= driver.last_tick_ms);

        const elapsed_ticks = @divFloor(now_ms - driver.last_tick_ms, driver.options.tick_ms);
        const run_count: u64 = @min(elapsed_ticks, driver.options.ticks_per_poll_max);
        if (elapsed_ticks > run_count) {
            driver.last_tick_ms = now_ms;
        } else {
            driver.last_tick_ms += run_count * driver.options.tick_ms;
        }
        assert(driver.last_tick_ms <= now_ms);

        for (0..run_count) |_| {
            const effects = driver.node.step(.tick) catch unreachable; // proof: a tick input
            // carries no message or data, so no `StepError` variant can occur.
            try driver.execute(effects);
        }
    }

    /// Runs one step's effects in order. The persist phase sets `unsynced`; the first later
    /// effect of a send or apply phase is preceded by exactly one `sync`.
    fn execute(driver: *Driver, effects: Effects) Fault!void {
        errdefer driver.stopped = true;
        const store = driver.deps.store;
        var unsynced = false;
        var previous: Effect.Phase = .persist;

        for (effects.items) |*effect| {
            const phase = effect.phase();
            assert(phase_ordered(previous, phase));
            previous = phase;
            if (unsynced and phase != .persist) {
                try store.sync();
                unsynced = false;
            }
            assert(phase_ready(unsynced, phase));
            switch (effect.*) {
                .truncate => |from| try store.truncate(from),
                .append => |entries| try store.append(entries),
                .save_hard_state => |*hard_state| try store.save_hard_state(hard_state),
                .send => |*message| driver.deps.transport.send(message),
                .apply => |entries| {
                    for (entries) |*entry| try driver.deps.state_machine.apply(entry);
                },
                .leader_changed => {},
            }
            if (phase == .persist) unsynced = true;
        }
        if (unsynced) {
            try store.sync();
            unsynced = false;
        }
        assert(!unsynced);
    }
};

test "driver: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("driver_test.zig");
}
