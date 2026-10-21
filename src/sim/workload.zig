//! synod.sim.workload — the KV workload of the simulator (ADR-008 "Workload"; plan 004 item 10):
//! the command codec, the `KvStateMachine` that replaces the recording state machine, and the
//! `Workload` that invents client operations and builds the history `HistoryChecker` judges.
//!
//! Codec: a `Command` is 24 bytes, `"kv"`, version, kind, client u16, key u16, value u64,
//! op_id u32, crc32 of bytes 0..20, little-endian. `decode` is total: every other byte string
//! is one of five typed errors.
//!
//! State machine: a register file of `keys_count` registers (initially 0). Every applied entry
//! leaves one `Applied` record, drained by the simulation after the event. A no-op, a
//! `conf_change`, an undecodable entry and a key outside the table are recorded with
//! `command = null`: the typed "bad key" outcome, never handed to the history checker.
//!
//! Workload: clients with one operation outstanding each. An operation is invoked at a
//! successful propose and completed when its proposer applies the same entry at the index it
//! was given. Any other outcome (another entry there, the proposer crashing) leaves it pending
//! for good and retires the client index: the slot gets a fresh index, because a pending
//! operation stays outstanding for `HistoryChecker`'s one-operation-per-client rule. A put never
//! writes 0 (the initial register) and `invoke < complete` strictly.
//!
//! Allocation: `KvStateMachine.init` and `Workload.init` only; nothing allocates afterwards.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
const invariants = @import("invariants.zig");
const linearizability = @import("linearizability.zig");
const prng_module = @import("prng.zig");

const Entry = types.Entry;
const Index = types.Index;
const Prng = prng_module.Prng;

pub const Kind = linearizability.Kind;
pub const Operation = linearizability.Operation;

/// Encoded size of a `Command`: "kv", version, kind, client u16, key u16, value u64, op_id u32,
/// crc32 of bytes 0..20; little-endian.
pub const command_bytes: u32 = 24;
pub const command_version: u8 = 1;

/// Bytes covered by the trailing crc32.
const sealed_bytes: usize = 20;

comptime {
    assert(sealed_bytes + @sizeOf(u32) == command_bytes);
}

pub const Command = struct {
    kind: Kind,
    client_index: u16,
    key: u16,
    value: u64,
    op_id: u32,
};

pub const DecodeError = error{
    CommandLength,
    CommandMagic,
    CommandVersion,
    CommandKind,
    CommandChecksum,
};

pub fn encode(command: *const Command, out: *[command_bytes]u8) void {
    assert(@intFromEnum(command.kind) != 0);
    out[0] = 'k';
    out[1] = 'v';
    out[2] = command_version;
    out[3] = @intFromEnum(command.kind);
    std.mem.writeInt(u16, out[4..6], command.client_index, .little);
    std.mem.writeInt(u16, out[6..8], command.key, .little);
    std.mem.writeInt(u64, out[8..16], command.value, .little);
    std.mem.writeInt(u32, out[16..20], command.op_id, .little);
    const crc = std.hash.Crc32.hash(out[0..sealed_bytes]);
    std.mem.writeInt(u32, out[sealed_bytes..command_bytes], crc, .little);
    assert(out[2] == command_version);
}

pub fn decode(bytes: []const u8) DecodeError!Command {
    if (bytes.len != command_bytes) return error.CommandLength;

    if (bytes[0] != 'k' or bytes[1] != 'v') return error.CommandMagic;

    if (bytes[2] != command_version) return error.CommandVersion;

    const kind = std.enums.fromInt(Kind, bytes[3]) orelse return error.CommandKind;
    const crc_want = std.mem.readInt(u32, bytes[sealed_bytes..command_bytes][0..4], .little);
    if (std.hash.Crc32.hash(bytes[0..sealed_bytes]) != crc_want) return error.CommandChecksum;

    const command: Command = .{
        .kind = kind,
        .client_index = std.mem.readInt(u16, bytes[4..6], .little),
        .key = std.mem.readInt(u16, bytes[6..8], .little),
        .value = std.mem.readInt(u64, bytes[8..16], .little),
        .op_id = std.mem.readInt(u32, bytes[16..20], .little),
    };
    assert(bytes.len == command_bytes);
    return command;
}

