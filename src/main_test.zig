//! Tests for the CLI and the analysis pipeline it drives.
//!
//! They live in their own file so `main.zig` holds only the implementation —
//! `max_file_lines` is meant to bound the code you read, not the tests that
//! read it — and because driving the pipeline needs access to its internal
//! steps (`runAnalysis`, `evaluateCheck`, …) rather than a process boundary.
//! `build.zig` roots the `main` test artifact at this file, so the dependency
//! is one way: tests → implementation, never the reverse.

const std = @import("std");
const main = @import("main.zig");
const core = @import("core");
const metrics = @import("metrics");
const analysis = @import("analysis");

test "analysis pipeline runs against a temporary project" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\const helper = @import("helper.zig");
        \\pub fn main() void {
        \\    helper();
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/helper.zig",
        .data =
        \\pub fn helper() void {}
        ,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const result = try main.runAnalysis(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(u32, 2), result.report.file_count);
    try std.testing.expectEqual(@as(usize, 1), result.import_edges.len);
    try std.testing.expectEqual(@as(u32, 2), result.report.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.report.dead_functions);
}

test "oversized and non-parseable files are skipped, not fatal" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/small.zig", .data = "pub fn small() void {}\n" });

    // Larger than the 100 KiB parse limit, smaller than the walker's 512 KiB
    // file limit: the file is walked, counted and then skipped for parsing.
    const big_line = "pub fn big() void {}\n";
    var big = try std.testing.allocator.alloc(u8, 101 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..big_line.len], big_line);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/big.zig", .data = big });

    // Larger than the walker's 512 KiB file limit: the file never becomes a
    // node, is not line-counted and never reaches the parser.
    var huge = try std.testing.allocator.alloc(u8, 600 * 1024);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    @memcpy(huge[0..big_line.len], big_line);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/huge.zig", .data = huge });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const result = try main.runAnalysis(arena.allocator(), io, project_path);

    // Both oversized files are absent from the graph and from `file_count`; each
    // is reported with the limit it hit instead of aborting the run.
    try std.testing.expectEqual(@as(u32, 1), result.report.file_count);
    try std.testing.expectEqual(@as(u32, 1), result.report.total_functions);
    try std.testing.expectEqual(@as(usize, 2), result.skipped_files.len);
    try std.testing.expectEqualStrings("parse_too_large", skipReasonIn(result.skipped_files, "src/big.zig") orelse "missing");
    try std.testing.expectEqualStrings("file_too_large", skipReasonIn(result.skipped_files, "src/huge.zig") orelse "missing");
}

/// Look up the reason a path was skipped in the analysis result. Returns null
/// when the path is absent, so a missing entry fails the assertion as
/// "missing" instead of needing a print to explain what went wrong.
fn skipReasonIn(skipped: []const analysis.walker.SkippedFile, path: []const u8) ?[]const u8 {
    for (skipped) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.reason;
    }
    return null;
}

test "temporary project supports check and gate evaluation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 0.0\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const check = try main.evaluateCheck(arena.allocator(), io, project_path);
    try std.testing.expect(check.check.pass());
    const saved = try main.saveGate(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(u32, 1), saved.report.file_count);
    const compared = try main.compareGate(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(usize, 0), compared.violations.len);
}

test "temporary invalid rules are rejected before output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 2.0\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectError(error.InvalidRules, main.evaluateCheck(arena.allocator(), io, project_path));
}

test "temporary command helpers return typed setup errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectError(error.NoRulesFile, main.evaluateCheck(arena.allocator(), io, project_path));
    try std.testing.expectError(error.NoBaseline, main.compareGate(arena.allocator(), io, project_path));
}

test "filter source paths excludes non-source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all_paths = [_][]const u8{
        "src/main.zig",
        "README.md",
        "src/app.py",
        "package.json",
        "src/types.ts",
    };
    const source_paths = try main.filterSourcePaths(arena.allocator(), &all_paths);
    try std.testing.expectEqual(@as(usize, 3), source_paths.len);
    try std.testing.expectEqualStrings("src/main.zig", source_paths[0]);
    try std.testing.expectEqualStrings("src/app.py", source_paths[1]);
    try std.testing.expectEqualStrings("src/types.ts", source_paths[2]);
}

test "json error envelope has stable fields" {
    const payload = main.JsonError{
        .schema_version = main.json_schema_version,
        .tool_version = main.tool_version,
        .ok = false,
        .error_info = .{
            .code = "InvalidRules",
            .category = "configuration",
            .message = "InvalidRules",
        },
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"category\":\"configuration\"") != null);
}

test "hotspots are sorted by complexity score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const funcs = [_]core.types.FuncInfo{
        .{
            .name = "low",
            .start_line = 1,
            .end_line = 2,
            .line_count = 2,
            .cyclomatic_complexity = 2,
            .cognitive_complexity = 2,
        },
        .{
            .name = "high",
            .start_line = 1,
            .end_line = 20,
            .line_count = 20,
            .cyclomatic_complexity = 20,
            .cognitive_complexity = 30,
        },
    };
    const files = [_]metrics.dead_code.FileFuncs{
        .{ .file = "src/lib.zig", .contents = "", .funcs = &funcs },
    };
    const hotspots = try main.collectHotspots(arena.allocator(), &files);
    try std.testing.expectEqual(@as(usize, 2), hotspots.len);
    try std.testing.expectEqualStrings("high", hotspots[0].name);
    try std.testing.expectEqualStrings("low", hotspots[1].name);
}

