//! synod.store — `MemoryStore`, the in-memory `LogStore` for tests and simulation.
//!
//! Purpose: a `LogStore` (interfaces.zig) with no disk and no `Io`, so the simulator and the
//! unit tests can stand in for a real durable store. Behaviour is pinned by
//! `store_conformance.zig`, the one suite every implementation (including the future strata
//! adapter, PRD 6B) must pass. `store_conformance` is re-exported here as `conformance`.
//!
//! Invariants (`check_invariants`): `entries[i]` holds index `base_index + 1 + i` for
//! `i < count`, terms are non-zero and non-decreasing, and the entry bytes are packed back to
//! back at the start of `data` in entry order, `data_used` bytes in all. A snapshot record
//! exists exactly when `base_index != .zero`, and every slice in it points into the store's own
//! buffers.
//!
//! Allocation and ownership: `init` allocates four buffers from `gpa` sized by `Options`
//! (Tiger Style §1.9); no method allocates afterwards and no allocator is stored. `deinit` takes
//! the same `gpa`. The store copies everything it is given (entry data, snapshot data, node
//! lists) and lends borrowed views on read, valid until the next mutating call. Values it is
//! handed must not alias its own buffers.
//!
//! Durability: none. Every mutation is visible at once and `sync` is a no-op, which trivially
//! satisfies "durable once `sync` returns"; a crash-losing variant belongs to the simulator.
//!
//! Cost: `append`/`get`/`last_index` touch O(batch) bytes; `truncate` is O(1); a compacting
//! `save_snapshot` moves the retained suffix once (O(count + data_used)). Simplicity over speed
//! is deliberate here: this store exists for determinism, not throughput.
//!
//! The plan (002 item 1D) sketched this over `log.Log`. `Log` is a contiguous run from index 1
//! with borrowed entry data, so it can neither start above a snapshot nor own bytes; the store
//! therefore keeps its own window, sharing only the `LogStore` contract.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

pub const conformance = @import("store_conformance.zig");

const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const NodeId = types.NodeId;
const Snapshot = types.Snapshot;
const SnapshotRecord = interfaces.SnapshotRecord;
const Term = types.Term;

/// Construction-time limits for `MemoryStore.init`. Passed explicitly; no default.
pub const Options = struct {
    /// Most entries held at once. Precondition: `> 0`.
    entries_max: u32,
    /// Most entry-data bytes held at once, summed over all entries.
    data_bytes_max: u32,
    /// Most snapshot-data bytes held at once.
    snapshot_bytes_max: u32,
};

/// What `check_invariants` can find wrong. Any of these is a bug in this file.
pub const InvariantError = error{
    CountOverCapacity,
    DataOverCapacity,
    EntryIndexGap,
    EntryTermInvalid,
    EntryDataMisplaced,
    SnapshotMissing,
    SnapshotUnexpected,
    SnapshotMisplaced,
};

