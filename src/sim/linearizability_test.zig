//! Tests for `sim/linearizability.zig` (ADR-008, "Linearizability"; plan 004 item 9), written
//! before the implementation. Hand-built histories of `put`/`get` operations: linearizable ones
//! that must pass, non-linearizable ones that must raise `Linearizability`, the Wing-Gong /
//! Herlihy-Wing / Porcupine style histories, pending (indeterminate) operations, per-key
//! independence, the three boundaries (`history_ops_max`, `keys_max`, `search_steps_max`), every
//! `CheckError` variant, and the allocation contract (everything at `init`, nothing in `check`).
//! The seeded model test against a brute-force reference is in `linearizability_model_test.zig`.
//!
//! Conventions: events are distinct integers (a position in one total order), histories are
//! listed in `invoke_event` order, a client never has two outstanding operations, and a client
//! with a pending operation has no later one. A value of 0 means "never written"; puts write
//! non-zero values. Malformed histories are the caller's bug (asserted) and are not provoked,
//! except that `HistoryTooLong` is decided before any work, so it is checked against one.

const std = @import("std");
const testing = std.testing;
const fx = @import("linearizability_fixtures.zig");

const CheckError = fx.CheckError;
const Operation = fx.Operation;
const put = fx.put;
const get = fx.get;
const put_pending = fx.put_pending;
const get_pending = fx.get_pending;
const expect_ok = fx.expect_ok;
const expect_violation = fx.expect_violation;
const expect_verdict = fx.expect_verdict;

// ---------------------------------------------------------------- linearizable histories

test "linearizability: empty history is linearizable" {
    try expect_ok(&[_]Operation{});
}

test "linearizability: a single put is linearizable" {
    try expect_ok(&.{put(0, 0, 5, 1, 2)});
}

test "linearizability: a get on a never written key returns 0" {
    try expect_ok(&.{get(0, 0, 0, 1, 2)});
}

test "linearizability: a get after a completed put returns the written value" {
    try expect_ok(&.{ put(0, 0, 5, 1, 2), get(1, 0, 5, 3, 4) });
}

test "linearizability: a sequential overwrite is read back as the last value" {
    try expect_ok(&.{
        put(0, 0, 1, 1, 2),
        put(1, 0, 2, 3, 4),
        get(2, 0, 2, 5, 6),
        get(0, 0, 2, 7, 8),
    });
}

test "linearizability: a get concurrent with a put may return the old value" {
    try expect_ok(&.{ put(0, 0, 7, 1, 4), get(1, 0, 0, 2, 3) });
}

test "linearizability: a get concurrent with a put may return the new value" {
    try expect_ok(&.{ put(0, 0, 7, 1, 4), get(1, 0, 7, 2, 3) });
}

test "linearizability: a get concurrent with a second put returns old or new, nothing else" {
    for ([_]u64{ 0, 1, 2, 3 }) |seen| {
        const history = [_]Operation{
            put(0, 0, 1, 1, 2),
            put(1, 0, 2, 3, 8),
            get(2, 0, seen, 4, 5),
        };
        try expect_verdict(&history, if (seen == 1 or seen == 2) null else error.Linearizability);
    }
}

test "linearizability: after two concurrent puts a later get may see either one" {
    for ([_]u64{ 0, 1, 2, 3 }) |seen| {
        const history = [_]Operation{
            put(0, 0, 1, 1, 4),
            put(1, 0, 2, 2, 5),
            get(2, 0, seen, 6, 7),
        };
        try expect_verdict(&history, if (seen == 1 or seen == 2) null else error.Linearizability);
    }
}

test "linearizability: reads that straddle one write agree on one switch point" {
    try expect_ok(&.{
        put(0, 0, 9, 1, 10),
        get(1, 0, 0, 2, 4),
        get(2, 0, 9, 3, 6),
        get(1, 0, 9, 7, 8),
    });
}

// ----------------------------------------------------------- non-linearizable histories

