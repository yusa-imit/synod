//! Test fixtures for `sim/network.zig` and `sim/simulation.zig`: the single construction path
//! for a test `Network` (`Rig`), message builders, an owned message description (`Spec`) the
//! model tests replay against a reference, a drain helper, and the `Simulation` helpers (the
//! options builder, leader and commit queries, the scripted-proposal loop). Test support only;
//! nothing here is public API.
//!
//! Allocation: only through the `gpa` the caller passes to `Rig.init`/`Rig.deinit`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const clock_module = @import("clock.zig");
const network_module = @import("network.zig");
const prng_module = @import("prng.zig");
const simulation_module = @import("simulation.zig");

const Entry = types.Entry;
const Header = types.Header;
const Message = types.Message;
const MessageKind = types.MessageKind;
const Network = network_module.Network;
const Prng = prng_module.Prng;
const VirtualClock = clock_module.VirtualClock;

pub const entries_max: u32 = 4;
pub const entry_bytes_max: u32 = 16;
pub const start_ms: u64 = 1000;

pub const limits: Message.Limits = .{
    .entries_max = entries_max,
    .entry_bytes_max = entry_bytes_max,
    .snapshot_bytes_max = 0,
};

/// A deterministic, lossless network: every message takes exactly 5 ms, 8 fit in flight.
pub const base_model: Network.Model = .{
    .messages_max = 8,
    .delay_ms_min = 5,
    .delay_ms_max = 5,
    .loss_percent = 0,
    .duplicate_percent = 0,
};

pub fn options_of(nodes_count: u8, model: Network.Model, fault: Network.Fault) Network.Options {
    return .{
        .nodes_count = nodes_count,
        .message_limits = limits,
        .model = model,
        .fault = fault,
    };
}

/// A `Network` and the clock it reads, in place: the network holds a pointer to `clock`.
pub const Rig = struct {
    clock: VirtualClock,
    network: Network,

    pub fn init(
        rig: *Rig,
        gpa: Allocator,
        options: Network.Options,
        seed: u64,
    ) Allocator.Error!void {
        rig.clock = VirtualClock.init(start_ms);
        try rig.network.init(gpa, &options, &rig.clock, Prng.init(seed));
    }

    pub fn deinit(rig: *Rig, gpa: Allocator) void {
        rig.network.deinit(gpa);
    }

    pub fn advance(rig: *Rig, delta_ms: u64) void {
        rig.clock.advance_to(rig.clock.time_ms + delta_ms);
    }
};

/// The link from node slot `from` to node slot `to` (0-based).
pub fn link_of(from: usize, to: usize) Network.Link {
    return .{ .from_index = @intCast(from), .to_index = @intCast(to) };
}

pub fn header(from: u64, to: u64, term: u64) Header {
    return .{
        .protocol_version = types.protocol_version_current,
        .term = @enumFromInt(term),
        .from = @enumFromInt(from),
        .to = @enumFromInt(to),
    };
}

pub fn vote(from: u64, to: u64, term: u64) Message {
    return .{ .request_vote = .{
        .header = header(from, to, term),
        .last_log_index = @enumFromInt(3),
        .last_log_term = @enumFromInt(2),
    } };
}

pub fn vote_response(from: u64, to: u64, term: u64, granted: bool) Message {
    return .{ .request_vote_response = .{ .header = header(from, to, term), .granted = granted } };
}

pub fn append(from: u64, to: u64, term: u64, entries: []const Entry) Message {
    return .{ .append_entries = .{
        .header = header(from, to, term),
        .prev_log_index = @enumFromInt(11),
        .prev_log_term = @enumFromInt(4),
        .leader_commit = @enumFromInt(9),
        .round = 77,
        .entries = entries,
    } };
}

pub fn entry_of(index: u64, term: u64, data: []const u8) Entry {
    return .{
        .index = @enumFromInt(index),
        .term = @enumFromInt(term),
        .kind = .normal,
        .data = data,
    };
}

