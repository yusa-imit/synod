# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `src/log.zig`, `src/types.zig`: camelCase functions renamed to snake_case per Tiger Style §3.6
  (`last_index`, `term_at`, `conflict_at`, `validate_transition`, and private helpers). Public
  API rename, done before the v0.3.0 tag pins it.
- `README.md` (plan 002, item 10): `types`, `interfaces`, `log`, and `store` marked
  *implemented*; status paragraph and install section no longer claim a pure scaffold.
  Tiger Style baseline re-measured over Phase 1 code: `tidy` clean, 0 `NotImplemented` in those
  four modules, no function over 70 lines.

### Added

- `src/types.zig` (plan 002, item 1A-i): `NodeId`, `Term`, `Index` as distinct non-exhaustive
  `enum(u64)` types (never `usize`), each with a named zero sentinel; `EntryKind`, `Entry`,
  `HardState` (24-byte `extern struct`, no padding, `eql` and `validateTransition`), and
  `Snapshot`. See ADR-004 for the wire-shape rationale.
- `src/types.zig` (plan 002, item 1A-ii): the `Message` union (`RequestVote`/`PreVote`/
  `AppendEntries`/`InstallSnapshot` and their responses), `Header` (protocol-version and term
  on every variant), and the joint-consensus `Configuration`/`ConfChange` membership types,
  each with a structural `validate()`. See ADR-005 for the wire-shape rationale.
- `src/log.zig` (plan 002, item 1B-i): in-memory Raft `Log` — `init`/`deinit`/`append`/
  `truncate`/`termAt`/`lastIndex`, allocated once at `init` from a bounded `entries_max`,
  returning `error.LogFull` at capacity rather than growing unbounded.
- `src/log.zig` (plan 002, item 1B-ii): `Log.conflictAt`, the Raft thesis §5.3 fast-backtrack
  conflict-point search over `AppendResponse.outcome.rejected`'s `Conflict` hint; and
  `Log.validate`/`InvariantError`, a defense-in-depth corruption checker (index contiguity,
  non-decreasing terms, no snapshot-boundary gap) for Phase 3's simulator to report a failing
  seed instead of panicking.
- `src/interfaces.zig` (plan 002, item 1C): the five vtables `Transport`, `LogStore`,
  `StateMachine`, `Clock`, `Rng` and `SnapshotRecord`, each two words and built only through
  comptime `X.init(&impl)` (a static per-type vtable; `@compileError` on a missing or mis-typed
  method). Forwarding methods assert the caller's contract. Narrow named error sets
  (`LogStore.WriteError`/`UpdateError`/`ReadError`, `StateMachine.ApplyError`/`SnapshotError`/
  `RestoreError`) replace the PRD's `anyerror`; `Rng.uint_less_than` is a one-draw multiply-high
  bound. See ADR-006.
- `src/store.zig` (plan 002, item 1D): `MemoryStore`, an in-memory `LogStore` that copies all
  entry, snapshot and node-list bytes into four buffers allocated once in `init` from
  `Options` (`entries_max`, `data_bytes_max`, `snapshot_bytes_max`); `StoreFull` is checked
  before any mutation. `check_invariants()` names the first broken invariant. The reusable
  `store.conformance(store: LogStore)` suite (`src/store_conformance.zig`) drives only the
  vtable, so the future strata adapter runs the same cases; a seeded model-based test
  compares `MemoryStore` against a trivial reference table.

### Fixed

- `synod.version` (and `synod version`) is now derived from `build.zig.zon` at build time
  instead of a hardcoded `0.1.0`, so the reported version can no longer drift from the
  manifest; v0.2.0 reported itself as 0.1.0.
- `tools/tidy.zig`'s wire-`usize` check now recognizes `extern`/`packed` struct and union
  declarations — previously `pub const HardState = extern struct { ... }` silently skipped the
  check entirely.

## [0.2.0] - 2026-09-16

### Changed

- README reconciled with reality: Zig badge `0.15.x` → `0.16.0`; module table gained a
  `Status` column, every row marked `planned` (nothing is implemented yet); the intro
  paragraph and `Status` section now say plainly that the repo is a scaffold, not a working
  library; the install snippet points at the not-yet-tagged `v0.2.0` instead of the
  never-published `v0.1.0`, with a note that no tag exists until plan 001 item 11 releases it.
