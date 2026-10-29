# Plan 005 — Phase 4 snapshots, compaction, joint consensus, ReadIndex

## Goal

Bound the Raft log with snapshots and a compaction policy, catch lagging followers up with
InstallSnapshot, change membership by joint consensus only, serve ReadIndex reads, and drive
all of it through the sim under crashes, partitions and churn, reads checked for linearizability.

## Why now

v0.5.0 closed Phase 3 (milestone #57); Phase 4 is next in `REALM.md`'s build order and in
`000-inherited.md`. Without compaction a 64-entry log caps a sim run at 63 ops (cycle 65 had to
widen the workload test to 256 entries), so long seeds exercise a toy. Compaction goes first:
InstallSnapshot, catching up a new empty voter, and long read workloads all need it. silica and
zoltraak need membership change and reads before a Phase 6 PoC means anything. No `directive`.

## Scope

Every code item is one PR with a failing test first; `zig build test`, `zig fmt --check`,
`zig build tidy`, `zig build sim -Dseeds=1000` and all CI jobs green before merge. Every item is
`blocked_by: none`: synod depends on nothing.

- [x] 1. **ADR-009 — Phase 4 node contract.** `architect` (opus), docs, no test. Settles what
      ADR-007/008 deferred: `log.Log` base `(index, term)`; who snapshots (node emits a due
      effect, driver runs `StateMachine.snapshot` → `save_snapshot` → `sync`, node compacts on
      confirmation); knobs `snapshot_entries_min`, `trailing`; `Restore.snapshot`; `Input`/
      `Effect` variants for conf change, ReadIndex, install (persist), restore (apply); the
      effect slot count; `ConfChange` codec (magic, version, crc32); sim snapshot sizing.
      *Verify:* `docs/adr/0009-*.md` merged, naming every `pub` symbol of items 2–10.
- [x] 2. **4D-i `log.Log` base index.** `compact(through)` keeps the dropped prefix's
      `(index, term)` as base; `term_at(base)` answers, below it is a typed `LogCompacted` (a
      peer may ask legitimately); `validate` requires the first entry at `base + 1`. Node-owned
      bytes are re-packed once per compaction, never grown. *Failing test first:* 200 appends
      through a 64-slot log compacted every 32; seeded model of `term_at`/`append`/`truncate`.
- [x] 3. **4D-ii Compaction policy in the node.** Emit the due effect when
      `applied - base >= snapshot_entries_min`, compact on confirmation keeping `trailing`
      entries; `check_invariants` adds `base <= applied`. In `src/raft/snapshot.zig`: `node.zig`
      is at its 800-line cap. *Failing test first:* a `log_entries_max = 64` node commits and
      applies 500 proposals (red today with `ProposeLogFull`).
- [ ] 4. **4A-i Driver snapshot path, restart from a snapshot.** Snapshot into a buffer sized
      at `init`, save, sync, confirm; `Driver.init` restores the state machine from the store's
      snapshot and replays only `(base, commit]`. *Failing test first:* restart over a store
      with a snapshot at 400 plus 20 entries matches a never-crashed replica's KV digest; a
      snapshot over its buffer is a typed `Fault`, fail-stop.
- [ ] 5. **4A-ii InstallSnapshot.** A peer with `next <= base` enters progress `snapshot` and
      gets one whole `install_snapshot` (bounded by `snapshot_bytes_max`) per round timeout,
      then `probe`s from `match + 1`. A follower acks a snapshot at or below `commit` without
      installing; else truncate, install, restore, reply. *Failing test first:* a follower cut
      off across two compactions catches up only by snapshot; stale and duplicate snapshots
      change nothing; an oversize one is `MessageTooLarge`, never an assert.
- [ ] 6. **Sim snapshots.** The KV `"SKV1"` stream (ADR-008) replaces the `StateMachineFailed`
      stubs; `CrashStore.crash` covers `save_snapshot` (unsynced lost, torn caught by crc32);
      `Network` slots carry snapshot bytes; the checker adds equal state digests at equal
      applied index; the workload test returns to `log_entries_max = 64`. *Failing test
      first:* a planted restore that drops a key fails with its seed; 1000 seeds green with
      floors >= 30% seeds past 63 ops, >= 20% with an InstallSnapshot.
- [ ] 7. **4B-i `src/raft/membership.zig` — codec and joint quorum.** Pure: `ConfChange` in
      `Entry.data` (corrupt peer bytes are typed `Conf*` errors); a vote or match wins only
      with a majority of `voters` and, when joint, of `voters_outgoing`; legal transitions.
      *Failing test first:* a joint table where each side alone loses; codec round trip and a
      flipped byte; a seeded model against a brute-force subset count.
- [ ] 8. **4B-ii Joint consensus in the node.** `Input.conf_change`, leader only, one in flight
      (`ConfChangePending`); a configuration takes effect on append, not commit (thesis §4.1),
      and rolls back on truncate; the leader proposes `leave_joint` once `enter_joint` commits
      and steps down if outside C_new; learners never vote. No single-server path (REALM.md).
      *Failing test first:* 3→5 and 5→3 swaps that remove the leader; a second change while
      joint is refused; truncating an uncommitted `enter_joint` restores the old config.
- [ ] 9. **4C ReadIndex, `src/raft/read.zig`.** `Input.read_index(ctx)`, ctx bounded and
      copied; refused until an entry of the leader's term commits (thesis §6.4); `read_ready`
      once a joint-aware quorum acks a later heartbeat `round` and `applied >= index`; pending
      reads capped by `reads_max`, failed typed on step-down. *Failing test first:* a deposed
      minority leader never emits `read_ready`; read `reads_max + 1` is `ReadIndexFull`.
- [ ] 10. **Sim churn and linearizable reads.** Workload `get`s use ReadIndex, completing at
      `read_ready`; a churn event adds a learner, then `enter_joint`/`leave_joint`; election
      safety is judged per configuration. The new variants replace the `else =>` arms in
      `node_fault`/`propose_draw` with exhaustive switches (open since cycle 65). *Failing test
      first:* a planted `read_ready` without the round fails `Linearizability` with its seed;
      1000 seeds green with floors for a finished membership change and a joint-config read.
- [ ] 11. **Re-measure Tiger Style baseline and sweep cost.** Assert density, longest function,
      file sizes, tidy for new files; sim and bench timings vs PRD §5; nightly runtime vs its
      120-min cap (78 min on 2026-10-26; cut seeds if over 100). Tick 4A, 4B, 4D and ReadIndex
      in `000-inherited.md`, update README. Docs, no test. *Verify:* `zig build tidy` green,
      table in `STATE.md`, latest `sim-nightly.yml` run succeeded.
- [ ] 12. **Release v0.6.0.** MINOR bump in `build.zig.zon`, CHANGELOG (breaks listed), README
      install tag, annotated tag, GitHub release. Its test is the `REALM.md` gate: 0 test
      failures, 6 cross targets green, 0 open `bug` issues. *Verify:* `gh release view v0.6.0`.

## Out of scope

- Leader lease reads (the other half of 4C): safe only under a clock-drift bound the sim's
  single virtual clock cannot falsify. Plan 006 adds per-node skew first; that line stays open.
- Chunked InstallSnapshot, TimeoutNow (a wire change, ADR-005), single-server membership
  change (REALM.md), automatic learner promotion, Phase 5 and Phase 6 (strata snapshots: 6B).

## Risks

- **Configuration on append** is where joint-consensus bugs live; item 8 tests rollback, item
  10 churns it under crashes. A sim-found bug is fixed first as a `bug`, its seed the test.
- **Compacting what a slow follower needs**: `trailing` + InstallSnapshot; item 6's floor tests it.
- **Sizing**: per-node snapshot buffers times in-flight messages; ADR-009 sizes them and may
  outgrow ADR-007's `peers_max + 7` effect slots. `node.zig` is full: new code goes in new files.
- **Nightly cap**: more work per event may push 100k seeds past 120 min; item 11 measures.
- **Item size**: 6, 8 and 10 are largest; one that overruns a cycle is split in a plan-tick PR.

## Done when

- `zig build`, `zig build test`, `zig build tidy`, `zig build bench`, `zig fmt --check`,
  `zig build sim -Dseeds=1000` green on 0.16.0; all CI jobs green on `main`.
- `docs/adr/0009-*.md` and `src/raft/{snapshot,membership,read}.zig` exist;
  `grep -rn 'log_entries_max = 256' src/sim/` prints nothing.
- Latest `sim-nightly.yml` run succeeded; 4A, 4B, 4D, ReadIndex ticked in `000-inherited.md`;
  this plan's milestone issue closed; `gh release view v0.6.0` succeeds.

## Version impact

**MINOR**: 0.5.0 → 0.6.0. New `Input`/`Effect` variants, `Restore.snapshot` and `Config` fields
break exhaustive switches and literals; `VERSIONING.md` lets MINOR break at `0.x`, and no
kingdom `build.zig.zon` pins synod (re-checked at release), so no `migration` issue. The wire
is unchanged (`install_snapshot` exists per ADR-005; ReadIndex rides `round`), so
`protocol_version_current` stays 1; the `ConfChange` entry codec carries its own version.
