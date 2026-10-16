//! Red tests for `Node.init_bytes_max` and `Driver.init_bytes_max` (ADR-008 "Consequences" 1,
//! plan 004 item 4). The contract: an upper bound, in bytes, on everything `init` allocates for
//! a `Config`, alignment slack included, so a simulation can give every node one
//! `FixedBufferAllocator` and a restart (reset the buffer, `Driver.init` again) never allocates
//! from the heap mid-run.
//!
//! Method: the bound is checked against a `FixedBufferAllocator` of exactly that size placed at
//! an odd address (the worst start alignment), against the requested bytes a counting
//! allocator sees (a lower bound; and at most 64 bytes of slack per allocation, an upper one),
//! and for monotonicity in every `Config` field that sizes an allocation. Nothing here reads
//! the implementation; the bound is whatever satisfies these properties.
//!
//! Allocation: `std.testing.allocator` for the buffers, so a leak fails the test.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const interfaces = @import("interfaces.zig");
const raft = @import("raft.zig");
const types = @import("types.zig");
const fx = @import("raft/fixtures.zig");
const store_module = @import("store.zig");
const driver_module = @import("driver.zig");

const Driver = driver_module.Driver;
const Entry = types.Entry;
const Message = types.Message;
const Node = raft.Node;
const StateMachine = interfaces.StateMachine;

const slack_per_allocation = 64;

const roomy: raft.Config = blk: {
    var result = fx.config5;
    result.learners_max = 4;
    result.inflight_max = 8;
    result.log_entries_max = 64;
    result.log_bytes_max = 512;
    break :blk result;
};

const cases = [_]raft.Config{ fx.config, fx.config5, roomy };

/// A buffer of `bytes` bytes whose first byte is misaligned: the worst case for slack.
fn odd_buffer(bytes: u64) ![]align(16) u8 {
    return testing.allocator.alignedAlloc(u8, .@"16", @intCast(bytes + 1));
}

fn expect_node_fits(config: raft.Config) !void {
    const bound = Node.init_bytes_max(&config);
    const floor: u64 = config.log_bytes_max +
        @as(u64, config.log_entries_max) * @sizeOf(Entry);
    try testing.expect(bound >= floor); // The entry array and the byte arena alone.

    const raw = try odd_buffer(bound);
    defer testing.allocator.free(raw);
    var fba = std.heap.FixedBufferAllocator.init(raw[1..]);
    var rig: fx.Rig = undefined;
    const restore = fx.restore_of(fx.hard_state_of(0, 0, 0), &.{});
    try rig.init(fba.allocator(), config, &restore, 1);
    defer rig.deinit(fba.allocator());
    try testing.expect(fba.end_index <= bound);
    try testing.expect(fba.end_index > 0);
}

test "init_bytes_max: Node.init fits a buffer of exactly that size at an odd address" {
    for (cases) |config| try expect_node_fits(config);
}

test "init_bytes_max: Node bound lies between the requested bytes and 64 bytes of slack each" {
    for (cases) |config| {
        var counting = testing.FailingAllocator.init(testing.allocator, .{});
        var rig: fx.Rig = undefined;
        const restore = fx.restore_of(fx.hard_state_of(0, 0, 0), &.{});
        try rig.init(counting.allocator(), config, &restore, 1);
        defer rig.deinit(counting.allocator());
        const bound = Node.init_bytes_max(&config);
        try testing.expect(counting.alloc_index >= 6); // Log, arena, lists, effects, leader.
        try testing.expect(bound >= counting.allocated_bytes);
        try testing.expect(bound <= counting.allocated_bytes +
            @as(u64, counting.alloc_index) * slack_per_allocation);
    }
}

test "init_bytes_max: Node bound is pure and grows with every field that sizes an allocation" {
    const base = Node.init_bytes_max(&fx.config);
    try testing.expectEqual(base, Node.init_bytes_max(&fx.config));

    var more_entries = fx.config;
    more_entries.log_entries_max += 8;
    try testing.expect(Node.init_bytes_max(&more_entries) > base);

    var more_bytes = fx.config;
    more_bytes.log_bytes_max += 64;
    try testing.expect(Node.init_bytes_max(&more_bytes) >= base + 64);

    var more_voters = fx.config;
    more_voters.voters_max += 2;
    try testing.expect(Node.init_bytes_max(&more_voters) > base);

    var more_learners = fx.config;
    more_learners.learners_max += 2;
    try testing.expect(Node.init_bytes_max(&more_learners) > base);

    var more_inflight = fx.config;
    more_inflight.inflight_max += 4;
    try testing.expect(Node.init_bytes_max(&more_inflight) >= base);
}

// ---- Driver ---------------------------------------------------------------------------------

