# synod

> The council where nodes reach consensus — Raft, membership, and failure detection for Zig

synod는 I/O를 전혀 하지 않는 순수 상태기계 Raft 코어(선출, 로그 복제, 스냅샷, 조인트 합의 멤버십, ReadIndex/리스 읽기)와 SWIM 가십 멤버십, φ-accrual 장애 감지기, 하이브리드 논리 시계를 제공한다. 네트워크·디스크·시계는 vtable로 주입되며, 같은 코어가 결정론적 시뮬레이터 안에서 수백만 시나리오로 검증된다. silica의 복제/failover와 zoltraak의 cluster/sentinel이 이 위로 이식된다.

[![CI](https://github.com/yusa-imit/synod/workflows/CI/badge.svg)](https://github.com/yusa-imit/synod/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.x-orange.svg)](https://ziglang.org)

---

## Status

**Bootstrap** — API 설계 및 Phase 1 구현 중. 안정 릴리즈 전까지 API는 변경될 수 있다.

## Modules

| Module | Purpose |
|---|---|
| `synod.types` | NodeId, Term, Index, Entry, HardState, Snapshot, Message union, ConfChange. |
| `synod.interfaces` | Transport, LogStore, StateMachine, Clock, Rng vtables. |
| `synod.log` | In-memory Raft log with append/truncate/term lookup and invariant validation. |
| `synod.raft` | Pure state machine: election (PreVote), replication, progress tracking, snapshot, joint-consensus membership, ReadIndex and lease reads. |
| `synod.driver` | Executes Effects against Transport / LogStore / StateMachine. |
| `synod.membership` | SWIM gossip protocol: ping, ping-req, suspicion, incarnation numbers. |
| `synod.detector` | φ-accrual failure detector. |
| `synod.clock` | Hybrid logical clock, Lamport clock, monotonic Clock interface. |
| `synod.store` | In-memory LogStore for tests and simulation. |
| `synod.sim` | Deterministic simulation: virtual clock, virtual network (delay, loss, partition, reorder), scenarios, Raft safety invariants, linearizability checker. |
| `synod.adapters` | Opt-in adapters: sirocco Transport, strata LogStore. |

## Install

```bash
zig fetch --save https://github.com/yusa-imit/synod/archive/refs/tags/v0.1.0.tar.gz
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
