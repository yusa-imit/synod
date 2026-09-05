# synod — Product Requirements Document

> **synod**: 노드들이 모여 합의에 이르는 회의. Zig 왕국의 분산 시스템 프리미티브.
> Layer: **Foundation** · Consumers: silica (복제/failover), zoltraak (cluster/sentinel)

---

## 1. 배경과 문제

silica는 `src/replication/`에서 스트리밍 복제, 자동 failover, 레플리카 승격을 직접 구현했다. zoltraak는 `storage/{cluster,sentinel,replication}.zig`에서 같은 문제를 다시 풀었다. 둘 다 "리더 선출 + 로그 복제 + 멤버십 변경 + 장애 감지"라는 동일한 코어를 필요로 하며, 이 코어는 검증이 극도로 어렵다(분산 버그는 재현이 안 된다).

synod는 이 코어를 **한 번**, **결정론적 시뮬레이션으로 검증된** 라이브러리로 제공한다.

## 2. 목표 (Goals)

1. **Raft 완전 구현**: 선출, 로그 복제, 스냅샷, 조인트 합의 멤버십 변경, PreVote, 리더 리스(read-index / lease read)
2. **멤버십 & 장애 감지**: SWIM 가십 프로토콜 + φ-accrual 장애 감지기
3. **I/O 무관 코어**: 코어는 순수 상태기계 (`step(msg) -> []Effect`). 네트워크·디스크·시계는 인터페이스로 주입
4. **결정론적 시뮬레이션 테스트**: 가상 시계 + 가상 네트워크(지연, 분할, 재정렬, 유실)로 수백만 시나리오를 초 단위로 실행
5. **어댑터**: sirocco(Transport), strata(LogStore) 어댑터를 제공하되 코어는 이들에 의존하지 않음
6. **제로 의존성 코어**: `synod` 모듈 자체는 Zig std만 사용

## 3. 비목표 (Non-Goals)

- Paxos/EPaxos 계열 — Raft만 (필요 시 v2)
- 분산 트랜잭션(2PC/Percolator) — 상위 레이어
- 서비스 디스커버리 UI/CLI — 소비자 프로젝트 몫

## 4. 아키텍처

```
┌───────────────────────────────────────────────────┐
│ adapters: sirocco_transport | strata_logstore     │
├───────────────────────────────────────────────────┤
│ raft: Node (state machine) · Log · Snapshot ·      │
│       Membership (joint) · ReadIndex · Lease       │
├─────────────────────┬─────────────────────────────┤
│ membership: SWIM    │ detector: PhiAccrual        │
├─────────────────────┴─────────────────────────────┤
│ clock: HLC · Lamport · Monotonic                  │
├───────────────────────────────────────────────────┤
│ interfaces: Transport · LogStore · StateMachine · │
│             Clock · Rng                            │
├───────────────────────────────────────────────────┤
│ sim: VirtualNetwork · VirtualClock · Scenario ·   │
│      Invariants (linearizability checker)         │
└───────────────────────────────────────────────────┘
```

### 4.1 코어 인터페이스

```zig
pub const NodeId = u64;

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        send: *const fn (*anyopaque, to: NodeId, msg: Message) anyerror!void,
    },
};

pub const LogStore = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        append: *const fn (*anyopaque, entries: []const Entry) anyerror!void,
        truncate: *const fn (*anyopaque, from_index: u64) anyerror!void,
        get: *const fn (*anyopaque, index: u64) anyerror!?Entry,
        lastIndex: *const fn (*anyopaque) u64,
        saveHardState: *const fn (*anyopaque, HardState) anyerror!void, // term, vote, commit
        saveSnapshot: *const fn (*anyopaque, Snapshot) anyerror!void,
        loadSnapshot: *const fn (*anyopaque) anyerror!?Snapshot,
    },
};

pub const StateMachine = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        apply: *const fn (*anyopaque, Entry) anyerror!void,
        snapshot: *const fn (*anyopaque, writer: anytype) anyerror!void,
        restore: *const fn (*anyopaque, reader: anytype) anyerror!void,
    },
};
```

### 4.2 Raft `Node` — 순수 상태기계

```zig
pub const Node = struct {
    pub fn init(allocator, id: NodeId, config: Config, store: LogStore) !Node;
    /// 외부 이벤트 하나를 처리하고 효과 목록을 반환. I/O 하지 않음.
    pub fn step(self: *Node, input: Input) ![]Effect;
    pub fn tick(self: *Node, now_ms: u64) ![]Effect;
    pub fn propose(self: *Node, data: []const u8) ![]Effect;
    pub fn proposeConfChange(self: *Node, change: ConfChange) ![]Effect;
    pub fn readIndex(self: *Node, ctx: []const u8) ![]Effect;
};

pub const Effect = union(enum) {
    send: struct { to: NodeId, msg: Message },
    persist: struct { hard_state: ?HardState, entries: []const Entry },
    apply: []const Entry,
    snapshot: Snapshot,
    read_ready: struct { ctx: []const u8, index: u64 },
    leader_changed: ?NodeId,
};
```

`Driver`가 `Effect`를 Transport/LogStore/StateMachine에 실행한다. 이 분리 덕분에 코어는 시뮬레이터 안에서 그대로 돌아간다.

