# ADR-001: Zero-dependency core

## Status

Accepted.

## Context

synod is a foundation-layer repo (`citadel/core/rules/00-kingdom.md`): foundation depends on Zig
std alone, and never on another foundation or on a kingdom library. synod's own consumers,
silica (replication/failover) and zoltraak (cluster/sentinel), each want a Raft core wired to
their own transport, disk, and clock. If synod imported a concrete network or storage
implementation, every consumer would inherit that choice transitively, and synod could not be
driven deterministically by a simulator.

## Decision

`src/raft.zig`, `src/membership.zig`, and `src/detector.zig` (the core state machines) never
import `std.net`, `std.fs`, or `std.time` directly, and `build.zig.zon` carries no
`.dependencies`. All I/O — transport, log storage, the clock, randomness — is injected through
vtables declared in `src/interfaces.zig` (`Transport`, `LogStore`, `StateMachine`, `Clock`,
`Rng`). State transitions happen only through `step()`/`tick()`, which take the current state and
inputs and return effects by value; the core never calls a callback or reaches out for its own
I/O. Consumers, or synod's own `src/adapters.zig`, supply the concrete implementations (a
sirocco-backed `Transport`, a strata-backed `LogStore`) at the composition root.

## Consequences

- The same core can be driven byte-for-byte deterministically by `src/sim.zig` across many
  seeded scenarios before it ever touches a real socket, because every side effect is a value
  the driver replays rather than an in-place syscall.
- silica and zoltraak each bring their own `Transport`/`LogStore`/`Clock` adapters instead of
  synod choosing for them, keeping the dependency graph pointing down only.
- `src/adapters.zig` (sirocco transport, strata logstore) stays optional and last in the module
  build order (`REALM.md`) — it is the one place allowed to know about a concrete transport or
  store, and it is never imported by `raft`, `membership`, or `detector`.
- Enforcement is mechanical, not just reviewed: `zig build tidy` (plan 001) greps `src/raft.zig`,
  `src/membership.zig`, and `src/detector.zig` for `std.net`, `std.fs`, `std.time`, and `std.Io`
  and fails the build on a hit.
