# ADR-009: Phase 4 node contract — log base, snapshots, joint consensus, ReadIndex

## Status

Proposed (plan 005, item 1); accepted when its PR merges. Amends ADR-007 and ADR-008 as stated.

## Context

ADR-007 deferred snapshot effects, conf-change and ReadIndex inputs, `Restore.snapshot` and a log
base; ADR-008 deferred snapshot slots, snapshot ops in `CrashStore` and churn. Today a 64-slot log
caps a run at 63 ops, `install_snapshot` gets only the term rules, conf entries are opaque, and
`node.zig` is at its 800-line cap. This ADR names every `pub` symbol of plan 005 items 2–10 so no
later cycle redesigns; once synod is pinned each shape is MAJOR.

## Decision

**Log base (item 2, `src/log.zig`).** Base `(index, term)` of the dropped prefix:

```zig
pub const Base = struct { index: Index, term: Term, // (index == .zero) == (term == .zero)
    pub const zero: Base = .{ .index = .zero, .term = .zero } };
pub const TermError = error{LogCompacted};
pub const Log = struct { entries: []Entry, count: u32, base: Base, // [i].index == base + 1 + i
    pub fn reset(log: *Log, base: Base) void; // empty at `base`: restore, install
    pub fn compact(log: *Log, through: Index) void; // base.index <= through <= last_index()
    pub fn term_at(log: *const Log, index: Index) TermError!Term; // index <= last (asserted)
    pub fn last_term(log: *const Log) Term;
    pub fn entry_at(log: *const Log, index: Index) *const Entry; // base < index <= last
    pub fn range(log: *const Log, after: Index, through: Index) []const Entry; // (after, through]
};
```

`compact` sets `base = (through, term_at(through))`, moving the kept slots to the front once.
`term_at(base.index)` is `base.term`; below it is `LogCompacted` (a peer may ask). `conflict_at`
requires `prev_log_index >= base.index` (callers trim, below). `validate`: first entry at
`base.index + 1` (`InvariantSnapshotGap`), term `>= base.term` (`InvariantTermRegressed`), and
`base.index`/`base.term` are both zero or both nonzero (`InvariantBaseMalformed`).
`Log` owns no bytes: `snapshot.compact` re-packs the node arena once per compaction (one
`copyForwards`, each `data` re-pointed), never grows it.

**Node contract (ADR-007 additions; `...` is unchanged).**

