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
//! ban list (`catch unreachable` without `// proof:`, `std.debug.print`, `std.time.*`, `usize`
//! in a wire struct, a missing `//!` header), loading `tools/tidy_baseline.txt` when present,
//! also checks `build.zig`'s header, prints violations to stderr, and exits non-zero if any
//! file had one.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

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
        const trimmed = std.mem.trimLeft(u8, line, " \t");
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

        const after_name = std.mem.trimLeft(u8, source[at + name.len ..], " \t\r\n");
        if (!std.mem.startsWith(u8, after_name, "=")) continue;
        const after_eq = std.mem.trimLeft(u8, after_name[1..], " \t\r\n");
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
    assert(!has_header or first_line.len >= 3);
    return has_header;
}

/// Reads `sub_path` under `dir` and returns its contents, or an empty slice if the file does
/// not exist. Precondition: `gpa` outlives the returned slice; the caller frees it.
fn readOptionalFile(gpa: Allocator, dir: std.fs.Dir, sub_path: []const u8) ![]u8 {
    assert(sub_path.len > 0);

    const contents = dir.readFileAlloc(gpa, sub_path, file_bytes_max) catch |err| switch (err) {
        error.FileNotFound => return try gpa.alloc(u8, 0),
        else => return err,
    };

    assert(contents.len <= file_bytes_max);
    return contents;
}

/// Prints every size violation (line-length, function-length) to stderr. Returns whether any
/// was printed.
fn reportSizeViolations(
    path: []const u8,
    line_violations: []const LineViolation,
    fn_violations: []const FunctionViolation,
) bool {
    assert(path.len > 0);

    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    for (line_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: line too long ({d} > {d})\n", .{
            v.path, v.line, v.length, line_length_max,
        }) catch continue;
        stderr.writeAll(msg) catch {};
    }
    for (fn_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: fn {s} too long ({d} > {d})\n", .{
            v.path, v.line_start, v.name, v.lines, function_lines_max,
        }) catch continue;
        stderr.writeAll(msg) catch {};
    }

    return line_violations.len > 0 or fn_violations.len > 0;
}

/// Prints every ban-list violation (catch unreachable, banned pattern, wire usize, missing
/// module header) to stderr. Returns whether any was printed.
fn reportBanViolations(
    path: []const u8,
    catch_violations: []const CatchUnreachableViolation,
    debug_print_violations: []const BannedPatternViolation,
    time_violations: []const BannedPatternViolation,
    wire_violations: []const WireUsizeViolation,
    missing_header: bool,
) bool {
    assert(path.len > 0);

    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    for (catch_violations) |v| {
        const msg = std.fmt.bufPrint(
            &buf,
            "{s}:{d}: catch unreachable without a // proof: comment\n",
            .{ v.path, v.line },
        ) catch continue;
        stderr.writeAll(msg) catch {};
    }
    for ([_][]const BannedPatternViolation{ debug_print_violations, time_violations }) |group| {
        for (group) |v| {
            const msg = std.fmt.bufPrint(&buf, "{s}:{d}: banned pattern {s} in src/\n", .{
                v.path, v.line, v.pattern,
            }) catch continue;
            stderr.writeAll(msg) catch {};
        }
    }
    for (wire_violations) |v| {
        const msg = std.fmt.bufPrint(&buf, "{s}:{d}: usize field in wire struct {s}\n", .{
            v.path, v.line, v.type_name,
        }) catch continue;
        stderr.writeAll(msg) catch {};
    }
    if (missing_header) {
        const msg = std.fmt.bufPrint(&buf, "{s}: missing a //! module header on line 1\n", .{
            path,
        }) catch "";
        stderr.writeAll(msg) catch {};
    }

    return catch_violations.len > 0 or debug_print_violations.len > 0 or
        time_violations.len > 0 or wire_violations.len > 0 or missing_header;
}

/// Checks one file under `src_dir` and reports its violations. Returns whether it had any.
fn checkFile(
    gpa: Allocator,
    src_dir: std.fs.Dir,
    rel_path: []const u8,
    path: []const u8,
    baseline: []const BaselineEntry,
) !bool {
    assert(rel_path.len > 0);
    assert(path.len > 0);

    const source = try src_dir.readFileAlloc(gpa, rel_path, file_bytes_max);
    defer gpa.free(source);

    const line_violations = try checkLineLengths(gpa, path, source);
    defer gpa.free(line_violations);
    const fn_violations = try checkFunctionLengths(gpa, path, source, baseline);
    defer gpa.free(fn_violations);
    const size_bad = reportSizeViolations(path, line_violations, fn_violations);

    const catch_violations = try checkCatchUnreachable(gpa, path, source);
    defer gpa.free(catch_violations);
    const debug_print_violations = try checkBannedPattern(gpa, path, source, "std.debug.print");
    defer gpa.free(debug_print_violations);
    const time_violations = try checkBannedPattern(gpa, path, source, "std.time.");
    defer gpa.free(time_violations);
    const wire_violations = try checkWireUsize(gpa, path, source);
    defer gpa.free(wire_violations);
    const missing_header = !hasModuleHeader(source);
    const ban_bad = reportBanViolations(
        path,
        catch_violations,
        debug_print_violations,
        time_violations,
        wire_violations,
        missing_header,
    );

    return size_bad or ban_bad;
}

