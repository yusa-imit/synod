# synod

> The council where nodes reach consensus — Raft, membership, and failure detection for Zig

synod는 I/O를 전혀 하지 않는 순수 상태기계 Raft 코어(선출, 로그 복제, 스냅샷, 조인트 합의 멤버십,
ReadIndex/리스 읽기)와 SWIM 가십 멤버십, φ-accrual 장애 감지기, 하이브리드 논리 시계를 **목표로**
설계된 프로젝트다 (`docs/PRD.md` 참고). 네트워크·디스크·시계는 vtable로 주입될 예정이며, 같은
코어를 결정론적 시뮬레이터로 검증하는 것이 최종 목표다. silica의 복제/failover와 zoltraak의
cluster/sentinel이 이 위로 이식될 예정이지만, 아래 "Status"에 나오듯 현재는 전부 스캐폴드 단계다.

[![CI](https://github.com/yusa-imit/synod/workflows/CI/badge.svg)](https://github.com/yusa-imit/synod/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange.svg)](https://ziglang.org)

---

## Status

**Phase 1 implemented** — `types`, `interfaces`, `log`, and `store` are real, tested code. The
Raft state machine (`raft`, `driver`), SWIM `membership`, `detector`, `clock`, `sim`, and
`adapters` are still stubs (`error.NotImplemented`). The design in this README and in
`docs/PRD.md` is the target shape; treat synod as unusable as a consensus library until Phase 2
(`raft`) lands. `docs/plans/002-*.md` tracks the Phase 1 milestone.

## Modules

| Module | Purpose | Status |
|---|---|---|
| `synod.types` | NodeId, Term, Index, Entry, HardState, Snapshot, Message union, ConfChange. | implemented |
| `synod.interfaces` | Transport, LogStore, StateMachine, Clock, Rng vtables. | implemented |
| `synod.log` | In-memory Raft log with append/truncate/term lookup and invariant validation. | implemented |
| `synod.raft` | Pure state machine: election (PreVote), replication, progress tracking, snapshot, joint-consensus membership, ReadIndex and lease reads. | planned |
| `synod.driver` | Executes Effects against Transport / LogStore / StateMachine. | planned |
| `synod.membership` | SWIM gossip protocol: ping, ping-req, suspicion, incarnation numbers. | planned |
| `synod.detector` | φ-accrual failure detector. | planned |
| `synod.clock` | Hybrid logical clock, Lamport clock, monotonic Clock interface. | planned |
| `synod.store` | In-memory LogStore for tests and simulation. | implemented |
| `synod.sim` | Deterministic simulation: virtual clock, virtual network (delay, loss, partition, reorder), scenarios, Raft safety invariants, linearizability checker. | planned |
| `synod.adapters` | Opt-in adapters: sirocco Transport, strata LogStore. | planned |

## Install

`v0.2.0` contains only the scaffold; `v0.3.0` is the first release with Phase 1 code
(types, interfaces, log, in-memory store). To fetch a tag:

```bash
zig fetch --save https://github.com/yusa-imit/synod/archive/refs/tags/v0.3.0.tar.gz
```

```zig
// build.zig
const synod = b.dependency("synod", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("synod", synod.module("synod"));
```

## Build

```bash
zig build            # library + CLI
zig build test       # unit tests
zig build bench      # benchmarks
zig build docs       # API docs → zig-out/docs
```

## Part of the Zig Kingdom

synod is a foundation component consumed by: silica, zoltraak.
See [citadel](https://github.com/yusa-imit/citadel) for the full map.

## License

MIT — see [LICENSE](LICENSE).
