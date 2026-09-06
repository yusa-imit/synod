//! synod.raft — Pure state machine: election (PreVote), replication, progress tracking,
//! snapshot, joint-consensus membership, ReadIndex and lease reads.
//!
//! Planned files (see docs/PRD.md):
//!   - `raft/node.zig`
//!   - `raft/progress.zig`
//!   - `raft/snapshot.zig`
//!   - `raft/membership.zig`
//!   - `raft/read.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "raft: module compiles" {
    std.testing.refAllDecls(@This());
}