/// Checks `build.zig` for a `//!` module header only (its size was already fixed by plan 001
/// item 2). Returns whether it is missing one.
fn checkBuildZigHeader(gpa: Allocator) !bool {
    const source = try std.fs.cwd().readFileAlloc(gpa, "build.zig", file_bytes_max);
    defer gpa.free(source);

    if (hasModuleHeader(source)) return false;
    std.fs.File.stderr().writeAll("build.zig: missing a //! module header on line 1\n") catch {};
    return true;
}

/// Walks `src/` for `*.zig` files, checks each against `line_length_max`,
/// `function_lines_max` (excused by `tools/tidy_baseline.txt` where present), and the
/// semantic ban list (catch unreachable, std.debug.print, std.time.*, usize in wire structs,
/// missing `//!` headers); also checks `build.zig`'s header. Prints violations to stderr and
/// exits non-zero if any file had one.
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const baseline_text = try readOptionalFile(gpa, std.fs.cwd(), "tools/tidy_baseline.txt");
    defer gpa.free(baseline_text);

    const baseline = try parseBaseline(gpa, baseline_text);
    defer gpa.free(baseline);

    var src_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    var had_violation = try checkBuildZigHeader(gpa);
    var files_seen: u32 = 0;
    while (try walker.next()) |entry| {
        assert(files_seen <= files_max);
        files_seen += 1;
        if (files_seen == files_max) return error.TooManyFiles;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);

        if (try checkFile(gpa, src_dir, entry.path, path, baseline)) had_violation = true;
    }

    if (had_violation) std.process.exit(1);
}

/// Test fixture only: builds, at comptime, the source of a `total_lines`-line function named
/// `name` (declaration line, `total_lines - 2` filler statement lines, closing brace line).
fn comptimeFunctionSource(comptime name: []const u8, comptime total_lines: u32) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        assert(total_lines >= 2);
        var src: []const u8 = "pub fn " ++ name ++ "() void {\n";
        var i: u32 = 0;
        while (i < total_lines - 2) : (i += 1) {
            src = src ++ "    _ = 0;\n";
        }
        src = src ++ "}\n";
        assert(std.mem.count(u8, src, "\n") == total_lines);
        return src;
    }
}

/// Test fixture only: builds, at comptime, a function containing one nested `if` block, so
/// that a naive "stop at the first closing brace" scanner disagrees with a correct
/// brace-depth scanner about where the function ends.
fn comptimeNestedFunctionSource(
    comptime name: []const u8,
    comptime inner_filler_lines: u32,
    comptime outer_filler_lines: u32,
) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var src: []const u8 = "pub fn " ++ name ++ "() void {\n";
        src = src ++ "    if (true) {\n";
        var i: u32 = 0;
        while (i < inner_filler_lines) : (i += 1) src = src ++ "        _ = 0;\n";
        src = src ++ "    }\n";
        i = 0;
        while (i < outer_filler_lines) : (i += 1) src = src ++ "    _ = 0;\n";
        src = src ++ "}\n";
        return src;
    }
}

// -- checkLineLengths ------------------------------------------------------------------

test "tidy: checkLineLengths returns empty slice for an empty source" {
    const violations = try checkLineLengths(testing.allocator, "src/empty.zig", "");
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths returns empty slice when every line fits the limit" {
    const source = "const x = 1;\nconst y = 2;\n";
    const violations = try checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths treats an exactly-100-column line as not a violation" {
    const line = "a" ** 100;
    const source = line ++ "\n";
    const violations = try checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths flags an exactly-101-column line with correct line and length" {
    const line = "a" ** 101;
    const source = "short\n" ++ line ++ "\n";
    const violations = try checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqual(@as(u32, 101), violations[0].length);
    try testing.expectEqualStrings("src/example.zig", violations[0].path);
}

test "tidy: checkLineLengths flags only the offending line among several short ones" {
    const long_line = "b" ** 150;
    const source = "ok\n" ++ long_line ++ "\nok again\n";
    const violations = try checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqual(@as(u32, 150), violations[0].length);
}

test "tidy: checkLineLengths flags a too-long final line even with no trailing newline" {
    const long_line = "c" ** 120;
    const violations = try checkLineLengths(testing.allocator, "src/example.zig", long_line);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
    try testing.expectEqual(@as(u32, 120), violations[0].length);
}

