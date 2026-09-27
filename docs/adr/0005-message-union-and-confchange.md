# ADR-005: The `Message` union and joint-consensus `ConfChange`

## Status

Proposed (plan 002, item 1A-ii); accepted when the 1A-ii PR merges.

## Context

`Transport` (1C) carries `Message`; silica/zoltraak adapters encode it. Once pinned, a field
change is MAJOR, so rolling-upgrade, PreVote, backtrack, and joint-consensus fields land now
(REALM.md: version on every wire message; joint consensus is the only membership path).

## Decision

```zig
pub const protocol_version_min: u16 = 1; // oldest accepted; 0 is never valid
pub const protocol_version_current: u16 = 1; // newest accepted; sent value is from raft.Config
pub const voters_max = 16; // per voter set, and learners_max = 16: stack-sized quorum math
pub const Header = struct { protocol_version: u16, term: Term, from: NodeId, to: NodeId };
pub const VoteRequest = struct { header: Header, last_log_index: Index, last_log_term: Term };
pub const VoteResponse = struct { header: Header, granted: bool };
pub const AppendRequest = struct { header: Header, prev_log_index: Index, prev_log_term: Term,
    leader_commit: Index, round: u64, entries: []const Entry }; // entries borrowed
pub const Conflict = struct { index: Index, term: Term };
pub const AppendOutcome = union(enum) { accepted: Index, rejected: Conflict }; // match index
pub const AppendResponse = struct { header: Header, round: u64, outcome: AppendOutcome };
pub const SnapshotRequest = struct { header: Header, snapshot: Snapshot, // data borrowed
    configuration: Configuration }; // membership as of snapshot.index
pub const SnapshotResponse = struct { header: Header, match_index: Index };
pub const MessageKind = enum(u8) { request_vote = 1, request_vote_response = 2, pre_vote = 3,
    pre_vote_response = 4, append_entries = 5, append_entries_response = 6,
    install_snapshot = 7, install_snapshot_response = 8 };
pub const Message = union(MessageKind) {
    request_vote: VoteRequest, request_vote_response: VoteResponse,
    pre_vote: VoteRequest, pre_vote_response: VoteResponse,
    append_entries: AppendRequest, append_entries_response: AppendResponse,
    install_snapshot: SnapshotRequest, install_snapshot_response: SnapshotResponse,
    pub const Limits = struct { entries_max: u32, entry_bytes_max: u32, snapshot_bytes_max: u64 };
    pub fn header(message: *const Message) *const Header; // one exhaustive switch
    pub fn validate(message: *const Message, limits: Limits) MessageError!void;
};
pub const Configuration = struct { // lists borrowed, strictly ascending (no dupes, no .none)
    voters: []const NodeId, // 1..voters_max; C_new
    voters_outgoing: []const NodeId, // C_old while joint, else empty
    learners: []const NodeId, // 0..learners_max; disjoint from voters (may overlap outgoing)
    pub fn validate(configuration: *const Configuration) ConfError!void;
};
pub const ConfChange = union(enum) {
    enter_joint: Configuration, // C_old,new: voters_outgoing non-empty
    leave_joint: Configuration, // C_new: voters_outgoing empty
    pub fn validate(change: *const ConfChange) ConfError!void;
};
pub const ConfError = error{ ConfVotersEmpty, ConfVotersTooMany, ConfLearnersTooMany,
    ConfNodesUnsorted, ConfLearnerIsVoter, ConfJointShape };
pub const MessageError = ConfError || error{ MessageVersionUnsupported, MessageTermZero,
    MessageNodeInvalid, MessageLogPositionInvalid, MessageEntriesNotContiguous,
    MessageEntryTermInvalid, MessageTooLarge, MessageSnapshotInvalid, MessageConflictInvalid };
```

- **Header first in every payload, no defaults**: a payload built without it does not compile.
- **PreVote gets its own variants (shared payloads), not `pre_vote: bool`.** It must not raise
  the receiver's term or touch `HardState.vote`; a forgotten bool compiles and causes the very
  disruption PreVote prevents. A grant echoes the request's term, a rejection the responder's.
- **A rejection carries a `Conflict` hint** (Raft thesis §5.3): the follower's term at
  `prev_log_index` and the first index of that term. For a shorter log it is `.zero` and
  last index `.next()`. Without it, a follower k entries behind costs k round trips. A leader
  may ignore it (step back by one), but adding it later breaks the wire. **`round`** drops
  reordered responses and gives ReadIndex (plan 003) its "acked after the read" proof.
- **Plain structs, not `extern`.** Payloads hold slices and unions, `Header` would pad, and
  nothing compares them byte-for-byte. Adapter frames carry magic, encoding version, and
  checksum (ADR-004). `protocol_version` versions Raft semantics: deploy "accept N+1, send N",
  then flip `raft.Config`. `MessageKind` starts at 1 so adapters may use it as the wire tag.
- **`ConfChange` is absolute, not deltas**: idempotent, canonical (`std.mem.eql` on sorted
  lists), no single-server shape. `raft` (plan 003) matches it against the current config.
- **`validate` is structural and bounded**: version in range; term, `from`, `to` non-zero,
  `from != to`; log term `.zero` iff its index is; terms `<= header.term`; entries contiguous
  from `prev_log_index.next()`, terms non-decreasing; `Limits`; snapshot and `Conflict` index
  non-zero. Peer data returns `Message*`/`Conf*`; `Invariant*` stays for local corruption.

## Consequences

- 1A-ii tests: exhaustive `switch`; comptime check that every payload's field 0 is
  `header: Header` with no defaults; 8 kinds and `fromInt(0) == null`; one negative test per
  error; borrow identity; a seeded model of `validate`.
- A new variant or field fails consumer switches at compile time, bumps
  `protocol_version_current`, is MAJOR once pinned; TimeoutNow arrives that way.
- Messages borrow until `step()` returns; `Transport.send` (1C) documents that lifetime.
- `Snapshot` is unchanged. Store (1D) must persist a `Configuration` per snapshot. The
  `ConfChange` codec into `Entry.data` (plan 003) carries its own magic, version, checksum.