pub const KvStateMachine = struct {
    pub const Applied = struct {
        index: Index,
        entry_fingerprint: u64,
        /// Null for a no-op, a `conf_change`, an undecodable entry or a key >= `keys_count`.
        command: ?Command,
        /// put: the stored value; get: the current value (0 = never written); null command: 0.
        result: u64,
    };

    pub const Options = struct { keys_count: u16, applied_max: u32 };

    pub const InvariantError = error{KvInvariant};

    values: []u64,
    records: []Applied,
    len: u32,

    pub fn init(kv: *KvStateMachine, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.keys_count > 0);
        assert(options.applied_max > 0);
        const values = try gpa.alloc(u64, options.keys_count);
        errdefer gpa.free(values);

        const records = try gpa.alloc(Applied, options.applied_max);
        @memset(values, 0);
        kv.* = .{ .values = values, .records = records, .len = 0 };
    }

    pub fn deinit(kv: *KvStateMachine, gpa: Allocator) void {
        assert(kv.values.len > 0);
        assert(kv.records.len > 0);
        gpa.free(kv.records);
        gpa.free(kv.values);
        kv.* = undefined;
    }

    pub fn as_state_machine(kv: *KvStateMachine) interfaces.StateMachine {
        assert(kv.len <= kv.records.len);
        return interfaces.StateMachine.init(kv);
    }

    /// Never fails except when `applied_max` records are undrained: `StateMachineFailed`.
    pub fn apply(kv: *KvStateMachine, entry: *const Entry) interfaces.StateMachine.ApplyError!void {
        assert(entry.index != Index.zero);
        assert(kv.len <= kv.records.len);
        if (kv.len == kv.records.len) return error.StateMachineFailed;

        var record: Applied = .{
            .index = entry.index,
            .entry_fingerprint = invariants.fingerprint(entry),
            .command = null,
            .result = 0,
        };
        if (command_of(entry, kv.values.len)) |command| {
            record.command = command;
            record.result = kv.execute(&command);
        }
        kv.records[kv.len] = record;
        kv.len += 1;
    }

    /// Runs `command` on its register and returns the result a record carries.
    fn execute(kv: *KvStateMachine, command: *const Command) u64 {
        assert(command.key < kv.values.len);
        switch (command.kind) {
            .put => {
                assert(command.value != 0); // A put never writes the initial register value.
                kv.values[command.key] = command.value;
                return command.value;
            },
            .get => return kv.values[command.key],
        }
    }

    /// Phase 3 takes no snapshots (ADR-008, to be amended): a call is a harness fault.
    pub fn snapshot(
        kv: *KvStateMachine,
        writer: *Io.Writer,
    ) interfaces.StateMachine.SnapshotError!void {
        assert(kv.len <= kv.records.len);
        assert(writer.end <= writer.buffer.len);
        return error.StateMachineFailed;
    }

    /// Phase 3 restores no snapshots (ADR-008, to be amended): a call is a harness fault.
    pub fn restore(
        kv: *KvStateMachine,
        reader: *Io.Reader,
    ) interfaces.StateMachine.RestoreError!void {
        assert(kv.len <= kv.records.len);
        assert(reader.seek <= reader.end);
        return error.StateMachineFailed;
    }

    /// The records applied since the last `drain`, in apply order; empties the buffer. Borrowed
    /// until the next `apply`.
    pub fn drain(kv: *KvStateMachine) []const Applied {
        assert(kv.len <= kv.records.len);
        const drained = kv.records[0..kv.len];
        kv.len = 0;
        assert(drained.len <= kv.records.len);
        return drained;
    }

    /// Restart: every key back to 0 and the undrained records void (the machine is volatile).
    pub fn reset(kv: *KvStateMachine) void {
        assert(kv.len <= kv.records.len);
        @memset(kv.values, 0);
        kv.len = 0;
        assert(kv.records.len > 0);
    }

    pub fn check_invariants(kv: *const KvStateMachine) InvariantError!void {
        if (kv.values.len == 0) return error.KvInvariant;

        if (kv.len > kv.records.len) return error.KvInvariant;

        for (kv.records[0..kv.len]) |record| {
            if (record.index == Index.zero) return error.KvInvariant;

            const command = record.command orelse continue;
            if (command.key >= kv.values.len) return error.KvInvariant;
        }
    }
};