// -- parseBaseline -----------------------------------------------------------------------

test "tidy: parseBaseline returns empty slice for empty input" {
    const entries = try parseBaseline(testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "tidy: parseBaseline returns empty slice when input is only blank lines" {
    const entries = try parseBaseline(testing.allocator, "\n\n\n");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "tidy: parseBaseline parses a single path:function:lines entry" {
    const entries = try parseBaseline(testing.allocator, "src/raft.zig:step:71\n");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("src/raft.zig", entries[0].path);
    try testing.expectEqualStrings("step", entries[0].name);
    try testing.expectEqual(@as(u32, 71), entries[0].lines_max);
}

test "tidy: parseBaseline skips blank lines interleaved between entries" {
    const text = "src/a.zig:f:71\n\nsrc/b.zig:g:80\n\n";
    const entries = try parseBaseline(testing.allocator, text);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("f", entries[0].name);
    try testing.expectEqualStrings("g", entries[1].name);
    try testing.expectEqual(@as(u32, 71), entries[0].lines_max);
    try testing.expectEqual(@as(u32, 80), entries[1].lines_max);
}

test "tidy: parseBaseline rejects a line missing the colon separator" {
    try testing.expectError(
        error.InvalidBaseline,
        parseBaseline(testing.allocator, "not_a_valid_baseline_line"),
    );
}

test "tidy: parseBaseline rejects a non-numeric lines field" {
    try testing.expectError(
        error.InvalidBaseline,
        parseBaseline(testing.allocator, "src/a.zig:f:seventy"),
    );
}

test "tidy: parseBaseline rejects a line with an extra colon-delimited field" {
    try testing.expectError(
        error.InvalidBaseline,
        parseBaseline(testing.allocator, "src/a.zig:f:71:extra"),
    );
}

// -- checkFunctionLengths ------------------------------------------------------------------

test "tidy: checkFunctionLengths accepts a single-line-body function" {
    const source = "fn f() void {}\n";
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkFunctionLengths accepts a function at exactly the 70-line limit" {
    const source = comptime comptimeFunctionSource("at_limit", 70);
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkFunctionLengths flags a 71-line function with no baseline entry" {
    const source = comptime comptimeFunctionSource("over_by_one", 71);
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("over_by_one", violations[0].name);
    try testing.expectEqual(@as(u32, 1), violations[0].line_start);
    try testing.expectEqual(@as(u32, 71), violations[0].lines);
}

test "tidy: checkFunctionLengths flags a 72-line function with no baseline entry" {
    // Off-by-one guard: only a *baseline-listed* function gets the 71-72 red zone
    // allowance. An unlisted function must still be flagged at 72, not just at 73+.
    const source = comptime comptimeFunctionSource("red_zone_unlisted", 72);
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("red_zone_unlisted", violations[0].name);
    try testing.expectEqual(@as(u32, 72), violations[0].lines);
}

test "tidy: checkFunctionLengths flags a 73-line function with no baseline entry" {
    const source = comptime comptimeFunctionSource("well_over", 73);
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("well_over", violations[0].name);
    try testing.expectEqual(@as(u32, 73), violations[0].lines);
}

test "tidy: checkFunctionLengths accepts a 71-line function with a covering baseline entry" {
    const source = comptime comptimeFunctionSource("covered", 71);
    const baseline = [_]BaselineEntry{
        .{ .path = "src/example.zig", .name = "covered", .lines_max = 71 },
    };
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &baseline,
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkFunctionLengths still flags a function past what its own baseline entry allows" {
    const source = comptime comptimeFunctionSource("under_covered", 72);
    const baseline = [_]BaselineEntry{
        .{ .path = "src/example.zig", .name = "under_covered", .lines_max = 71 },
    };
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &baseline,
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 72), violations[0].lines);
}

test "tidy: checkFunctionLengths caps baseline allowance at the red zone regardless of entry" {
    // Even a baseline entry declaring lines_max far above the red zone cap (1000) may not
    // authorize more than function_lines_red_zone_max (72) lines.
    const source = comptime comptimeFunctionSource("over_cap", 73);
    const baseline = [_]BaselineEntry{
        .{ .path = "src/example.zig", .name = "over_cap", .lines_max = 1000 },
    };
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &baseline,
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 73), violations[0].lines);
}

test "tidy: checkFunctionLengths ignores a baseline entry for a different path" {
    const source = comptime comptimeFunctionSource("unmatched_path", 71);
    const baseline = [_]BaselineEntry{
        .{ .path = "src/other.zig", .name = "unmatched_path", .lines_max = 80 },
    };
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &baseline,
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
}

