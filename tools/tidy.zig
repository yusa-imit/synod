//! tools/tidy.zig — Tiger Style size-floor and ban-list checker.
//!
//! Pure, in-memory functions only; no file I/O happens here. `main()` (added alongside the
//! real implementation) walks `src/` and feeds each file's path and contents into these
//! functions. Ownership: `path`, `source`, and `text` must outlive every returned slice —
//! `LineViolation.path`, `FunctionViolation.path`/`.name`, and `BaselineEntry.path`/`.name`
//! are sub-slices of the caller's buffers, never duplicated. Only the top-level slice
//! returned by each function is heap-owned (by `gpa`) and must be freed by the caller.
//!
//! Baseline invariant: `function_lines_red_zone_max` is the hard ceiling for any
//! baseline-covered function. A `BaselineEntry.lines_max` value above the red zone cap is
//! clamped down, never trusted past it — an entry cannot buy more than 72 lines.
//!
//! Every checker here is a naive line/substring/brace scan, not a real Zig parser: none is
//! comment- or string-literal-aware, so a pattern inside a `//` comment or a string constant
//! can false-positive. This matches the file's existing size checks and keeps the tool
//! dependency-free; a false positive is cheap to silence at the call site (reword the line).
//!
//! `main()` walks `src/` recursively, checks every `*.zig` file against the size rules, the
//! ban list (`catch unreachable` without `// proof:`, `std.debug.print`, `std.time.*`, `std.Io`
//! in core-purity files, `usize` in a wire struct, a missing `//!` header), loading
//! `tools/tidy_baseline.txt` when present, also checks `build.zig`'s header, prints violations
//! to stderr, and exits non-zero if any file had one.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const line_length_max: usize = 100;
pub const function_lines_max: usize = 70;
pub const function_lines_red_zone_max: usize = 72;

comptime {
    assert(function_lines_max < function_lines_red_zone_max);
    assert(line_length_max > 0);
}

/// Bytes read per source file `main()` scans; generous for a hand-written `.zig` file.
const file_bytes_max: usize = 4 * 1024 * 1024;
/// Files visited per `main()` walk; a tripwire against a runaway or symlink-looped tree.
const files_max: u32 = 10_000;

pub const LineViolation = struct {
    path: []const u8,
    line: u32,
    length: u32,
};

pub const FunctionViolation = struct {
    path: []const u8,
    name: []const u8,
    line_start: u32,
    lines: u32,
};

pub const BaselineEntry = struct {
    path: []const u8,
    name: []const u8,
    lines_max: u32,
};

/// Precondition: `path` and `source` outlive the returned slice.
/// Postcondition: one `LineViolation` per 1-indexed line whose byte length exceeds
/// `line_length_max`; a source with no offending line returns an empty (but allocated,
/// caller-freed) slice.
pub fn checkLineLengths(
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
) Allocator.Error![]LineViolation {
    assert(path.len > 0);
    assert(line_length_max > 0);

    var violations: std.ArrayList(LineViolation) = .empty;
    errdefer violations.deinit(gpa);

    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_count: u32 = 0;
    while (lines.next()) |line| : (line_number += 1) {
        line_count += 1;
        if (line.len > line_length_max) {
            try violations.append(gpa, .{
                .path = path,
                .line = line_number,
                .length = @intCast(line.len),
            });
        }
    }

    assert(violations.items.len <= line_count);
    return violations.toOwnedSlice(gpa);
}

/// Precondition: `text` outlives the returned slice.
/// Postcondition: one `BaselineEntry` per non-blank `path:function:lines` line, in order;
/// blank lines are skipped. Returns `error.InvalidBaseline` for a line missing the
/// two-colon `path:function:lines` shape or with a non-numeric `lines` field.
pub fn parseBaseline(
    gpa: Allocator,
    text: []const u8,
) (Allocator.Error || error{InvalidBaseline})![]BaselineEntry {
    var entries: std.ArrayList(BaselineEntry) = .empty;
    errdefer entries.deinit(gpa);

    const lines_max_possible = std.mem.count(u8, text, "\n") + 1;
    assert(lines_max_possible >= 1);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        assert(line.len > 0);
        const entry = try parseBaselineLine(line);
        try entries.append(gpa, entry);
    }

    assert(entries.items.len <= lines_max_possible);
    return entries.toOwnedSlice(gpa);
}

