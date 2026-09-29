//! synod.interfaces — the five injected-dependency vtables of ADR-006: `Transport`,
//! `LogStore`, `StateMachine`, `Clock`, `Rng`.
//!
//! Purpose: the Raft core and its driver see the network, the disk, the application, time and
//! randomness only through these types, so a deterministic simulator can stand in for each.
//!
//! Ownership: every interface is two words, `ptr` (the erased implementation) and `vtable`
//! (static, one per implementation type). An interface value never owns its implementation:
//! the caller keeps the implementation alive and at a stable address for as long as any
//! interface built from it is used. Nothing here stores an allocator.
//!
//! Allocation: none. Constructing an interface and every forwarding call are allocation-free;
//! entry, snapshot and message bytes are borrowed exactly as each method documents.
//!
//! Construction: `X.init(&impl)` is the only path. It runs at comptime, checks that `impl`'s
//! methods exist with the vtable's signatures (`@compileError` otherwise), and takes the address
//! of a per-type static vtable. Dispatch is runtime; the forwarding methods assert the caller's
//! contract, so every implementation is checked by the same code.

const std = @import("std");
const assert = std.debug.assert;
const types = @import("types.zig");

const Configuration = types.Configuration;
const Entry = types.Entry;
const HardState = types.HardState;
const Index = types.Index;
const Message = types.Message;
const Snapshot = types.Snapshot;
const Term = types.Term;

/// A snapshot together with the cluster configuration it was taken under. Both are borrowed
/// from the `LogStore` until its next mutating call.
pub const SnapshotRecord = struct {
    snapshot: Snapshot,
    configuration: Configuration,
};

// ---------------------------------------------------------------------------------------
// Comptime construction helpers
// ---------------------------------------------------------------------------------------

/// The implementation struct behind `impl`, which must be `*T` with `T` a non-zero-sized
/// struct (a zero-sized one has no distinct address to erase).
fn implType(comptime P: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
        @compileError("interface init expects a mutable single-item pointer *T, found " ++
            @typeName(P));
    }
    const T = info.pointer.child;
    if (@typeInfo(T) != .@"struct") {
        @compileError("interface implementation must be a struct, found " ++ @typeName(T));
    }
    if (@sizeOf(T) == 0) {
        @compileError("interface implementation must not be zero-sized: " ++ @typeName(T));
    }
    return T;
}

