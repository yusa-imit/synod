//! synod.raft — Pure state machine: election (PreVote), replication, progress tracking,
//! snapshot, joint-consensus membership, ReadIndex and lease reads.
//!
//! Files (see docs/PRD.md and docs/adr/0007-raft-node-contract.md):
//!   - `raft/node.zig`: implemented (plan 003 item 2A-i): `Node`, `Config`, `Restore`, `Input`,
//!     `Effect`, `Effects`, and the error sets, re-exported below.
//!   - `raft/progress.zig`: implemented (plan 003 item 2C), internal (not re-exported)
//!   - `raft/snapshot.zig`: planned
//!   - `raft/membership.zig`: planned
//!   - `raft/read.zig`: planned
//!
//! Status: skeleton. `Node` restores, validates and routes messages, applies the term rules and
//! counts ticks; elections, replication and apply land with the later items of plan 003.

const std = @import("std");

pub const node = @import("raft/node.zig");
pub const Config = node.Config;
pub const Restore = node.Restore;
pub const Input = node.Input;
pub const Effect = node.Effect;
pub const Effects = node.Effects;
pub const Role = node.Role;
pub const Status = node.Status;
pub const Node = node.Node;
pub const InitError = node.InitError;
pub const ReceiveError = node.ReceiveError;
pub const ProposeError = node.ProposeError;
pub const StepError = node.StepError;
pub const InvariantError = node.InvariantError;

test "raft: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    // `progress` is internal (not re-exported), so its tests are pulled in here.
    _ = @import("raft/progress_test.zig");
}
