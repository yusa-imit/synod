# ADR-007: The Raft `Node` contract — `Input`, `Effect`, `Config`, and the driver

## Status

Accepted (plan 003, item 1).

## Context

PRD §4.2's `step(input) ![]Effect` leaves the slice's owner open and implies an allocation per
step (Tiger Style §1.9); `tick(now_ms)` hands the core time that ADR-002/006 route through the
injected `Clock`; `init(allocator, id, config, store)` has the pure core call `LogStore`.
`log.Log` borrows entry `data`, an `AppendRequest` borrows until `step()` returns, and
`LogStore.get` until the next mutation: without one named owner, entry bytes dangle. Once
zoltraak or silica pins synod, every shape below is MAJOR.

## Decision

```zig
pub const Config = struct { // src/raft/node.zig, re-exported by src/raft.zig; no defaults
    id: NodeId, // != .none (ADR-004)
    protocol_version: u16, // sent in every Header; protocol_version_min..=current
    election_ticks: u32, heartbeat_ticks: u32, // t, timeout in [t, 2t); heartbeat 1..t-1
    voters_max: u32, learners_max: u32, // per voter set <= types.voters_max; <= learners_max
    inflight_max: u32, // unacked AppendRequests per peer, > 0
    log_entries_max: u32, log_bytes_max: u32, // log.Log slots; node-owned entry bytes
    message_limits: Message.Limits, // validates every received Message; bounds every batch
};
pub const Restore = struct { // borrowed for the init call only; init copies all of it
    hard_state: HardState,
    entries: []const Entry, // the whole log, contiguous from index 1
    configuration: Configuration, // Phase 2: from the composition root, not the log
};
pub const Input = union(enum) {
    message: *const Message, // borrowed until step() returns
    tick, // one logical tick; carries no time value
    propose: []const u8, // command bytes, borrowed until step() returns; leader only
};
pub const Effect = union(enum) {
    truncate: Index, // LogStore.truncate(from)
    append: []const Entry, // LogStore.append; non-empty, contiguous
    save_hard_state: HardState, // LogStore.save_hard_state
    send: Message, // Transport.send; destination is header().to (ADR-006)
    apply: []const Entry, // StateMachine.apply each, index order, exactly once
    leader_changed: NodeId, // .none = unknown; informational
    pub const Phase = enum(u8) { persist = 1, send = 2, apply = 3, notify = 4 };
    pub fn phase(effect: *const Effect) Phase;
};
pub const Effects = struct { items: []const Effect }; // borrowed view, see below
pub const Role = enum { follower, pre_candidate, candidate, leader };
pub const Status = struct { role: Role, term: Term, vote: NodeId, leader: NodeId,
    commit_index: Index, applied_index: Index, last_index: Index };
pub const InitError = Allocator.Error || ConfError || error{ RestoreLogFull, RestoreInconsistent };
pub const ReceiveError = MessageError || error{StepMisrouted};
pub const ProposeError = error{ ProposeNotLeader, ProposeTooLarge, ProposeLogFull };
pub const StepError = ReceiveError || ProposeError; // a tick never fails
pub const InvariantError = log.Log.InvariantError || error{ InvariantCommitBeyondLog,
    InvariantAppliedBeyondCommit, InvariantTermBehindLog, InvariantVoteWithoutTerm,
    InvariantLeaderRole, InvariantEntryDataMisplaced, InvariantElectionTimeout,
    InvariantProgressOrder, InvariantInflightOverflow };
pub const Node = struct {
    pub fn init(node: *Node, gpa: Allocator, config: Config, restore: *const Restore,
        rng: Rng) InitError!void;
    pub fn deinit(node: *Node, gpa: Allocator) void;
    pub fn step(node: *Node, input: Input) StepError!Effects;
    pub fn status(node: *const Node) Status;
    pub fn entries(node: *const Node) []const Entry; // borrowed until the next step()
    pub fn check_invariants(node: *const Node) InvariantError!void;
};
pub const Driver = struct { // src/driver.zig, the std.Io boundary (ADR-002)
    node: raft.Node, // read-only from outside: node.status(), node.entries()
    pub const Options = struct { tick_ms: u32, ticks_per_poll_max: u32 };
    pub const Deps = struct { store: LogStore, transport: Transport,
        state_machine: StateMachine, clock: Clock, rng: Rng };
    pub const Fault = LogStore.WriteError || StateMachine.ApplyError; // UpdateError is a subset
    pub fn init(driver: *Driver, io: Io, gpa: Allocator, config: raft.Config, options: Options,
        configuration: *const Configuration, deps: Deps)
        (raft.InitError || LogStore.ReadError)!void;
    pub fn deinit(driver: *Driver, io: Io, gpa: Allocator) void;
    pub fn receive(driver: *Driver, io: Io, message: *const Message)
        (raft.ReceiveError || Fault)!void;
    pub fn propose(driver: *Driver, io: Io, data: []const u8) (raft.ProposeError || Fault)!void;
    pub fn poll(driver: *Driver, io: Io) Fault!void; // Clock -> ticks -> step(.tick)
};
```

