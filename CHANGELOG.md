# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

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
