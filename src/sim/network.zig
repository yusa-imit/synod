//! synod.sim.network — the simulator's virtual network (ADR-008, "Network"): a fixed table of
//! in-flight messages with seeded delay, loss and duplication, reorder by delay, and a
//! reachability matrix for partitions. It is a `Transport`.
//!
//! STUB (plan 004 item 2, Red step): the shapes and error set are final, the behavior is not.
//! Every method does nothing or returns a deliberately wrong value so the tests in
//! `network_test.zig` and `network_model_test.zig` fail until the zig-developer implements it.
//! The tests read exactly two fields, `counters` and `used`, to provoke `InvariantError`.
//!
//! Allocation: `init` only (messages_max + 1 slots with owned entry bytes, the matrix).

const std = @import("std");
const Allocator = std.mem.Allocator;
const interfaces = @import("../interfaces.zig");
const types = @import("../types.zig");
const clock_module = @import("clock.zig");
const prng_module = @import("prng.zig");

const Message = types.Message;
const Prng = prng_module.Prng;
const VirtualClock = clock_module.VirtualClock;

pub const Network = struct {
    pub const Fault = enum(u8) { none = 1, forge_votes = 2, flip_data = 3 };

    pub const Model = struct {
        messages_max: u32,
        delay_ms_min: u32,
        delay_ms_max: u32,
        loss_percent: u8,
        duplicate_percent: u8,
    };

    pub const Options = struct {
        nodes_count: u8,
        message_limits: Message.Limits,
        model: Model,
        fault: Fault,
    };

    /// 0-based slots; node id = slot + 1.
    pub const Link = struct { from_index: u8, to_index: u8 };

    pub const Stats = struct {
        sent: u64,
        delivered: u64,
        duplicated: u64,
        dropped_loss: u64,
        dropped_full: u64,
        dropped_cut: u64,
        dropped_down: u64,
    };

    /// `NetworkStatsDiverged`: sent + duplicated != delivered + dropped_* + in_flight.
    /// `NetworkTableOverfull`: more messages in flight than `messages_max`.
    pub const InvariantError = error{ NetworkStatsDiverged, NetworkTableOverfull };

    options: Options,
    /// The running counters `stats()` returns; tests corrupt them to provoke the invariant.
    counters: Stats,
    /// Occupied in-flight slots, what `in_flight()` returns; tests corrupt it likewise.
    used: u32,

    pub fn init(
        network: *Network,
        gpa: Allocator,
        options: *const Options,
        virtual_clock: *VirtualClock,
        prng: Prng,
    ) Allocator.Error!void {
        _ = .{ gpa, virtual_clock, prng };
        network.* = .{ .options = options.*, .counters = std.mem.zeroes(Stats), .used = 0 };
    }

    pub fn deinit(network: *Network, gpa: Allocator) void {
        _ = .{ network, gpa };
    }

    /// Bytes `init` requests from `gpa`, summed over its allocations.
    pub fn bytes_required(options: *const Options) u64 {
        _ = options;
        return 0;
    }

    pub fn send(network: *Network, message: *const Message) void {
        _ = .{ network, message };
    }

    pub fn set_partition(network: *Network, side_a: []const u8, side_b: []const u8) void {
        _ = .{ network, side_a, side_b };
    }

    pub fn cut(network: *Network, link: Link) void {
        _ = .{ network, link };
    }

    pub fn heal(network: *Network) void {
        _ = network;
    }

    pub fn reachable(network: *const Network, link: Link) bool {
        _ = .{ network, link };
        return false;
    }

    pub fn next_due_ms(network: *const Network) ?u64 {
        _ = network;
        return null;
    }

    pub fn pop_due(network: *Network) ?*const Message {
        _ = network;
        return null;
    }

    pub fn drop_down(network: *Network) void {
        _ = network;
    }

    pub fn in_flight(network: *const Network) u32 {
        return network.used;
    }

    pub fn trace_hash(network: *const Network) u64 {
        _ = network;
        return 0;
    }

    pub fn stats(network: *const Network) Stats {
        return network.counters;
    }

    pub fn check_invariants(network: *const Network) InvariantError!void {
        _ = network;
    }

    pub fn as_transport(network: *Network) interfaces.Transport {
        return interfaces.Transport.init(network);
    }
};