/// True when a method returning `Actual` can stand in for one declared to return `Expected`:
/// identical, or an error union with the same payload whose error set is a subset (it then
/// coerces in the generated thunk).
fn returnCompatible(comptime Actual: type, comptime Expected: type) bool {
    if (Actual == Expected) return true;
    const actual = @typeInfo(Actual);
    const expected = @typeInfo(Expected);
    if (actual != .error_union or expected != .error_union) return false;
    if (actual.error_union.payload != expected.error_union.payload) return false;
    const actual_errors = @typeInfo(actual.error_union.error_set).error_set orelse return false;
    const expected_errors = @typeInfo(expected.error_union.error_set).error_set orelse
        return true;
    inline for (actual_errors) |actual_error| {
        const found = inline for (expected_errors) |expected_error| {
            if (comptime std.mem.eql(u8, actual_error.name, expected_error.name)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// Compile error unless `T` declares method `name` as `fn (*T, params...) Return`.
fn requireMethod(
    comptime T: type,
    comptime name: []const u8,
    comptime params: []const type,
    comptime Return: type,
) void {
    const where = @typeName(T) ++ "." ++ name;
    if (!@hasDecl(T, name)) @compileError("missing interface method " ++ where);
    const method = @typeInfo(@TypeOf(@field(T, name)));
    if (method != .@"fn") @compileError(where ++ " must be a method");
    const function = method.@"fn";
    if (function.params.len != params.len + 1) {
        @compileError(where ++ " has the wrong parameter count");
    }
    if (function.params[0].type != *T) @compileError(where ++ " must take self as *" ++
        @typeName(T));
    inline for (params, 1..) |Param, i| {
        if (function.params[i].type != Param) {
            @compileError(where ++ " parameter type mismatch, expected " ++ @typeName(Param));
        }
    }
    if (!returnCompatible(function.return_type.?, Return)) {
        @compileError(where ++ " must return " ++ @typeName(Return));
    }
}

/// Recovers the typed implementation from the erased pointer stored in an interface.
fn cast(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

// ---------------------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------------------

/// Best-effort message delivery. The impl may drop, delay, duplicate, or reorder; it never
/// corrupts (adapter frames checksum, ADR-004).
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: *const Message) void,
    };

    /// Builds a `Transport` over `impl` (`*T`, `T` a non-zero-sized struct with
    /// `pub fn send(self: *T, message: *const Message) void`). `impl` must outlive the result.
    pub fn init(impl: anytype) Transport {
        const T = comptime implType(@TypeOf(impl));
        comptime requireMethod(T, "send", &.{*const Message}, void);
        return .{ .ptr = impl, .vtable = &Static(T).vtable };
    }

    fn Static(comptime T: type) type {
        return struct {
            fn call_send(ptr: *anyopaque, message: *const Message) void {
                return cast(T, ptr).send(message);
            }

            const vtable: VTable = .{ .send = call_send };
        };
    }

    /// Sends `message` to `message.header().to`. Precondition: protocol version non-zero,
    /// `from` and `to` not `.none`, `from != to`. `message` and every slice in it are borrowed
    /// for this call only: the impl encodes or copies before returning, never blocks on the
    /// network (a full bounded queue drops), and never re-enters the raft core.
    pub fn send(self: Transport, message: *const Message) void {
        const header = message.header();
        assert(header.protocol_version != 0);
        assert(header.from != .none);
        assert(header.to != .none);
        assert(header.from != header.to);
        self.vtable.send(self.ptr, message);
    }
};

// ---------------------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------------------

/// Monotonic time source; never wall time. The only clock the raft core may read.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_ms: *const fn (ptr: *anyopaque) u64,
    };

    /// Builds a `Clock` over `impl` (`*T`, `T` a non-zero-sized struct with
    /// `pub fn now_ms(self: *T) u64`). `impl` must outlive the result.
    pub fn init(impl: anytype) Clock {
        const T = comptime implType(@TypeOf(impl));
        comptime requireMethod(T, "now_ms", &.{}, u64);
        return .{ .ptr = impl, .vtable = &Static(T).vtable };
    }

    fn Static(comptime T: type) type {
        return struct {
            fn call_now_ms(ptr: *anyopaque) u64 {
                return cast(T, ptr).now_ms();
            }

            const vtable: VTable = .{ .now_ms = call_now_ms };
        };
    }

    /// Milliseconds since an arbitrary epoch. The impl guarantees non-decreasing results; the
    /// raft core asserts it, because only the caller sees two consecutive readings (a stateless
    /// forwarder cannot, so it asserts nothing here).
    pub fn now_ms(self: Clock) u64 {
        return self.vtable.now_ms(self.ptr);
    }
};

// ---------------------------------------------------------------------------------------
// Rng
// ---------------------------------------------------------------------------------------

/// Source of uniformly distributed 64-bit words. Not `std.Random`: its bounded helpers loop
/// and its vtable is wider than one word.
pub const Rng = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next_u64: *const fn (ptr: *anyopaque) u64,
    };

    /// Builds an `Rng` over `impl` (`*T`, `T` a non-zero-sized struct with
    /// `pub fn next_u64(self: *T) u64`). `impl` must outlive the result.
    pub fn init(impl: anytype) Rng {
        const T = comptime implType(@TypeOf(impl));
        comptime requireMethod(T, "next_u64", &.{}, u64);
        return .{ .ptr = impl, .vtable = &Static(T).vtable };
    }

    fn Static(comptime T: type) type {
        return struct {
            fn call_next_u64(ptr: *anyopaque) u64 {
                return cast(T, ptr).next_u64();
            }

            const vtable: VTable = .{ .next_u64 = call_next_u64 };
        };
    }

    /// The next uniformly distributed word. Consumes exactly one draw from the impl.
    pub fn next_u64(self: Rng) u64 {
        return self.vtable.next_u64(self.ptr);
    }

    /// A value in `[0, bound)` from exactly one draw: multiply-high `(x * bound) >> 64`, no
    /// rejection loop, so it always terminates; the bias is below `bound / 2^64`.
    /// Precondition: `bound > 0`.
    pub fn uint_less_than(self: Rng, bound: u64) u64 {
        assert(bound > 0);
        const product = @as(u128, self.next_u64()) * @as(u128, bound);
        const result: u64 = @intCast(product >> 64);
        assert(result < bound);
        return result;
    }
};

// ---------------------------------------------------------------------------------------
// StateMachine
// ---------------------------------------------------------------------------------------