/// Parses one non-blank `path:function:lines` line into a `BaselineEntry` sub-slicing `line`.
fn parseBaselineLine(line: []const u8) error{InvalidBaseline}!BaselineEntry {
    assert(line.len > 0);

    const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidBaseline;
    assert(first_colon < line.len);
    const rest = line[first_colon + 1 ..];
    const second_colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidBaseline;
    assert(second_colon < rest.len);
    const path = line[0..first_colon];
    const name = rest[0..second_colon];
    const lines_field = rest[second_colon + 1 ..];

    const lines_max = std.fmt.parseInt(u32, lines_field, 10) catch return error.InvalidBaseline;

    return .{ .path = path, .name = name, .lines_max = lines_max };
}

/// Precondition: `path`, `source`, and every `BaselineEntry` in `baseline` outlive the
/// returned slice.
/// Postcondition: one `FunctionViolation` per declared function (`pub fn name(` or
/// `fn name(`, top-level or nested, brace-delimited) whose inclusive line count — from its
/// declaration line through the line of its matching closing brace, tracked by brace depth
/// — exceeds `function_lines_max`. A function over the limit is excused only if `baseline`
/// holds an entry matching `path` and the function's name whose `lines_max` (clamped to
/// `function_lines_red_zone_max`) is at least the function's measured line count.
pub fn checkFunctionLengths(
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
    baseline: []const BaselineEntry,
) Allocator.Error![]FunctionViolation {
    assert(path.len > 0);
    assert(function_lines_max < function_lines_red_zone_max);

    var violations: std.ArrayList(FunctionViolation) = .empty;
    errdefer violations.deinit(gpa);

    var line_number: u32 = 1;
    var offset: usize = 0;
    while (offset <= source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
        const line = source[offset..line_end];
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (functionNameAt(trimmed)) |name| {
            if (findFunctionEnd(source, offset, line_number)) |end| {
                const lines_count = end.line - line_number + 1;
                const allowed = allowedFunctionLines(baseline, path, name);
                if (lines_count > allowed) {
                    try violations.append(gpa, .{
                        .path = path,
                        .name = name,
                        .line_start = line_number,
                        .lines = lines_count,
                    });
                }
            }
        }
        if (line_end >= source.len) break;
        offset = line_end + 1;
        line_number += 1;
    }

    assert(violations.items.len <= line_number);
    return violations.toOwnedSlice(gpa);
}

/// Returns the function name starting at `trimmed` (a `pub fn `/`fn `-prefixed line with
/// leading whitespace already stripped), or `null` if the line does not declare a function.
fn functionNameAt(trimmed: []const u8) ?[]const u8 {
    const prefix_len: usize = if (std.mem.startsWith(u8, trimmed, "pub fn "))
        7
    else if (std.mem.startsWith(u8, trimmed, "fn "))
        3
    else
        return null;
    assert(prefix_len == 3 or prefix_len == 7);

    const rest = trimmed[prefix_len..];
    const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const name = rest[0..paren];
    if (name.len == 0) return null;
    return name;
}

const FunctionEnd = struct { line: u32 };

/// Scans forward from `decl_offset` (the byte offset of the declaration line's start) for the
/// first `{`, then tracks brace depth to find its match. Returns `null` for malformed input
/// (no opening brace, or more closes than opens) rather than crashing on bad source text.
fn findFunctionEnd(source: []const u8, decl_offset: usize, decl_line: u32) ?FunctionEnd {
    assert(decl_offset <= source.len);
    assert(decl_line >= 1);

    const open = std.mem.indexOfScalarPos(u8, source, decl_offset, '{') orelse return null;
    var line = decl_line + @as(u32, @intCast(std.mem.count(u8, source[decl_offset..open], "\n")));

    var depth: i32 = 1;
    var i: usize = open + 1;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '\n' => line += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .line = line };
                if (depth < 0) return null;
            },
            else => {},
        }
    }
    return null;
}

