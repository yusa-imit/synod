# Plan 004 — Phase 3 deterministic simulation harness

## Goal

Turn the `sim` stub into a deterministic simulator: virtual clock and network driving real
`Driver`s over crash-capable stores, five Raft safety properties checked after every event, a
linearizability checker over a log-replicated KV workload, `zig build sim -Dseeds=N` in CI.

## Why now

v0.4.0 closed Phase 2 (milestone #39). `REALM.md`'s build order and ROADMAP's synod target
("raft election/replication + simulator") put `sim` next; Phase 4 is only trustworthy under a
sweep that exists first. Plan 003's `raft/cluster_test.zig` proves the method at 500 seeds but
drives bare `Node`s, never crashes one, and checks four of five properties; this plan promotes
it into the public `sim` module (PRD §4.5) instead of growing a second harness.

## Scope

- [ ] 1. **ADR-008 — simulator contract.** `architect` (opus), docs, no test. Decide: sim drives
      `Driver`s (so persist→sync→send→apply is exercised) and threads the caller's `io`; one root
      seed split into per-concern PRNG streams (adding a node must not reshuffle network draws);
      limits `nodes_max`, `messages_max`, `delay_ms_max`, `events_max`, `history_ops_max`,
      `search_steps_max`, all sized at `init`; crash model (unsynced writes lost); `Report`
      (seed, event, violation) and `sim.Error`; PRD §4.5 `runUntil`/`check` in snake_case;
      layout `src/sim/*.zig`. *Verify:* `docs/adr/0008-*.md` merged; every `pub` symbol of
      items 2–10 named in it. `blocked_by: none`
- [ ] 2. **3A-i `sim/clock.zig`, `sim/network.zig`.** First widen tidy's purity gate to
      `src/sim/` (no wall clock, fs, net, threads), as plan 003 did for `src/raft/`. Clock only
      moves forward (asserted). Network: fixed in-flight table promoted from `cluster_test`'s
      `Slot` (owned entry copies), seeded delay, loss and duplicate percent, reorder by delay,
      partitions as a reachability matrix; a full table drops and counts, never grows.
      *Failing test first:* tidy flags a `src/sim/` fixture using `std.time`; one seed run twice
      gives the same delivery-trace hash; a cut pair never delivers. `blocked_by: none`
- [ ] 3. **3B `sim/invariants.zig` — five safety properties.** Promote `cluster_test`'s `Oracle`
      and add the missing *leader append-only* (a leader never truncates or overwrites its own
      log in its term). Pure over observations, blind to `Node` internals; `cluster_test`
      imports it in the same PR so no duplicate outlives a cycle. *Failing test first:* per
      property, a hand-built history that passes and one that fails with the named error.
      `blocked_by: none`
- [ ] 4. **3A-ii `sim/simulation.zig` — event loop.** `init(gpa, io, options)` builds N drivers
      over `MemoryStore`, a network-backed `Transport`, the virtual `Clock`, a recording
      `StateMachine`; `step` runs one event (delivery or clock advance + `poll`), then every
      node's `check_invariants()` and item 3's checker; `run_until(ms)` stops at `events_max`
      with a typed error, never loops unbounded. *Failing test first:* PRD §4.5's scenario
      (5 nodes, `{0,1}`/`{2,3,4}`, 10 s) elects in the majority and commits; the minority never
      commits. `blocked_by: none`
- [ ] 5. **3A-iii Crash and restart.** Sim-only crash store: writes since the last `sync` vanish
      on crash; restart is a fresh `Driver.init` over the same store (ADR-006). Why: no harness
      yet tests persist-before-send, the rule a double vote breaks. *Failing test first:* a
      planted store that loses a *synced* `save_hard_state` makes a seed fail `ElectionSafety`
      with its seed in the `Report`; the honest store passes 200 crash-heavy seeds.
      `blocked_by: none`
- [ ] 6. **Retire the duplicate harness.** Port `cluster_test`'s scenarios, vacuity floors (≥40%
      seeds with two leader terms, ≥30% with a truncate) and planted faults (`forge_votes`,
      `flip_data`) onto `Simulation`; delete its `Cluster`. *Failing test first:* the ported
      floor and planted-fault tests run red against item 4's sim before wiring. *Verify:*
      `zig build test` < 10 s, `cluster_test.zig` gone or < 150 lines. `blocked_by: none`
