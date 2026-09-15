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

**Scaffold** — every module below is a stub (`error.NotImplemented`, no real logic). The design
in this README and in `docs/PRD.md` is the target shape, not the current implementation; treat
synod as unusable and unreleased as a real dependency until modules start moving from *planned*
to *implemented*. `docs/plans/001-*.md` tracks the Zig 0.16 + Tiger Style baseline milestone
currently in progress; Phase 1 (`types`/`log`/`interfaces`/`store`) is the next real code.

## Modules

| Module | Purpose | Status |
|---|---|---|
| `synod.types` | NodeId, Term, Index, Entry, HardState, Snapshot, Message union, ConfChange. | planned |
| `synod.interfaces` | Transport, LogStore, StateMachine, Clock, Rng vtables. | planned |
| `synod.log` | In-memory Raft log with append/truncate/term lookup and invariant validation. | planned |
| `synod.raft` | Pure state machine: election (PreVote), replication, progress tracking, snapshot, joint-consensus membership, ReadIndex and lease reads. | planned |
| `synod.driver` | Executes Effects against Transport / LogStore / StateMachine. | planned |
| `synod.membership` | SWIM gossip protocol: ping, ping-req, suspicion, incarnation numbers. | planned |
| `synod.detector` | φ-accrual failure detector. | planned |
| `synod.clock` | Hybrid logical clock, Lamport clock, monotonic Clock interface. | planned |
| `synod.store` | In-memory LogStore for tests and simulation. | planned |
| `synod.sim` | Deterministic simulation: virtual clock, virtual network (delay, loss, partition, reorder), scenarios, Raft safety invariants, linearizability checker. | planned |
| `synod.adapters` | Opt-in adapters: sirocco Transport, strata LogStore. | planned |

## Install

Not yet released — no tag exists. `v0.2.0` is the next planned release (plan 001, item 11);
once tagged:

```bash
zig fetch --save https://github.com/yusa-imit/synod/archive/refs/tags/v0.2.0.tar.gz
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
