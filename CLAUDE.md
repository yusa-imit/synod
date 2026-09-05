# synod — Claude Code Orchestrator

> **synod**: The council where nodes reach consensus — Raft, membership, and failure detection for Zig
> Current Phase: **Bootstrap → Phase 1**
> Kingdom layer: **Foundation** · Consumers: silica, zoltraak

---

## Project Overview

- **Language**: Zig 0.15.2
- **Type**: Library (consumed via `build.zig.zon`) + small CLI
- **Build**: `zig build` / `zig build test` / `zig build bench`
- **PRD**: `docs/PRD.md` (전체 요구사항 — 반드시 먼저 읽는다)
- **Milestones**: `docs/milestones.md` (진행 상황의 단일 진실)
- **Branch Strategy**: `main` (development)
- **Dependencies**: Zig std만. 왕국의 다른 컴포넌트에 의존하지 않는다 (어댑터는 예외, PRD 참조)
- **Kingdom map**: `citadel` 레포의 `docs/KINGDOM.md`

synod는 I/O를 전혀 하지 않는 순수 상태기계 Raft 코어(선출, 로그 복제, 스냅샷, 조인트 합의 멤버십, ReadIndex/리스 읽기)와 SWIM 가십 멤버십, φ-accrual 장애 감지기, 하이브리드 논리 시계를 제공한다. 네트워크·디스크·시계는 vtable로 주입되며, 같은 코어가 결정론적 시뮬레이터 안에서 수백만 시나리오로 검증된다. silica의 복제/failover와 zoltraak의 cluster/sentinel이 이 위로 이식된다.

## Repository Structure

```
synod/
├── CLAUDE.md                    # THIS FILE — orchestrator
├── docs/PRD.md                  # Product Requirements Document
├── docs/milestones.md           # Phase checklist (single source of truth)
├── .claude/
│   ├── agents/                  # zig-developer, test-writer, code-reviewer, architect, git-manager, ci-cd
│   ├── commands/                # /build /test /implement /fix /review /status /release /bench
│   ├── memory/                  # project-context, architecture, decisions, debugging, patterns
│   └── settings.json
├── .github/workflows/ci.yml     # Build, test, fmt, cross-compile
├── src/
│   ├── root.zig                 # Library root — re-exports all public modules
│   ├── main.zig                 # CLI entry point
│   ├── types.zig               # NodeId, Term, Index, Entry, HardState, Snapshot, Message union, ConfChange
│   ├── interfaces.zig          # Transport, LogStore, StateMachine, Clock, Rng vtables
│   ├── log.zig                 # In-memory Raft log with append/truncate/term lookup and invariant validation
│   ├── raft.zig                # Pure state machine: election (PreVote), replication, progress tracking, snapshot, joint-consensus membership, ReadIndex and lease reads
│   │   ├── raft/node.zig
│   │   ├── raft/progress.zig
│   │   ├── raft/snapshot.zig
│   │   ├── raft/membership.zig
│   │   ├── raft/read.zig
│   ├── driver.zig              # Executes Effects against Transport / LogStore / StateMachine
│   ├── membership.zig          # SWIM gossip protocol: ping, ping-req, suspicion, incarnation numbers
│   │   ├── membership/swim.zig
│   ├── detector.zig            # φ-accrual failure detector
│   │   ├── detector/phi_accrual.zig
│   ├── clock.zig               # Hybrid logical clock, Lamport clock, monotonic Clock interface
│   │   ├── clock/hlc.zig
│   │   ├── clock/lamport.zig
│   ├── store.zig               # In-memory LogStore for tests and simulation
│   │   ├── store/memory.zig
│   ├── sim.zig                 # Deterministic simulation: virtual clock, virtual network (delay, loss, partition, reorder), scenarios, Raft safety invariants, linearizability checker
│   │   ├── sim/clock.zig
│   │   ├── sim/network.zig
│   │   ├── sim/simulation.zig
│   │   ├── sim/invariants.zig
│   │   ├── sim/linearizability.zig
│   └── adapters.zig            # Opt-in adapters: sirocco Transport, strata LogStore
│       ├── adapters/sirocco_transport.zig
│       ├── adapters/strata_logstore.zig
├── bench/main.zig               # Benchmark harness
├── examples/                    # Runnable examples
└── tests/                       # Integration / property / fuzz tests
```

> **NOTE**: 위 구조와 PRD의 구조는 **참고용**이다. 구현 과정에서 파일명·모듈 구성은 변경될 수 있다. 변경 시 이 파일과 `.claude/memory/architecture.md`를 갱신한다.

---

## Development Workflow

### Autonomous Development Protocol

Claude Code는 이 프로젝트에서 **완전 자율 개발**을 수행한다.

1. **작업 수신** → `docs/milestones.md`에서 다음 미완료 항목 식별 (의존성 순서 준수)
2. **계획 수립** → 대화형 세션: `EnterPlanMode`; 자율 세션(`claude -p`): 내부적으로 계획 후 즉시 구현 (plan mode 도구 사용 금지)
3. **팀 구성** → 복잡도에 따라 서브에이전트 호출
4. **구현** → TDD: test-writer(Red) → zig-developer(Green) → code-reviewer
5. **검증** → `zig build test`, `zig fmt --check src build.zig`
6. **커밋 + 푸시** → 단위별 즉시. `git add <files>` 명시, `git add -A` 금지
7. **메모리 갱신** → `.claude/memory/`, `docs/milestones.md` 체크박스

### Team Orchestration