/// Deaf and mute seams: only `Driver.init` runs here, so nothing is ever sent or applied.
const Seams = struct {
    dummy: u8 = 0,

    pub fn send(seams: *Seams, message: *const Message) void {
        _ = .{ seams, message };
    }

    pub fn now_ms(seams: *Seams) u64 {
        _ = seams;
        return 0;
    }

    pub fn next_u64(seams: *Seams) u64 {
        seams.dummy +%= 1;
        return @as(u64, seams.dummy) *% 0x9e3779b97f4a7c15;
    }

    pub fn apply(seams: *Seams, entry: *const Entry) StateMachine.ApplyError!void {
        _ = .{ seams, entry };
    }

    pub fn snapshot(seams: *Seams, writer: *std.Io.Writer) StateMachine.SnapshotError!void {
        _ = .{ seams, writer };
    }

    pub fn restore(seams: *Seams, reader: *std.Io.Reader) StateMachine.RestoreError!void {
        _ = .{ seams, reader };
    }
};

/// A store holding a full log (`log_entries_max` entries), the largest restore there is.
fn full_store(store: *store_module.MemoryStore, config: raft.Config) !void {
    try store.init(testing.allocator, .{
        .entries_max = config.log_entries_max,
        .data_bytes_max = config.log_bytes_max,
        .snapshot_bytes_max = 0,
    });
    var entries: [64]Entry = undefined;
    assert(config.log_entries_max <= entries.len);
    const log = fx.fill_entries(&entries, config.log_entries_max, 1);
    try interfaces.LogStore.init(store).append(log);
    // The entries are in term 1, so a consistent restore needs a hard state of at least that.
    const hard_state = fx.hard_state_of(1, 0, 0);
    try interfaces.LogStore.init(store).save_hard_state(&hard_state);
}

fn driver_boot(
    driver: *Driver,
    gpa: std.mem.Allocator,
    config: raft.Config,
    store: *store_module.MemoryStore,
    seams: *Seams,
) !void {
    const deps: Driver.Deps = .{
        .store = interfaces.LogStore.init(store),
        .transport = interfaces.Transport.init(seams),
        .state_machine = StateMachine.init(seams),
        .clock = interfaces.Clock.init(seams),
        .rng = interfaces.Rng.init(seams),
    };
    const options: Driver.Options = .{ .tick_ms = 10, .ticks_per_poll_max = 2 };
    try driver.init(testing.io, gpa, config, options, &fx.configuration, deps);
}

test "init_bytes_max: Driver.init over a full log fits a buffer of exactly that size, twice" {
    for (cases) |config| {
        const bound = Driver.init_bytes_max(&config);
        const node_bound = Node.init_bytes_max(&config);
        const scratch = @as(u64, config.log_entries_max) * @sizeOf(Entry);
        try testing.expect(bound >= node_bound + scratch); // Nodes plus the restore scratch.

        var store: store_module.MemoryStore = undefined;
        try full_store(&store, config);
        defer store.deinit(testing.allocator);
        const raw = try odd_buffer(bound);
        defer testing.allocator.free(raw);
        var fba = std.heap.FixedBufferAllocator.init(raw[1..]);
        var seams: Seams = .{};

        var driver: Driver = undefined;
        try driver_boot(&driver, fba.allocator(), config, &store, &seams);
        try testing.expectEqual(config.log_entries_max, @as(u32, @intCast(
            @intFromEnum(driver.node.status().last_index),
        )));
        try testing.expect(fba.end_index <= bound);
        driver.deinit(testing.io, fba.allocator());

        fba.reset(); // A restart: same buffer, fresh Driver.init over the same store.
        try driver_boot(&driver, fba.allocator(), config, &store, &seams);
        try testing.expect(fba.end_index <= bound);
        driver.deinit(testing.io, fba.allocator());
    }
}

test "init_bytes_max: Driver bound is at least Node's and never smaller for a bigger log" {
    var small = fx.config;
    small.log_entries_max = 4;
    var large = fx.config;
    large.log_entries_max = 16;
    try testing.expect(Driver.init_bytes_max(&small) >= Node.init_bytes_max(&small));
    try testing.expect(Driver.init_bytes_max(&large) > Driver.init_bytes_max(&small));
    try testing.expectEqual(Driver.init_bytes_max(&large), Driver.init_bytes_max(&large));
}

test "init_bytes_max: Driver.init with a restore beyond log_entries_max still refuses cleanly" {
    // The bound sizes the scratch by `log_entries_max`; a larger store is refused first
    // (RestoreLogFull) and allocates nothing, so the bound is never what a bad store needs.
    var config = fx.config;
    config.log_entries_max = 4;
    var store: store_module.MemoryStore = undefined;
    try store.init(testing.allocator, .{
        .entries_max = 8,
        .data_bytes_max = 8,
        .snapshot_bytes_max = 0,
    });
    defer store.deinit(testing.allocator);
    var entries: [8]Entry = undefined;
    try interfaces.LogStore.init(&store).append(fx.fill_entries(&entries, 8, 1));

    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var seams: Seams = .{};
    var driver: Driver = undefined;
    const result = driver_boot(&driver, counting.allocator(), config, &store, &seams);
    try testing.expectError(error.RestoreLogFull, result);
    try testing.expectEqual(@as(usize, 0), counting.alloc_index);
}