test "linearizability: a stale read after a completed put is a violation" {
    try expect_violation(&.{ put(0, 0, 1, 1, 2), get(1, 0, 0, 3, 4) });
}

test "linearizability: a stale read of the previous put after an overwrite is a violation" {
    try expect_violation(&.{ put(0, 0, 1, 1, 2), put(1, 0, 2, 3, 4), get(2, 0, 1, 5, 6) });
}

test "linearizability: a client does not read its own earlier put as unwritten" {
    try expect_violation(&.{ put(0, 0, 1, 1, 2), get(0, 0, 0, 3, 4) });
}

test "linearizability: a read of a value no one wrote is a violation" {
    try expect_violation(&.{ put(0, 0, 1, 1, 2), get(1, 0, 9, 3, 4) });
}

test "linearizability: a read of a value on a key with no puts is a violation" {
    try expect_violation(&.{get(0, 0, 7, 1, 2)});
}

test "linearizability: a read of a value before its put was invoked is a violation" {
    try expect_violation(&.{ get(0, 0, 1, 1, 2), put(1, 0, 1, 3, 4) });
}

test "linearizability: reading the new value and then the old one goes back in time" {
    try expect_violation(&.{
        put(0, 0, 1, 1, 2),
        put(1, 0, 2, 3, 20),
        get(2, 0, 2, 4, 5),
        get(2, 0, 1, 6, 7),
    });
}

test "linearizability: reading the old value and then the new one is fine" {
    try expect_ok(&.{
        put(0, 0, 1, 1, 2),
        put(1, 0, 2, 3, 20),
        get(2, 0, 1, 4, 5),
        get(2, 0, 2, 6, 7),
    });
}

test "linearizability: two clients seeing two concurrent puts in opposite orders" {
    try expect_violation(&.{
        put(0, 0, 1, 1, 20),
        put(1, 0, 2, 2, 21),
        get(2, 0, 1, 3, 5),
        get(3, 0, 2, 4, 6),
        get(2, 0, 2, 7, 9),
        get(3, 0, 1, 8, 10),
    });
}

test "linearizability: two clients seeing two concurrent puts in the same order is fine" {
    try expect_ok(&.{
        put(0, 0, 1, 1, 20),
        put(1, 0, 2, 2, 21),
        get(2, 0, 1, 3, 5),
        get(3, 0, 1, 4, 6),
        get(2, 0, 2, 7, 9),
        get(3, 0, 2, 8, 10),
    });
}

test "linearizability: a returned value changed to a wrong one turns pass into violation" {
    for ([_]u64{ 0, 1, 2, 3 }) |seen| {
        const history = [_]Operation{
            put(0, 0, 1, 1, 2),
            put(1, 0, 2, 3, 4),
            get(2, 0, seen, 5, 6),
        };
        try expect_verdict(&history, if (seen == 2) null else error.Linearizability);
    }
}

test "linearizability: overlap in time makes a stale value legal, a gap makes it a violation" {
    try expect_ok(&.{ get(1, 0, 0, 4, 6), put(0, 0, 7, 5, 10) });
    try expect_violation(&.{ put(0, 0, 7, 5, 10), get(1, 0, 0, 11, 12) });
}

// ------------------------------------------ Wing-Gong / Herlihy-Wing / Porcupine histories

test "linearizability: paper: reads overlapping a write on both sides of its point" {
    // C reads 0 and B reads 1 while the write is open; their intervals overlap, so the write
    // can sit between their linearization points.
    try expect_ok(&.{
        put(0, 0, 1, 1, 10),
        get(2, 0, 0, 2, 4),
        get(1, 0, 1, 3, 6),
    });
}

test "linearizability: paper: a read after another read saw the write may not see 0" {
    // B returned 1 at event 3, C started at 4: the write already took effect, C reads 0.
    try expect_violation(&.{
        put(0, 0, 1, 1, 10),
        get(1, 0, 1, 2, 3),
        get(2, 0, 0, 4, 5),
    });
}

