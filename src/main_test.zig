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

// ── Documentation ───────────────────────────────────────────────────────────
//
// Documentation rot is invisible to the compiler: a link to a renamed file, an
// anchor that no longer matches a heading, or an English/Spanish pair that
// drifted apart all fail silently. These tests run from the repository root
// (`zig build test` sets it), which is where the documents live.

const doc_files = [_][]const u8{ "README.md", "README.es.md", "TODO.md", "TODO.es.md" };

fn readDoc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, name, .{}) catch |err| {
        std.debug.print("cannot open {s} from the current directory ({s}); run the tests from the repository root\n", .{ name, @errorName(err) });
        return err;
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buffer);
    const read = try file.readPositionalAll(io, buffer, 0);
    return try allocator.realloc(buffer, read);
}

test "every relative link in the documentation resolves" {
    const allocator = std.testing.allocator;
    for (doc_files) |name| {
        const contents = try readDoc(allocator, name);
        defer allocator.free(contents);

        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, contents, cursor, "](")) |link| {
            const target_start = link + 2;
            const target_end = std.mem.indexOfScalarPos(u8, contents, target_start, ')') orelse break;
            const target = contents[target_start..target_end];
            cursor = target_end + 1;
            if (target.len == 0 or std.mem.startsWith(u8, target, "http")) continue;

            const hash = std.mem.indexOfScalar(u8, target, '#');
            const path = if (hash) |at| target[0..at] else target;
            const fragment = if (hash) |at| target[at + 1 ..] else "";

            if (path.len == 0) {
                // A pure in-page anchor has to match a heading of this document.
                // The verdict is an assertion; the print only names the offender,
                // which a bare expect() cannot do among 199 links.
                if (!hasAnchor(contents, fragment)) {
                    std.debug.print("{s} links to #{s}, which is not a heading of that file\n", .{ name, fragment });
                    try std.testing.expect(false);
                }
                continue;
            }
            // A relative path has to exist, and its fragment — if any — has to
            // match a heading of the file it points at.
            const linked = readDoc(allocator, path) catch |err| {
                std.debug.print("{s} links to {s}, which cannot be read ({s})\n", .{ name, path, @errorName(err) });
                return err;
            };
            defer allocator.free(linked);
            if (fragment.len > 0 and !hasAnchor(linked, fragment)) {
                std.debug.print("{s} links to {s}#{s}, and {s} has no such heading\n", .{ name, path, fragment, path });
                try std.testing.expect(false);
            }
        }
    }
}

test "english and spanish task lists stay in parallel" {
    const allocator = std.testing.allocator;
    const en = try readDoc(allocator, "TODO.md");
    defer allocator.free(en);
    const es = try readDoc(allocator, "TODO.es.md");
    defer allocator.free(es);

    // Same sections, same completion state, same number of tasks per section.
    var en_sections = std.ArrayList(Section).empty;
    defer en_sections.deinit(allocator);
    try collectSections(allocator, en, &en_sections);
    var es_sections = std.ArrayList(Section).empty;
    defer es_sections.deinit(allocator);
    try collectSections(allocator, es, &es_sections);

    try std.testing.expectEqual(en_sections.items.len, es_sections.items.len);
    for (en_sections.items, es_sections.items) |english, spanish| {
        try std.testing.expectEqualStrings(english.id, spanish.id);
        try std.testing.expectEqual(english.closed, spanish.closed);
        try std.testing.expectEqual(english.open, spanish.open);
    }
}

const Section = struct {
    id: []const u8,
    closed: usize,
    open: usize,
};

/// Count the tasks of each `### [x] ID — title` section. The identifier is
/// language independent (`IO-001`), so the two files can be compared by it.
fn collectSections(allocator: std.mem.Allocator, markdown: []const u8, out: *std.ArrayList(Section)) !void {
    var current: ?Section = null;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (parseSectionHeader(line)) |header| {
            if (current) |section| try out.append(allocator, section);
            current = header;
            continue;
        }
        if (current) |*section| {
            if (std.mem.startsWith(u8, line, "- [x] ")) {
                section.closed += 1;
            } else if (std.mem.startsWith(u8, line, "- [ ] ")) {
                section.open += 1;
            }
        }
    }
    if (current) |section| try out.append(allocator, section);
}

fn parseSectionHeader(line: []const u8) ?Section {
    if (!std.mem.startsWith(u8, line, "### ")) return null;
    const rest = line["### ".len..];
    // "### [x] IO-001 — Title" → "IO-001"
    const after_state = if (std.mem.startsWith(u8, rest, "[x] ")) rest["[x] ".len..] else rest["[ ] ".len..];
    const end = std.mem.indexOf(u8, after_state, " ") orelse after_state.len;
    return .{ .id = after_state[0..end], .closed = 0, .open = 0 };
}

/// GitHub's heading anchor rule, for the characters these documents use:
/// lowercase, punctuation dropped, each space turned into a dash. Note that a
/// dropped symbol between two spaces leaves *two* dashes ("P2 — tests" becomes
/// "p2--tests"), which is easy to get wrong when writing a link by hand.
fn hasAnchor(markdown: []const u8, anchor: []const u8) bool {
    var buffer: [512]u8 = undefined;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#")) continue;
        const rest = std.mem.trim(u8, std.mem.trimStart(u8, line, "#"), " \t");
        if (rest.len == 0) continue;
        if (std.mem.eql(u8, slugify(rest, &buffer), anchor)) return true;
    }
    return false;
}

