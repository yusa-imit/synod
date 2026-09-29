# ADR-006: The five interface vtables

## Status

Accepted (plan 002, item 1C).

## Context

PRD §4.1 sketches `Transport`/`LogStore`/`StateMachine` with `anyerror` (Tiger Style bans it in
a `pub fn`) and `writer: anytype` (not expressible in a function pointer). `LogStore` must be
implemented by the in-memory store (1D) and a future strata adapter (PRD 6B), so its durability,
borrowing, and error semantics must be exact now. `Clock`/`Rng` are how `core_purity_files`
(ADR-002) see time and randomness. Once pinned, a signature change is MAJOR.

## Decision

Shape and construction, identical for all five (`X` is the interface):

```zig
pub const X = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { ... }; // one fn pointer per method, first param `*anyopaque`
    pub fn init(impl: anytype) X; // the only construction path; see below
    // thin forwarding methods: `x.method(args)` asserts the contract, then dispatches
};
```

- **`X.init(impl)` is the one construction path.** `impl` must be `*T`, `T` a non-zero-sized
  struct with methods named exactly as the vtable fields; `init` builds a static per-`T` vtable
  at comptime (`@compileError` on a missing or mis-typed method). Comptime runs only here;
  dispatch is runtime. No hand-built `VTable` literals anywhere, tests included.
- **Contract assertions live in the forwarding methods,** so every implementation (memory,
  strata, fixtures) is checked by the same code, ADR-003's paired path.
- **Names are `snake_case`** (tiger-style §6): `last_index`, not PRD's `lastIndex`.
- **Error sets are named, prefixed, and narrow per method.** Local faults (`*IoFailed`,
  `*Corrupt`, `StateMachineFailed`) mean fail-stop: the caller stops using that instance.

`Transport.send(message: *const Message) void`. The destination is `message.header().to` (no
separate `to`, so they cannot disagree). Best effort: may drop, delay, duplicate, or reorder;
never corrupt (adapter frames checksum, ADR-004). The message and its borrowed slices live only
for the call: the impl encodes or copies before returning, never blocks on the network (bounded
queue sized at init; full means drop), never re-enters the raft core. Asserts version non-zero,
`from`/`to` not `.none`, `from != to`.

`LogStore`, three error sets:

```zig
pub const WriteError = error{ StoreFull, StoreIoFailed }; // append, save_snapshot
pub const UpdateError = error{StoreIoFailed}; // truncate, save_hard_state, sync
pub const ReadError = error{ StoreCorrupt, StoreIoFailed }; // get, load_*
```

- `append(entries)`: non-empty, contiguous from `last_index().next()`, terms non-zero and
  non-decreasing (asserted). Never overwrites: conflicts are `truncate`d first. Copies `data`.
- `truncate(from)`: drops indices `>= from`; `from` in `1..=last_index().next()` (asserted).
  Above the snapshot and never below the commit index: raft's contract, not checkable without a
  fallible read.
- `get(index) ReadError!Entry`: `index` in `1..=last_index()` (asserted; the snapshot lower
  bound is raft's). A result whose `index` differs or whose `term` is zero is `StoreCorrupt`.
  `data` borrowed until the next mutating call.
- `last_index() Index`: infallible, cached in memory; `.zero` when empty.
- `save_hard_state(*const HardState)`: `commit_index <= last_index()` (asserted), so a batch
  appends before it saves, and a vote implies a non-zero term (asserted). `load_hard_state()
  ReadError!HardState`: `.empty` if never saved; an incoherent record is `StoreCorrupt`.
- `save_snapshot(*const Snapshot, *const Configuration)`: index and term non-zero, configuration
  valid (asserted); index above the previous snapshot is the impl's to reject.
  Drops entries `<= snapshot.index`; keeps
  the suffix only if the entry at `snapshot.index` has `snapshot.term` (compaction), else drops
  all (install). After, `last_index() >= snapshot.index`. Copies `data` and node lists.
- `load_snapshot() ReadError!?SnapshotRecord`: `null` on a fresh store (no valid sentinel
  exists: an empty `Configuration` is invalid). Borrowed until the next mutating call.
- `sync() UpdateError!void`: the durability barrier.

Durability: mutations are visible to reads at once, durable only once `sync` returns. A crash
loses a *suffix* of unsynced mutations in call order, never a middle one (strata's WAL gives
this; the Phase 3 simulator models it). The driver syncs before any send that depends on the
batch (vote grant, append response). `StoreFull` is checked before mutating: the store is
unchanged and the caller may compact or reject. Implementations reserve space for fixed-size
records, so only the variable-size writes can be full.

`StateMachine` is called by `driver.zig`, never by `raft.zig` (which stays `std.Io`-free):

```zig
pub const ApplyError = error{StateMachineFailed};
pub const SnapshotError = std.Io.Writer.Error || error{StateMachineFailed};
pub const RestoreError = std.Io.Reader.Error ||
    error{ StateMachineSnapshotInvalid, StateMachineFailed };
```

`apply(*const Entry)` gets every committed entry in index order, `conf_change` and empty no-ops
included. Deterministic command failures are state, not errors. `snapshot(*std.Io.Writer)`
writes a stream that carries its own magic, version, and checksum; the caller bounds the writer
at `snapshot_bytes_max` and flushes it. `restore(*std.Io.Reader)` resets all state first, so a
retry with a fresh reader is valid, and rejects a bad stream as `StateMachineSnapshotInvalid`.

`Clock.now_ms() u64`: monotonic, non-decreasing, arbitrary epoch, never wall time. Raft
asserts that. `Rng.next_u64() u64`, plus `uint_less_than(bound) u64`, not in the vtable:
multiply-high `(x * bound) >> 64`, bound > 0, result < bound (asserted). No rejection loop,
so it always terminates; bias is below `bound / 2^64`. `std.Random` is not used: its bounded
helper loops and its `fill` vtable is wider than one word.

## Consequences

- 1C tests use test-private fixtures (a transport recorder, a stub store tracking
  `last_index`, a manual clock, a fixed-value rng, a recording state machine), each built via
  `X.init(&fixture)`. Public deterministic impls arrive with `sim.zig` (Phase 3). 1D's
  `conformance(store: LogStore)` is the shared LogStore test suite.
- 1D must own entry bytes, since `Log` stores borrowed `data`: one buffer allocated at `init`,
  `StoreFull` when exhausted. It must also give `Log` a snapshot base index, because `Log`
  assumes index 1 is always the first entry.
- `get` borrows until the next mutation. That constrains how the leader builds
  `AppendRequest`. A range read is added only if plan 003 measures a need.
- `log.zig`/`types.zig` `camelCase` methods (`lastIndex`, `termAt`, `conflictAt`,
  `validateTransition`) break tiger-style §6. They are renamed before v0.3.0 pins them.
