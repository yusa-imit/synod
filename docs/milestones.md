# synod — Milestones

> 마일스톤은 **이름(테마)** 으로 관리한다. 버전 번호는 릴리즈 시점에 `build.zig.zon` 현재 버전 + 1 로 결정한다.
> 상세 요구사항: `docs/PRD.md`. 진행 상황은 이 파일의 체크박스가 단일 진실이다.

## 현재 상태

- **Phase**: Bootstrap 완료 → Phase 1 착수
- **버전**: 0.1.0 (미릴리즈)
- **CI**: 초기 워크플로우 등록

## Phase 1 — Core Types & Log

- [ ] 1A `types.zig`
- [ ] 1B `log.zig` + `validate()`
- [ ] 1C `interfaces.zig` vtables
- [ ] 1D `store/memory.zig`

## Phase 2 — Raft Election & Replication

- [ ] 2A `raft/node.zig` — states, election, PreVote
- [ ] 2B AppendEntries, commit advance, conflict resolution
- [ ] 2C `raft/progress.zig`
- [ ] 2D `driver.zig`

## Phase 3 — Simulation Harness

- [ ] 3A `sim/clock.zig`, `sim/network.zig`, `sim/simulation.zig`
- [ ] 3B `sim/invariants.zig` — 5 safety properties
- [ ] 3C seeded CI test step (`zig build sim -Dseeds=N`)
- [ ] 3D `sim/linearizability.zig`

## Phase 4 — Snapshot & Membership

- [ ] 4A `raft/snapshot.zig` + InstallSnapshot
- [ ] 4B `raft/membership.zig` — joint consensus
- [ ] 4C `raft/read.zig` — ReadIndex, lease
- [ ] 4D log compaction policy

## Phase 5 — SWIM & Clocks

- [ ] 5A `membership/swim.zig`
- [ ] 5B `detector/phi_accrual.zig`
- [ ] 5C `clock/hlc.zig`, `clock/lamport.zig`

## Phase 6 — Adapters & Integration

- [ ] 6A `adapters/sirocco_transport.zig`
- [ ] 6B `adapters/strata_logstore.zig`
- [ ] 6C zoltraak cluster on synod (PoC)
- [ ] 6D silica failover on synod (PoC)


## 성능 목표

`docs/PRD.md` §5 참조. 각 Phase 완료 시 `zig build bench` 결과를 아래에 기록한다.

| 날짜 | 지표 | 측정값 | 목표 | 비고 |
|---|---|---|---|---|
| | | | | |
