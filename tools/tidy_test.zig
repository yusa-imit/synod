//! Test suite for tools/tidy.zig, split out to keep tidy.zig itself under the 800-line size
//! floor it enforces on everything else. Pulled into the `zig build test` graph via the
//! `test { _ = @import("tidy_test.zig"); }` block at the end of tidy.zig — Zig collects test
//! declarations from every file reachable through an `@import`, so no build.zig change is
//! needed. Exercises only `tidy`'s `pub` surface; no file I/O happens here.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const tidy = @import("tidy.zig");

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
    const violations = try tidy.checkLineLengths(testing.allocator, "src/empty.zig", "");
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths returns empty slice when every line fits the limit" {
    const source = "const x = 1;\nconst y = 2;\n";
    const violations = try tidy.checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths treats an exactly-100-column line as not a violation" {
    const line = "a" ** 100;
    const source = line ++ "\n";
    const violations = try tidy.checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkLineLengths flags an exactly-101-column line with correct line and length" {
    const line = "a" ** 101;
    const source = "short\n" ++ line ++ "\n";
    const violations = try tidy.checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqual(@as(u32, 101), violations[0].length);
    try testing.expectEqualStrings("src/example.zig", violations[0].path);
}

test "tidy: checkLineLengths flags only the offending line among several short ones" {
    const long_line = "b" ** 150;
    const source = "ok\n" ++ long_line ++ "\nok again\n";
    const violations = try tidy.checkLineLengths(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqual(@as(u32, 150), violations[0].length);
}

test "tidy: checkLineLengths flags a too-long final line even with no trailing newline" {
    const long_line = "c" ** 120;
    const violations = try tidy.checkLineLengths(testing.allocator, "src/example.zig", long_line);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
    try testing.expectEqual(@as(u32, 120), violations[0].length);
}

// -- parseBaseline -----------------------------------------------------------------------

test "tidy: parseBaseline returns empty slice for empty input" {
    const entries = try tidy.parseBaseline(testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "tidy: parseBaseline returns empty slice when input is only blank lines" {
    const entries = try tidy.parseBaseline(testing.allocator, "\n\n\n");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "tidy: parseBaseline parses a single path:function:lines entry" {
    const entries = try tidy.parseBaseline(testing.allocator, "src/raft.zig:step:71\n");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("src/raft.zig", entries[0].path);
    try testing.expectEqualStrings("step", entries[0].name);
    try testing.expectEqual(@as(u32, 71), entries[0].lines_max);
}

test "tidy: parseBaseline skips blank lines interleaved between entries" {
    const text = "src/a.zig:f:71\n\nsrc/b.zig:g:80\n\n";
    const entries = try tidy.parseBaseline(testing.allocator, text);
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
        tidy.parseBaseline(testing.allocator, "not_a_valid_baseline_line"),
    );
}

test "tidy: parseBaseline rejects a non-numeric lines field" {
    try testing.expectError(
        error.InvalidBaseline,
        tidy.parseBaseline(testing.allocator, "src/a.zig:f:seventy"),
    );
}

test "tidy: parseBaseline rejects a line with an extra colon-delimited field" {
    try testing.expectError(
        error.InvalidBaseline,
        tidy.parseBaseline(testing.allocator, "src/a.zig:f:71:extra"),
    );
}

// -- checkFunctionLengths ------------------------------------------------------------------

test "tidy: checkFunctionLengths accepts a single-line-body function" {
    const source = "fn f() void {}\n";
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkFunctionLengths accepts a function at exactly the 70-line limit" {
    const source = comptime comptimeFunctionSource("at_limit", 70);
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkFunctionLengths flags a 71-line function with no baseline entry" {
    const source = comptime comptimeFunctionSource("over_by_one", 71);
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
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
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("red_zone_unlisted", violations[0].name);
    try testing.expectEqual(@as(u32, 72), violations[0].lines);
}

test "tidy: checkFunctionLengths flags a 73-line function with no baseline entry" {
    const source = comptime comptimeFunctionSource("well_over", 73);
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("well_over", violations[0].name);
    try testing.expectEqual(@as(u32, 73), violations[0].lines);
}

test "tidy: checkFunctionLengths accepts a 71-line function with a covering baseline entry" {
    const source = comptime comptimeFunctionSource("covered", 71);
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .name = "covered", .lines_max = 71 },
    };
    const violations = try tidy.checkFunctionLengths(
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
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .name = "under_covered", .lines_max = 71 },
    };
    const violations = try tidy.checkFunctionLengths(
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
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .name = "over_cap", .lines_max = 1000 },
    };
    const violations = try tidy.checkFunctionLengths(
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
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/other.zig", .name = "unmatched_path", .lines_max = 80 },
    };
    const violations = try tidy.checkFunctionLengths(
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
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .name = "some_other_fn", .lines_max = 80 },
    };
    const violations = try tidy.checkFunctionLengths(
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
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("nested_over_limit", violations[0].name);
    try testing.expectEqual(@as(u32, 71), violations[0].lines);
}

