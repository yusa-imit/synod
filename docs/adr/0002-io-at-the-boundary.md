# ADR-002: `io: Io` at the boundary only

## Status

Accepted.

## Context

Zig 0.16 threads `io: Io` through every filesystem, network, time, sleep, sync, and process API
(`citadel/core/rules/zig-0.16.md`). synod is not the kingdom's `io: Io` spike — sigil is, and the
convention itself is already settled there — but synod must apply it without eroding ADR-001's
core-purity guarantee: `raft`, `membership`, and `detector` never import `std.net`, `std.fs`, or
`std.time`, so that `src/sim.zig` can drive them byte-for-byte deterministically. `std.Io` is the
same kind of import as those three — a real clock, a real socket, a real filesystem sit behind
its vtable — so admitting `std.Io` into the core would reopen the exact hole ADR-001 closed, just
under a different name.

## Decision

`io: Io` is the first parameter after the receiver on every public function in `src/driver.zig`
and `src/adapters.zig` (the effect-execution and concrete-transport/store boundary) and on the
`src/main.zig` and `bench/main.zig` entry points — mirroring the kingdom convention exactly.
`src/raft.zig`, `src/membership.zig`, `src/detector.zig`, `src/clock.zig`, and `src/log.zig` never
import or reference `std.Io` in any form; they keep taking the injected `Clock`/`Rng` vtables
declared in `src/interfaces.zig` instead. `src/clock.zig` in particular stays off
`std.Io.Clock` deliberately (PRD §4.1): the core's notion of time is the vtable `Clock` synod
already owns, not the runtime's clock.

Enforcement is mechanical: `zig build tidy` bans the substring `std.Io` in
`src/raft.zig`, `src/membership.zig`, `src/detector.zig`, `src/clock.zig`, and `src/log.zig`
specifically — not across all of `src/`, since `main.zig`, `bench/main.zig`, `driver.zig`, and
`adapters.zig` are expected to use `std.Io` at the boundary.

## Consequences

- The same mechanical guarantee ADR-001 gives `std.net`/`std.fs`/`std.time` in the core now
  covers `std.Io` too — a reviewer does not have to catch this by eye, and a fuzzer or future
  contributor cannot introduce it by accident.
- `driver` and `adapters` are the only modules allowed to see a concrete `Io`; when Phase 1B/1C
  (`log`, `interfaces`, `store`) land, `store.zig`'s in-memory `LogStore` still takes no `Io`
  either, since it is exercised purely through the `LogStore` vtable and never touches a real
  file — only a future `strata`-backed adapter in `src/adapters.zig` would.
- `src/clock.zig`'s HLC/Lamport/monotonic `Clock` stays a pure vtable target; nothing in the core
  can special-case "the real clock" the way an `Io.Clock` import would invite.
