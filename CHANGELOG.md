# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