/// The replicated application. Called by `driver.zig`, never by `raft.zig`, which stays
/// `std.Io`-free.
pub const StateMachine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Local fault: fail-stop, the caller stops using this instance.
    pub const ApplyError = error{StateMachineFailed};
    pub const SnapshotError = std.Io.Writer.Error || error{StateMachineFailed};
    pub const RestoreError = std.Io.Reader.Error ||
        error{ StateMachineSnapshotInvalid, StateMachineFailed };

    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, entry: *const Entry) ApplyError!void,
        snapshot: *const fn (ptr: *anyopaque, writer: *std.Io.Writer) SnapshotError!void,
        restore: *const fn (ptr: *anyopaque, reader: *std.Io.Reader) RestoreError!void,
    };

    /// Builds a `StateMachine` over `impl` (`*T`, `T` a non-zero-sized struct with `apply`,
    /// `snapshot`, `restore` of the `VTable` signatures). `impl` must outlive the result.
    pub fn init(impl: anytype) StateMachine {
        const T = comptime implType(@TypeOf(impl));
        comptime requireMethod(T, "apply", &.{*const Entry}, ApplyError!void);
        comptime requireMethod(T, "snapshot", &.{*std.Io.Writer}, SnapshotError!void);
        comptime requireMethod(T, "restore", &.{*std.Io.Reader}, RestoreError!void);
        return .{ .ptr = impl, .vtable = &Static(T).vtable };
    }

    fn Static(comptime T: type) type {
        return struct {
            fn call_apply(ptr: *anyopaque, entry: *const Entry) ApplyError!void {
                return cast(T, ptr).apply(entry);
            }

            fn call_snapshot(ptr: *anyopaque, writer: *std.Io.Writer) SnapshotError!void {
                return cast(T, ptr).snapshot(writer);
            }

            fn call_restore(ptr: *anyopaque, reader: *std.Io.Reader) RestoreError!void {
                return cast(T, ptr).restore(reader);
            }

            const vtable: VTable = .{
                .apply = call_apply,
                .snapshot = call_snapshot,
                .restore = call_restore,
            };
        };
    }

    /// Applies one committed entry. Precondition: `entry` is a real log entry (index and term
    /// non-zero). Called for every committed entry in index order, `conf_change` and empty
    /// no-ops included. A deterministic command failure is state, not an error.
    pub fn apply(self: StateMachine, entry: *const Entry) ApplyError!void {
        assert(entry.index != Index.zero);
        assert(entry.term != Term.zero);
        try self.vtable.apply(self.ptr, entry);
    }

    /// Writes a self-describing stream (magic, version, checksum). Precondition: `writer` is
    /// a consistent `std.Io.Writer`; the caller bounds it at `snapshot_bytes_max` and flushes.
    pub fn snapshot(self: StateMachine, writer: *std.Io.Writer) SnapshotError!void {
        // No contract assertions: `Writer` state is owned by std and its invariants hold by
        // construction, so an assert here would only restate them.
        try self.vtable.snapshot(self.ptr, writer);
    }

    /// Resets all state, then loads the stream, so a retry with a fresh reader is valid. A bad
    /// stream is `StateMachineSnapshotInvalid`. Precondition: `reader` is consistent.
    pub fn restore(self: StateMachine, reader: *std.Io.Reader) RestoreError!void {
        // No contract assertions, for the same reason as `snapshot`.
        try self.vtable.restore(self.ptr, reader);
    }
};

// ---------------------------------------------------------------------------------------
// LogStore
// ---------------------------------------------------------------------------------------

