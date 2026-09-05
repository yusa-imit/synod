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