/// Returns the maximum line count `name` (declared in `path`) may reach without a violation:
/// the matching baseline entry's `lines_max`, clamped to `function_lines_red_zone_max`, or
/// `function_lines_max` when no entry matches.
fn allowedFunctionLines(baseline: []const BaselineEntry, path: []const u8, name: []const u8) u32 {
    for (baseline) |entry| {
        if (std.mem.eql(u8, entry.path, path) and std.mem.eql(u8, entry.name, name)) {
            return @min(entry.lines_max, function_lines_red_zone_max);
        }
    }
    return function_lines_max;
}

pub const CatchUnreachableViolation = struct {
    path: []const u8,
    line: u32,
};

pub const BannedPatternViolation = struct {
    path: []const u8,
    line: u32,
    pattern: []const u8,
};

pub const WireUsizeViolation = struct {
    path: []const u8,
    line: u32,
    type_name: []const u8,
};

/// Wire/format structs whose fields must stay `u64` — `usize` differs across the 6
/// cross-compile targets, so it may never appear inside these on-wire types.
pub const wire_struct_names = [_][]const u8{ "Message", "Entry", "HardState", "Snapshot" };

/// Core-purity files (`docs/adr/0002-io-at-the-boundary.md`): `std.Io` never appears in these
/// — they take the injected `Clock`/`Rng` vtables from `src/interfaces.zig` instead, so
/// `src/sim.zig` can drive them deterministically. `src/main.zig`, `bench/main.zig`,
/// `src/driver.zig`, and `src/adapters.zig` are the `std.Io` boundary and are deliberately
/// excluded.
pub const core_purity_files = [_][]const u8{
    "src/raft.zig",  "src/membership.zig", "src/detector.zig",
    "src/clock.zig", "src/log.zig",
};

/// True if `path` is one of the exact `core_purity_files` paths (a whole-path match, not a
/// suffix or substring match — `src/sub/raft.zig` and `raft.zig` are both `false`).
pub fn isCorePurityFile(path: []const u8) bool {
    assert(path.len > 0);
    comptime assert(core_purity_files.len == 5);

    for (core_purity_files) |core_path| {
        if (std.mem.eql(u8, path, core_path)) return true;
    }
    return false;
}

/// Precondition: `path` and `source` outlive the returned slice.
/// Postcondition: one `CatchUnreachableViolation` per line containing `catch unreachable`
/// that has no `// proof:` comment on that same line or on the line immediately before it.
pub fn checkCatchUnreachable(
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
) Allocator.Error![]CatchUnreachableViolation {
    assert(path.len > 0);

    var violations: std.ArrayList(CatchUnreachableViolation) = .empty;
    errdefer violations.deinit(gpa);

    const line_count = std.mem.count(u8, source, "\n") + 1;
    var prev_line: ?[]const u8 = null;
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        defer prev_line = line;
        if (std.mem.indexOf(u8, line, "catch unreachable") == null) continue;
        const proof_here = std.mem.indexOf(u8, line, "// proof:") != null;
        const proof_before = if (prev_line) |p|
            std.mem.indexOf(u8, p, "// proof:") != null
        else
            false;
        if (proof_here or proof_before) continue;
        try violations.append(gpa, .{ .path = path, .line = line_number });
    }

    assert(violations.items.len <= line_count);
    return violations.toOwnedSlice(gpa);
}

/// Precondition: `path`, `source`, and `pattern` outlive the returned slice.
/// Postcondition: one `BannedPatternViolation` per line containing `pattern` as a substring.
pub fn checkBannedPattern(
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
    pattern: []const u8,
) Allocator.Error![]BannedPatternViolation {
    assert(path.len > 0);
    assert(pattern.len > 0);

    var violations: std.ArrayList(BannedPatternViolation) = .empty;
    errdefer violations.deinit(gpa);

    const line_count = std.mem.count(u8, source, "\n") + 1;
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (std.mem.indexOf(u8, line, pattern) == null) continue;
        try violations.append(gpa, .{ .path = path, .line = line_number, .pattern = pattern });
    }

    assert(violations.items.len <= line_count);
    return violations.toOwnedSlice(gpa);
}

