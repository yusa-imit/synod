//! synod.store_conformance — one behavioural suite for every `LogStore` implementation.
//!
//! Purpose: `conformance(store)` drives a fresh store only through the `LogStore` vtable, so the
//! in-memory store and the future strata adapter (PRD 6B) are held to the same contract by the
//! same code (ADR-003's paired-path requirement). Nothing here names a concrete store.
//!
//! Contract of the caller: `store` is fresh (empty log, no hard state, no snapshot) and has room
//! for at least `entries_min` entries, `data_bytes_min` entry-data bytes and `snapshot_bytes_min`
//! snapshot bytes at once. The suite mutates it; hand it a throwaway instance.
//!
//! Allocation: none. Failures are reported as test errors, so call it from a `test` block.

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const LogStore = interfaces.LogStore;
const NodeId = types.NodeId;
const Snapshot = types.Snapshot;
const Term = types.Term;

/// Capacity a store must offer for `conformance` to run.
pub const entries_min: u32 = 8;
pub const data_bytes_min: u32 = 64;
pub const snapshot_bytes_min: u32 = 32;

/// Runs every case in order against `store`. Precondition: `store` is fresh (see module doc).
pub fn conformance(store: LogStore) !void {
    assert(entries_min > 0);
    try case_fresh(store);
    try case_append_get(store);
    try case_data_is_copied(store);
    try case_hard_state(store);
    try case_truncate_then_append(store);
    try case_snapshot_compaction(store);
    try case_snapshot_install(store);
    try case_snapshot_conflict(store);
    try case_sync_is_neutral(store);
}

fn idx(value: u64) Index {
    return @enumFromInt(value);
}

fn term(value: u64) Term {
    return @enumFromInt(value);
}

fn node(value: u64) NodeId {
    return @enumFromInt(value);
}

fn entry(index: u64, term_value: u64, data: []const u8) Entry {
    return .{ .index = idx(index), .term = term(term_value), .kind = .normal, .data = data };
}

fn expect_entry(store: LogStore, index: u64, term_value: u64, data: []const u8) !void {
    const found = try store.get(idx(index));
    try expectEqual(idx(index), found.index);
    try expectEqual(term(term_value), found.term);
    try expectEqualSlices(u8, data, found.data);
}

/// A fresh store has no log, no hard state and no snapshot.
fn case_fresh(store: LogStore) !void {
    try expectEqual(Index.zero, store.last_index());
    const hard_state = try store.load_hard_state();
    try expect(hard_state.eql(&HardState.empty));
    try expect((try store.load_snapshot()) == null);
}

/// Two batches append contiguously; every entry reads back with its term, kind and data.
fn case_append_get(store: LogStore) !void {
    try store.append(&.{ entry(1, 1, "a"), entry(2, 1, "") });
    try expectEqual(idx(2), store.last_index());
    try store.append(&.{ entry(3, 2, "ccc"), .{
        .index = idx(4),
        .term = term(2),
        .kind = .conf_change,
        .data = "cc",
    }, entry(5, 3, "e") });
    try expectEqual(idx(5), store.last_index());
    try expect_entry(store, 1, 1, "a");
    try expect_entry(store, 2, 1, "");
    try expect_entry(store, 3, 2, "ccc");
    try expect_entry(store, 5, 3, "e");
    const conf = try store.get(idx(4));
    try expectEqual(types.EntryKind.conf_change, conf.kind);
    try expectEqualSlices(u8, "cc", conf.data);
}

/// `append` copies `data`: scribbling over the caller's buffer afterwards changes nothing.
fn case_data_is_copied(store: LogStore) !void {
    var scratch = [_]u8{ 'x', 'y' };
    try store.append(&.{entry(6, 3, &scratch)});
    scratch = .{ 'z', 'z' };
    try expect_entry(store, 6, 3, "xy");
    try store.truncate(idx(6));
    try expectEqual(idx(5), store.last_index());
}

/// Hard state round-trips whole, and a later save replaces the earlier one.
fn case_hard_state(store: LogStore) !void {
    const first: HardState = .{ .term = term(3), .vote = node(2), .commit_index = idx(2) };
    try store.save_hard_state(&first);
    const loaded = try store.load_hard_state();
    try expect(loaded.eql(&first));
    const second: HardState = .{ .term = term(4), .vote = .none, .commit_index = idx(2) };
    try store.save_hard_state(&second);
    try expect((try store.load_hard_state()).eql(&second));
}

