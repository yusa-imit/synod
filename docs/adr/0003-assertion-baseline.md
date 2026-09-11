# ADR-003: Assertion baseline

## Status

Accepted.

## Context

`citadel/core/rules/tiger-style.md` §1.1 requires an average of at least two assertions per
function — preconditions on entry, postconditions and invariants on exit — asserted on at least
two independent code paths per property (§1.2). Every `src/*.zig` top-level module
(`types`, `interfaces`, `log`, `raft`, `driver`, `membership`, `detector`, `clock`, `store`,
`sim`, `adapters`) is still an 18–26 line stub with no logic to assert over; retrofitting
assertions onto a stub would be decorative, not load-bearing. The only real code in the repo
today is `src/main.zig`'s argument handling and `bench/main.zig`'s ops-per-second math — both
already carry preconditions and postconditions from prior review passes (commits `e66e98c` and
`c366e6b`). This ADR records the baseline as a standing contract for the code that
exists now and the modules `REALM.md`'s build order lands next, rather than deferring the
decision until the retrofit is due.

## Decision

1. **Now, in `src/main.zig` and `bench/main.zig`:** every function asserts its preconditions on
   entry. `main()` in both files asserts `args.len >= 1` (the process always has an argv[0]) and,
   in the CLI, that the resolved command string is non-empty; `bench/main.zig`'s `main()` asserts
   the elapsed-time invariant (`elapsed.raw.nanoseconds >= 0`, a monotonic-clock postcondition)
   and the ops/rate implication (`ops > 0 or ns_per_op == 0`, split as `if` per Tiger Style
   §1.4 rather than a compound `or` on the caller side); `matchesFilter` asserts the precondition
   `name.len > 0` and the postcondition that a found index plus the filter length never exceeds
   the haystack length. `grep -c assert src/main.zig bench/main.zig` must stay greater than 0;
   CI's existing `zig build test` (which runs `bench_tests`) is the regression gate — a future
   change that deletes these asserts without replacing them fails no automated check today, so
   `code-reviewer` treats a diff that lowers either file's assert count as a WARNING by default.
2. **Going forward, in `src/types.zig`, `src/interfaces.zig`, `src/log.zig`, `src/store.zig`**
   (the modules `REALM.md`'s build order lands first — `types` → `interfaces` + `log` → `store`):
   every `pub fn` added while implementing PRD phases 1A–1D asserts its preconditions on entry
   and its postconditions/invariants on exit, split per property rather than compounded, and each
   property is asserted on at least two independent paths where the module has more than one
   caller-facing entry point (Tiger Style §1.2). `src/interfaces.zig` declares vtables
   (`Transport`/`LogStore`/`StateMachine`/`Clock`/`Rng`) rather than logic; the contract there is
   that any concrete free function it does gain (a default/no-op implementation, a vtable
   validity check) follows the same rule — a pure `struct` of function pointers with no bodies
   has nothing to assert over and is not exempted so much as inapplicable until one exists. Once
   `src/log.zig` gains real mutating state, `log.validate()` (or the module's chosen name for the
   same contract — see the module's own doc comment when it lands) runs at the end of every test
   that appends, truncates, or restores the log, per the plan 001 assertion-baseline item and
   `REALM.md`'s Core-is-pure-state-machine pattern. Garbage caller state (out-of-range index,
   overlapping slices) is asserted; garbage log *data* (a malformed persisted entry) is a typed
   `Error` return, never an assert, per Tiger Style's assert-vs-return line.
3. This ADR does not add a new mechanical `tidy` check: an assertion-density gate over stub
   modules with no logic would have nothing to measure and nothing to fail on. The gate is
   `code-reviewer` at implementation time for `types`/`log`/`store` (verifying the two-assertions-
   per-function average and the paired-path rule on the actual diff) plus the existing
   `zig build test` regression suite for `main.zig`/`bench/main.zig`. A future cycle may add a
   mechanical density check once `log.validate()` exists and there is a second real module to
   validate the check against — recorded here so an implementer knows why it doesn't exist yet,
   not because it was overlooked.

## Consequences

- The baseline is enumerable today (`grep -c assert src/main.zig bench/main.zig` > 0) and
  falsifiable going forward: `code-reviewer` has a concrete two-assertion, two-path target to
  check `types.zig`/`log.zig`/`store.zig` against as soon as Phase 1A lands, instead of
  discovering the standard ad hoc mid-review.
- `log.validate()`'s invariant-checking contract is deferred to the module that will actually
  define what "valid" means (entry indices contiguous, terms non-decreasing, no gap at the
  snapshot boundary) — this ADR fixes *when* it must run (every mutating test) without
  prescribing its internals ahead of the design.
- No new CI gate lands with this ADR; the risk accepted is that a reviewer could still miss an
  assertion-count regression in `main.zig`/`bench/main.zig` between cycles. That risk is judged
  acceptable because both files are small (38 and 68 lines) and `code-reviewer` runs on every PR
  that touches them.