/// Field-wise equality of two messages, entry bytes included (never pointer equality).
pub fn message_eql(a: *const Message, b: *const Message) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    if (!std.meta.eql(a.header().*, b.header().*)) return false;
    return switch (a.*) {
        .request_vote => |x| std.meta.eql(x, b.request_vote),
        .pre_vote => |x| std.meta.eql(x, b.pre_vote),
        .request_vote_response => |x| x.granted == b.request_vote_response.granted,
        .pre_vote_response => |x| x.granted == b.pre_vote_response.granted,
        .append_entries => |x| append_eql(&x, &b.append_entries),
        else => false,
    };
}

fn append_eql(a: *const types.AppendRequest, b: *const types.AppendRequest) bool {
    if (a.prev_log_index != b.prev_log_index or a.prev_log_term != b.prev_log_term) return false;
    if (a.leader_commit != b.leader_commit or a.round != b.round) return false;
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| {
        if (x.index != y.index or x.term != y.term or x.kind != y.kind) return false;
        if (!std.mem.eql(u8, x.data, y.data)) return false;
    }
    return true;
}

/// An owned description of a message, so a reference model can rebuild it at will.
pub const Spec = struct {
    pub const Kind = enum { vote, pre_vote, vote_response, pre_vote_response, append };

    kind: Kind,
    from: u64,
    to: u64,
    term: u64,
    flag: bool,
    count: u8,
    lens: [entries_max]u8,
    bytes: [entries_max][entry_bytes_max]u8,

    /// The borrowed `Message` for `spec`; `scratch` and `spec` must outlive it.
    pub fn build(spec: *const Spec, scratch: *[entries_max]Entry) Message {
        const head = header(spec.from, spec.to, spec.term);
        switch (spec.kind) {
            .vote => return vote(spec.from, spec.to, spec.term),
            .pre_vote => return .{ .pre_vote = vote(spec.from, spec.to, spec.term).request_vote },
            .vote_response => return vote_response(spec.from, spec.to, spec.term, spec.flag),
            .pre_vote_response => return .{ .pre_vote_response = .{
                .header = head,
                .granted = spec.flag,
            } },
            .append => {},
        }
        for (0..spec.count) |k| {
            scratch[k] = entry_of(k + 1, spec.term, spec.bytes[k][0..spec.lens[k]]);
        }
        return append(spec.from, spec.to, spec.term, scratch[0..spec.count]);
    }
};

/// A random message from node id `from` to node id `to`, tagged with `term` (a unique serial).
pub fn random_spec(prng: *Prng, from: u64, to: u64, term: u64) Spec {
    var spec: Spec = undefined;
    spec.kind = @enumFromInt(prng.uint_less_than(5));
    spec.from = from;
    spec.to = to;
    spec.term = term;
    spec.flag = prng.chance(50);
    spec.count = 0;
    spec.lens = @splat(0);
    spec.bytes = @splat(@splat(0));
    if (spec.kind != .append) return spec;
    spec.count = @intCast(prng.uint_less_than(entries_max + 1));
    for (0..spec.count) |k| {
        spec.lens[k] = @intCast(prng.uint_less_than(entry_bytes_max + 1));
        for (&spec.bytes[k]) |*byte| byte.* = @truncate(prng.next_u64());
    }
    return spec;
}

/// What a drain saw of one delivery: when, who, which message.
pub const Seen = struct { at_ms: u64, from: u64, to: u64, term: u64, kind: MessageKind };

pub fn seen_of(message: *const Message, at_ms: u64) Seen {
    const head = message.header();
    return .{
        .at_ms = at_ms,
        .from = @intFromEnum(head.from),
        .to = @intFromEnum(head.to),
        .term = @intFromEnum(head.term),
        .kind = std.meta.activeTag(message.*),
    };
}

/// Advances the clock from due time to due time, popping everything, until nothing is in
/// flight. Returns the deliveries in order; fails instead of spinning if delivery stalls.
pub fn drain(rig: *Rig, out: []Seen) error{TestUnexpectedResult}![]const Seen {
    var count: usize = 0;
    var rounds: u32 = 0;
    while (rig.network.next_due_ms()) |due| {
        rounds += 1;
        if (rounds > 4096) return error.TestUnexpectedResult;
        if (due > rig.clock.time_ms) rig.clock.advance_to(due);
        while (rig.network.pop_due()) |message| {
            if (count == out.len) return error.TestUnexpectedResult;
            out[count] = seen_of(message, rig.clock.time_ms);
            count += 1;
        }
    }
    assert(count <= out.len);
    return out[0..count];
}

