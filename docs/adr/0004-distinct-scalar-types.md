# ADR-004: Distinct scalar types and the in-memory Raft vocabulary

## Status

Accepted.

## Context

PRD §4.1 sketches `pub const NodeId = u64`, and `Entry`, `HardState`, and every `LogStore`
method place two or three `u64` values side by side — the swap bug Tiger Style §3.12/§3.15 says
the type system will not catch. Every later module (log, interfaces, store, raft, sim) and the
future strata/sirocco adapters build on these shapes, and once a consumer pins synod a change
becomes a MAJOR bump (plan 002, "Version impact").

## Decision

`NodeId`, `Term`, and `Index` are non-exhaustive `enum(u64)` types, each with 0 as a named
variant: `NodeId.none` ("no vote", replacing `?NodeId`, matching etcd/raft vectors), `Term.zero`,
`Index.zero` ("before the first entry"). Comparison is `order()` returning `std.math.Order`;
`==` works natively; mixing the types fails to compile. `EntryKind` is an exhaustive
`enum(u8)` with discriminants starting at 1. `HardState` is a 24-byte `extern struct` with
comptime-asserted layout, and its durability contract is `validateTransition`, which returns
`error.Invariant*` (REALM.md). These are in-memory types only: they carry no magic, version, or
checksum, because the core never encodes bytes (PRD §7). Each adapter encoding frames them with
its own magic, version, and checksum, and the protocol-version field lives on `Message` (1A-ii).

## Consequences

- A term/index swap is a compile error at every call site across the kingdom, for free.
- Construction is `@enumFromInt(n)` and arithmetic is `@intFromEnum`; `Index.next` owns the
  one overflow-checked increment so log code never hand-rolls it.
- No real node may use id 0; `raft.Config` (plan 003) asserts it. Consumers with string node
  ids (zoltraak's `[40]u8`) map them to `NodeId` at their composition root.
- `interfaces.zig` (1C) takes `Index`, not `u64`, in `truncate`/`get` — a second correction to PRD §4.1.
- tidy's wire-struct check must recognise `extern struct` declarations, or `HardState` silently
  leaves the `usize` gate; that fix ships with this ADR.