test "depth path maps solver nodes to source paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/util.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/main.zig", .to_file = "src/lib.zig" },
        .{ .from_file = "src/lib.zig", .to_file = "src/util.zig" },
    };
    const path = try main.buildDepthPath(arena.allocator(), &paths, &edges);
    try std.testing.expectEqualSlices([]const u8, &paths, path);
}

test "json payloads expose root and units" {
    try std.testing.expectEqualStrings("0-10000", main.jsonUnits().quality_signal);
    try std.testing.expectEqualStrings("lines", main.jsonUnits().line_counts);
    try std.testing.expectEqualStrings("edges", main.jsonUnits().edge_counts);
    try std.testing.expect(main.hasJsonFlag(&[_][]const u8{ "path", "--json" }));
    try std.testing.expect(!main.hasJsonFlag(&[_][]const u8{ "--", "--json" }));
    try std.testing.expectEqualStrings("usage", main.errorCategory("UnknownFlag"));
    try std.testing.expectEqualStrings("baseline", main.errorCategory("NoBaseline"));
}

test "parse options accepts flags and path" {
    const args = [_][]const u8{ "--json", "project" };
    const options = try main.parseOptions("scan", &args);
    try std.testing.expectEqualStrings("project", options.path);
    try std.testing.expect(options.json);
    try std.testing.expect(!options.save);
}

test "parse options supports escaped path" {
    const args = [_][]const u8{ "--", "-project" };
    const options = try main.parseOptions("scan", &args);
    try std.testing.expectEqualStrings("-project", options.path);
}

test "parse options rejects invalid combinations" {
    const unknown = [_][]const u8{"--bogus"};
    try std.testing.expectError(error.UnknownFlag, main.parseOptions("scan", &unknown));

    const extra = [_][]const u8{ "one", "two" };
    try std.testing.expectError(error.ExtraArgument, main.parseOptions("scan", &extra));

    const duplicate = [_][]const u8{ "--json", "--json" };
    try std.testing.expectError(error.DuplicateFlag, main.parseOptions("scan", &duplicate));

    const invalid_save = [_][]const u8{"--save"};
    try std.testing.expectError(error.InvalidFlag, main.parseOptions("scan", &invalid_save));
}

test "complexity ceilings fail the check and name the offending function" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);

    // Two functions over the ceiling and one under it, so the check has to
    // separate offenders from compliant code rather than flag the file.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/lib.zig",
        .data =
        \\fn simple() u32 {
        \\    return 1;
        \\}
        \\fn busy(flag: bool) u32 {
        \\    if (flag) {
        \\        if (!flag) {
        \\            while (flag) {
        \\                if (flag and !flag) {
        \\                    for (0..3) |i| {
        \\                        if (i == 1) {
        \\                            if (i != 2) {
        \\                                return i;
        \\                            }
        \\                        }
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return 0;
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 0.0\nmax_cyclomatic = 2\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const execution = try main.evaluateCheck(arena.allocator(), io, project_path);
    const check = execution.check;

    try std.testing.expect(!check.pass());
    try std.testing.expectEqual(@as(u32, 2), check.rules_checked);
    try std.testing.expectEqual(@as(usize, 1), check.violations.len);
    const violation = check.violations[0];
    try std.testing.expectEqualStrings("max_cyclomatic", violation.rule);
    try std.testing.expectEqualStrings("busy", violation.subject.?);
    try std.testing.expectEqual(@as(u32, 4), violation.line.?);
    try std.testing.expectEqual(@as(usize, 1), violation.files.len);
    try std.testing.expectEqualStrings("src/lib.zig", violation.files[0]);
    // The message has to stand on its own in a terminal.
    try std.testing.expect(std.mem.indexOf(u8, violation.message, "src/lib.zig:4: busy") != null);
    try std.testing.expect(std.mem.indexOf(u8, violation.message, "cyclomatic complexity") != null);
}

test "complexity violations carry subject and line into the json payload" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/lib.zig",
        .data =
        \\fn busy(flag: bool) u32 {
        \\    if (flag) {
        \\        if (!flag) {
        \\            return 0;
        \\        }
        \\    }
        \\    return 1;
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 0.0\nmax_cyclomatic = 2\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const execution = try main.evaluateCheck(arena.allocator(), io, project_path);
    const violations = try arena.allocator().alloc(main.JsonViolation, execution.check.violations.len);
    for (execution.check.violations, 0..) |violation, index| {
        violations[index] = .{
            .rule = violation.rule,
            .severity = violation.severity.label(),
            .message = violation.message,
            .from = if (violation.files.len >= 1) violation.files[0] else null,
            .to = if (violation.files.len >= 2) violation.files[1] else null,
            .subject = violation.subject,
            .line = violation.line,
        };
    }
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    // A single-file violation must still report `from`: that used to require
    // two files and silently produced null.
    try std.testing.expectEqualStrings("src/lib.zig", violations[0].from.?);
    try std.testing.expectEqual(@as(?[]const u8, null), violations[0].to);
    try std.testing.expectEqualStrings("busy", violations[0].subject.?);
    try std.testing.expectEqual(@as(?u32, 1), violations[0].line);
}