test "tidy: checkFunctionLengths ignores a baseline entry for a different function name" {
    const source = comptime comptimeFunctionSource("unmatched_name", 71);
    const baseline = [_]BaselineEntry{
        .{ .path = "src/example.zig", .name = "some_other_fn", .lines_max = 80 },
    };
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &baseline,
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
}

test "tidy: checkFunctionLengths counts through nested braces, not just to the first '}'" {
    // A scanner that stops at the first closing brace would end this function inside the
    // `if` block (well under 70 lines) instead of at its real, 71-line closing brace.
    const source = comptime comptimeNestedFunctionSource("nested_over_limit", 30, 37);
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("nested_over_limit", violations[0].name);
    try testing.expectEqual(@as(u32, 71), violations[0].lines);
}

test "tidy: checkFunctionLengths reports the correct name and line_start among two functions" {
    const long_source = comptime comptimeFunctionSource("second_long", 71);
    const source = "fn first_short() void {}\n\n" ++ long_source;
    const violations = try checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("second_long", violations[0].name);
    try testing.expectEqual(@as(u32, 3), violations[0].line_start);
    try testing.expectEqual(@as(u32, 71), violations[0].lines);
}

// -- checkCatchUnreachable -----------------------------------------------------------------

test "tidy: checkCatchUnreachable flags a bare catch unreachable" {
    const source = "const x = f() catch unreachable;\n";
    const violations = try checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
}

test "tidy: checkCatchUnreachable accepts a proof comment on the same line" {
    const source = "const x = f() catch unreachable; // proof: f never fails here\n";
    const violations = try checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkCatchUnreachable accepts a proof comment on the previous line" {
    const source = "// proof: f never fails here\nconst x = f() catch unreachable;\n";
    const violations = try checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkCatchUnreachable rejects a proof comment two lines before" {
    const source = "// proof: f never fails here\n\nconst x = f() catch unreachable;\n";
    const violations = try checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 3), violations[0].line);
}

test "tidy: checkCatchUnreachable flags each offending line independently" {
    const source = "a() catch unreachable;\nb() catch unreachable; // proof: b is total\n";
    const violations = try checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
}

// -- checkBannedPattern ---------------------------------------------------------------------

test "tidy: checkBannedPattern flags std.debug.print" {
    const source = "std.debug.print(\"x\", .{});\n";
    const violations = try checkBannedPattern(
        testing.allocator,
        "src/example.zig",
        source,
        "std.debug.print",
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
    try testing.expectEqualStrings("std.debug.print", violations[0].pattern);
}

test "tidy: checkBannedPattern flags std.time usage" {
    const source = "const now = std.time.milliTimestamp();\n";
    const violations = try checkBannedPattern(
        testing.allocator,
        "src/example.zig",
        source,
        "std.time.",
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
}

test "tidy: checkBannedPattern returns empty slice when the pattern is absent" {
    const source = "const x = 1;\nconst y = 2;\n";
    const violations = try checkBannedPattern(
        testing.allocator,
        "src/example.zig",
        source,
        "std.debug.print",
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// -- checkWireUsize --------------------------------------------------------------------------

test "tidy: checkWireUsize flags a usize field inside a wire struct" {
    const source =
        \\pub const Entry = struct {
        \\    index: usize,
        \\    term: u64,
        \\};
        \\
    ;
    const violations = try checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqualStrings("Entry", violations[0].type_name);
}

test "tidy: checkWireUsize accepts an all-u64 wire struct" {
    const source =
        \\pub const HardState = struct {
        \\    term: u64,
        \\    voted_for: u64,
        \\};
        \\
    ;
    const violations = try checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkWireUsize ignores usize fields outside the named wire structs" {
    const source =
        \\pub const Scratch = struct {
        \\    len: usize,
        \\};
        \\
    ;
    const violations = try checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkWireUsize flags a usize field inside a wire union" {
    const source =
        \\pub const Message = union(enum) {
        \\    vote: struct { count: usize },
        \\};
        \\
    ;
    const violations = try checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("Message", violations[0].type_name);
}

test "tidy: checkWireUsize does not match a name that is a substring of another identifier" {
    const source =
        \\pub const EntrySet = struct {
        \\    count: usize,
        \\};
        \\
    ;
    const violations = try checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// -- hasModuleHeader -------------------------------------------------------------------------

test "tidy: hasModuleHeader accepts a file starting with //!" {
    try testing.expect(hasModuleHeader("//! module doc\nconst x = 1;\n"));
}

test "tidy: hasModuleHeader rejects a file with no header" {
    try testing.expect(!hasModuleHeader("const x = 1;\n"));
}

test "tidy: hasModuleHeader rejects a file whose first line is a regular comment" {
    try testing.expect(!hasModuleHeader("// not a module header\nconst x = 1;\n"));
}

test "tidy: hasModuleHeader rejects an empty file" {
    try testing.expect(!hasModuleHeader(""));
}
