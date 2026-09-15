# Plan 002 — Phase 1: core types, log, interfaces, in-memory store

## Goal

Land the first four stops of `REALM.md`'s module build order as real, asserted, tested code —
`types` → `interfaces` + `log` → `store` — and release v0.3.0, ending the scaffold phase.

## Why now

v0.2.0 closed milestone 001 and every `src/*.zig` is still an 18–26 line stub, so `STATE.md`'s
all-zero Tiger Style table measures a scaffold, not discipline. Phase 2's election state machine
needs `Entry`/`Term`/`Index`, a log with `termAt` and conflict search, and a `LogStore` to
persist through; ROADMAP Phase 2 wants types + log + raft + simulator before zoltraak's sentinel
election moves onto synod. The wire shape decided here — protocol-version field, `u64` never
`usize`, explicit error sets, not the PRD's `anyerror` — is free while nothing pins synod and
becomes a MAJOR-bump negotiation the moment something does.

## Scope

- [ ] **Bug: the released v0.2.0 reports itself as 0.1.0.** `src/root.zig:11` hardcodes
      `SemanticVersion{0,1,0}` while `build.zig.zon` says `0.2.0` and tag `v0.2.0` is published,
      so `synod version` prints `synod 0.1.0`; `main.zig:37` only tests `major == 0`. Derive
      `version` from the manifest (comptime parse of `@embedFile("../build.zig.zon")`, or
      `b.addOptions`) so they cannot drift again. *Verify:* `./zig-out/bin/synod version` prints
      `synod 0.2.0`; editing the zon version turns `zig build test` red. `blocked_by: none`
- [ ] **Tiger Style gap, part 1 — remove the two size violations.** `tools/tidy.zig` is 1266
      lines (limit 800), `build.zig`'s `pub fn build` is 87 (limit 70); deferred since cycle 5
      because tidy's `main()` walks `src/` only. Move tidy's ~550 lines of inline tests to
      `tools/tidy_test.zig` and extract `build.zig`'s step wiring into helpers — pure moves.
      *Verify:* `wc -l tools/tidy.zig` < 800, `zig build test` count unchanged, `tidy` green.
      `blocked_by: none`
- [ ] **Tiger Style gap, part 2 — point the gate at itself.** Widen tidy's walk to `tools/`, add
      a function-length check for `build.zig`. Splitting first (part 1) removes the red window a
      single combined PR would otherwise need. *Verify:* `zig build tidy` green; reverting either
      part-1 move turns it red. `blocked_by: none`
- [ ] **1A-i `types.zig` — scalars, `Entry`, `HardState`, `Snapshot`.** Tests first for
      `Term`/`Index` ordering and `HardState` comparison. `NodeId`/`Term`/`Index` are distinct
      `u64`-backed decls (never `usize`); `Entry{ index, term, kind, data: []const u8 }` keeps an
      explicit `kind` so conf-change entries stay distinguishable in Phase 4. *Verify:* `test` +
      `tidy` green, no `NotImplemented` left, `grep -c assert src/types.zig` ≥ 2x `pub fn` count.
      `blocked_by: none`
- [ ] **1A-ii `types.zig` — `Message` union and `ConfChange`.** Split from 1A-i: the message set
      (RequestVote/PreVote, AppendEntries, InstallSnapshot, responses) plus exhaustiveness tests
      does not fit one cycle beside the scalars. Every variant carries `protocol_version: u16`
      and `term` now, per `REALM.md` — rolling upgrades are why it exists and retrofitting it is
      a wire break. `ConfChange` is joint-consensus-shaped, no single-server path. *Verify:* a
      test switches exhaustively over `Message` — a new variant, or one built without a
      `protocol_version`, must fail to compile. `blocked_by: none`
- [ ] **1B-i `log.zig` — `Log` with `append`/`truncate`/`termAt`/`lastIndex`.** In-memory,
      allocated at `init`, bounded capacity from options (no unbounded growth). Asserts monotonic
      index on append and index-in-range on `termAt`; garbage *caller* state asserts, garbage
      *data* returns a typed error. *Verify:* append/truncate/lookup tests including empty-log
      and capacity-limit negative space. `blocked_by: none`
- [ ] **1B-ii `log.zig` — conflict-point search and `validate()`.** Split from 1B-i: the Raft
      conflict scan plus the invariant checker is its own cycle. `validate()` returns
      `error.Invariant*` (contiguous indices, non-decreasing terms, no snapshot-boundary gap)
      instead of asserting, per `REALM.md`, so Phase 3's simulator can report the seed. *Verify:*
      `validate()` runs at the end of every log-mutating test (ADR-003) and a hand-corrupted
      entry array yields the specific `error.Invariant*`. `blocked_by: none`