test "linearizability: paper: two overlapping writes, a later read sees either order" {
    for ([_]u64{ 0, 1, 2, 3 }) |seen| {
        const history = [_]Operation{
            put(0, 0, 1, 1, 4),
            put(1, 0, 2, 2, 5),
            get(2, 0, seen, 6, 7),
        };
        try expect_verdict(&history, if (seen == 1 or seen == 2) null else error.Linearizability);
    }
}

test "linearizability: paper: the later-invoked write may take effect first" {
    // put 2 starts after put 1 starts but both overlap, so the order 2 then 1 is allowed.
    try expect_ok(&.{
        put(0, 0, 1, 1, 6),
        put(1, 0, 2, 2, 5),
        get(2, 0, 2, 3, 4),
        get(2, 0, 1, 7, 8),
    });
}

test "linearizability: paper: a read cannot see a write that completes after it returned" {
    // The only put is invoked strictly after the get completed.
    try expect_violation(&.{ get(0, 0, 1, 1, 2), put(1, 0, 1, 3, 9) });
}

test "linearizability: paper: a write whose client crashed stays visible once observed" {
    try expect_ok(&.{
        put_pending(0, 0, 1, 1),
        get(1, 0, 1, 2, 3),
        get(2, 0, 1, 4, 5),
    });
    try expect_violation(&.{
        put_pending(0, 0, 1, 1),
        get(1, 0, 1, 2, 3),
        get(2, 0, 0, 4, 5),
    });
}

test "linearizability: paper: four clients, two keys, a long history with one bad read" {
    const good = [_]Operation{
        put(0, 0, 1, 1, 6),
        put(1, 1, 5, 2, 4),
        get(2, 0, 0, 3, 5),
        get(3, 1, 5, 7, 8),
        put(2, 0, 2, 9, 12),
        get(3, 0, 1, 10, 11),
        get(1, 0, 2, 13, 14),
        get(0, 1, 5, 15, 16),
    };
    try expect_ok(&good);
    var bad = good;
    bad[7].value = 0; // Key 1 was written 5 by event 4: reading 0 at event 15 is stale.
    try expect_violation(&bad);
}

// -------------------------------------------------------------------- pending operations

test "linearizability: a pending put alone is linearizable" {
    try expect_ok(&.{put_pending(0, 0, 4, 1)});
}

test "linearizability: a get may observe the value of a pending put" {
    try expect_ok(&.{ put_pending(0, 0, 5, 1), get(1, 0, 5, 2, 3) });
}

test "linearizability: a get may also miss a pending put" {
    try expect_ok(&.{ put_pending(0, 0, 5, 1), get(1, 0, 0, 2, 3) });
    try expect_ok(&.{
        put_pending(0, 0, 5, 1),
        get(1, 0, 0, 2, 3),
        get(1, 0, 0, 4, 5),
        get(1, 0, 0, 6, 7),
    });
}

test "linearizability: observing a pending put and then not observing it is a violation" {
    try expect_violation(&.{
        put_pending(0, 0, 5, 1),
        get(1, 0, 5, 2, 3),
        get(1, 0, 0, 4, 5),
    });
}

test "linearizability: a value only a pending put could have written may be read" {
    // Nothing completed wrote 8 on this key; the pending put is the only source.
    try expect_ok(&.{ put(0, 0, 1, 1, 2), put_pending(1, 0, 8, 3), get(2, 0, 8, 4, 5) });
}

test "linearizability: a pending put cannot be observed before it was invoked" {
    try expect_violation(&.{ get(1, 0, 5, 1, 2), put_pending(0, 0, 5, 3) });
}

test "linearizability: a pending put may take effect long after later operations" {
    try expect_ok(&.{
        put(0, 0, 1, 1, 2),
        put_pending(1, 0, 2, 3),
        get(2, 0, 1, 4, 5),
        get(2, 0, 1, 6, 7),
        get(2, 0, 2, 100, 101),
    });
}

test "linearizability: a pending put may also never take effect" {
    try expect_ok(&.{
        put(0, 0, 1, 1, 2),
        put_pending(1, 0, 2, 3),
        get(2, 0, 1, 4, 5),
        get(2, 0, 1, 100, 101),
    });
}

