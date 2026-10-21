//! synod.sim.workload — the KV workload of the simulator (ADR-008 "Workload"; plan 004 item 10):
//! the command codec, the `KvStateMachine` that replaces the recording state machine, and the
//! `Workload` that invents client operations and builds the history `HistoryChecker` judges.
//!
//! RED SKELETON: the public API is declared; the bodies are deliberately wrong stubs so the
//! item-10 tests compile and fail. The developer replaces every body.
//!
//! Allocation: `KvStateMachine.init` and `Workload.init` only; nothing allocates afterwards.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
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
    _ = command;
    @memset(out, 0);
}

pub fn decode(bytes: []const u8) DecodeError!Command {
    _ = bytes;
    return error.CommandChecksum;
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
        gpa.free(kv.records);
        gpa.free(kv.values);
        kv.* = undefined;
    }

    pub fn as_state_machine(kv: *KvStateMachine) interfaces.StateMachine {
        return interfaces.StateMachine.init(kv);
    }

    /// Never fails except when `applied_max` records are undrained: `StateMachineFailed`.
    pub fn apply(kv: *KvStateMachine, entry: *const Entry) interfaces.StateMachine.ApplyError!void {
        _ = kv;
        _ = entry;
        return error.StateMachineFailed;
    }

    /// Phase 3 takes no snapshots (ADR-008, to be amended): a call is a harness fault.
    pub fn snapshot(
        kv: *KvStateMachine,
        writer: *Io.Writer,
    ) interfaces.StateMachine.SnapshotError!void {
        _ = kv;
        _ = writer;
        return error.StateMachineFailed;
    }

    /// Phase 3 restores no snapshots (ADR-008, to be amended): a call is a harness fault.
    pub fn restore(
        kv: *KvStateMachine,
        reader: *Io.Reader,
    ) interfaces.StateMachine.RestoreError!void {
        _ = kv;
        _ = reader;
        return error.StateMachineFailed;
    }

    /// The records applied since the last `drain`, in apply order; empties the buffer. Borrowed
    /// until the next `apply`.
    pub fn drain(kv: *KvStateMachine) []const Applied {
        _ = kv;
        return &.{};
    }

    /// Restart: every key back to 0 and the undrained records void (the machine is volatile).
    pub fn reset(kv: *KvStateMachine) void {
        _ = kv;
    }

    pub fn check_invariants(kv: *const KvStateMachine) InvariantError!void {
        _ = kv;
    }
};

pub const Invocation = struct { node_index: u8, log_index: Index, event_index: u64 };

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
    len: u32,

    /// Allocates the history (`history_ops_max` records) and nothing else afterwards.
    pub fn init(
        workload: *Workload,
        gpa: Allocator,
        options: Options,
        history_ops_max: u32,
        prng: Prng,
    ) Allocator.Error!void {
        const ops = try gpa.alloc(Operation, history_ops_max);
        workload.* = .{
            .options = options,
            .history_ops_max = history_ops_max,
            .prng = prng,
            .ops = ops,
            .len = 0,
        };
    }

    pub fn deinit(workload: *Workload, gpa: Allocator) void {
        gpa.free(workload.ops);
        workload.* = undefined;
    }

    /// When the next command is due; null when `clients_count == 0` or the history is full.
    pub fn next_due_ms(workload: *const Workload) ?u64 {
        _ = workload;
        return null;
    }

    /// Precondition: `next_due_ms() != null` and `now_ms >= next_due_ms().?`. Draws the next due
    /// time in `[now_ms + 1, now_ms + op_interval_ms_max]`, then returns a command for a free
    /// client, or null when every client has an operation outstanding.
    pub fn next_command(workload: *Workload, now_ms: u64) ?Command {
        _ = workload;
        _ = now_ms;
        return null;
    }

    /// The command was proposed successfully: its client now has an operation outstanding.
    pub fn invoked(workload: *Workload, command: *const Command, invocation: Invocation) void {
        _ = workload;
        _ = command;
        _ = invocation;
    }

    /// The command was refused (`ProposeNotLeader`, `ProposeLogFull`): no record is made.
    pub fn rejected(workload: *Workload, command: *const Command) void {
        _ = workload;
        _ = command;
    }

    /// Node `node_index` applied `record` during event `event_index`.
    pub fn applied(
        workload: *Workload,
        node_index: u8,
        record: *const KvStateMachine.Applied,
        event_index: u64,
    ) void {
        _ = workload;
        _ = node_index;
        _ = record;
        _ = event_index;
    }

    /// Node `node_index` crashed: every operation it proposed that is outstanding goes pending.
    pub fn crashed(workload: *Workload, node_index: u8) void {
        _ = workload;
        _ = node_index;
    }

    pub fn history(workload: *const Workload) []const Operation {
        return workload.ops[0..workload.len];
    }

    pub fn stats(workload: *const Workload) Stats {
        _ = workload;
        return .{ .ops_invoked = 0, .ops_completed = 0, .ops_pending = 0 };
    }

    pub fn check_invariants(workload: *const Workload) InvariantError!void {
        _ = workload;
    }
};