/// Durable Raft log, hard state and snapshot. Mutations are visible to reads at once and
/// durable only once `sync` returns; a crash loses a suffix of unsynced mutations in call
/// order, never a middle one. `*IoFailed` and `*Corrupt` are fail-stop for the instance.
pub const LogStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// `append`, `save_snapshot`. `StoreFull` is checked before mutating: nothing changed.
    pub const WriteError = error{ StoreFull, StoreIoFailed };
    /// `truncate`, `save_hard_state`, `sync`.
    pub const UpdateError = error{StoreIoFailed};
    /// `get`, `load_hard_state`, `load_snapshot`.
    pub const ReadError = error{ StoreCorrupt, StoreIoFailed };

    pub const VTable = struct {
        append: *const fn (ptr: *anyopaque, entries: []const Entry) WriteError!void,
        truncate: *const fn (ptr: *anyopaque, from: Index) UpdateError!void,
        get: *const fn (ptr: *anyopaque, index: Index) ReadError!Entry,
        last_index: *const fn (ptr: *anyopaque) Index,
        save_hard_state: *const fn (
            ptr: *anyopaque,
            hard_state: *const HardState,
        ) UpdateError!void,
        load_hard_state: *const fn (ptr: *anyopaque) ReadError!HardState,
        save_snapshot: *const fn (
            ptr: *anyopaque,
            snapshot: *const Snapshot,
            configuration: *const Configuration,
        ) WriteError!void,
        load_snapshot: *const fn (ptr: *anyopaque) ReadError!?SnapshotRecord,
        sync: *const fn (ptr: *anyopaque) UpdateError!void,
    };

    /// Builds a `LogStore` over `impl` (`*T`, `T` a non-zero-sized struct with one method per
    /// `VTable` field, error sets equal to or narrower than the named ones). `impl` must
    /// outlive the result.
    pub fn init(impl: anytype) LogStore {
        const T = comptime implType(@TypeOf(impl));
        comptime requireMethods(T);
        return .{ .ptr = impl, .vtable = &Static(T).vtable };
    }

    fn requireMethods(comptime T: type) void {
        requireMethod(T, "append", &.{[]const Entry}, WriteError!void);
        requireMethod(T, "truncate", &.{Index}, UpdateError!void);
        requireMethod(T, "get", &.{Index}, ReadError!Entry);
        requireMethod(T, "last_index", &.{}, Index);
        requireMethod(T, "save_hard_state", &.{*const HardState}, UpdateError!void);
        requireMethod(T, "load_hard_state", &.{}, ReadError!HardState);
        const snapshot_params = &.{ *const Snapshot, *const Configuration };
        requireMethod(T, "save_snapshot", snapshot_params, WriteError!void);
        requireMethod(T, "load_snapshot", &.{}, ReadError!?SnapshotRecord);
        requireMethod(T, "sync", &.{}, UpdateError!void);
    }

    fn Static(comptime T: type) type {
        return struct {
            fn call_append(ptr: *anyopaque, entries: []const Entry) WriteError!void {
                return cast(T, ptr).append(entries);
            }

            fn call_truncate(ptr: *anyopaque, from: Index) UpdateError!void {
                return cast(T, ptr).truncate(from);
            }

            fn call_get(ptr: *anyopaque, index: Index) ReadError!Entry {
                return cast(T, ptr).get(index);
            }

            fn call_last_index(ptr: *anyopaque) Index {
                return cast(T, ptr).last_index();
            }

            fn call_save_hard_state(
                ptr: *anyopaque,
                hard_state: *const HardState,
            ) UpdateError!void {
                return cast(T, ptr).save_hard_state(hard_state);
            }

            fn call_load_hard_state(ptr: *anyopaque) ReadError!HardState {
                return cast(T, ptr).load_hard_state();
            }

            fn call_save_snapshot(
                ptr: *anyopaque,
                snapshot: *const Snapshot,
                configuration: *const Configuration,
            ) WriteError!void {
                return cast(T, ptr).save_snapshot(snapshot, configuration);
            }

            fn call_load_snapshot(ptr: *anyopaque) ReadError!?SnapshotRecord {
                return cast(T, ptr).load_snapshot();
            }

            fn call_sync(ptr: *anyopaque) UpdateError!void {
                return cast(T, ptr).sync();
            }

            const vtable: VTable = .{
                .append = call_append,
                .truncate = call_truncate,
                .get = call_get,
                .last_index = call_last_index,
                .save_hard_state = call_save_hard_state,
                .load_hard_state = call_load_hard_state,
                .save_snapshot = call_save_snapshot,
                .load_snapshot = call_load_snapshot,
                .sync = call_sync,
            };
        };
    }

    /// The last index in the log, `.zero` when empty. Infallible: implementations cache it.
    pub fn last_index(self: LogStore) Index {
        return self.vtable.last_index(self.ptr);
    }

    /// Appends `entries` after the current last index. Precondition: non-empty, contiguous
    /// from `last_index().next()`, terms non-zero and non-decreasing. Never overwrites:
    /// conflicts are `truncate`d first (the first term against the store's last term is the
    /// impl's to check: it needs a fallible read). Copies `data`. `StoreFull` leaves the store
    /// unchanged.
    pub fn append(self: LogStore, entries: []const Entry) WriteError!void {
        assert(entries.len > 0);
        const last_before = self.last_index();
        const first: u64 = @intFromEnum(last_before.next());
        var term_floor: u64 = 0;
        for (entries, 0..) |entry, offset| {
            assert(@intFromEnum(entry.index) == first + offset);
            assert(entry.term != Term.zero);
            assert(@intFromEnum(entry.term) >= term_floor);
            term_floor = @intFromEnum(entry.term);
        }
        self.vtable.append(self.ptr, entries) catch |err| {
            switch (err) {
                error.StoreFull => assert(self.last_index() == last_before),
                error.StoreIoFailed => {},
            }
            return err;
        };
        assert(self.last_index() == entries[entries.len - 1].index);
    }

    /// Drops every index `>= from`. Precondition: `from` in `1..=last_index().next()`; it lies
    /// above the snapshot and never below the commit index (raft's contract, which the store
    /// cannot check without a fallible read).
    pub fn truncate(self: LogStore, from: Index) UpdateError!void {
        const last_before = self.last_index();
        assert(from != Index.zero);
        assert(from.order(last_before.next()) != .gt);
        try self.vtable.truncate(self.ptr, from);
        assert(@intFromEnum(self.last_index()) == @intFromEnum(from) - 1);
    }

    /// The entry at `index`; `data` is borrowed until the next mutating call. Precondition:
    /// `index` in `(snapshot.index, last_index()]` (the lower bound needs a fallible read, so
    /// only `index >= 1` is asserted). Postcondition: the result's index matches and its term
    /// is non-zero; a mismatch in persisted data is `StoreCorrupt`, never an assert.
    pub fn get(self: LogStore, index: Index) ReadError!Entry {
        assert(index != Index.zero);
        assert(index.order(self.last_index()) != .gt);
        const entry = try self.vtable.get(self.ptr, index);
        if (entry.index != index) return error.StoreCorrupt;
        if (entry.term == Term.zero) return error.StoreCorrupt;
        return entry;
    }

    /// Persists `hard_state`. Precondition: `commit_index <= last_index()` (append a batch
    /// before saving the commit that covers it) and a vote implies a non-zero term.
    pub fn save_hard_state(self: LogStore, hard_state: *const HardState) UpdateError!void {
        assert(hard_state.commit_index.order(self.last_index()) != .gt);
        assert(hard_state_coherent(hard_state));
        try self.vtable.save_hard_state(self.ptr, hard_state);
    }

    /// The saved hard state, `HardState.empty` if never saved. Persisted bytes are user data:
    /// an incoherent record (commit beyond the log, vote without a term) is `StoreCorrupt`.
    pub fn load_hard_state(self: LogStore) ReadError!HardState {
        const hard_state = try self.vtable.load_hard_state(self.ptr);
        if (hard_state.commit_index.order(self.last_index()) == .gt) return error.StoreCorrupt;
        if (!hard_state_coherent(&hard_state)) return error.StoreCorrupt;
        return hard_state;
    }

    /// Stores `snapshot` and drops entries `<= snapshot.index`; keeps the suffix only if the
    /// entry at `snapshot.index` has `snapshot.term` (compaction), else drops all (install).
    /// Copies `data` and the node lists. Precondition: index and term non-zero, `configuration`
    /// valid, index above the previous snapshot (that last one needs a fallible read, so it is
    /// the impl's to reject). Postcondition: `last_index() >= snapshot.index`. `StoreFull`
    /// leaves the store unchanged.
    pub fn save_snapshot(
        self: LogStore,
        snapshot: *const Snapshot,
        configuration: *const Configuration,
    ) WriteError!void {
        assert(snapshot.index != Index.zero);
        assert(snapshot.term != Term.zero);
        assert(configurationValid(configuration));
        const last_before = self.last_index();
        self.vtable.save_snapshot(self.ptr, snapshot, configuration) catch |err| {
            switch (err) {
                error.StoreFull => assert(self.last_index() == last_before),
                error.StoreIoFailed => {},
            }
            return err;
        };
        assert(self.last_index().order(snapshot.index) != .lt);
    }

    /// The saved snapshot and its configuration, `null` on a fresh store. Borrowed until the
    /// next mutating call. A zero index or term in persisted data is `StoreCorrupt`.
    pub fn load_snapshot(self: LogStore) ReadError!?SnapshotRecord {
        const record = try self.vtable.load_snapshot(self.ptr);
        if (record) |found| {
            if (found.snapshot.index == Index.zero) return error.StoreCorrupt;
            if (found.snapshot.term == Term.zero) return error.StoreCorrupt;
        }
        return record;
    }

    /// The durability barrier: everything mutated before it is durable once it returns. The
    /// driver syncs before any send that depends on the batch (vote grant, append response).
    pub fn sync(self: LogStore) UpdateError!void {
        const last_before = self.last_index();
        try self.vtable.sync(self.ptr);
        assert(self.last_index() == last_before);
    }
};

/// A vote implies a non-zero term.
fn hard_state_coherent(hard_state: *const HardState) bool {
    if (hard_state.vote == .none) return true;
    return hard_state.term != Term.zero;
}

fn configurationValid(configuration: *const Configuration) bool {
    configuration.validate() catch return false;
    return true;
}

test {
    _ = @import("interfaces_test.zig");
}