### 4.3 `membership` — SWIM

- ping / ping-req / ack, suspicion 서브프로토콜, 가십 piggyback
- 인카네이션 번호로 오탐 복구
- `PhiAccrual` 장애 감지기 (Hayashibara 2004) — 하트비트 간격 분포로 의심 수준 산출

### 4.4 `clock`

- `Hlc` (Hybrid Logical Clock) — silica MVCC 타임스탬프 후보
- `Lamport`
- `Clock` 인터페이스 — 시뮬레이터가 가상 시계 주입

### 4.5 `sim` — 결정론적 시뮬레이션

```zig
var sim = try Simulation.init(allocator, .{ .seed = 42, .nodes = 5 });
sim.network.setPartition(&.{ 0, 1 }, &.{ 2, 3, 4 });
try sim.runUntil(.{ .ms = 10_000 });
try sim.check(.electionSafety);   // 한 term에 리더는 최대 1
try sim.check(.logMatching);
try sim.check(.leaderCompleteness);
try sim.check(.stateMachineSafety);
```

- 가상 네트워크: 지연 분포, 유실률, 재정렬, 분할/복구, 노드 crash/restart
- 시드 하나로 완전 재현. CI에서 매 빌드마다 N개 시드 실행, nightly에 100k 시드
- Raft 논문의 5개 안전 속성을 불변식으로 검사
- 선형화 가능성 체커 (Knossos/Porcupine 방식, 소규모 히스토리)

## 5. 성능 목표

| 지표 | 목표 |
|---|---|
| 3노드 커밋 지연 (LAN, strata 로그) | p50 < 1ms, p99 < 5ms |
| 처리량 (배치 커밋) | 200k entries/s |
| 리더 failover 감지→새 리더 | < 500ms (election timeout 150–300ms) |
| 시뮬레이션 속도 | 1 시나리오(5노드, 10초 가상시간) < 50ms 실시간 |

## 6. 마일스톤

### Phase 1 — Core Types & Log
- 1A `types.zig` — NodeId, Term, Index, Entry, HardState, Message 유니온
- 1B `log.zig` — 인메모리 로그 (append/truncate/term lookup), 불변식 `validate()`
- 1C `interfaces.zig` — Transport/LogStore/StateMachine/Clock/Rng vtable
- 1D `store/memory.zig` — 인메모리 LogStore

### Phase 2 — Raft Election & Replication
- 2A `raft/node.zig` — follower/candidate/leader 상태, 선출, PreVote
- 2B AppendEntries 복제, 커밋 인덱스 전진, 로그 충돌 해소
- 2C `raft/progress.zig` — per-follower 진행 추적 (probe/replicate/snapshot 상태)
- 2D `driver.zig` — Effect 실행기

### Phase 3 — Simulation Harness
- 3A `sim/clock.zig`, `sim/network.zig`, `sim/simulation.zig`
- 3B `sim/invariants.zig` — 5개 Raft 안전 속성
- 3C 시드 기반 CI 테스트 (`zig build sim -Dseeds=1000`)
- 3D 선형화 체커

### Phase 4 — Snapshot & Membership
- 4A `raft/snapshot.zig` — 스냅샷 생성/전송(InstallSnapshot)/복원
- 4B `raft/membership.zig` — 조인트 합의 (C_old,new)
- 4C `raft/read.zig` — ReadIndex, 리더 리스 읽기
- 4D 로그 컴팩션 정책

### Phase 5 — SWIM & Clocks
- 5A `membership/swim.zig`
- 5B `detector/phi_accrual.zig`
- 5C `clock/hlc.zig`, `clock/lamport.zig`

### Phase 6 — Adapters & Integration
- 6A `adapters/sirocco_transport.zig` — TCP 프레이밍, 재연결
- 6B `adapters/strata_logstore.zig` — WAL 기반 LogStore
- 6C zoltraak cluster를 synod로 이식 (PoC)
- 6D silica failover를 synod 선출로 이식 (PoC)

## 7. 설계 원칙

- **코어는 절대 I/O 하지 않는다** — 이것이 검증 가능성의 전부
- **모든 난수/시계는 주입** — 시뮬레이터 결정론의 전제
- **메시지는 버전 필드 포함** — 롤링 업그레이드 대비
- **`@panic` 금지, 불변식 위반은 `error.Invariant*`** — 시뮬레이터가 잡아서 시드와 함께 보고
- **직렬화는 sigil에 위임하되 코어는 `[]const u8`만 본다**

## 8. 테스트 전략

- 유닛: 로그 연산, 상태 전이 표
- 시뮬레이션: 분할, 유실, 재정렬, crash/restart, 멤버십 변경 중 분할
- 프로퍼티: 임의 메시지 시퀀스에도 안전 속성 유지
- 인터롭: etcd/raft 테스트 벡터 참조 (가능한 범위)

## 9. 리스크

| 리스크 | 완화 |
|---|---|
| 멤버십 변경 중 안전성 버그 (Raft 논문 정오표 이슈) | 조인트 합의만 지원, 단일 서버 변경 방식은 제외 |
| 시뮬레이터가 실제 네트워크와 괴리 | Phase 6 실통합 테스트를 CI에 포함 |