/// True if `c` may appear inside a Zig identifier.
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True if `haystack` contains `word` as a whole identifier token, not as a substring of a
/// longer identifier (so `usize` does not match `my_usize_thing`).
fn containsWord(haystack: []const u8, word: []const u8) bool {
    assert(word.len > 0);

    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, word)) |at| {
        const before_ok = at == 0 or !isIdentChar(haystack[at - 1]);
        const after = at + word.len;
        const after_ok = after >= haystack.len or !isIdentChar(haystack[after]);
        if (before_ok and after_ok) return true;
        from = at + 1;
    }
    return false;
}

/// Returns the byte offset just past a whole-word occurrence of `name` in `source` at or
/// after `from` that is (across any run of spaces, tabs, or newlines) followed by `=` and
/// then `struct` or `union`, or `null` if none remains.
fn findWireDeclEnd(source: []const u8, from: usize, name: []const u8) ?usize {
    assert(name.len > 0);
    assert(from <= source.len);

    var search_from = from;
    while (std.mem.indexOfPos(u8, source, search_from, name)) |at| {
        search_from = at + 1;
        const before_ok = at == 0 or !isIdentChar(source[at - 1]);
        const after_ok = at + name.len < source.len and !isIdentChar(source[at + name.len]);
        if (!before_ok or !after_ok) continue;

        const after_name = std.mem.trimStart(u8, source[at + name.len ..], " \t\r\n");
        if (!std.mem.startsWith(u8, after_name, "=")) continue;
        const after_eq = std.mem.trimStart(u8, after_name[1..], " \t\r\n");
        const is_struct = std.mem.startsWith(u8, after_eq, "struct");
        const is_union = std.mem.startsWith(u8, after_eq, "union");
        if (!is_struct and !is_union) continue;
        return at + name.len;
    }
    return null;
}

/// Precondition: `path` and `source` outlive the returned slice.
/// Postcondition: one `WireUsizeViolation` per line inside a `pub const <Name> = struct {`
/// or `= union(enum) {` block (for each `Name` in `wire_struct_names`) that contains the
/// whole word `usize`. Declaration and closing-brace lines are excluded.
pub fn checkWireUsize(
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
) Allocator.Error![]WireUsizeViolation {
    assert(path.len > 0);

    var violations: std.ArrayList(WireUsizeViolation) = .empty;
    errdefer violations.deinit(gpa);

    const line_count = std.mem.count(u8, source, "\n") + 1;

    for (wire_struct_names) |type_name| {
        var from: usize = 0;
        while (findWireDeclEnd(source, from, type_name)) |decl_end| {
            const open = std.mem.indexOfScalarPos(u8, source, decl_end, '{') orelse break;
            const decl_line = lineNumberAt(source, open);
            const end = findFunctionEnd(source, decl_end, decl_line) orelse break;
            assert(end.line >= decl_line);
            from = open + 1;

            const decl_end_of_line = std.mem.indexOfScalarPos(
                u8,
                source,
                open,
                '\n',
            ) orelse source.len;
            var offset = decl_end_of_line + 1;
            var line_number = decl_line + 1;
            while (line_number < end.line and offset <= source.len) {
                const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse
                    source.len;
                const line = source[offset..line_end];
                if (containsWord(line, "usize")) {
                    try violations.append(gpa, .{
                        .path = path,
                        .line = line_number,
                        .type_name = type_name,
                    });
                }
                offset = line_end + 1;
                line_number += 1;
            }
        }
    }

    assert(violations.items.len <= wire_struct_names.len * line_count);
    return violations.toOwnedSlice(gpa);
}

/// Returns the 1-indexed line number containing byte `offset` of `source`.
fn lineNumberAt(source: []const u8, offset: usize) u32 {
    assert(offset <= source.len);
    const number = @as(u32, @intCast(std.mem.count(u8, source[0..offset], "\n"))) + 1;
    assert(number >= 1);
    return number;
}