pub const MemoryStore = struct {
    /// Entry window, `entries_max` slots; `entries[i].index == base_index + 1 + i`.
    entries: []Entry,
    /// Packed entry bytes, `data_bytes_max` long.
    data: []u8,
    /// Snapshot payload, `snapshot_bytes_max` long.
    snapshot_data: []u8,
    /// Snapshot node lists, laid out voters, voters_outgoing, learners.
    node_ids: []NodeId,
    /// Live entries in `entries[0..count]`.
    count: u32,
    /// Bytes of `data` in use.
    data_used: u32,
    /// Index and term of the saved snapshot, `.zero` for both when there is none.
    base_index: Index,
    base_term: Term,
    hard_state: HardState,
    snapshot: ?SnapshotRecord,

    /// Allocates the four buffers from `gpa`. Precondition: `options.entries_max > 0`; `target`
    /// is not initialised. On error nothing is left allocated. The buffers live on the heap;
    /// `target` itself must stay at a stable address while a `LogStore` built from it is used.
    pub fn init(target: *MemoryStore, gpa: Allocator, options: Options) Allocator.Error!void {
        assert(options.entries_max > 0);
        const nodes_count = 2 * types.voters_max + types.learners_max;

        const entries = try gpa.alloc(Entry, options.entries_max);
        errdefer gpa.free(entries);

        const data = try gpa.alloc(u8, options.data_bytes_max);
        errdefer gpa.free(data);

        const snapshot_data = try gpa.alloc(u8, options.snapshot_bytes_max);
        errdefer gpa.free(snapshot_data);

        const node_ids = try gpa.alloc(NodeId, nodes_count);
        errdefer gpa.free(node_ids);

        target.* = .{
            .entries = entries,
            .data = data,
            .snapshot_data = snapshot_data,
            .node_ids = node_ids,
            .count = 0,
            .data_used = 0,
            .base_index = .zero,
            .base_term = .zero,
            .hard_state = HardState.empty,
            .snapshot = null,
        };
        assert(target.entries.len == options.entries_max);
        assert(target.last_index() == Index.zero);
    }

    /// Frees what `init` allocated with the same `gpa`. Precondition: `init` succeeded and
    /// `deinit` has not run on `self` (a second call is not detected).
    pub fn deinit(self: *MemoryStore, gpa: Allocator) void {
        assert(self.entries.len > 0);
        assert(self.count <= self.entries.len);
        gpa.free(self.entries);
        gpa.free(self.data);
        gpa.free(self.snapshot_data);
        gpa.free(self.node_ids);
        self.* = undefined;
    }

    /// Asserts nothing; walks the state and names the first broken invariant. Call after every
    /// mutation in tests. Cost O(count).
    pub fn check_invariants(self: *const MemoryStore) InvariantError!void {
        if (self.count > self.entries.len) return error.CountOverCapacity;
        if (self.data_used > self.data.len) return error.DataOverCapacity;
        var offset: usize = 0;
        var term_floor: u64 = @intFromEnum(self.base_term);
        for (self.entries[0..self.count], 0..) |entry, position| {
            const expected = @intFromEnum(self.base_index) + 1 + position;
            if (@intFromEnum(entry.index) != expected) return error.EntryIndexGap;
            if (entry.term == Term.zero) return error.EntryTermInvalid;
            if (@intFromEnum(entry.term) < term_floor) return error.EntryTermInvalid;
            term_floor = @intFromEnum(entry.term);
            if (@intFromPtr(entry.data.ptr) != @intFromPtr(self.data.ptr) + offset) {
                return error.EntryDataMisplaced;
            }
            offset += entry.data.len;
        }
        if (offset != self.data_used) return error.EntryDataMisplaced;
        try self.check_snapshot_invariants();
    }

    fn check_snapshot_invariants(self: *const MemoryStore) InvariantError!void {
        const record = self.snapshot orelse {
            if (self.base_index != Index.zero) return error.SnapshotMissing;
            return;
        };
        if (self.base_index == Index.zero) return error.SnapshotUnexpected;
        if (record.snapshot.index != self.base_index) return error.SnapshotMisplaced;
        if (record.snapshot.term != self.base_term) return error.SnapshotMisplaced;
        if (record.snapshot.data.len > self.snapshot_data.len) return error.SnapshotMisplaced;
        if (@intFromPtr(record.snapshot.data.ptr) != @intFromPtr(self.snapshot_data.ptr)) {
            return error.SnapshotMisplaced;
        }
        const nodes = record.configuration.voters.len +
            record.configuration.voters_outgoing.len + record.configuration.learners.len;
        if (nodes > self.node_ids.len) return error.SnapshotMisplaced;
        if (record.configuration.voters.ptr != self.node_ids.ptr) return error.SnapshotMisplaced;
    }

    // -----------------------------------------------------------------------------------
    // LogStore methods (reached through `LogStore.init(&memory)`).
    // -----------------------------------------------------------------------------------

    pub fn last_index(self: *MemoryStore) Index {
        assert(self.count <= self.entries.len);
        const last = @intFromEnum(self.base_index) + self.count;
        return @enumFromInt(last);
    }

    /// Precondition: `entries` continue the log (`entries[0].index == last_index().next()`) and
    /// their first term is not below the last term held.
    pub fn append(self: *MemoryStore, entries: []const Entry) LogStore.WriteError!void {
        assert(entries.len > 0);
        assert(entries[0].index == self.last_index().next());
        assert(entries[0].term.order(self.last_term()) != .lt);
        if (entries.len > self.entries.len - self.count) return error.StoreFull;
        var bytes: usize = 0;
        for (entries) |entry| bytes += entry.data.len;
        if (bytes > self.data.len - self.data_used) return error.StoreFull;

        const count_before = self.count;
        for (entries) |entry| {
            const start = self.data_used;
            @memcpy(self.data[start..][0..entry.data.len], entry.data);
            self.entries[self.count] = entry;
            self.entries[self.count].data = self.data[start..][0..entry.data.len];
            self.data_used += @intCast(entry.data.len);
            self.count += 1;
        }
        assert(self.count == count_before + entries.len);
        assert(self.last_index() == entries[entries.len - 1].index);
    }

    /// Precondition: `from` in `base_index + 1 ..= last_index().next()`.
    pub fn truncate(self: *MemoryStore, from: Index) LogStore.UpdateError!void {
        assert(from.order(self.base_index) == .gt);
        assert(from.order(self.last_index().next()) != .gt);
        const keep: u32 = @intCast(@intFromEnum(from) - @intFromEnum(self.base_index) - 1);
        assert(keep <= self.count);
        if (keep < self.count) {
            const start = @intFromPtr(self.entries[keep].data.ptr) - @intFromPtr(self.data.ptr);
            self.data_used = @intCast(start);
            self.count = keep;
        }
        assert(self.last_index().next() == from);
    }

    /// Precondition: `index` in `base_index + 1 ..= last_index()`.
    pub fn get(self: *MemoryStore, index: Index) LogStore.ReadError!Entry {
        assert(index.order(self.base_index) == .gt);
        assert(index.order(self.last_index()) != .gt);
        const position = @intFromEnum(index) - @intFromEnum(self.base_index) - 1;
        const found = self.entries[position];
        assert(found.index == index);
        return found;
    }

    pub fn save_hard_state(
        self: *MemoryStore,
        hard_state: *const HardState,
    ) LogStore.UpdateError!void {
        assert(hard_state.commit_index.order(self.last_index()) != .gt);
        self.hard_state = hard_state.*;
        assert(self.hard_state.eql(hard_state));
    }

    pub fn load_hard_state(self: *MemoryStore) LogStore.ReadError!HardState {
        // No commit-vs-log assert: a caller that truncated below its commit gets `StoreCorrupt`
        // from `LogStore.load_hard_state`, the contract's answer for an incoherent record.
        assert(self.count <= self.entries.len);
        return self.hard_state;
    }

    /// Precondition: `snapshot.index` is above the previous snapshot's. Nothing changes on
    /// `StoreFull`.
    pub fn save_snapshot(
        self: *MemoryStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) LogStore.WriteError!void {
        assert(snapshot.index.order(self.base_index) == .gt);
        assert(configuration.voters.len <= types.voters_max);
        if (snapshot.data.len > self.snapshot_data.len) return error.StoreFull;

        const last_before = self.last_index();
        if (self.holds_term(snapshot.index, snapshot.term)) {
            self.compact_to(snapshot.index);
        } else {
            self.count = 0;
            self.data_used = 0;
        }
        self.base_index = snapshot.index;
        self.base_term = snapshot.term;
        self.snapshot = self.copy_snapshot(snapshot, configuration);
        assert(self.last_index().order(snapshot.index) != .lt);
        if (last_before.order(snapshot.index) == .gt) {
            assert(self.last_index().order(last_before) != .gt); // Only a conflict shrinks it.
        }
    }

    pub fn load_snapshot(self: *MemoryStore) LogStore.ReadError!?SnapshotRecord {
        assert((self.snapshot == null) == (self.base_index == Index.zero));
        return self.snapshot;
    }

    /// Nothing to flush: every mutation is already as durable as this store gets.
    pub fn sync(self: *MemoryStore) LogStore.UpdateError!void {
        assert(self.count <= self.entries.len);
        assert(self.data_used <= self.data.len);
    }

    // -----------------------------------------------------------------------------------
    // Helpers.
    // -----------------------------------------------------------------------------------

    /// The term of the last entry held, or the snapshot's when the window is empty.
    fn last_term(self: *MemoryStore) Term {
        if (self.count == 0) return self.base_term;
        return self.entries[self.count - 1].term;
    }

    /// True when `index` is in the window and its entry has `term_value`.
    fn holds_term(self: *MemoryStore, index: Index, term_value: Term) bool {
        if (index.order(self.last_index()) == .gt) return false;
        assert(index.order(self.base_index) == .gt);
        const position = @intFromEnum(index) - @intFromEnum(self.base_index) - 1;
        return self.entries[position].term == term_value;
    }

    /// Drops entries `<= index`, sliding the rest (and their bytes) to the front. Precondition:
    /// `index` in `base_index + 1 ..= last_index()`.
    fn compact_to(self: *MemoryStore, index: Index) void {
        const drop: u32 = @intCast(@intFromEnum(index) - @intFromEnum(self.base_index));
        assert(drop >= 1);
        assert(drop <= self.count);
        const count_before = self.count;
        const data_before = self.data_used;
        // Entry bytes are packed in order, so the dropped prefix is exactly the bytes before
        // the first retained entry (or all of them when nothing is retained).
        const start: usize = if (drop < self.count)
            @intFromPtr(self.entries[drop].data.ptr) - @intFromPtr(self.data.ptr)
        else
            self.data_used;
        const kept = self.data_used - start;
        @memmove(self.data[0..kept], self.data[start..][0..kept]);
        var offset: usize = 0;
        for (drop..self.count) |source| {
            const length = self.entries[source].data.len;
            self.entries[source - drop] = self.entries[source];
            self.entries[source - drop].data = self.data[offset..][0..length];
            offset += length;
        }
        self.count -= drop;
        self.data_used = @intCast(offset);
        assert(offset == kept);
        assert(self.count == count_before - drop);
        assert(self.data_used <= data_before);
    }

    /// Copies `snapshot` and `configuration` into the store's buffers and returns the record
    /// viewing them. Precondition: `snapshot.data` fits; the node lists satisfy `Configuration`
    /// limits.
    fn copy_snapshot(
        self: *MemoryStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) SnapshotRecord {
        assert(snapshot.data.len <= self.snapshot_data.len);
        @memcpy(self.snapshot_data[0..snapshot.data.len], snapshot.data);
        const lists = [_][]const NodeId{
            configuration.voters, configuration.voters_outgoing, configuration.learners,
        };
        var views: [3][]const NodeId = undefined;
        var used: usize = 0;
        for (lists, 0..) |list, which| {
            assert(used + list.len <= self.node_ids.len);
            @memcpy(self.node_ids[used..][0..list.len], list);
            views[which] = self.node_ids[used..][0..list.len];
            used += list.len;
        }
        return .{
            .snapshot = .{
                .index = snapshot.index,
                .term = snapshot.term,
                .data = self.snapshot_data[0..snapshot.data.len],
            },
            .configuration = .{
                .voters = views[0],
                .voters_outgoing = views[1],
                .learners = views[2],
            },
        };
    }
};

test {
    _ = @import("store_test.zig");
    _ = conformance;
}