/// Writes the anchor of `heading` into `out` and returns the written prefix.
/// The buffer belongs to the caller on purpose: returning a slice of a local
/// array would dangle as soon as this function returns.
fn slugify(heading: []const u8, out: []u8) []const u8 {
    const buffer = out;
    var length: usize = 0;
    var index: usize = 0;
    while (index < heading.len) {
        const width = std.unicode.utf8ByteSequenceLength(heading[index]) catch {
            index += 1;
            continue;
        };
        if (index + width > heading.len) break;
        if (length + width > buffer.len) break;
        const codepoint = std.unicode.utf8Decode(heading[index .. index + width]) catch {
            index += width;
            continue;
        };
        if (codepoint == ' ' or codepoint == '\t') {
            if (length + 1 < buffer.len) {
                buffer[length] = '-';
                length += 1;
            }
            index += width;
            continue;
        }
        if (!keepsInAnchor(codepoint)) {
            index += width;
            continue;
        }
        // Only ASCII has a case to fold here: the accented letters these
        // documents use are already lowercase, or appear lowercase in the
        // heading.
        const folded: u21 = if (codepoint < 0x80) std.ascii.toLower(@intCast(codepoint)) else codepoint;
        const written = std.unicode.utf8Encode(folded, buffer[length..]) catch break;
        length += written;
        index += width;
    }
    return buffer[0..length];
}

/// Which code points survive GitHub's slugger. ASCII letters, digits and the
/// hyphen stay; the Latin-1 letters the Spanish documents use stay, because
/// they are letters and not punctuation; typographic symbols (em dash, curly
/// quotes, arrows, ellipsis) are dropped. Zig's std has no Unicode
/// general-category lookup, so "letter" is expressed as the ranges these
/// documents actually use — which is also why a heading with, say, Greek text
/// would need this list extended.
fn keepsInAnchor(codepoint: u21) bool {
    if (codepoint < 0x80) {
        const c: u8 = @intCast(codepoint);
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
    }
    if (codepoint == 0xA1) return true; // ¡
    if (codepoint < 0xC0 or codepoint > 0xFF) return false;
    if (codepoint == 0xD7 or codepoint == 0xF7) return false; // × ÷ are not letters
    return true;
}

test "the two READMEs document the same numbers" {
    // The example output is a snapshot of a real run, and the Spanish README is
    // a translation of the English one. When one is refreshed and the other is
    // not, the documentation quietly starts lying in two languages at once.
    // Comparing every number in the two example blocks catches that without
    // hardcoding a single value here: the numbers move, the agreement does not.
    const allocator = std.testing.allocator;
    const en = try readDoc(allocator, "README.md");
    defer allocator.free(en);
    const es = try readDoc(allocator, "README.es.md");
    defer allocator.free(es);

    for ([_][]const u8{ "Quality Signal:", "\"quality_signal\":" }) |marker| {
        const english = try numberTokens(allocator, try exampleBlock(en, marker));
        defer allocator.free(english);
        const spanish = try numberTokens(allocator, try exampleBlock(es, marker));
        defer allocator.free(spanish);
        if (!std.mem.eql(u8, english, spanish)) {
            std.debug.print("example numbers differ: en [{s}] vs es [{s}]\n", .{ english, spanish });
            try std.testing.expect(false);
        }
    }
}

/// The first fenced block that contains `marker`.
fn exampleBlock(markdown: []const u8, marker: []const u8) ![]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, markdown, cursor, "```")) |open| {
        const body_start = open + 3;
        const close = std.mem.indexOfPos(u8, markdown, body_start, "```") orelse break;
        const body = markdown[body_start..close];
        if (std.mem.indexOf(u8, body, marker) != null) return body;
        cursor = close + 3;
    }
    std.debug.print("no fenced example block contains {s}\n", .{marker});
    return error.ExampleNotFound;
}

/// Every run of digits (and decimal points) in `text`, in order, separated by
/// spaces: "Found 33 files, 14103 lines" becomes "33 14103".
fn numberTokens(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (!std.ascii.isDigit(text[index]) and text[index] != '.') {
            index += 1;
            continue;
        }
        const start = index;
        while (index < text.len and (std.ascii.isDigit(text[index]) or text[index] == '.')) index += 1;
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, text[start..index]);
    }
    return out.toOwnedSlice(allocator);
}

test "slugify matches the anchor rule GitHub applies" {
    var buffer: [512]u8 = undefined;
    // One dash per space, everything lowercased.
    try std.testing.expectEqualStrings("skipped-files", slugify("Skipped files", &buffer));
    try std.testing.expectEqualStrings("archivos-omitidos", slugify("Archivos omitidos", &buffer));
    // A dropped symbol between two spaces leaves *two* dashes — the rule a
    // hand-written anchor most often gets wrong.
    try std.testing.expectEqualStrings("p2--tests-performance-and-delivery", slugify("P2 — tests, performance and delivery", &buffer));
    try std.testing.expectEqualStrings("p2--pruebas-rendimiento-y-entrega", slugify("P2 — pruebas, rendimiento y entrega", &buffer));
    // Underscores survive, backticks and dots do not: this is the shape of a
    // real heading in this repository.
    try std.testing.expectEqualStrings("rules--tdlearnrulestoml", slugify("Rules — `.tdlearn/rules.toml`", &buffer));
    try std.testing.expectEqualStrings("max_cyclomatic-es-una-lista-de-trabajo", slugify("`max_cyclomatic` es una lista de trabajo", &buffer));
}