- [ ] **1C `interfaces.zig` — the five vtables.** `Transport`/`LogStore`/`StateMachine`/`Clock`/
      `Rng` in a `ptr` + `*const VTable` shape. **Correction to PRD §4.1's sketch, state it in
      the PR body:** `anyerror!void` becomes a named error set per method (Tiger Style bans
      `anyerror` in a `pub fn`), and `snapshot(writer: anytype)` is not expressible in a function
      pointer at all — use `*std.Io.Writer`/`*std.Io.Reader`, legal because `interfaces.zig` is
      not in tidy's `core_purity_files` (ADR-002 puts the `Io` boundary at driver/adapters).
      *Verify:* no-op impls dispatch; `tidy` green. `blocked_by: none`
- [ ] **1D `store.zig` — in-memory `LogStore` + reusable conformance suite.** Implements the 1C
      vtable over `Log`, with `saveHardState`/`saveSnapshot`/`loadSnapshot`. Write the tests as
      `fn conformance(store: LogStore)` the future strata adapter (PRD 6B) calls unchanged — one
      suite, two implementations, which is also ADR-003's paired-path requirement. *Verify:*
      append→truncate→reload and hard-state/snapshot round-trips driven through the vtable, not
      the concrete type. `blocked_by: none`
- [ ] **Re-measure the Tiger Style baseline over real code.** `STATE.md` says the all-zero table
      must be re-run once Phase 1 lands; this is that run. Record assert density per module,
      function lengths, first honest `tidy` numbers; flip README's rows for those four modules
      from *planned* to *implemented*. *Verify:* `tidy` green; new table in `STATE.md`.
      `blocked_by: none`
- [ ] **Release v0.3.0.** MINOR bump in `build.zig.zon` (item 1 propagates it to
      `synod.version`), CHANGELOG section, annotated tag, GitHub release. Gate per `REALM.md`:
      `zig build test` 0 failures, 6 cross-compile targets green, 0 open `bug` issues. *Verify:*
      `gh release view v0.3.0` succeeds and `zig fetch <v0.3.0 tarball>` resolves.
      `blocked_by: none`

## Out of scope

- Phase 2 (election, PreVote, AppendEntries, `progress.zig`, `driver.zig`) — plan 003;
  `src/raft.zig` and `src/driver.zig` stay stubs, no `step()`/`tick()` here.
- Phases 3–6: simulator, snapshots/joint consensus, SWIM, phi-accrual, HLC, adapters.
- Serialization (PRD §7: the core sees `[]const u8`; ADR-001 forbids depending on sigil) and
  compaction policy — `Snapshot` as a type lands, the policy does not.

## Risks

- **Getting the wire shape wrong is expensive later.** Mitigation: the protocol-version field and
  the `u64` rule land in 1A-ii; tidy enforces the second, an exhaustive-switch test the first.
- **Tiger Style thresholds are unproven against real code** (plan 001's own risk). Item 10 is the
  checkpoint: if assert density or the 70-line limit fights the log code, argue it in plan 003
  with numbers, never by quietly widening the baseline file.
- **ADR-003's assertion contract has no mechanical gate** — `code-reviewer` enforces it. If items
  4–9 give a stable density measure, plan 003 should propose the check ADR-003 §3 defers.

## Done when

- `zig build`, `zig build test`, `zig build tidy`, `zig build bench`, `zig fmt --check` green on
  0.16.0; all 7 CI jobs green on `main`.
- `grep -c NotImplemented src/{types,interfaces,log,store}.zig` → 0.
- Phase 1 items 1A–1D ticked in `docs/plans/000-inherited.md`, this plan's milestone issue
  closed, `gh release view v0.3.0` succeeds.

## Version impact

**none (MINOR at 0.x)** — 0.2.0 → 0.3.0. Additive: four stub modules gain real symbols. Deleting
each `Error{NotImplemented}` is technically a public removal, but `VERSIONING.md` keeps
foundation repos at `0.x` until two consumers depend on them and lets MINOR break during `0.x`,
and nothing pins synod today (silica and zoltraak adopt it in ROADMAP Phase 3) — so no
`migration` issue and no MAJOR. Said plainly because it expires: once either pins a tag, renaming
a `Message` variant, widening an error set, or adding a wire field becomes MAJOR. That is the
argument for fixing the protocol-version field and the explicit error sets in this plan.
