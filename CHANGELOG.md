# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- CI `paths-ignore` no longer references the removed `.claude/memory/**` path.
- `src/root.zig` and `bench/main.zig` doc comments point at `docs/plans/000-inherited.md`
  instead of the renamed `docs/milestones.md`.

### Added

- `docs/adr/0001-zero-dependency-core.md` recording the foundation-layer zero-dependency core
  decision.
- `tools/tidy.zig`: a Tiger Style size floor — `zig build tidy` (now a `zig build test`
  dependency) enforces line length ≤ 100 columns and function length ≤ 70 lines, with a
  `tools/tidy_baseline.txt` red-zone allowance (≤ 72 lines) for pre-existing functions listed
  there by `path:function:lines`.