```zig
pub const Config = struct { ...,
    snapshot_entries_min: u32, // 1 ..< log_entries_max: due when applied - log base >= it
    snapshot_trailing: u32, // < snapshot_entries_min: entries kept at or below the snapshot
    reads_max: u32 }; // >= 1; snapshot_bytes_max stays message_limits' (<= maxInt(u32))
pub const Restore = struct { hard_state: HardState,
    snapshot: log.Base, // the store's snapshot; .zero when none
    entries: []const Entry, // contiguous from snapshot.index + 1
    configuration: Configuration }; // as of snapshot.index; the bootstrap one when none
pub const Input = union(enum) { message: *const Message, tick, propose: []const u8,
    conf_change: *const Configuration, // target C_new and learners, settled; leader only
    read_index: u64, // ctx, echoed in `Read`; leader only
    snapshot_saved: Index }; // the pending snapshot_due, saved and synced; emits nothing
pub const Read = struct { ctx: u64, index: Index };
pub const SnapshotSend = struct { header: Header, snapshot: log.Base };
pub const SnapshotDue = struct { snapshot: log.Base, configuration: Configuration };
pub const Effect = union(enum) {
    truncate: Index, append: []const Entry, save_hard_state: HardState, // persist
    save_snapshot: interfaces.SnapshotRecord, // persist; install: data borrows Input.message
    send: Message, send_snapshot: SnapshotSend, // send; the driver fills data from the store
    restore: Index, apply: []const Entry, // apply; restore before any apply
    leader_changed: NodeId, read_ready: []const Read, read_failed: []const Read, // notify
    snapshot_due: SnapshotDue, // snapshot; at most one, always last
    pub const Phase = enum(u8) { persist = 1, send = 2, apply = 3, notify = 4, snapshot = 5 };
};
pub const Status = struct { ..., snapshot_index: Index, configuration_index: Index,
    reads_pending: u32 };
pub const InitError = Allocator.Error || ConfError || membership.ConfDecodeError ||
    error{ RestoreLogFull, RestoreInconsistent };
pub const ReceiveError = MessageError || membership.ConfDecodeError || error{StepMisrouted};
pub const ConfChangeError = ConfError || error{ ConfChangeNotLeader, ConfChangePending,
    ConfChangeTooLarge, ConfChangeLogFull };
pub const ReadIndexError = error{ ReadIndexNotLeader, ReadIndexNotReady, ReadIndexFull };
pub const StepError = ReceiveError || ProposeError || ConfChangeError || ReadIndexError;
pub const InvariantError = ... || error{ InvariantBaseBeyondApplied,
    InvariantConfigurationInvalid, InvariantReadOrder };
// Node gains: pub fn configuration_current(node: *const Node) Configuration; // borrowed
pub const Driver = struct { ..., // src/driver.zig
    pub const Fault = LogStore.WriteError || LogStore.ReadError || StateMachine.ApplyError ||
        StateMachine.RestoreError || error{SnapshotTooLarge};
    pub const ReadOutcome = enum(u8) { ready = 1, failed = 2 };
    pub const ReadDone = struct { read: raft.Read, outcome: ReadOutcome };
    pub fn init(...) (raft.InitError || LogStore.ReadError || StateMachine.RestoreError)!void;
    pub fn conf_change(driver: *Driver, io: Io, target: *const Configuration)
        (raft.ConfChangeError || Fault)!void;
    pub fn read_index(driver: *Driver, io: Io, ctx: u64) (raft.ReadIndexError || Fault)!void;
    pub fn reads_done(driver: *const Driver) []const ReadDone; // this call's; until the next
};
```

- **Effects: `peers_max + 9` slots** (`effects_fixed_count = 9`). Worst step: a deposed
  leader takes a conflicting batch from a higher term: `save_hard_state`, `truncate`,
  `append`, `save_hard_state`, one `send`, `apply`, `read_failed`, two `leader_changed`,
  `snapshot_due` = 10; a leader's steps are smaller. Step end runs `apply_ready`, then
  `read.emit`, then `snapshot.emit_due`.