- [ ] 7. **3C `zig build sim -Dseeds=N`.** A build step (default 1000, `-Dseed=S` replays one),
      ReleaseSafe, prints the first failing `Report` and exits non-zero; a CI step runs
      `-Dseeds=1000`; `zig build bench` gains PRD §5's scenario (5 nodes, 10 s virtual).
      *Failing test first:* a planted-fault option exits non-zero naming the seed. *Verify:*
      CI job green; bench median recorded in `STATE.md` against the < 50 ms target.
      `blocked_by: none`
- [ ] 8. **Nightly 100k-seed sweep.** Scheduled + `workflow_dispatch` job running
      `zig build sim -Dseeds=100000` (PRD §4.5), seed window rotated by date. Why separate: its
      own failure mode (runtime cap). *Verify:* `gh run list --workflow sim-nightly.yml` success.
      *Failing test first:* a dispatch with item 7's planted fault goes red. `blocked_by: none`
- [ ] 9. **3D-i `sim/linearizability.zig` — checker.** Wing–Gong/Porcupine search over a KV
      model, split per key (P-compositionality); explicit stack, no recursion; pending
      (indeterminate) ops allowed; histories over `history_ops_max` are refused and a search
      past `search_steps_max` returns `error.CheckInconclusive`, never "pass". *Failing test
      first:* Porcupine-paper histories (linearizable, not, with pending ops) and an
      over-budget one. `blocked_by: none`
- [ ] 10. **3D-ii KV workload in the sim.** Clients propose `put`/`get` entries (reads go through
      the log: ReadIndex is Phase 4); invoke at propose, complete at the proposer's apply,
      pending if it crashed or lost leadership; checked by item 9 at `run_until` end.
      *Failing test first:* a planted harness fault that acks an uncommitted `put` fails
      `Linearizability` with its seed; 1000 seeds pass under `zig build sim`. `blocked_by: none`
- [ ] 11. **Re-measure Tiger Style baseline.** Assert density, longest function, tidy numbers for
      `src/sim/*`; flip README's sim row, tick Phase 3 (3A–3D) in `docs/plans/000-inherited.md`.
      Docs, no test. *Verify:* `zig build tidy` green; table in `STATE.md`. `blocked_by: none`
- [ ] 12. **Release v0.5.0.** MINOR bump in `build.zig.zon`, CHANGELOG, README install tag,
      annotated tag, GitHub release. Its test is the `REALM.md` gate: 0 test failures, 6 cross
      targets green, 0 open `bug` issues. *Verify:* `gh release view v0.5.0`; `zig fetch` of the
      tag resolves. `blocked_by: none`

## Out of scope

- Phase 4 (snapshots, joint consensus, ReadIndex, compaction); the sim gains those events then.
- Phase 5 (SWIM, phi-accrual, HLC) and Phase 6 adapters; the sim never opens a socket or file.
- ADR-003's mechanical assertion-density gate, deferred again by plan 003: a tooling theme for
  plan 005 or a stabilize cycle; item 11 keeps the numbers current.

## Risks

- **The sweep will find real bugs.** That is the point; a sim-found bug is fixed as a `bug`
  first (CYCLE.md), with its seed as the regression test, before the next item. The open
  `catch unreachable` in `driver.poll` is the likeliest first hit.
- **Owned message copies** cost `messages_max × entries_max × entry_bytes_max`; ADR-008 sizes it.
- **Vacuity**: a sim that never partitions or crashes passes trivially; items 5, 6, 10 assert
  floors (share of seeds with a leader change, truncate, crash, pending op).
- **Linearizability search is exponential.** Per-key split and `search_steps_max` bound it;
  inconclusive fails the run, never passes it.
- **Sizing.** Items 4 and 9 are largest; if one overruns a cycle, split it in a plan-tick PR.

## Done when

- `zig build`, `zig build test`, `zig build tidy`, `zig build bench`, `zig fmt --check` and
  `zig build sim -Dseeds=1000` green on 0.16.0; all CI jobs green on `main`.
- `grep -c NotImplemented src/sim.zig` → 0; `docs/adr/0008-*.md` and the five `src/sim/` files.
- A successful `sim-nightly.yml` run exists; Phase 3 ticked in `docs/plans/000-inherited.md`;
  this plan's milestone issue closed; `gh release view v0.5.0` succeeds.

## Version impact

**MINOR** — 0.4.0 → 0.5.0. Additive: the public `sim` module (`Simulation`, `Network`,
`VirtualClock`, invariants, linearizability checker). Dropping the stub's
`Error{NotImplemented}` is a removal, but `VERSIONING.md` keeps foundation at `0.x` where MINOR
may break, and no kingdom `build.zig.zon` pins synod (re-checked at release), so no `migration`
issue. `raft`, `driver` and ADR-005 wire shapes do not change; a PR that needs one says so.
