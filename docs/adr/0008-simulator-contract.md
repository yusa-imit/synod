# ADR-008: The simulator contract — `Simulation`, network, crash store, checkers

## Status

Accepted (plan 004, item 1).

## Context

PRD §4.5 sketches `Simulation.init(allocator, .{ .seed, .nodes })`, `runUntil`, `check`.
`raft/cluster_test.zig` proves the method at 500 seeds but drives bare `Node`s (persist, sync,
send and apply never run), never crashes, checks four of the five Raft properties, and draws
every concern from one PRNG, so one new draw reshuffles the network. Items 2–10 of plan 004
add `src/sim/`; once public, its shapes are MINOR at 0.x and MAJOR once pinned. This ADR names
every `pub` symbol those items add, so no later cycle redesigns.

## Decision

**Layout.** `src/sim/{prng,clock,network,crash_store,invariants,linearizability,workload,
simulation}.zig`. `src/sim.zig` re-exports the eight files as namespaces plus `Simulation`,
`Options`, `Report`, `Error`, `Stats`, `Plant`, `Property`, `Prng`, `VirtualClock`, `Network`,
`CrashStore`, `run_seed`, and drops `Error{NotImplemented}`. That is the whole surface; a new
`pub` decl in `src/sim/` amends this ADR. `prng` (the determinism root) and `workload` (keeps
`simulation.zig` one cycle in size) are beyond the plan's five. The CLI is `tools/sim_cli.zig`.

**Convention.** Each stateful type `T` below (`Network`, `CrashStore`, `Checker`,
`HistoryChecker`, `KvStateMachine`, `Workload`) has `pub fn init(t: *T, gpa: Allocator,
options: *const T.Options, <extra>) Allocator.Error!void` (`<extra>` noted per type) and
`pub fn deinit(t: *T, gpa: Allocator) void`, allocates nothing after `init`, and adapts to an
interface only through `pub fn as_<interface>(t: *T) <Interface>`.

**Purity and `io`.** Item 2 adds to tidy `pub const sim_purity_dir = "src/sim/"`,
`pub fn is_sim_purity_file(path: []const u8) bool` (also true for `src/sim.zig`) and
`pub const sim_banned_patterns = .{ "std.time.", "std.fs.", "std.net.", "std.Thread",
"std.process.", "std.posix.", "std.os.", "std.crypto.random", "std.Random", "Io.Clock",
"Io.Dir", "Io.File", "Io.net", "Io.Mutex", "Io.Group", "Io.Threaded", "io.sleep",
"io.async", "io.concurrent" }`. `std.Io` stays legal: `simulation.zig` takes `io: Io` first
after the receiver (ADR-002) and passes it unchanged to `Driver`; it never stores `io` or calls
a method on it. The KV machine names `*std.Io.Writer`/`Reader`, in-memory types. No other sim
type takes `io`. Tests pass `std.testing.io`; CLI and bench pass `init.io`.

**Seeds.** One root `seed: u64`; each concern draws from its own stream, a function of
`(root, stream, lane)` only, never of `nodes_count` or of another stream's draws:

```zig
pub const Stream = enum(u8) { network = 1, faults = 2, workload = 3, node = 4 };
pub fn derive_seed(root_seed: u64, stream: Stream, lane: u32) u64; // see below
pub const Prng = struct { // SplitMix64
    state: u64,
    pub fn init(seed: u64) Prng;
    pub fn next_u64(prng: *Prng) u64; // the interfaces.Rng method
    pub fn uint_less_than(prng: *Prng, bound: u64) u64; // multiply-high, bound > 0, one draw
    pub fn chance(prng: *Prng, percent: u8) bool; // percent <= 100, one draw
    pub fn as_rng(prng: *Prng) interfaces.Rng;
};
```

`derive_seed = mix64(root_seed ^ mix64((stream << 32) | lane))`, `mix64` the SplitMix64
finalizer. `network`, `faults`, `workload` use lane 0; node `i` in its `g`-th life uses
`(g << 8) | i` (`g < 2^24`, asserted): node 2's timer draws are identical in a 3- and a 5-node
run, and a restart gets a fresh seed-determined stream. `std.Random` is banned in `src/sim/`:
its algorithms are not pinned across Zig releases, and a nightly seed must replay after a
toolchain bump. Scheduling draws nothing; ties break by a fixed order.