- **One entry point.** `step` checks `Message.validate(config.message_limits)` and
  `header().to == config.id` first; a `StepError` returns before any mutation, with no
  `Effects`. Stale-term and unknown-sender messages are not errors: a reply or nothing.
- **Ticks, not time.** `Driver.poll` turns `clock.now_ms()` into whole `tick_ms` ticks, one
  `step(.tick)` each, at most `ticks_per_poll_max` (a longer stall drops the rest). PreVote's
  "heard from a leader" (thesis §9.6) is under `election_ticks` since the last valid append.
  The stored `Rng` is drawn once per election-timer reset, `t + rng.uint_less_than(t)`.
- **Effects: one ordered list, sized at `init`, borrowed.** `peers_max + 5` slots, with
  `peers_max = 2 * voters_max + learners_max - 1` (joint-sized, so Phase 4 changes no size).
  Per step, in this order: at most one `truncate`, `append`, `save_hard_state` (skipped when
  `eql` to the last emitted), one `send` per peer, one `apply`, one `leader_changed`. `phase()`
  is non-decreasing, asserted on emit (node) and on execute (driver). `Effects` and every slice
  it reaches borrow node memory until the next `step()`/`deinit()`; the driver finishes first.
- **The node owns entry bytes**: `log_bytes_max`, allocated at `init`, packed in index order.
  Proposals, received `AppendRequest.entries`, and `Restore.entries` are copied in; `log.Log`
  borrows from it; `truncate` reclaims the suffix. `LogStore.append` copies, `Transport.send`
  encodes, `StateMachine.apply` borrows for the call. `ProposeTooLarge` is data above
  `entry_bytes_max`; `ProposeLogFull`, no slot or byte left. A full follower stores the prefix
  that fits and acks its true match.
- **`init` takes data, not a `LogStore`.** `Conf*` for a configuration over the `Config` caps;
  `RestoreInconsistent` for entries not contiguous from 1, a term above `hard_state.term`, or
  `commit_index` past the log; `RestoreLogFull` past capacity. A restarted node is a follower
  at `applied_index == .zero` whose first step applies `(0, commit_index]` into a fresh state
  machine. `Driver.init` reads the store into a `gpa` scratch slice freed before return (reads
  do not mutate, so `get` borrows hold). A new leader appends an empty `.normal` entry (§5.4.2).
- **Persist, sync, send, apply; fail-stop.** The driver runs the persist phase, then one
  `store.sync()` if it held any effect, then sends, then applies (an `unsynced` flag is
  asserted clear before each send and apply). Step N+1 never runs before step N's sync, so the
  node counts its own match as `last_index` and every vote or ack is durable before it leaves.
  Any `Fault`, `StoreFull` included, stops the driver: it returns the error and asserts on any
  later call; recovery is a fresh `Driver.init` (ADR-006 crash model). `io` is per ADR-002.
- **Layout.** `src/raft/node.zig` (`step` split per message kind, under 70 lines; `src/raft.zig`
  drops `Error{NotImplemented}`); `src/raft/progress.zig` is internal, not re-exported
  (`match`/`next`, `probe`/`replicate`, `inflight_max` window). More `src/raft/*.zig` need no ADR.

Rejected: a `![]Effect` allocated per step (allocation after init); callbacks (REALM.md);
per-phase slices (the order stated twice); `tick(now_ms)` (time in the core); `init` reading
`LogStore` (I/O-shaped failure in the core); `Log` borrowing message or store bytes (dangles);
separate `tick`/`propose` methods (three places to assert the `Effects` lifetime).

## Consequences

- 2A-i: one test per `RestoreInconsistent` shape; a `StepError` leaves `status()`/`entries()`
  unchanged; seeded inputs keep `phase()` ordered and counts within capacity, with
  `check_invariants()` after every step. Ownership tests under `std.testing.allocator`
  overwrite the proposal and message buffers after `step`; an `Rng` fixture sees one draw per
  reset and both ends of `[t, 2t)`.
- 2D: sending before `sync` trips the assertion; a `Fault` stops the driver; a restart over
  the same `MemoryStore` re-applies `(0, commit_index]` in order.
- Memory is fixed at `init`. A commit-only `save_hard_state` costs a sync; plan 004 measures
  it, and dropping it changes no signature.
- Phase 4 adds snapshot effects (save in persist, restore in apply), `read_ready` (notify),
  conf-change and ReadIndex `Input` variants, `Restore.snapshot`, and a `log.Log` base index:
  breaking for exhaustive switches (MINOR at 0.x, MAJOR once pinned), absorbed by `Driver`.
  The progress `snapshot` state is internal and free. PRD §4.2 now points here (2A-i PR).
