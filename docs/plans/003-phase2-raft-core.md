# Plan 003 — Phase 2: pure Raft core, election and replication

## Goal

Turn the `raft` and `driver` stubs into a pure Raft core: a `Node` changed only by `step()`/
`tick()`, returning Effects by value, with PreVote election, `progress`-tracked replication and
commit advancement, and a driver executing Effects against ADR-006's interfaces; release v0.4.0.

## Why now

v0.3.0 closed Phase 1 (milestone #20); `REALM.md`'s build order puts `raft` (election, then
replication) and then `driver` next. ROADMAP Phase 2 wants synod at "types + log + raft
election/replication + simulator" before zoltraak's sentinel election moves onto it, and Phase 3's
simulator (plan 004) can only drive a core that exists. The Effect and Input shapes are free to
choose while nothing pins synod; once zoltraak or silica does, changing them is MAJOR.

## Scope

- [ ] **ADR-007 — `Node`, `Input`, `Effect`, `Config`, driver contract.** `architect` (opus),
      docs-only PR. PRD §4.2's `![]Effect` leaves ownership open and `tick(now_ms)` conflicts
      with the injected `Clock`; decide: the bounded Effects container returned by value (sized
      at `init` from `voters_max + learners_max` and `Message.Limits`, no growth); `tick` input;
      `Rng` for election jitter; how `init` receives restored `HardState` and log without the
      core calling `LogStore`; who owns proposed entry bytes (`log.Log` borrows, `MemoryStore`
      copies); the persist-before-send ordering the driver must honor; `check_invariants()`'s
      `error.Invariant*` set; file layout `src/raft/{node,progress}.zig`. *Verify:*
      `docs/adr/0007-*.md` merged; every new `pub` symbol in items 2–10 is named in it.
      `blocked_by: none`
- [ ] **2A-i `raft/node.zig` skeleton — roles, term rules, invariants.** First, widen tidy's
      `core_purity_files` from whole-path matches to also cover `src/raft/` (today
      `src/raft/node.zig` would escape the `std.Io` ban; the gate must exist before the file).
      Then `init`, roles (follower, pre_candidate, candidate, leader), "higher term: step down
      and emit persist", stale-term drop, `check_invariants()`. *Verify:* tidy fixture with
      `std.Io` in `src/raft/x.zig` is flagged; term-rule tests call `check_invariants()` after
      every `step`. `blocked_by: none`
- [ ] **2A-ii Election — randomized timeout, RequestVote, vote granting.** Timeout drawn from
      `Rng` in `[t, 2t)`; one vote per term, persisted before the response (Effect order);
      §5.4.1 up-to-date check via `log.last_index`/`term_at`; quorum over `Configuration`
      computed joint-shaped from day one (ADR-005) though Phase 2 never enters joint. *Verify:*
      hand-driven 3- and 5-node tests: one leader, split vote retries, stale log refused.
      `blocked_by: none`
- [ ] **2A-iii PreVote.** Split from 2A-ii: a second message pair and role. A pre-candidate bumps
      no term; a node that heard from a leader within the minimum timeout refuses (thesis
      §9.6). Why: a partitioned node rejoining must not depose a healthy leader. *Verify:*
      test where an isolated node ticks 100 timeouts and rejoins — cluster term unchanged,
      leader kept. `blocked_by: none`
- [ ] **2C `raft/progress.zig` — per-follower tracker.** Before replication, which consumes it.
      `match`/`next`, `probe`/`replicate` states, in-flight window bounded at `init`, fast
      backtrack from a `Conflict`. Internal (not re-exported from `root.zig`), so Phase 4 can
      add a `snapshot` state without a MAJOR. *Verify:* unit tests plus a seeded test against
      a naive reference; `match < next` asserted on both update paths. `blocked_by: none`
- [ ] **2B-i Leader replication — propose, AppendEntries, heartbeats.** `propose` appends to the
      leader log and emits persist; `tick` sends heartbeats; batches bounded by
      `Message.Limits`; responses update `progress` (accepted → `match`, rejected → backtrack).
      *Verify:* leader + 2 hand-stepped followers: a proposal reaches all logs; a rejection
      backs `next` up to the conflict run in one round trip. `blocked_by: none`
- [ ] **2B-ii Follower log matching.** Split from 2B-i: the receive side. Consistency check with
      `Log.conflict_at`, truncate only a conflicting suffix (never committed entries, asserted),
      append, reply `accepted(match)` or `rejected(Conflict)`. *Verify:* Raft paper Figure 7
      follower logs (a)–(f) each converge to the leader's log; `log.validate()` after each step.
      `blocked_by: none`