test "tidy: checkFunctionLengths reports the correct name and line_start among two functions" {
    const long_source = comptime comptimeFunctionSource("second_long", 71);
    const source = "fn first_short() void {}\n\n" ++ long_source;
    const violations = try tidy.checkFunctionLengths(
        testing.allocator,
        "src/example.zig",
        source,
        &[_]tidy.BaselineEntry{},
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
    const violations = try tidy.checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
}

test "tidy: checkCatchUnreachable accepts a proof comment on the same line" {
    const source = "const x = f() catch unreachable; // proof: f never fails here\n";
    const violations = try tidy.checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkCatchUnreachable accepts a proof comment on the previous line" {
    const source = "// proof: f never fails here\nconst x = f() catch unreachable;\n";
    const violations = try tidy.checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: checkCatchUnreachable rejects a proof comment two lines before" {
    const source = "// proof: f never fails here\n\nconst x = f() catch unreachable;\n";
    const violations = try tidy.checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 3), violations[0].line);
}

test "tidy: checkCatchUnreachable flags each offending line independently" {
    const source = "a() catch unreachable;\nb() catch unreachable; // proof: b is total\n";
    const violations = try tidy.checkCatchUnreachable(testing.allocator, "src/example.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].line);
}

// -- checkBannedPattern ---------------------------------------------------------------------

test "tidy: checkBannedPattern flags std.debug.print" {
    const source = "std.debug.print(\"x\", .{});\n";
    const violations = try tidy.checkBannedPattern(
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
    const violations = try tidy.checkBannedPattern(
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
    const violations = try tidy.checkBannedPattern(
        testing.allocator,
        "src/example.zig",
        source,
        "std.debug.print",
    );
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// -- std.Io core purity (ADR-002) -----------------------------------------------------------
//
// `docs/adr/0002-io-at-the-boundary.md` bans the substring `std.Io` in exactly five
// core-purity files, not across all of `src/` the way `std.debug.print`/`std.time.` are
// banned uniformly by `checkFile()`. This is a *file-scoped* check, following the
// `wire_struct_names` precedent (a comptime list consulted by a check function) rather than a
// bare `checkBannedPattern` call applied to every file — see `core_purity_files` and
// `isCorePurityFile` above, and their wiring into `checkFile()`'s `io_purity_violations`.

test "tidy: isCorePurityFile is true for exactly the five ADR-002 core-purity files" {
    const core_files = [_][]const u8{
        "src/raft.zig",
        "src/membership.zig",
        "src/detector.zig",
        "src/clock.zig",
        "src/log.zig",
    };
    try testing.expectEqual(@as(usize, 5), tidy.core_purity_files.len);
    for (core_files) |path| {
        try testing.expect(tidy.isCorePurityFile(path));
    }
}

test "tidy: isCorePurityFile excludes the std.Io-boundary files main/bench/driver/adapters" {
    try testing.expect(!tidy.isCorePurityFile("src/main.zig"));
    try testing.expect(!tidy.isCorePurityFile("bench/main.zig"));
    try testing.expect(!tidy.isCorePurityFile("src/driver.zig"));
    try testing.expect(!tidy.isCorePurityFile("src/adapters.zig"));
}

test "tidy: isCorePurityFile rejects a path that merely ends with a core-purity file name" {
    // Whole-path match only — a nested or differently-rooted path must not false-positive.
    try testing.expect(!tidy.isCorePurityFile("src/sub/raft.zig"));
    try testing.expect(!tidy.isCorePurityFile("raft.zig"));
}

test "tidy: checkBannedPattern flags std.Io in a src/raft.zig-shaped fixture" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn step(io: std.Io) void {
        \\    _ = io;
        \\}
        \\
    ;
    const violations = try tidy.checkBannedPattern(testing.allocator, "src/raft.zig", source, "std.Io");
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u32, 3), violations[0].line);
    try testing.expectEqualStrings("std.Io", violations[0].pattern);
}

test "tidy: checkBannedPattern flags std.Io in each ADR-002 core-purity file" {
    const core_files = [_][]const u8{
        "src/raft.zig",
        "src/membership.zig",
        "src/detector.zig",
        "src/clock.zig",
        "src/log.zig",
    };
    const source = "const x = std.Io.Dir.cwd();\n";
    for (core_files) |path| {
        try testing.expect(tidy.isCorePurityFile(path));
        const violations = try tidy.checkBannedPattern(testing.allocator, path, source, "std.Io");
        defer testing.allocator.free(violations);
        try testing.expectEqual(@as(usize, 1), violations.len);
        try testing.expectEqualStrings(path, violations[0].path);
        try testing.expectEqualStrings("std.Io", violations[0].pattern);
    }
}

test "tidy: checkBannedPattern returns zero std.Io violations for a core-purity file with none" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn step(clock: Clock) void {
        \\    _ = clock;
        \\}
        \\
    ;
    const violations = try tidy.checkBannedPattern(testing.allocator, "src/raft.zig", source, "std.Io");
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tidy: a std.Io-boundary file like src/driver.zig is excluded despite containing std.Io" {
    // The key file-scoping behavior: the same substring that gets flagged in src/raft.zig
    // must NOT cause src/driver.zig to be treated as a core-purity file.
    const path = "src/driver.zig";
    try testing.expect(!tidy.isCorePurityFile(path));

    // Sanity: the substring really is present, so a non-scoped check (checkBannedPattern
    // called unconditionally, as std.debug.print/std.time. are) would have flagged it.
    const source = "pub fn run(io: std.Io) void {\n    _ = io;\n}\n";
    const unscoped = try tidy.checkBannedPattern(testing.allocator, path, source, "std.Io");
    defer testing.allocator.free(unscoped);
    try testing.expectEqual(@as(usize, 1), unscoped.len);
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
    const violations = try tidy.checkWireUsize(testing.allocator, "src/types.zig", source);
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
    const violations = try tidy.checkWireUsize(testing.allocator, "src/types.zig", source);
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
    const violations = try tidy.checkWireUsize(testing.allocator, "src/types.zig", source);
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
    const violations = try tidy.checkWireUsize(testing.allocator, "src/types.zig", source);
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
    const violations = try tidy.checkWireUsize(testing.allocator, "src/types.zig", source);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// -- hasModuleHeader -------------------------------------------------------------------------

test "tidy: hasModuleHeader accepts a file starting with //!" {
    try testing.expect(tidy.hasModuleHeader("//! module doc\nconst x = 1;\n"));
}

test "tidy: hasModuleHeader rejects a file with no header" {
    try testing.expect(!tidy.hasModuleHeader("const x = 1;\n"));
}

test "tidy: hasModuleHeader rejects a file whose first line is a regular comment" {
    try testing.expect(!tidy.hasModuleHeader("// not a module header\nconst x = 1;\n"));
}

test "tidy: hasModuleHeader rejects an empty file" {
    try testing.expect(!tidy.hasModuleHeader(""));
}