**Clock.** `pub const VirtualClock = struct { time_ms: u64 }`, no allocation, with `pub fn
init(start_ms: u64) VirtualClock`, `pub fn now_ms(virtual_clock: *VirtualClock) u64` (the
`Clock` method), `pub fn advance_to(virtual_clock: *VirtualClock, time_ms: u64) void`
(asserts never backwards), `pub fn as_clock(virtual_clock: *VirtualClock) Clock`. All nodes
share one clock.

**Network** (item 2, promotes `cluster_test`'s `Slot`):

```zig
pub const Network = struct {
    pub const Fault = enum(u8) { none = 1, forge_votes = 2, flip_data = 3 };
    pub const Model = struct { messages_max: u32, delay_ms_min: u32, delay_ms_max: u32,
        loss_percent: u8, duplicate_percent: u8 };
    pub const Options = struct { nodes_count: u8, message_limits: Message.Limits,
        model: Model, fault: Fault };
    pub const Link = struct { from_index: u8, to_index: u8 }; // 0-based slots, id = slot + 1
    pub const Stats = struct { sent: u64, delivered: u64, duplicated: u64, dropped_loss: u64,
        dropped_full: u64, dropped_cut: u64, dropped_down: u64 };
    // init extra: virtual_clock: *VirtualClock, prng: Prng; as_transport
    pub fn bytes_required(options: *const Options) u64;
    pub fn send(network: *Network, message: *const Message) void; // the Transport method
    pub fn set_partition(network: *Network, side_a: []const u8, side_b: []const u8) void;
    pub fn cut(network: *Network, link: Link) void; // one direction
    pub fn heal(network: *Network) void;
    pub fn reachable(network: *const Network, link: Link) bool;
    pub fn next_due_ms(network: *const Network) ?u64;
    pub fn pop_due(network: *Network) ?*const Message; // borrowed until the next pop_due
    pub fn drop_down(network: *Network) void; // counts a delivery to a crashed node
    pub fn in_flight(network: *const Network) u32;
    pub fn trace_hash(network: *const Network) u64; // over (seq, at_ms, from, to, kind)
    pub fn stats(network: *const Network) Stats;
};
```

`send` copies the message and entry bytes into a free slot, draws one `chance(loss_percent)`
and one delay in `[delay_ms_min, delay_ms_max]`, stamps a sequence number; a full table drops
the new message (`dropped_full`) and never grows. `pop_due` takes the least `(at_ms, seq)` due
by now (reorder is emergent), copies it to a dedicated delivery slot (sends made while it is
received cannot overwrite it), checks reachability at delivery (`dropped_cut`), and draws one
`chance(duplicate_percent)` that re-arms the slot. `forge_votes` grants every denied
`request_vote_response`; `flip_data` flips a byte of the first non-empty entry. Phase 3
asserts no `install_snapshot`. **Sizing** at `init`: `bytes_required = (messages_max + 1) *
(@sizeOf(Message) + entries_max * (@sizeOf(Entry) + entry_bytes_max))` plus a fixed
`nodes_max^2` matrix; the sweep preset (256, 16, 32) is about 0.3 MiB.

*Amendment (item 2).* Each in-flight slot also needs bookkeeping (due time, sequence, link,
flags), so `bytes_required` adds `messages_max * Network.slot_meta_bytes` (`pub const`, 24).
The reachability matrix is a fixed `[nodes_max][nodes_max]bool` inside `Network`, not a `gpa`
allocation, so `bytes_required` is exactly what `init` requests. Item 2 also adds
`Network.InvariantError = error{ NetworkStatsDiverged, NetworkTableOverfull }` and
`check_invariants(network: *const Network) InvariantError!void` (the conservation identity
`sent + duplicated == delivered + dropped_* + in_flight`, and `in_flight <= messages_max`);
`pop_due` consumes a message cut at delivery and goes on to the next due one; `drop_down`
reclassifies the last delivery (`delivered - 1`, `dropped_down + 1`); a duplicate is re-armed
once (not itself duplicated) with a fresh delay draw; `set_partition` replaces earlier cuts;
`send` draws loss then delay on every call, before the table-full check.

**Crash store** (item 5):

```zig
pub const CrashStore = struct {
    pub const Fault = enum(u8) { none = 1, lose_synced_hard_state = 2 };
    pub const Options = struct { store: store.Options, journal_ops_max: u32,
        journal_bytes_max: u32, fault: Fault };
    pub const InvariantError = store.InvariantError || error{CrashStoreDiverged};
    // as_log_store; last_index, append, truncate, get, save_hard_state, load_hard_state,
    // save_snapshot, load_snapshot, sync: the LogStore methods, MemoryStore's signatures.
    pub fn arm_failure(crash_store: *CrashStore, calls_until: u32) void;
    pub fn crash(crash_store: *CrashStore, keep_count: u32) void;
    pub fn unsynced_count(crash_store: *const CrashStore) u32;
    pub fn check_invariants(crash_store: *const CrashStore) InvariantError!void;
};
```

Two `MemoryStore`s, `durable` and `live`, and a journal of `journal_ops_max` mutations owning
copies of their bytes. Mutations go to `live` and the journal; `sync` replays the journal into
`durable`; a full journal flushes early (durable before `sync` is allowed, ADR-006).
`crash(keep_count <= unsynced_count())` rebuilds `live` from `durable` plus the first
`keep_count` journal ops: a suffix is lost, never a middle (ADR-006); it disarms any failure
and asserts no snapshot record (Phase 4). `arm_failure(n)`: the `n`-th next mutation or `sync`
(0 = next) returns `StoreIoFailed` and mutates nothing — a torn crash. The driver fail-stops
mid-step (ADR-007), so unsynced writes exist exactly when they can be lost; crashes only
between events would be vacuous, since the driver syncs at the end of every step.
`lose_synced_hard_state`: at `crash`, `durable`'s hard state reverts to its value before the
last synced change, forgetting a durable vote. `CrashStore` passes `store.conformance`.

**Invariants** (item 3, promotes `Oracle`, adds leader append-only):

```zig
pub const Property = enum(u8) { election_safety = 1, leader_append_only = 2,
    log_matching = 3, leader_completeness = 4, state_machine_safety = 5, linearizability = 6 };
pub const Violation = error{ ElectionSafety, LeaderAppendOnly, LogMatching,
    LeaderCompleteness, StateMachineSafety, Linearizability };
pub fn violation_of(property: Property) Violation;
pub const Observation = struct { node_index: u8, status: raft.Status, log: []const Entry };
pub fn fingerprint(entry: *const Entry) u64; // Wyhash of term, kind, data
pub fn log_matching(a: []const Entry, b: []const Entry) Violation!void;
pub fn leader_append_only(before: []const u64, after: []const Entry) Violation!void;
pub const Checker = struct {
    pub const Options = struct { nodes_count: u8, log_entries_max: u32, terms_max: u32 };
    pub const Stats = struct { leader_terms: u32, committed_max: u64 };
    pub fn observe(checker: *Checker, observations: []const Observation)
        (Violation || error{TermsExhausted})!void;
    pub fn applied(checker: *Checker, node_index: u8, index: Index, entry_fingerprint: u64)
        Violation!void;
    pub fn restarted(checker: *Checker, node_index: u8) void;
    pub fn check(checker: *const Checker, property: Property) Violation!void;
    pub fn stats(checker: *const Checker) Stats;
};
```

Blind to `Node` internals: it sees `status()`, `entries()` (borrowed for the call) and applied
records. Election safety: one leader per term, a `terms_max + 1` table (beyond is
`TermsExhausted`). Leader append-only: per node, the fingerprints of its log when last seen
leading term T; a later observation in T must extend them. Log matching: pairwise. Leader
completeness: a leader of T holds every entry chosen in a term `<= T`. State machine safety:
the first commit of an index fixes its fingerprint; a differing commit, an overwritten
committed prefix, a commit regressing on a live node, or an apply out of order, repeated or
past commit is `StateMachineSafety` (`cluster_test`'s `CommitRegression`,
`CommittedOverwritten`, `ApplyOrder` fold in; the replay shows which). `restarted` clears a
node's commit, applied length and leader memory, never the chosen entries. `check` returns
the latched first violation (asserts `property != .linearizability`). Memory: `nodes_count *
log_entries_max * 8 + log_entries_max * 24 + terms_max + 1` bytes.

**Linearizability** (item 9):

```zig
pub const Kind = enum(u8) { put = 1, get = 2 };
pub const Operation = struct { client_index: u16, kind: Kind, key: u16,
    value: u64, // put: written; get: returned; 0 = never written
    invoke_event: u64, complete_event: ?u64 }; // null = pending
pub const CheckError = error{ Linearizability, CheckInconclusive, HistoryTooLong };
pub const HistoryChecker = struct {
    pub const Options = struct { history_ops_max: u32, keys_max: u16, search_steps_max: u64 };
    pub fn check(history_checker: *HistoryChecker, history: []const Operation)
        CheckError!void;
};
```

One register per key, initially 0. Wing–Gong search, split per key (P-compositionality), an
explicit stack of `history_ops_max` frames, no recursion, no memo cache (adding one changes no
signature). A pending put linearizes anywhere after its invoke or never; a pending get is
dropped. `history.len > history_ops_max` is `HistoryTooLong` before any work; running out of
`search_steps_max` (summed over keys) is `CheckInconclusive`, which fails a run, never passes
it. A malformed history (complete before invoke, key `>= keys_max`, two outstanding ops on one
client) is the caller's bug and asserted. Memory: `O(history_ops_max)`, at `init`.

**Workload** (item 10):

```zig
pub const command_bytes: u32 = 24; // "kv", version, kind, client u16, key u16, value u64,
pub const command_version: u8 = 1; // op_id u32, crc32 of bytes 0..20; little-endian
pub const Command = struct { kind: Kind, client_index: u16, key: u16, value: u64,
    op_id: u32 };
pub const DecodeError = error{ CommandLength, CommandMagic, CommandVersion, CommandKind,
    CommandChecksum };
pub fn encode(command: *const Command, out: *[command_bytes]u8) void;
pub fn decode(bytes: []const u8) DecodeError!Command;
pub const KvStateMachine = struct {
    pub const Applied = struct { index: Index, entry_fingerprint: u64, command: ?Command,
        result: u64 };
    pub const Options = struct { keys_count: u16, applied_max: u32 };
    // as_state_machine; apply, snapshot, restore: StateMachine's exact signatures. apply
    // never fails: a no-op, conf_change or undecodable entry is recorded, `command = null`.
    pub fn drain(kv: *KvStateMachine) []const Applied; // borrowed until the next apply
    pub fn reset(kv: *KvStateMachine) void; // restart: every key back to 0
};
pub const Invocation = struct { node_index: u8, log_index: Index, event_index: u64 };
pub const Workload = struct {
    pub const Fault = enum(u8) { none = 1, ack_uncommitted = 2 };
    pub const Options = struct { clients_count: u16, keys_count: u16, put_percent: u8,
        op_interval_ms_max: u32, fault: Fault }; // clients_count 0 = no workload
    pub const Stats = struct { ops_invoked: u32, ops_completed: u32, ops_pending: u32 };
    // init extra: history_ops_max: u32, prng: Prng
    pub fn next_due_ms(workload: *const Workload) ?u64; // null: history full or no clients
    pub fn next_command(workload: *Workload, now_ms: u64) ?Command;
    pub fn invoked(workload: *Workload, command: *const Command, invocation: Invocation) void;
    pub fn rejected(workload: *Workload, command: *const Command) void;
    pub fn applied(workload: *Workload, node_index: u8, record: *const KvStateMachine.Applied,
        event_index: u64) void;
    pub fn crashed(workload: *Workload, node_index: u8) void;
    pub fn history(workload: *const Workload) []const Operation;
    pub fn stats(workload: *const Workload) Stats;
};
```

A command goes to a node that believes it leads (seeded pick). Invoke at a successful
`propose`, keeping `status().last_index` as its index; complete when the proposer applies that
index with the same `op_id` (a get returns the applied value); a different entry there, or the
proposer's crash, leaves it pending. `ProposeNotLeader`/`ProposeLogFull` call `rejected`: no
history record, the op never entered a log. `ack_uncommitted` completes a put at invoke. The
KV snapshot stream carries magic `"SKV1"`, version, key count, values, crc32 (ADR-006).

**Simulation** (items 4, 5, 10):

```zig
pub const nodes_max: u8 = 7; // comptime-asserted <= types.voters_max
pub const Plant = enum(u8) { none = 1, forge_votes = 2, flip_data = 3,
    lose_synced_hard_state = 4, ack_uncommitted = 5 };
pub const Faults = struct { fault_interval_ms_max: u32, partition_percent: u8,
    crash_percent: u8, torn_percent: u8, partition_ms_max: u32, down_ms_max: u32 };
pub const Options = struct {
    seed: u64, nodes_count: u8, tick_ms: u32,
    raft: raft.Config, // id == .none (asserted); node slot i gets id i + 1
    network: Network.Model, faults: Faults, workload: Workload.Options,
    events_max: u64, terms_max: u32, history_ops_max: u32, search_steps_max: u64,
    plant: Plant,
    pub fn quiet(seed: u64, nodes_count: u8) Options; // no loss, faults or workload
    pub fn sweep(seed: u64) Options; // 3 nodes (even seed) or 5 (odd), everything on
};
pub const Stats = struct { events: u64, leader_terms: u32, committed_max: u64, applied: u64,
    truncates: u64, partitions: u32, crashes: u32, torn_crashes: u32, restarts: u32,
    workload: Workload.Stats, network: Network.Stats, digest: u64 };
pub const LimitError = error{ EventsExhausted, TermsExhausted, HistoryTooLong,
    CheckInconclusive };
pub const NodeError = raft.InvariantError || raft.InitError || raft.ReceiveError ||
    CrashStore.InvariantError || error{ ProposeTooLarge, StoreFull, StoreCorrupt,
    StateMachineFailed };
pub const Error = invariants.Violation || LimitError || NodeError;
pub const Report = struct { seed: u64, event_index: u64, violation: Error };
pub const Simulation = struct {
    network: Network, // public for scripted partitions (PRD §4.5)
    virtual_clock: VirtualClock, // read-only from outside
    pub fn init(simulation: *Simulation, io: Io, gpa: Allocator, options: *const Options)
        Error!void;
    pub fn deinit(simulation: *Simulation, io: Io, gpa: Allocator) void;
    pub fn step(simulation: *Simulation, io: Io) Error!void;
    pub fn run_until(simulation: *Simulation, io: Io, time_ms: u64) Error!void;
    pub fn check(simulation: *Simulation, property: Property) Error!void;
    pub fn crash(simulation: *Simulation, io: Io, node_index: u8) void; // clean, scripted
    pub fn restart(simulation: *Simulation, io: Io, node_index: u8) Error!void;
    pub fn status(simulation: *const Simulation, node_index: u8) ?raft.Status; // null: down
    pub fn stats(simulation: *const Simulation) Stats;
    pub fn report(simulation: *const Simulation) Report; // only after a step failed
};
pub fn run_seed(io: Io, gpa: Allocator, options: *const Options, duration_ms: u64,
    report: *Report) Error!Stats; // init, run_until, check(.linearizability), deinit
```

- **`init` owns all memory.** Per node: a `CrashStore` (sized from `log_entries_max`,
  `log_bytes_max`; journal 8 ops, `entries_max * entry_bytes_max` bytes), a `KvStateMachine`
  (`applied_max = log_entries_max`), a `Prng`, and a `FixedBufferAllocator` of
  `Driver.init_bytes_max(&config)` bytes that every `Driver.init` uses and a restart resets.
  Plus `Network`, `Checker`, `Workload`, `HistoryChecker`. Nothing allocates after `init`.
- **One event per `step`**: the least `(time_ms, kind, node_index, seq)`, kinds ordered
  `deliver < restart < heal < fault < propose < tick`. The clock `advance_to`s it, then one
  of: `Driver.receive` of `pop_due` (a down target is `drop_down`); a restart; a heal; a fault
  draw (partition a seeded minority for `[1, partition_ms_max]`, or crash a node, torn with
  `torn_percent` via `arm_failure`); a workload `propose`; a tick (`poll` on every up node
  every `tick_ms`, `ticks_per_poll_max = 2`). `StoreIoFailed` from a driver call is the armed
  torn crash: `crash(keep_count)`, `keep_count` drawn in `[0, unsynced_count()]`; any other
  driver error is returned. Restart, `[1, down_ms_max]` ms later: `Driver.deinit`, a fresh
  `Driver.init` over the same store (ADR-006), lane generation + 1, `KvStateMachine.reset`,
  `Checker.restarted`.
- **After every event**: `node.check_invariants()` and `CrashStore.check_invariants()` per up
  node, `Checker.observe` over all up nodes, then each `drain()` into `Checker.applied` and
  `Workload.applied`. The first error latches the `Report`; a later `step` asserts.
- `run_until(time_ms)` steps while the next event is `<= time_ms`, then advances the clock to
  `time_ms`; reaching `events_max` first is `EventsExhausted`. `check(.linearizability)` runs
  `HistoryChecker` over `Workload.history()`; other properties ask `Checker`. Item 10's
  "checked at `run_until` end" is `run_seed`'s final `check`. `Plant` maps onto
  `Network.Fault`, `CrashStore.Fault`, `Workload.Fault`; it never touches `raft`/`driver`.

PRD §4.5 in snake case (item 4's PR points PRD §4.5 here):

```zig
const options = sim.Options.quiet(42, 5);
var simulation: sim.Simulation = undefined;
try simulation.init(io, gpa, &options);
defer simulation.deinit(io, gpa);
simulation.network.set_partition(&.{ 0, 1 }, &.{ 2, 3, 4 });
try simulation.run_until(io, 10_000);
try simulation.check(.election_safety); // and the other four, and .linearizability
```

**CLI** (item 7). `zig build sim [-Dseeds=N] [-Dseed=S] [-Dseed-first=F] [-Dplant=NAME]`;
`build.zig` turns the options into argv (`--seeds`, `--seed`, `--seed-first`, `--plant`; no
rebuild per seed) for `tools/sim_cli.zig`, built `ReleaseSafe`. It runs `run_seed` over
`Options.sweep(s)` for `s` in `[F, F + N)` (defaults `N = 1000`, `F = 0`), 10 000 ms each;
`-Dseed=S` runs only `S`; `-Dplant` sets `Options.plant`. First failure: prints `sim: FAIL
seed=S event=E violation=Name plant=P`, exits 1. Success: `sim: PASS seeds=N first=F
events=T`, exits 0. Bad arguments exit 2. CI runs `-Dseeds=1000`; the nightly
`-Dseeds=100000 -Dseed-first=<days since epoch * 100000>`. `zig build bench` gains
`sim_5n_10s`, `run_seed` over `Options.sweep(1)`.

Rejected: bare `Node`s (persist, sync, send, apply untested); one PRNG (a new draw reshuffles
all); `std.Random` (unpinned across releases); a stored `io`; crashes only between events
(vacuous under per-step sync); a growing pool; recursive search; inconclusive as a pass.

## Consequences

- **Changes outside `src/sim/`, to schedule:**
  1. `raft.Node.init_bytes_max(config: *const raft.Config) u64` and
     `Driver.init_bytes_max(config: *const raft.Config) u64` (every node allocation, the
     `log_entries_max` restore scratch, alignment slack per allocation). Additive, MINOR, in
     item 4's PR. Without it a restart allocates mid-run (Tiger Style §1.9).
  2. `tools/tidy.zig`: the three sim-purity decls (item 2). `build.zig`: `add_sim_step` and a
     CI step (item 7); `.github/workflows/sim-nightly.yml` (item 8).
  3. `cluster_test.zig` imports `invariants` (item 3); expectations that named the folded
     errors expect `StateMachineSafety`.
- **No change** to the five vtables, `Driver`'s signatures, or ADR-005 wire shapes: the
  network is a `Transport`, the crash store a `LogStore`, the KV a `StateMachine`. Applies are
  observed by recording (an `apply` cannot return a `Violation`) and truncates counted by the
  crash store (the driver hides `Effects`). `Driver.poll`'s `catch unreachable` stays; a sim
  hit on it is a `bug` issue fixed first, its seed the regression test.
- Tests beyond the plan's: `derive_seed` ignores `nodes_count`; `CrashStore` passes
  `store.conformance`; a 200-seed crash-heavy run asserts a floor of torn crashes that lost a
  write (item 5's vacuity floor).
- Phase 4 adds snapshot slots to `Network`, snapshot ops to `CrashStore.crash`, and
  conf-change and ReadIndex events: additive fields and variants, breaking only exhaustive
  switches (MINOR at 0.x).

## Amendments

- **Item 5 (crash and restart).** The event order within one virtual millisecond is
  `deliver < tick < restart < fault`, not the order above; a restart scheduled for time `t`
  runs before the fault draw of the same `t`. The journal is sized by `log_bytes_max` and an
  entry-slot bound (`log_entries_max`), not `entries_max * entry_bytes_max`. `Stats` gains
  `lossy_crashes` (crashes that dropped at least one unsynced write), the counter behind the
  "torn crashes that lost a write" vacuity floor. A restart that a planted store makes
  `RestoreInconsistent` leaves the node down for good (the node refuses to start on corrupt
  state); an honest store returning it is a bug. Scripted `crash` keeps zero unsynced writes
  (nothing is unsynced between events); only seeded torn crashes lose data.