- **Restart.** `Driver.init` loads the snapshot record: if any, `StateMachine.restore` from it,
  `Restore.snapshot`/`configuration` from it, `get` over `(snapshot, last]`; else the bootstrap
  `configuration`. `RestoreInconsistent` adds `snapshot.term > hard_state.term` and a first entry
  not at `snapshot.index + 1` or below `snapshot.term`. `commit = max(hard_state.commit,
  snapshot.index)` (a crash may lose the install's commit save), `applied = snapshot.index`.

**Who snapshots (items 3, 4).** At step end, if no due is pending and `applied - log.base.index
>= snapshot_entries_min`, the node emits `snapshot_due` (`applied`, its term, the configuration
as of `applied`). The driver runs it last: `StateMachine.snapshot` into a fixed writer over a
buffer of `snapshot_bytes_max` allocated at `init` (`WriteFailed` maps to `SnapshotTooLarge`,
fail-stop), `save_snapshot`, `sync`, then `step(.{ .snapshot_saved = index })`, whose `Effects`
it asserts empty. The node records `snapshot_index`, compacts through `max(base, index -|
snapshot_trailing)` and re-packs bytes. The store keeps nothing at or below `index`; the node
keeps `snapshot_trailing` entries for slightly lagging peers. `check_invariants` adds
`log.base <= snapshot_index <= applied` (`InvariantBaseBeyondApplied`).

**InstallSnapshot (item 5).** Progress (internal) gains `State.snapshot`, `on_snapshot_sent(p,
snapshot_index) void` (`next = index + 1`, one in flight) and `on_snapshot_acked(p, match_index)
bool` (only `match_index == next - 1`; then `match`, `next = match + 1`, `.probe`); 32 bytes
still. A peer with `next <= log.base.index` gets one `send_snapshot` and a `Round` record
that expires after `election_ticks` (then `on_timeout`, resent). The driver builds
`install_snapshot` from `load_snapshot()`; a missing or mismatched record is `StoreCorrupt`.
A follower: term rules first; a configuration over `Config` caps is `Conf*` before any
mutation; oversize data is `MessageTooLarge` (`validate`). `snapshot.index <= commit`: reply
`match_index = snapshot.index`, change nothing. Else `save_snapshot` (the store keeps the
suffix iff it holds `(index, term)`; the node mirrors it or `reset`s), the configuration copied,
`save_hard_state(commit = index)`, the reply, `restore(index)`; so `Input.message` lives until
the step's effects ran (`Driver.receive` holds it). An `append_entries` with `prev_log_index <
log.base.index` is trimmed to entries above the base (committed, so matching); if none remain
it is accepted at its last index.

**Conf-change codec and quorum (item 7, `src/raft/membership.zig`, pure).**

```zig
pub const conf_magic = "SYCC".*; pub const conf_version: u8 = 1;
pub const conf_ids_max: u32 = 2 * types.voters_max + types.learners_max; // 48
pub const conf_bytes_max: u32 = 13 + 8 * conf_ids_max; // 397
pub const ConfDecodeError = error{ ConfLength, ConfMagic, ConfVersion, ConfKind, ConfChecksum };
pub fn encoded_bytes(change: *const ConfChange) u32; // 13 + 8 * ids
pub fn encode(change: *const ConfChange, out: []u8) u32; // out.len >= encoded_bytes, asserted
pub fn decode(bytes: []const u8, ids: *[conf_ids_max]NodeId)
    (ConfDecodeError || ConfError)!ConfChange; // slices point into `ids`
pub fn enter_joint(current: *const Configuration, target: *const Configuration) ConfChange;
pub fn leave_joint(current: *const Configuration) ConfChange; // voters, learners of current
pub const Matches = struct { voters: []const u64, voters_outgoing: []const u64 }; // aligned
pub fn quorum_index(configuration: *const Configuration, matches: *const Matches) u64;
pub fn quorum_reached(configuration: *const Configuration, ids: []const NodeId) bool;
```

Layout, little-endian: magic 4 | version u8 | kind u8 (1 enter, 2 leave) | three list counts
u8 | ids u64 (voters, outgoing, learners) | `std.hash.Crc32` over all before it, u32. Decode
order: length >= 13, magic, version, exact length, checksum, kind, `ConfChange.validate`. A
quorum is a majority of `voters` and, when joint, of `voters_outgoing`; `quorum_index` is the
lower of the two sets' majority matches; learners count in neither.

**Joint consensus (item 8; node glue in `src/raft/reconfigure.zig`).** `Input.conf_change`
takes the target, not a `ConfChange`: the leader builds `enter_joint(current, target)`, so a
caller cannot submit `leave_joint`. Refusals, before mutation: not leader; target not settled
or over `Config` caps (`Conf*`); `ConfChangePending` while joint or `configuration_index >
commit`; `ConfChangeTooLarge` above `entry_bytes_max`; `ConfChangeLogFull`. A target equal to
the voters (only learners change) is legal. Rules: a configuration takes effect when its entry
is appended (leader, follower, restore), not committed; the leader rebuilds `Progress` then
(survivors keep theirs, new peers start at `Progress.init(last)`; slots: voters, outgoing-only,
learners, who replicate but never count). A truncate dropping `configuration_index` rescans
`(base, from)` backward for the last `conf_change`, else the configuration as of the base.
Decoding a node-held entry cannot fail (validated on receive or restore): asserted. When
`enter_joint` commits, the leader appends `leave_joint` (sent with each peer's next send); when
`leave_joint` commits and it is not in `voters`, it steps down at step end (term kept,
`leader_changed(.none)`, reads failed). A node not a voter in its own configuration never
grants a vote or pre-vote, never campaigns, and its grants are never tallied. There is no
single-server path. Internal `pub fn`s: `reconfigure.{on_append, on_truncate, on_compact,
on_commit, step_conf_change}`; `snapshot.{emit_due, saved, compact, step_install,
step_install_response, send}`; `read.{Storage, register, ack, fail_all, emit,
check_invariants}`.

**ReadIndex (item 9, `src/raft/read.zig`; thesis §6.4).** `read_index(ctx)`: `ReadIndexNotLeader`;
`ReadIndexNotReady` until `term_at(commit) == term`; `ReadIndexFull` at `reads_max`. It records
`{ctx, index = commit, round_min = rounds.id_next}`. Every `append_entries_response` at our
term from a voter slot, accepted or rejected, live round or not, raises that slot's
`acked_round`. A read is ready when the voters with `acked_round >= round_min`, plus self, form
a joint-aware `quorum_reached` under the configuration at check time. `round_min` never
decreases, so ready reads are a FIFO prefix; `read_ready` (then `read_failed`) are slices of a
`reads_max` out-buffer, emitted after `apply`, so `applied >= index` holds at the driver. A lone
voter is ready in its registering step. Any step-down fails every pending read in that step.
`InvariantReadOrder`: reads while not leading, over `reads_max`, index over commit, unordered.

**Simulator (items 6, 10; amends ADR-008).** `KvStateMachine`: stream magic `"SKV1"` | version
u8 | keys u16 | values u64 | crc32: `snapshot_magic`, `snapshot_version: u8 = 1`,
`snapshot_bytes(keys_count: u16) u32` (`11 + 8 * keys`), `digest(kv) u64`, `value(kv, key:
u16) u64`, `Fault = enum(u8) { none = 1, restore_drops_key = 2 }` in `Options.fault`.
`Checker.state_digest(checker, node_index: u8, applied: Index, digest: u64) Violation!void`: a
ring of `log_entries_max` `(index, digest)`; unequal digests at one index is
`StateMachineSafety`. `Network.snapshot_ids_max = 3 * nodes_max`. `CrashStore` journals
`save_snapshot` (unsynced lost, torn caught by crc32); `crash` stops asserting no snapshot.
`Workload.Fault.stale_read = 3` (a get served locally, no ReadIndex), `Workload.read_completed(
workload, node_index: u8, ctx: u64, value: u64, event_index: u64) InvariantError!void` (`ctx`
is `op_id`; a failed or refused read is `rejected`). `workload_hooks.ProposeFailure` adds
`raft.ReadIndexError`. `Faults.churn_percent: u8`: demote a seeded voter to learner or promote
a learner, one `Driver.conf_change`. `Plant.restore_drops_key = 6`, `stale_read = 7`.
`Stats` adds `snapshots: u64, installs: u64, conf_changes: u32, reads: u64`.

**Sim snapshot sizing.** `S = snapshot_bytes(keys_count)`; `WorkloadInvalid` adds
`snapshot_bytes_max < S`. Per node: driver buffer, `CrashStore` live, durable and one
journalled copy (at most one snapshot op is unsynced: the driver syncs after it) = `4S`.
`Network.bytes_required` adds `(messages_max + 1) * (S + 8 * snapshot_ids_max)`: each slot
owns a whole snapshot, so a duplicate or reorder never shares bytes. Presets set
`entry_bytes_max = 13 + 8 * snapshot_ids_max` (181, a 7-node joint change) and
`log_bytes_max += 4 * 181`. Sweep (5 nodes, 4 keys, 64 messages): S = 43 B, 65 × 211 B + 5 ×
172 B < 15 KiB of snapshot memory; `entries_max * entry_bytes_max` slots grow to 47 KiB.

**Wire.** No kind or field changes: `install_snapshot` exists (ADR-005), ReadIndex rides
`round`, `ConfChange` rides `Entry.data` with its own magic, version, crc32;
`protocol_version_current` stays 1. A v0.5 node ignores snapshots and conf entries, so mixed
0.5/0.6 clusters are unsupported; no consumer pins synod, so none exists to upgrade.

Rejected: a node-owned snapshot copy (a second `snapshot_bytes_max`; the store has it);
compacting unconfirmed (the leader could offer an unsaved snapshot); one effect per read
(unbounded slots); `ctx: []const u8` (a copy buffer; a `u64` is bounded and copied by value);
`Input.conf_change: ConfChange` (a caller-made `leave_joint`); a configuration-history array (the
rescan is bounded by `log_entries_max`); queueing reads before the term's commit; chunked
install, TimeoutNow, single-server change, lease reads (plan 005: out of scope).

## Consequences

- MINOR at 0.x: new `Input`/`Effect` variants, `Config`/`Restore`/`Status` fields,
  `Driver.Fault` and `Driver.init`'s error set, a fallible `Log.term_at`. `Transport`,
  `LogStore`, `StateMachine`, `Clock`, `Rng` vtables are unchanged.
- ADR-007 amended: `peers_max + 9` effects; restart at `applied = snapshot.index`; `Input.message`
  lives through effect execution; `Progress`, rounds for `peers_max` peers (was `2 * voters_max`).
- `Node.init_bytes_max` adds three member buffers (current, base, scratch), `2 * reads_max`
  `Read`s and `peers_max` round acks; `Driver.init_bytes_max` adds `snapshot_bytes_max` and
  `reads_max` `ReadDone`s. Nothing allocates after `init`.
- Tests beyond plan 005's: `effects_capacity` covers the 10-effect step; one test per
  `ConfDecodeError`; no `send_snapshot` before `snapshot_saved`.

## Notes for implementers

1. **`node.zig` cannot take the new declarations.** Item 3 first moves `Config` through
   `InvariantError` (not `Node`) to `src/raft/contract.zig`, re-exported by `src/raft.zig`.
2. **Base-zero arithmetic** (42 non-test sites use `log.count` as an index): `commit.zig`,
   `node_init.zig`, `follower.zig`, `Driver.init`'s `get(1..)`. Items 2–3 use `range`/`entry_at`.
3. **Learners get nothing today** (`leader.zig`: "learners get nothing"; `progress_capacity =
   2 * voters_max`). Item 8 widens slots to `peers_max` and keeps learners out of quorums.
4. **Joint quorum exists twice** (`election.quorum_reached`, `commit.quorum_index`). Item 7
   moves both into `membership.zig`; no third copy.
5. **`follower.zig` asserts only `leader_changed` follows `leader_changed`**; assert phase order
   instead. `apply_ready`'s `notify_max = 2` shift holds: read and snapshot effects come after.
6. **Plan wording vs. this ADR.** `trailing` is `snapshot_trailing`. `snapshot_bytes_max` is
   `message_limits.snapshot_bytes_max`, not a new knob. The ctx is a `u64`. "Planted
   `read_ready` without the round" is `Workload.Fault.stale_read` (ADR-008: plants never touch
   `raft`). "Election safety judged per configuration" stays per term.
7. `src/membership.zig` is the SWIM stub; item 7 writes `src/raft/membership.zig`. `CrashStore`
   asserts `snapshot == null` (`crash_store.zig:126`, `:299`); item 6 drops both. The presets'
   `entry_bytes_max = command_bytes` (24) cannot hold a conf entry; item 10 raises it.