/// The command inside `entry`, or null when the entry carries none: not a `normal` entry, an
/// empty no-op, undecodable bytes, or a key outside `keys_count`.
fn command_of(entry: *const Entry, keys_count: usize) ?Command {
    assert(keys_count > 0);
    assert(keys_count <= std.math.maxInt(u16) + 1);
    if (entry.kind != .normal) return null;

    const command = decode(entry.data) catch |err| switch (err) {
        error.CommandLength,
        error.CommandMagic,
        error.CommandVersion,
        error.CommandKind,
        error.CommandChecksum,
        => return null,
    };
    if (command.key >= keys_count) return null;

    return command;
}

pub const Invocation = struct { node_index: u8, log_index: Index, event_index: u64 };

/// What a client slot is doing.
const SlotState = enum(u8) {
    /// May be given a command.
    free,
    /// Has an operation outstanding: `Slot.op`.
    busy,
    /// Out of fresh client indices (`u16`): never used again.
    dead,
};

/// One concurrent client: the index its next operation carries, and its outstanding operation.
const Slot = struct { client_index: u16, state: SlotState, op: u32 };

/// What the workload remembers about an invoked operation besides its `Operation`.
const Meta = struct { node_index: u8, log_index: Index, op_id: u32 };

pub const Workload = struct {
    pub const Fault = enum(u8) { none = 1, ack_uncommitted = 2 };

    pub const Options = struct {
        /// Concurrent clients; 0 = no workload.
        clients_count: u16,
        keys_count: u16,
        /// Percent of commands that are puts, `[0, 100]`.
        put_percent: u8,
        /// A command is due every `[1, op_interval_ms_max]` ms.
        op_interval_ms_max: u32,
        fault: Fault,
    };

    /// `ops_invoked == history().len`; `ops_completed` counts records with a complete event;
    /// `ops_pending == ops_invoked - ops_completed` (in flight and gone pending alike).
    pub const Stats = struct { ops_invoked: u32, ops_completed: u32, ops_pending: u32 };

    pub const InvariantError = error{WorkloadInvariant};

    options: Options,
    history_ops_max: u32,
    prng: Prng,
    ops: []Operation,
    metas: []Meta,
    slots: []Slot,
    len: u32,
    completed: u32,
    /// When the next command is due; `maxInt(u64)` without clients.
    due_ms: u64,
    op_id_next: u32,
    /// The next fresh client index; a retired slot takes it.
    client_next: u32,

    /// Allocates the history (`history_ops_max` records, their notes and one slot per client)
    /// and nothing else afterwards.
    pub fn init(
        workload: *Workload,
        gpa: Allocator,
        options: Options,
        history_ops_max: u32,
        prng: Prng,
    ) Allocator.Error!void {
        assert(history_ops_max > 0);
        assert(options.put_percent <= 100);
        const ops = try gpa.alloc(Operation, history_ops_max);
        errdefer gpa.free(ops);

        const metas = try gpa.alloc(Meta, history_ops_max);
        errdefer gpa.free(metas);

        const slots = try gpa.alloc(Slot, options.clients_count);
        for (slots, 0..) |*slot, at| {
            slot.* = .{ .client_index = @intCast(at), .state = .free, .op = 0 };
        }
        workload.* = .{
            .options = options,
            .history_ops_max = history_ops_max,
            .prng = prng,
            .ops = ops,
            .metas = metas,
            .slots = slots,
            .len = 0,
            .completed = 0,
            .due_ms = std.math.maxInt(u64),
            .op_id_next = 0,
            .client_next = options.clients_count,
        };
        if (options.clients_count == 0) return;

        assert(options.keys_count > 0);
        assert(options.op_interval_ms_max > 0);
        workload.due_ms = 1 + workload.prng.uint_less_than(options.op_interval_ms_max);
    }

    pub fn deinit(workload: *Workload, gpa: Allocator) void {
        assert(workload.ops.len == workload.history_ops_max);
        assert(workload.metas.len == workload.history_ops_max);
        gpa.free(workload.slots);
        gpa.free(workload.metas);
        gpa.free(workload.ops);
        workload.* = undefined;
    }

    /// When the next command is due; null when `clients_count == 0` or the history is full.
    pub fn next_due_ms(workload: *const Workload) ?u64 {
        assert(workload.len <= workload.history_ops_max);
        if (workload.options.clients_count == 0) return null;

        if (workload.len == workload.history_ops_max) return null;

        assert(workload.due_ms != std.math.maxInt(u64));
        return workload.due_ms;
    }

    /// Precondition: `next_due_ms() != null` and `now_ms >= next_due_ms().?`. Draws the next due
    /// time in `[now_ms + 1, now_ms + op_interval_ms_max]`, then returns a command for a free
    /// client, or null when every client has an operation outstanding.
    pub fn next_command(workload: *Workload, now_ms: u64) ?Command {
        const due_ms = workload.next_due_ms() orelse unreachable; // Caller contract.
        assert(now_ms >= due_ms);
        const options = workload.options;
        const prng = &workload.prng;
        workload.due_ms = now_ms + 1 + prng.uint_less_than(options.op_interval_ms_max);

        var free_count: u32 = 0;
        for (workload.slots) |slot| {
            if (slot.state == .free) free_count += 1;
        }
        if (free_count == 0) return null;

        var skip = prng.uint_less_than(free_count);
        const client_index = for (workload.slots) |slot| {
            if (slot.state != .free) continue;

            if (skip == 0) break slot.client_index;
            skip -= 1;
        } else unreachable; // `free_count` slots are free and `skip < free_count`.
        const kind: Kind = if (prng.chance(options.put_percent)) .put else .get;
        const key: u16 = @intCast(prng.uint_less_than(options.keys_count));
        // A put never writes 0: it is the register's initial value.
        const value = if (kind == .put) 1 + prng.uint_less_than(std.math.maxInt(u64)) else 0;
        assert(workload.op_id_next < std.math.maxInt(u32));
        const op_id = workload.op_id_next;
        workload.op_id_next += 1;
        return .{
            .kind = kind,
            .client_index = client_index,
            .key = key,
            .value = value,
            .op_id = op_id,
        };
    }

    /// The command was proposed successfully: its client now has an operation outstanding.
    pub fn invoked(workload: *Workload, command: *const Command, invocation: Invocation) void {
        assert(workload.len < workload.history_ops_max);
        assert(command.key < workload.options.keys_count);
        const slot_at = workload.slot_of(command.client_index);
        const slot = &workload.slots[slot_at];
        assert(slot.state == .free);
        const op_at = workload.len;
        workload.ops[op_at] = .{
            .client_index = command.client_index,
            .kind = command.kind,
            .key = command.key,
            .value = if (command.kind == .put) command.value else 0,
            .invoke_event = invocation.event_index,
            .complete_event = null,
        };
        workload.metas[op_at] = .{
            .node_index = invocation.node_index,
            .log_index = invocation.log_index,
            .op_id = command.op_id,
        };
        slot.state = .busy;
        slot.op = op_at;
        workload.len += 1;
        if (workload.options.fault != .ack_uncommitted) return;

        if (command.kind != .put) return;

        // The planted lie: the client is told its put is durable before it is. The slot takes
        // a fresh client index because the ack is the very next event: the client's next
        // invoke could land on it, and `HistoryChecker` needs the two strictly apart.
        workload.ops[op_at].complete_event = invocation.event_index + 1;
        workload.completed += 1;
        workload.slot_renew(slot);
    }

    /// The command was refused (`ProposeNotLeader`, `ProposeLogFull`): no record is made.
    pub fn rejected(workload: *Workload, command: *const Command) void {
        assert(workload.slots[workload.slot_of(command.client_index)].state == .free);
        assert(command.op_id < workload.op_id_next);
    }

    /// Node `node_index` applied `record` during event `event_index`.
    pub fn applied(
        workload: *Workload,
        node_index: u8,
        record: *const KvStateMachine.Applied,
        event_index: u64,
    ) void {
        assert(record.index != Index.zero);
        assert(workload.len <= workload.history_ops_max);
        for (workload.slots) |*slot| {
            if (slot.state != .busy) continue;

            const meta = workload.metas[slot.op];
            if (meta.node_index != node_index or meta.log_index != record.index) continue;

            const command = record.command orelse {
                workload.slot_renew(slot); // A no-op or membership entry took the index.
                continue;
            };
            if (command.op_id != meta.op_id) {
                workload.slot_renew(slot); // Another command took the index.
                continue;
            }
            const op = &workload.ops[slot.op];
            assert(command.client_index == op.client_index);
            assert(event_index > op.invoke_event);
            op.complete_event = event_index;
            if (op.kind == .get) op.value = record.result;
            workload.completed += 1;
            slot.state = .free;
        }
    }

    /// Node `node_index` crashed: every operation it proposed that is outstanding goes pending.
    pub fn crashed(workload: *Workload, node_index: u8) void {
        assert(workload.len <= workload.history_ops_max);
        assert(workload.completed <= workload.len);
        for (workload.slots) |*slot| {
            if (slot.state != .busy) continue;

            if (workload.metas[slot.op].node_index == node_index) workload.slot_renew(slot);
        }
    }

    /// The slot index whose current client index is `client_index`. Precondition: there is one.
    fn slot_of(workload: *const Workload, client_index: u16) usize {
        for (workload.slots, 0..) |slot, at| {
            if (slot.state == .dead) continue;

            if (slot.client_index == client_index) return at;
        }
        unreachable; // Caller contract: `client_index` came from `next_command` of a live slot.
    }

    /// The slot's operation is over (pending for good, or acked by the lie): the slot takes a
    /// fresh client index and is free again, or is dead when the indices ran out.
    fn slot_renew(workload: *Workload, slot: *Slot) void {
        assert(slot.state == .busy);
        assert(workload.client_next <= std.math.maxInt(u16) + 1);
        if (workload.client_next > std.math.maxInt(u16)) {
            slot.state = .dead;
            return;
        }
        slot.client_index = @intCast(workload.client_next);
        slot.state = .free;
        workload.client_next += 1;
    }

    pub fn history(workload: *const Workload) []const Operation {
        return workload.ops[0..workload.len];
    }

    pub fn stats(workload: *const Workload) Stats {
        assert(workload.completed <= workload.len);
        return .{
            .ops_invoked = workload.len,
            .ops_completed = workload.completed,
            .ops_pending = workload.len - workload.completed,
        };
    }

    pub fn check_invariants(workload: *const Workload) InvariantError!void {
        if (workload.len > workload.history_ops_max) return error.WorkloadInvariant;

        var completed: u32 = 0;
        for (workload.history()) |op| {
            if (op.key >= workload.options.keys_count) return error.WorkloadInvariant;

            const end = op.complete_event orelse continue;
            if (end <= op.invoke_event) return error.WorkloadInvariant;

            completed += 1;
        }
        if (completed != workload.completed) return error.WorkloadInvariant;

        for (workload.slots) |slot| {
            if (slot.state != .busy) continue;

            if (slot.op >= workload.len) return error.WorkloadInvariant;

            const op = workload.ops[slot.op];
            if (op.complete_event != null) return error.WorkloadInvariant;

            if (op.client_index != slot.client_index) return error.WorkloadInvariant;
        }
    }
};