- `minimum_zig_version` bumped to `0.16.0`; CI resolves the toolchain from `build.zig.zon`
  instead of pinning `0.15.2` in `mlugg/setup-zig@v2`.
- `src/main.zig` migrated to the 0.16 entry-point shape: `pub fn main(init: std.process.Init)
  !void`, `init.gpa`, `init.minimal.args.toSlice(arena)`, `std.Io.File.stdout().writer(init.io,
  ...)`.
- `bench/main.zig` migrated to 0.16: `pub fn main(init: std.process.Init) !void`, `init.gpa`,
  `Io.Clock.Timestamp.now(init.io, .awake)`/`.untilNow(init.io)` replacing `std.time.Timer`, and
  the benchmark name filter extracted into a pure, unit-tested `matchesFilter` using
  `std.mem.find` instead of the removed `std.mem.indexOf`.
- CI gained a "Bench (compile + smoke run)" step (`zig build bench -- __ci_no_match__`) so the
  bench executable — previously unreachable from CI, since `zig build`'s default step never
  installs it — is actually built and its `main()` run on every push.
- `tools/tidy.zig` migrated to 0.16: `std.fs.Dir`/`std.fs.File` → `std.Io.Dir`/`std.Io.File`
  with `io: Io` threaded through every file-touching function, `GeneralPurposeAllocator` →
  `DebugAllocator`, `mem.trimLeft` → `mem.trimStart`.
- 0.16 library-core sweep confirmed: `src/` has zero hits for every remaining 0.15-only pattern
  (`= .{}` list literals, `indexOf*`, `fs.cwd`, `std.net`, `Thread.*`, `std.once`, `@Type`,
  `else => unreachable` over I/O errors, `std.time`) — no code change, `zig test src/root.zig`
  stays 12/12 green.

### Fixed

- CI `paths-ignore` no longer references the removed `.claude/memory/**` path.
- `src/root.zig` and `bench/main.zig` doc comments point at `docs/plans/000-inherited.md`
  instead of the renamed `docs/milestones.md`.
- `tools/tidy.zig`'s `hasModuleHeader` rewrote a compound `assert(!a or b)` implication as the
  Tiger-Style-preferred `if (a) assert(b);` form (rule: split compound assertions and
  conditions) — no behavior change.

### Added

- `docs/adr/0001-zero-dependency-core.md` recording the foundation-layer zero-dependency core
  decision.
- `tools/tidy.zig`: a Tiger Style size floor — `zig build tidy` (now a `zig build test`
  dependency) enforces line length ≤ 100 columns and function length ≤ 70 lines, with a
  `tools/tidy_baseline.txt` red-zone allowance (≤ 72 lines) for pre-existing functions listed
  there by `path:function:lines`.
- `tools/tidy.zig` ban list: `zig build tidy` now also rejects `catch unreachable` without a
  `// proof:` comment on the same or previous line, `std.debug.print`/`std.time.*` in `src/`,
  a `usize` field inside a wire/format struct (`Message`, `Entry`, `HardState`, `Snapshot`),
  and any `.zig` file missing a `//!` module header. `build.zig` and `src/main.zig` gained the
  headers they lacked.
- `docs/adr/0002-io-at-the-boundary.md` recording the `io: Io`-at-the-boundary rule: `io: Io`
  is the first parameter after the receiver on `src/driver.zig`/`src/adapters.zig` and the
  CLI/bench entry points, while `src/raft.zig`, `src/membership.zig`, `src/detector.zig`,
  `src/clock.zig`, and `src/log.zig` never reference `std.Io` and keep the injected
  `Clock`/`Rng` vtables instead. `tools/tidy.zig` gained a matching `core_purity_files`/
  `isCorePurityFile` check so `zig build tidy` fails on a `std.Io` hit in any of those five
  files.
- `docs/adr/0003-assertion-baseline.md` recording the assertion-baseline contract: `src/main.zig`
  and `bench/main.zig` (the only real code today) keep their existing preconditions/postconditions
  from prior review cycles (`grep -c assert` gives 3 and 6); `src/types.zig`, `src/interfaces.zig`,
  `src/log.zig`, and `src/store.zig` (the next modules per `REALM.md`'s build order) must assert
  preconditions on entry and invariants on exit on every `pub fn` once real logic lands, with
  `log.validate()` run at the end of every test that mutates the log.
