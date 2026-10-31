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
//! Snapshots (ADR-009): a `snapshot_due` effect, always the last of a step, is run as
//! `StateMachine.snapshot` into `snapshot_buffer` (`message_limits.snapshot_bytes_max` bytes,
//! allocated by `init`; one byte more is `SnapshotTooLarge`), `save_snapshot`, `sync`, then
//! `step(.snapshot_saved)`, whose `Effects` are asserted empty. Any failure is a fail-stop
//! `Fault` and the node is never told, so nothing compacts. `init` loads the store's snapshot,
//! restores the state machine from it and replays only `(snapshot.index, commit]`.
//!
//! Allocation: `init` allocates through the node, the snapshot buffer and a scratch slice freed
//! before it returns; no method allocates afterwards, and the driver stores no allocator.
//!
//! Time: `init` reads the clock once as the tick baseline. `poll` converts elapsed milliseconds
//! into whole `tick_ms` ticks, carries the remainder, runs at most `ticks_per_poll_max`, and
//! drops the debt of a longer stall by resetting the baseline to now.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const interfaces = @import("interfaces.zig");
const log = @import("log.zig");
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
    /// `snapshot_bytes_max` bytes the state machine snapshots into; owned, freed by `deinit`.
    snapshot_buffer: []u8,

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
    pub const Fault = LogStore.WriteError || LogStore.ReadError || StateMachine.ApplyError ||
        StateMachine.RestoreError || error{SnapshotTooLarge};
    pub const InitError = raft.InitError || LogStore.ReadError || StateMachine.RestoreError;

    /// Restores the node from `deps.store` (hard state, snapshot if any, and the log above it),
    /// restores the state machine from the snapshot and starts the tick clock. Precondition:
    /// `options.tick_ms > 0` and `options.ticks_per_poll_max > 0`. Without a snapshot the node
    /// starts from `configuration`; with one, from the snapshot's.
    pub fn init(
        driver: *Driver,
        io: Io,
        gpa: Allocator,
        config: raft.Config,
        options: Options,
        configuration: *const Configuration,
        deps: Deps,
    ) InitError!void {
        _ = io; // Reserved by ADR-002: the only place real I/O would enter.
        assert(options.tick_ms > 0);
        assert(options.ticks_per_poll_max > 0);

        const record = try deps.store.load_snapshot();
        var base = log.Base.zero;
        var restore_configuration = configuration.*;
        if (record) |found| {
            var reader = std.Io.Reader.fixed(found.snapshot.data);
            try deps.state_machine.restore(&reader);
            base = .{ .index = found.snapshot.index, .term = found.snapshot.term };
            restore_configuration = found.configuration;
        }
        const last_index = @intFromEnum(deps.store.last_index());
        // Store data, not a caller contract: refuse before sizing the scratch slice from it.
        if (last_index < @intFromEnum(base.index)) return error.StoreCorrupt;
        const tail_len = last_index - @intFromEnum(base.index);
        if (tail_len > config.log_entries_max) return error.RestoreLogFull;
        const scratch = try gpa.alloc(types.Entry, @intCast(tail_len));
        defer gpa.free(scratch);

        for (scratch, @intFromEnum(base.index) + 1..) |*slot, index| {
            slot.* = try deps.store.get(@enumFromInt(index));
        }
        const restore: raft.Restore = .{
            .hard_state = try deps.store.load_hard_state(),
            .snapshot = base,
            .entries = scratch,
            .configuration = restore_configuration,
        };
        try driver.node.init(gpa, config, &restore, deps.rng);
        errdefer driver.node.deinit(gpa);

        const buffer_len: usize = @intCast(config.message_limits.snapshot_bytes_max);
        driver.snapshot_buffer = try gpa.alloc(u8, buffer_len);
        driver.stopped = false;
        driver.deps = deps;
        driver.options = options;
        driver.last_tick_ms = deps.clock.now_ms();
        assert(!driver.stopped);
        assert(driver.snapshot_buffer.len == config.message_limits.snapshot_bytes_max);
    }

    /// An upper bound, in bytes, on everything `init` allocates for `config`: the node's
    /// allocations, the snapshot buffer and the restore scratch slice, alignment slack
    /// included (ADR-008). The scratch slice (`log_entries_max` entries) is live while the node
    /// allocates, so they all add up. Precondition: a coherent `config`.
    pub fn init_bytes_max(config: *const raft.Config) u64 {
        const node_bytes = raft.Node.init_bytes_max(config);
        const scratch_bytes = @as(u64, config.log_entries_max) * @sizeOf(types.Entry) +
            @alignOf(types.Entry) - 1;
        assert(node_bytes > 0);
        assert(scratch_bytes >= config.log_entries_max);
        return node_bytes + scratch_bytes + config.message_limits.snapshot_bytes_max;
    }

    pub fn deinit(driver: *Driver, io: Io, gpa: Allocator) void {
        _ = io;
        assert(driver.node.effects.len > 0);
        gpa.free(driver.snapshot_buffer);
        driver.snapshot_buffer = &.{};
        driver.node.deinit(gpa);
        assert(driver.snapshot_buffer.len == 0);
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

    /// Runs a `snapshot_due`: the state machine into `snapshot_buffer`, `save_snapshot`, `sync`,
    /// then `snapshot_saved` to the node. Precondition: nothing is unsynced and `due` is the last
    /// effect of the step (it borrows node storage that `snapshot_saved` is allowed to move).
    fn snapshot_save(driver: *Driver, due: *const raft.SnapshotDue) Fault!void {
        assert(!driver.stopped);
        assert(due.snapshot.index != .zero);
        assert(due.snapshot.term != .zero);
        const store = driver.deps.store;
        var writer = std.Io.Writer.fixed(driver.snapshot_buffer);

        driver.deps.state_machine.snapshot(&writer) catch |err| switch (err) {
            error.WriteFailed => return error.SnapshotTooLarge,
            error.StateMachineFailed => return error.StateMachineFailed,
        };
        writer.flush() catch |err| switch (err) {
            error.WriteFailed => return error.SnapshotTooLarge,
        };
        const snapshot: types.Snapshot = .{
            .index = due.snapshot.index,
            .term = due.snapshot.term,
            .data = writer.buffered(),
        };
        const index = due.snapshot.index;
        try store.save_snapshot(&snapshot, &due.configuration);
        try store.sync();

        // The node emitted `due` for exactly `index` and none was confirmed since, so no
        // `StepError` applies to `snapshot_saved`.
        const input: raft.Input = .{ .snapshot_saved = index };
        const confirmed = driver.node.step(input) catch unreachable; // proof: see above.
        assert(confirmed.items.len == 0);
        assert(driver.node.status().snapshot_index == index);
    }

    /// Runs a `send_snapshot`: loads the stored record, which must be exactly `send.snapshot`
    /// (else `StoreCorrupt`), and sends an `install_snapshot` over it. The record is borrowed
    /// from the store until its next mutating call, which `Transport.send` does not make.
    fn snapshot_send(driver: *Driver, send: *const raft.SnapshotSend) Fault!void {
        assert(!driver.stopped);
        assert(send.snapshot.index != .zero);
        const record = (try driver.deps.store.load_snapshot()) orelse return error.StoreCorrupt;
        if (record.snapshot.index != send.snapshot.index) return error.StoreCorrupt;
        if (record.snapshot.term != send.snapshot.term) return error.StoreCorrupt;

        const message: Message = .{ .install_snapshot = .{
            .header = send.header,
            .snapshot = record.snapshot,
            .configuration = record.configuration,
        } };
        driver.deps.transport.send(&message);
    }

    /// Runs a `restore`: the state machine from the stored snapshot, which the persist phase
    /// just saved and synced and must be exactly at `index` (else `StoreCorrupt`).
    fn snapshot_restore(driver: *Driver, index: types.Index) Fault!void {
        assert(!driver.stopped);
        assert(index != .zero);
        const record = (try driver.deps.store.load_snapshot()) orelse return error.StoreCorrupt;
        if (record.snapshot.index != index) return error.StoreCorrupt;

        var reader = std.Io.Reader.fixed(record.snapshot.data);
        try driver.deps.state_machine.restore(&reader);
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
                .save_snapshot => |*record| {
                    try store.save_snapshot(&record.snapshot, &record.configuration);
                },
                .send_snapshot => |*send| try driver.snapshot_send(send),
                .restore => |index| try driver.snapshot_restore(index),
                // The last effect of the step (ADR-009): `snapshot_saved` replaces the view.
                .snapshot_due => |*due| try driver.snapshot_save(due),
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
    _ = @import("driver_init_bytes_test.zig");
    _ = @import("driver_snapshot_test.zig");
}