/// Truncation drops a suffix; a new suffix appended at the cut is what reads back.
fn case_truncate_then_append(store: LogStore) !void {
    try store.truncate(idx(4));
    try expectEqual(idx(3), store.last_index());
    try expect_entry(store, 3, 2, "ccc");
    try store.truncate(idx(4)); // At last + 1: a legal no-op.
    try expectEqual(idx(3), store.last_index());
    try store.append(&.{ entry(4, 4, "new4"), entry(5, 4, "new5") });
    try expectEqual(idx(5), store.last_index());
    try expect_entry(store, 3, 2, "ccc");
    try expect_entry(store, 4, 4, "new4");
    try expect_entry(store, 5, 4, "new5");
}

/// A snapshot at an index whose term matches keeps the suffix above it (compaction).
fn case_snapshot_compaction(store: LogStore) !void {
    const voters = [_]NodeId{ node(1), node(2), node(3) };
    const learners = [_]NodeId{node(9)};
    const configuration: Configuration = .{
        .voters = &voters,
        .voters_outgoing = &.{},
        .learners = &learners,
    };
    var data = [_]u8{ 's', 'n', 'p' };
    const snapshot: Snapshot = .{ .index = idx(3), .term = term(2), .data = &data };
    try store.save_snapshot(&snapshot, &configuration);
    data = .{ 0, 0, 0 };
    try expectEqual(idx(5), store.last_index());
    try expect_entry(store, 4, 4, "new4");
    try expect_entry(store, 5, 4, "new5");
    const record = (try store.load_snapshot()).?;
    try expectEqual(idx(3), record.snapshot.index);
    try expectEqual(term(2), record.snapshot.term);
    try expectEqualSlices(u8, "snp", record.snapshot.data);
    try expectEqualSlices(NodeId, &voters, record.configuration.voters);
    try expectEqualSlices(NodeId, &learners, record.configuration.learners);
    try expectEqual(@as(usize, 0), record.configuration.voters_outgoing.len);
}

/// A snapshot beyond the log replaces it entirely (install); appends resume after it.
fn case_snapshot_install(store: LogStore) !void {
    const voters = [_]NodeId{ node(1), node(2) };
    const outgoing = [_]NodeId{node(1)};
    const configuration: Configuration = .{
        .voters = &voters,
        .voters_outgoing = &outgoing,
        .learners = &.{},
    };
    const snapshot: Snapshot = .{ .index = idx(8), .term = term(5), .data = "" };
    try store.save_snapshot(&snapshot, &configuration);
    try expectEqual(idx(8), store.last_index());
    const record = (try store.load_snapshot()).?;
    try expectEqual(idx(8), record.snapshot.index);
    try expectEqual(@as(usize, 0), record.snapshot.data.len);
    try expectEqualSlices(NodeId, &outgoing, record.configuration.voters_outgoing);
    try expectEqual(@as(usize, 0), record.configuration.learners.len); // No stale list.
    try store.append(&.{entry(9, 5, "after")});
    try expect_entry(store, 9, 5, "after");
    try expectEqual(idx(9), store.last_index());
}

/// A snapshot inside the log whose term disagrees with the entry there drops everything.
fn case_snapshot_conflict(store: LogStore) !void {
    try store.append(&.{ entry(10, 5, "ten"), entry(11, 6, "eleven") });
    const voters = [_]NodeId{node(4)};
    const configuration: Configuration = .{
        .voters = &voters,
        .voters_outgoing = &.{},
        .learners = &.{},
    };
    const snapshot: Snapshot = .{ .index = idx(10), .term = term(7), .data = "other" };
    try store.save_snapshot(&snapshot, &configuration);
    try expectEqual(idx(10), store.last_index());
    const record = (try store.load_snapshot()).?;
    try expectEqual(term(7), record.snapshot.term);
    try expectEqualSlices(u8, "other", record.snapshot.data);
    try expectEqualSlices(NodeId, &voters, record.configuration.voters);
}

/// `sync` is a durability barrier only: it changes no observable state.
fn case_sync_is_neutral(store: LogStore) !void {
    const last_before = store.last_index();
    const hard_before = try store.load_hard_state();
    try store.sync();
    try expectEqual(last_before, store.last_index());
    try expect((try store.load_hard_state()).eql(&hard_before));
    try expect((try store.load_snapshot()) != null);
}