```
Leader (orchestrator)
├── test-writer     — 실패하는 테스트 먼저 (MUST run before zig-developer)
├── zig-developer   — 테스트를 통과시키는 구현
├── code-reviewer   — 리뷰 & 품질
└── architect       — 설계 검토 (인터페이스/파일 포맷 변경 시 필수)
```

**TDD 규칙**: 모든 구현은 실패하는 테스트가 먼저 존재해야 한다. 테스트 수정은 test-writer가 한다.
**팀 생성 기준**: 3개 이상 파일 수정 → 팀 구성. 공개 인터페이스/포맷 변경 → architect 포함.

### Automated Session Execution

자동화 세션(citadel의 cron 잡)은 다음 순서로 실행한다.

**컨텍스트 복원**: `.claude/memory/project-context.md` → `architecture.md` → `decisions.md` → `debugging.md` → `patterns.md` → `docs/milestones.md`

**실행 사이클**:

| Phase | 내용 |
|---|---|
| 1. 상태 파악 | `git log -5`, `zig build test`, `gh run list --limit 3` |
| 1.5. 이슈 확인 | `gh issue list --state open --limit 10` — bug 라벨은 항상 최우선 |
| 2. 계획 | 내부 계획 (plan mode 금지) |
| 3. 구현 루프 | Red → Green → Refactor → 커밋+푸시, 단위별 반복 |
| 4. 리뷰 | `/review` |
| 5. 릴리즈 판단 | 마일스톤 완료 시 자동 (아래 규칙) |
| 6. 메모리 갱신 | `chore: update session memory` 별도 커밋 |
| 7. 세션 요약 | 템플릿 출력 |

### 버전 안전 규칙 (CRITICAL)

- 버전은 **단조 증가**. 릴리즈 전 `grep version build.zig.zon`과 `git tag -l 'v*' --sort=-v:refname | head -1` 확인
- 새 버전은 현재 버전의 **다음 마이너** (또는 fix만 있으면 패치). 건너뛰기·다운그레이드 금지
- **MAJOR**는 사용자 지시 시에만
- 릴리즈 조건: `zig build test` 0 failures · 6개 크로스 타겟 빌드 성공 · open `bug` 이슈 0개

**세션 요약 템플릿**:

    ## Session Summary
    ### Completed
    ### Files Changed
    ### Tests
    ### Benchmarks
    ### Next Priority
    ### Issues / Blockers

### Available Custom Agents

| Agent | Model | Purpose |
|---|---|---|
| zig-developer | sonnet | Zig 구현, 빌드 오류 해결 |
| code-reviewer | sonnet | 리뷰, 안전성/성능 검사 |
| test-writer | sonnet | 유닛/프로퍼티/fuzz/크래시 테스트 |
| architect | opus | 인터페이스·포맷·모듈 설계 |
| git-manager | haiku | Git 운영 |
| ci-cd | haiku | GitHub Actions |

### Available Slash Commands

`/build` `/test` `/implement <feature>` `/fix <bug>` `/review` `/status` `/release <version>` `/bench`

---

## Coding Standards

### Zig Conventions

- **Naming**: camelCase 함수/변수, PascalCase 타입, SCREAMING_SNAKE 상수
- **Errors**: 명시적 에러 유니온. 라이브러리 코드에서 `catch unreachable`, `@panic` 금지
- **Memory**: allocator-first. 전역 allocator 금지. 핫 패스에서 per-op 할당 금지
- **Output**: `std.debug.print` 금지 — writer 기반
- **Docs**: 모든 공개 함수에 doc comment (계약, 에러, 복잡도/비용)
- **Files**: 800줄 이하, 파일 하나에 개념 하나. 테스트는 파일 하단 `test` 블록
- **Format**: `zig fmt` 통과 필수 (CI에서 검사)

### Zig 0.15.x Guidelines

- `std.ArrayList(T)`는 unmanaged — `.empty`로 초기화, 모든 변경 메서드에 allocator 전달
- `child.wait()`는 stdout을 닫는다 — wait 전에 읽는다
- `callconv(.c)` 소문자
- 버퍼드 writer는 `std.process.exit()` 전에 flush
- 파일 스코프 `const X = expr;` (`comptime` 키워드 불필요)

### synod-Specific Rules

- **코어는 절대 I/O 하지 않는다** — `raft/`, `membership/`, `detector/`는 std.net/std.fs/std.time을 import하지 않는다 (리뷰에서 grep으로 검사)
- **시계와 난수는 주입** — `std.time.milliTimestamp()` 직접 호출 금지
- **모든 상태 전이는 `step()`/`tick()`을 통해서만** — 외부에서 필드를 직접 수정하지 않는다
- **Effect는 값으로 반환** — 코어가 콜백을 호출하지 않는다
- **멤버십 변경은 조인트 합의만** — 단일 서버 변경 방식 구현 금지
- **불변식 위반은 `error.Invariant*`** — 시뮬레이터가 시드와 함께 보고할 수 있도록
- **메시지에 프로토콜 버전 필드** — 롤링 업그레이드 대비

---

## Git Workflow

- `main` 직접 커밋 (자율 세션). 사람 작업은 `feat/<name>`, `fix/<name>`
- Conventional Commits: `feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`, `chore:`
- 커밋 전 `zig build test` 통과 필수. 깨진 코드 푸시 금지
- 커밋 트레일러: `Co-Authored-By: Claude <noreply@anthropic.com>`

## Shared Scratchpad Protocol

`.claude/scratchpad.md`는 한 TDD 사이클 동안 에이전트 간 컨텍스트 전달용이다. 사이클 시작 시 초기화하고, 각 에이전트는 작업 후 자기 섹션을 append한다 (다른 에이전트 기록 삭제 금지).