/// True if `source`'s very first line starts with a `//!` module doc comment.
pub fn hasModuleHeader(source: []const u8) bool {
    const first_line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    assert(first_line_end <= source.len);
    const first_line = source[0..first_line_end];
    const has_header = std.mem.startsWith(u8, first_line, "//!");
    if (has_header) assert(first_line.len >= 3);
    return has_header;
}

/// Reads `sub_path` under `dir` and returns its contents, or an empty slice if the file does
/// not exist. Precondition: `gpa` outlives the returned slice; the caller frees it.
fn readOptionalFile(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) ![]u8 {
    assert(sub_path.len > 0);

    const limit: Io.Limit = .limited(file_bytes_max);
    const contents = dir.readFileAlloc(io, sub_path, gpa, limit) catch |err| switch (err) {
        error.FileNotFound => return try gpa.alloc(u8, 0),
        else => return err,
    };

    assert(contents.len <= file_bytes_max);
    return contents;
}

/// Prints every size violation (line-length, function-length) to stderr. Returns whether any
/// was printed.
fn reportSizeViolations(
    io: Io,
    path: []const u8,
    line_violations: []const LineViolation,
    fn_violations: []const FunctionViolation,
) bool {
    assert(path.len > 0);

    const stderr = Io.File.stderr();
    var buf: [512]u8 = undefined;
    for (line_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: line too long ({d} > {d})\n", .{
            v.path, v.line, v.length, line_length_max,
        }) catch continue;
        stderr.writeStreamingAll(io, msg) catch {};
    }
    for (fn_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: fn {s} too long ({d} > {d})\n", .{
            v.path, v.line_start, v.name, v.lines, function_lines_max,
        }) catch continue;
        stderr.writeStreamingAll(io, msg) catch {};
    }

    return line_violations.len > 0 or fn_violations.len > 0;
}

/// Prints every ban-list violation (catch unreachable, banned pattern, `std.Io` core-purity,
/// wire usize, missing module header) to stderr. Returns whether any was printed.
fn reportBanViolations(
    io: Io,
    path: []const u8,
    catch_violations: []const CatchUnreachableViolation,
    debug_print_violations: []const BannedPatternViolation,
    time_violations: []const BannedPatternViolation,
    io_violations: []const BannedPatternViolation,
    wire_violations: []const WireUsizeViolation,
    missing_header: bool,
) bool {
    assert(path.len > 0);

    const stderr = Io.File.stderr();
    var buf: [512]u8 = undefined;
    for (catch_violations) |v| {
        const msg = std.fmt.bufPrint(
            &buf,
            "{s}:{d}: catch unreachable without a // proof: comment\n",
            .{ v.path, v.line },
        ) catch continue;
        stderr.writeStreamingAll(io, msg) catch {};
    }
    const banned_pattern_groups = [_][]const BannedPatternViolation{
        debug_print_violations, time_violations, io_violations,
    };
    for (banned_pattern_groups) |group| {
        for (group) |v| {
            const msg = std.fmt.bufPrint(&buf, "{s}:{d}: banned pattern {s} in src/\n", .{
                v.path, v.line, v.pattern,
            }) catch continue;
            stderr.writeStreamingAll(io, msg) catch {};
        }
    }
    for (wire_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: usize field in wire struct {s}\n", .{
            v.path, v.line, v.type_name,
        }) catch continue;
        stderr.writeStreamingAll(io, msg) catch {};
    }
    if (missing_header) {
        const msg = std.fmt.bufPrint(&buf, "{s}: missing a //! module header on line 1\n", .{
            path,
        }) catch "";
        stderr.writeStreamingAll(io, msg) catch {};
    }

    return catch_violations.len > 0 or debug_print_violations.len > 0 or
        time_violations.len > 0 or io_violations.len > 0 or
        wire_violations.len > 0 or missing_header;
}

