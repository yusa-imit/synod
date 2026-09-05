# synod — Project Context

## Current State (2026-09-05)

- **Phase**: Bootstrap complete. Next: Phase 1 (see `docs/milestones.md`)
- **Version**: 0.1.0 (unreleased)
- **Build**: `zig build test` green on skeleton
- **CI**: workflow registered, first run pending

## Immediate Next Steps

- 1A: 타입 정의 — 테스트: Message 유니온 태그 전수, HardState 비교
- 1B: 인메모리 로그 — 테스트: append/truncate/termAt, 충돌 지점 탐색, validate()
- 1C+1D: vtable 인터페이스와 인메모리 LogStore — 테스트: 저장/복원 라운드트립

## Session Log

**Session 0 (2026-09-05) — Bootstrap**
- Repository scaffolded from `citadel/templates/repo` by `citadel/scripts/scaffold.py`
- PRD written (`docs/PRD.md`), milestones enumerated, agent/command definitions installed
- Module stubs compile; each module has a placeholder test