test "linearizability: a pending put may land after a completed put but only once" {
    // 3 is read, then the pending 2 overwrites it: legal because 2 never returned.
    try expect_ok(&.{
        put_pending(0, 0, 2, 1),
        put(1, 0, 3, 2, 3),
        get(2, 0, 3, 4, 5),
        get(2, 0, 2, 6, 7),
    });
    // 2, then 3, then 2 again would need the one pending put to take effect twice.
    try expect_violation(&.{
        put_pending(0, 0, 2, 1),
        put(1, 0, 3, 2, 20),
        get(2, 0, 2, 4, 5),
        get(2, 0, 3, 6, 7),
        get(2, 0, 2, 8, 9),
    });
}

test "linearizability: two pending puts may be observed in either order" {
    try expect_ok(&.{
        put_pending(0, 0, 1, 1),
        put_pending(1, 0, 2, 2),
        get(2, 0, 2, 3, 4),
        get(2, 0, 1, 5, 6),
    });
    try expect_violation(&.{
        put_pending(0, 0, 1, 1),
        put_pending(1, 0, 2, 2),
        get(2, 0, 1, 3, 4),
        get(2, 0, 2, 5, 6),
        get(2, 0, 1, 7, 8),
    });
}

test "linearizability: a pending put on one key never explains a read on another" {
    try expect_violation(&.{ put_pending(0, 0, 5, 1), get(1, 1, 5, 2, 3) });
}

test "linearizability: a pending get is dropped whatever value it carries" {
    try expect_ok(&.{get_pending(0, 0, 99, 1)});
    try expect_ok(&.{ put(0, 0, 1, 1, 2), get_pending(1, 0, 99, 3), get(2, 0, 1, 4, 5) });
}

test "linearizability: a pending get does not rescue a violation" {
    try expect_violation(&.{
        put(0, 0, 1, 1, 2),
        get(1, 0, 0, 3, 4),
        get_pending(2, 0, 1, 5),
    });
}

// ------------------------------------------------------------------- per-key independence

test "linearizability: registers are independent, one key never sees another's puts" {
    // A single shared register would make the second get stale; per key it is a first read.
    try expect_ok(&.{ put(0, 0, 1, 1, 2), get(1, 1, 0, 3, 4) });
    try expect_violation(&.{ put(0, 0, 1, 1, 2), get(1, 1, 1, 3, 4) });
}

test "linearizability: a violation on key 3 alone is found among clean keys" {
    const clean_before = [_]Operation{ put(0, 0, 1, 1, 2), get(1, 1, 0, 3, 4) };
    const clean_after = [_]Operation{ put(2, 5, 3, 20, 21), get(2, 5, 3, 22, 23) };
    const bad = [_]Operation{ put(0, 3, 1, 5, 6), get(1, 3, 0, 7, 8) };
    try expect_ok(&(clean_before ++ clean_after));
    try expect_violation(&(clean_before ++ bad ++ clean_after));
    try expect_violation(&(bad ++ clean_after));
    try expect_violation(&(clean_before ++ bad));
}

test "linearizability: the bad key is found wherever it is among sixteen" {
    for (0..16) |bad_key| {
        var history: [32]Operation = undefined;
        for (0..16) |key| {
            const k: u16 = @intCast(key);
            history[key] = put(k, k, k + 1, key + 1, key + 100);
            const seen: u64 = if (key == bad_key) 0 else k + 1;
            history[16 + key] = get(k, k, seen, 200 + key, 300 + key);
        }
        try expect_violation(&history);
        history[16 + bad_key].value = bad_key + 1; // Repair that one read: all clean.
        try expect_ok(&history);
    }
}

test "linearizability: violations on two keys are still one Linearizability" {
    try expect_violation(&.{
        put(0, 0, 1, 1, 2),
        get(1, 0, 0, 3, 4),
        put(2, 7, 1, 5, 6),
        get(3, 7, 9, 7, 8),
    });
}