/// Checks one file under `src_dir` against the size rules and the ban list (catch unreachable,
/// std.debug.print, std.time.*, std.Io in core-purity files, usize in wire structs, missing
/// `//!` header) and reports its violations. Returns whether it had any.
fn checkFile(
    gpa: Allocator,
    io: Io,
    src_dir: Io.Dir,
    rel_path: []const u8,
    path: []const u8,
    baseline: []const BaselineEntry,
) !bool {
    assert(rel_path.len > 0);
    assert(path.len > 0);

    const source = try src_dir.readFileAlloc(io, rel_path, gpa, .limited(file_bytes_max));
    defer gpa.free(source);

    const line_violations = try checkLineLengths(gpa, path, source);
    defer gpa.free(line_violations);
    const fn_violations = try checkFunctionLengths(gpa, path, source, baseline);
    defer gpa.free(fn_violations);
    const size_bad = reportSizeViolations(io, path, line_violations, fn_violations);

    const catch_violations = try checkCatchUnreachable(gpa, path, source);
    defer gpa.free(catch_violations);
    const debug_print_violations = try checkBannedPattern(gpa, path, source, "std.debug.print");
    defer gpa.free(debug_print_violations);
    const time_violations = try checkBannedPattern(gpa, path, source, "std.time.");
    defer gpa.free(time_violations);
    // ADR-002: `std.Io` is only banned inside the five core-purity files, so the check itself
    // (and the allocation it makes) is conditional. `checkBannedPattern` always allocates via
    // `toOwnedSlice`, even for zero violations, so the exempt-file branch uses a compile-time
    // empty slice instead of calling it — and the matching `gpa.free` below is gated on the
    // same `is_core_purity_file` so it never frees a slice `gpa` did not allocate.
    const is_core_purity_file = isCorePurityFile(path);
    const io_purity_violations = if (is_core_purity_file)
        try checkBannedPattern(gpa, path, source, "std.Io")
    else
        &[_]BannedPatternViolation{};
    defer if (is_core_purity_file) gpa.free(io_purity_violations);
    if (!is_core_purity_file) assert(io_purity_violations.len == 0);

    const wire_violations = try checkWireUsize(gpa, path, source);
    defer gpa.free(wire_violations);
    const missing_header = !hasModuleHeader(source);
    const ban_bad = reportBanViolations(
        io,
        path,
        catch_violations,
        debug_print_violations,
        time_violations,
        io_purity_violations,
        wire_violations,
        missing_header,
    );

    return size_bad or ban_bad;
}

/// Checks `build.zig` for a `//!` module header only (its size was already fixed by plan 001
/// item 2). Returns whether it is missing one.
fn checkBuildZigHeader(gpa: Allocator, io: Io) !bool {
    const source = try Io.Dir.cwd().readFileAlloc(io, "build.zig", gpa, .limited(file_bytes_max));
    defer gpa.free(source);

    if (hasModuleHeader(source)) return false;
    const msg = "build.zig: missing a //! module header on line 1\n";
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return true;
}

/// Walks `src/` for `*.zig` files, checks each against `line_length_max`,
/// `function_lines_max` (excused by `tools/tidy_baseline.txt` where present), and the
/// semantic ban list (catch unreachable, std.debug.print, std.time.*, std.Io in core-purity
/// files, usize in wire structs, missing `//!` headers); also checks `build.zig`'s header.
/// Prints violations to stderr and exits non-zero if any file had one.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const baseline_text = try readOptionalFile(gpa, io, Io.Dir.cwd(), "tools/tidy_baseline.txt");
    defer gpa.free(baseline_text);

    const baseline = try parseBaseline(gpa, baseline_text);
    defer gpa.free(baseline);

    var src_dir = try Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    var had_violation = try checkBuildZigHeader(gpa, io);
    var files_seen: u32 = 0;
    while (try walker.next(io)) |entry| {
        assert(files_seen <= files_max);
        files_seen += 1;
        if (files_seen == files_max) return error.TooManyFiles;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);

        if (try checkFile(gpa, io, src_dir, entry.path, path, baseline)) had_violation = true;
    }

    if (had_violation) std.process.exit(1);
}

test {
    _ = @import("tidy_test.zig");
}