// ---- Simulation helpers ---------------------------------------------------------------------

pub const Simulation = simulation_module.Simulation;
pub const SimOptions = simulation_module.Options;

/// `Options.quiet` with the test-sized limits (the preset already is one); the one place a
/// test starts from, so a preset change lands here.
pub fn sim_quiet(seed: u64, nodes_count: u8) SimOptions {
    const options = SimOptions.quiet(seed, nodes_count);
    assert(options.plant == .none);
    assert(options.nodes_count == nodes_count);
    return options;
}

/// The node slots among `members` whose role is leader right now.
pub fn leaders_among(simulation: *const Simulation, members: []const u8) u32 {
    var count: u32 = 0;
    for (members) |slot| {
        const status = simulation.status(slot) orelse continue;
        if (status.role == .leader) count += 1;
    }
    return count;
}

/// The first slot among `members` that leads right now, if any.
pub fn leader_among(simulation: *const Simulation, members: []const u8) ?u8 {
    for (members) |slot| {
        const status = simulation.status(slot) orelse continue;
        if (status.role == .leader) return slot;
    }
    return null;
}

/// The highest commit index any of the first `nodes_count` nodes reports.
pub fn commit_max(simulation: *const Simulation, nodes_count: u8) u64 {
    var most: u64 = 0;
    for (0..nodes_count) |slot| {
        const status = simulation.status(@intCast(slot)) orelse continue;
        most = @max(most, @intFromEnum(status.commit_index));
    }
    return most;
}

pub const nodes5 = [_]u8{ 0, 1, 2, 3, 4 };
pub const minority = [_]u8{ 0, 1 };
pub const majority = [_]u8{ 2, 3, 4 };

/// Proposes `data` to the first leader among `members`; the index it will occupy.
/// Fails with `error.TestUnexpectedResult` if none leads.
pub fn propose_to_leader(
    io: std.Io,
    simulation: *Simulation,
    members: []const u8,
    data: []const u8,
) !u64 {
    const slot = leader_among(simulation, members) orelse return error.TestUnexpectedResult;
    try simulation.propose(io, slot, data);
    const status = simulation.status(slot) orelse return error.TestUnexpectedResult;
    return @intFromEnum(status.last_index);
}

/// Steps one event at a time until the clock reaches `time_ms`, running every property check
/// after each event. Bounded by `steps_limit`; running out is `error.TestUnexpectedResult`.
pub fn step_checked(
    io: std.Io,
    simulation: *Simulation,
    time_ms: u64,
    steps_limit: u32,
) !void {
    var steps: u32 = 0;
    while (simulation.virtual_clock.time_ms < time_ms) {
        steps += 1;
        if (steps > steps_limit) return error.TestUnexpectedResult;
        try simulation.step(io);
        try check_all(simulation);
    }
}

/// All five properties hold right now.
pub fn check_all(simulation: *Simulation) !void {
    try simulation.check(.election_safety);
    try simulation.check(.leader_append_only);
    try simulation.check(.log_matching);
    try simulation.check(.leader_completeness);
    try simulation.check(.state_machine_safety);
}

/// Every slot below `count` except `slot`, written into `out` (the other side of a cut).
pub fn others_of(out: *[7]u8, count: u8, slot: u8) []const u8 {
    assert(count <= out.len);
    assert(slot < count);
    var len: usize = 0;
    for (0..count) |other| {
        if (other == slot) continue;
        out[len] = @intCast(other);
        len += 1;
    }
    return out[0..len];
}

/// Cuts node `slot` off from the other `count - 1` nodes, both directions.
pub fn isolate(simulation: *Simulation, count: u8, slot: u8) void {
    var storage: [7]u8 = undefined;
    const rest = others_of(&storage, count, slot);
    simulation.network.set_partition(&.{slot}, rest);
}