- [ ] **2B-iii Commit advancement and apply.** Leader commits the highest index a quorum
      matches, only for a current-term entry (§5.4.2); followers take `min(leader_commit, last
      new index)`; emit `apply` in order, once. Why its own item: Figure 8 is the classic bug.
      *Verify:* a Figure 8 test (old-term entry never committed by counting); commit never
      decreases, asserted. `blocked_by: none`
- [ ] **Model-based seeded cluster test.** Tiger Style §5's library form of simulation, ahead of
      Phase 3's `sim/`: a test-only harness (3 and 5 nodes, seeded delivery order, drops,
      duplicates, fake `Clock`/`Rng`) checks `check_invariants()` on every node after every
      step, plus election safety, log matching, leader completeness, state machine safety.
      *Verify:* 500 seeds pass in `zig build test` in < 10 s; a planted bug (skip the
      current-term commit rule) fails and reports its seed. `blocked_by: none`
- [ ] **2D `driver.zig` — Effect executor.** The `std.Io` boundary (ADR-002). Executes Effects
      in ADR-007 order: `append`/`truncate`/`save_hard_state`, then `sync`, then `send`, then
      `apply`; store faults are fail-stop per ADR-006. *Verify:* three drivers over
      `MemoryStore`, a queue `Transport`, and a recording `StateMachine` elect a leader and
      apply the same 100 entries; a fixture sending before `sync` trips an assertion.
      `blocked_by: none`
- [ ] **Re-measure the Tiger Style baseline.** Assert density, longest function, and tidy numbers
      for `src/raft/*` and `driver.zig`; `step()`'s dispatch is the likeliest 70-line breach —
      split per message kind, never widen the baseline. Flip README rows for raft (election,
      replication) and driver. *Verify:* `zig build tidy` green; new table in `STATE.md`.
      `blocked_by: none`
- [ ] **Release v0.4.0.** MINOR bump in `build.zig.zon`, CHANGELOG section, README install tag,
      annotated tag, GitHub release. Gate per `REALM.md`: 0 test failures, 6 cross-compile
      targets green, 0 open `bug` issues. *Verify:* `gh release view v0.4.0` succeeds and
      `zig fetch` of the tag resolves. `blocked_by: none`

## Out of scope

- Phase 3 `sim/` (virtual network/clock, 100k-seed nightly, linearizability checker) — plan 004
  lifts item 9's harness into it rather than duplicating it.
- Phase 4: snapshots and `install_snapshot`, joint-consensus transitions, learners, ReadIndex,
  lease reads, CheckQuorum, compaction; the `snapshot` Effect and progress state stay undeclared.
- Leader transfer, proposal forwarding, and batching or pipelining beyond `Message.Limits`.
- ADR-003's mechanical assertion-density gate: item 11 gives the numbers; propose it in plan 004.
- Adapters (sirocco transport, strata logstore) and any consumer PoC (ROADMAP Phase 3).

## Risks

- **Effect shape is the most expensive decision here.** Item 1 fixes it by ADR before code; if
  items 2–10 need a change, amend ADR-007 in that PR with the reason, never drift silently.
- **Entry-byte ownership across `propose`, `log.Log` (borrows) and `MemoryStore` (copies)** can
  dangle. ADR-007 names the owner; the seeded test runs under `std.testing.allocator`.
- **Item sizing.** 2B-i and the seeded harness are the largest; if either overruns a cycle,
  split it (send side vs response side; harness vs property checks) in a plan-tick PR first.
  Item 9 also caps seeds and steps per seed; the large sweep is Phase 3's `zig build sim`.

## Done when

- `zig build`, `zig build test`, `zig build tidy`, `zig build bench`, `zig fmt --check` green on
  0.16.0; all 7 CI jobs green on `main`.
- `grep -c NotImplemented src/raft.zig src/driver.zig` → 0; `docs/adr/0007-*.md` exists.
- Phase 2 items 2A–2D ticked in `docs/plans/000-inherited.md`, this plan's milestone issue
  closed, `gh release view v0.4.0` succeeds.

## Version impact

**MINOR** — 0.3.0 → 0.4.0. Additive (`raft.Node`, `Input`, `Effect`, `Config`,
`driver.Driver`); dropping the stubs' `Error{NotImplemented}` is a removal, but `VERSIONING.md`
keeps foundation at `0.x` where MINOR may break, and no kingdom `build.zig.zon` pins synod, so
no `migration` issue. ADR-005 wire shapes do not change; a PR that needs one says so, as that
is MAJOR once pinned.
