const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Dead code and duplication detection.
///
/// A function is dead when ALL of:
///   - not public (no pub/export keyword)
///   - not a method (object dispatch untraceable at line level)
///   - not in a test file (path contains "test")
///   - name doesn't match implicit-entry conventions (main, init, deinit, ...)
///   - name never appears as a call target anywhere in the codebase
///
/// Duplicates: functions with identical normalized bodies (whitespace and
/// comments stripped, SipHash). Bodies under 20 normalized chars are skipped.
pub const DeadCodeResult = struct {
    /// dead_funcs / total_funcs, [0, 1]
    dead_code_ratio: f64 = 0.0,
    /// duplicated function instances / total_funcs, [0, 1]
    duplication_ratio: f64 = 0.0,
    /// (dead + duplicates) / total, clamped to [0, 1]
    redundancy_ratio: f64 = 0.0,
    total_functions: u32 = 0,
    dead_functions: u32 = 0,
    duplicate_functions: u32 = 0,
    /// File paths of dead functions (borrowed from input)
    dead_files: []const []const u8 = &.{},
};

/// Collected function with its file for cross-referencing.
/// Canonical definition lives in core.types.FileFuncs.
pub const FileFuncs = core.types.FileFuncs;

/// Implicit entry point names that are never considered dead even if private.
const implicit_entry_names = [_][]const u8{
    "main",   "new",   "default", "init",      "setup",       "teardown",
    "run",    "start", "stop",    "build",     "configure",   "register",
    "update", "draw",  "render",  "serialize", "deserialize", "deinit",
    "drop",   "clone", "fmt",     "from",      "into",
};

/// Analyze dead code and duplication.
/// `call_edges` (optional) provide precise cross-file liveness: a function
/// is alive if it is the `to_func` of any edge, or its name appears as a
/// call target in any file contents (fallback for same-file calls).
pub fn analyze(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    call_edges: []const core.types.CallEdge,
) !DeadCodeResult {
    var result = DeadCodeResult{};

    var total: u32 = 0;
    var dead: u32 = 0;

    var dead_files = std.ArrayList([]const u8).empty;
    errdefer dead_files.deinit(allocator);

    // Liveness from call edges: every to_func is called
    var edge_called = std.StringHashMap(void).init(allocator);
    defer edge_called.deinit();
    for (call_edges) |e| {
        _ = try edge_called.put(e.to_func, {});
    }

    // Fallback: identifiers followed by '(' anywhere (same-file calls,
    // method-style dispatch, dynamic patterns)
    var call_targets = std.StringHashMap(void).init(allocator);
    defer call_targets.deinit();
    for (file_funcs) |ff| {
        try collectCallTargets(&call_targets, ff);
    }

    // Duplicate detection: body hash → list of instances
    var body_hashes = std.AutoHashMap(u64, u32).init(allocator);
    defer body_hashes.deinit();

    for (file_funcs) |ff| {
        const is_test_file = std.mem.indexOf(u8, ff.file, "test") != null;

        for (ff.funcs) |func| {
            total += 1;

            // Duplicate tracking
            if (computeBodyHash(ff.contents, func)) |hash| {
                const gop = try body_hashes.getOrPut(hash);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1; // count extra instance
                } else {
                    gop.value_ptr.* = 1;
                }
            }

            // Dead-code rules
            if (func.is_public) continue;
            if (func.is_method) continue;
            if (is_test_file) continue;
            if (isImplicitEntry(func.name)) continue;
            if (edge_called.contains(func.name)) continue;
            if (call_targets.contains(func.name)) continue;

            dead += 1;
            try dead_files.append(allocator, ff.file);
        }
    }

    // Duplicate count: sum over groups with > 1 instance of (instances - 1)
    var dup_count: u32 = 0;
    var hash_iter = body_hashes.iterator();
    while (hash_iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            dup_count += entry.value_ptr.* - 1;
        }
    }

    result.total_functions = total;
    result.dead_functions = dead;
    result.duplicate_functions = dup_count;

    const total_f: f64 = @floatFromInt(total);
    if (total > 0) {
        result.dead_code_ratio = @as(f64, @floatFromInt(dead)) / total_f;
        result.duplication_ratio = @as(f64, @floatFromInt(dup_count)) / total_f;
        const waste = @as(f64, @floatFromInt(dead + dup_count));
        result.redundancy_ratio = @min(1.0, waste / total_f);
    }

    result.dead_files = try dead_files.toOwnedSlice(allocator);
    return result;
}

/// Collect identifiers followed by '(' as call targets.
/// Skips lines that are themselves function declarations (a definition's own
/// name would otherwise count as a call site).
fn collectCallTargets(targets: *std.StringHashMap(void), ff: FileFuncs) !void {
    // Build a per-line lookup of "is declaration line" for this file's funcs
    var decl_lines_buf: [64]u32 = undefined;
    var decl_count: usize = 0;
    for (ff.funcs) |f| {
        if (decl_count < decl_lines_buf.len) {
            decl_lines_buf[decl_count] = f.start_line;
            decl_count += 1;
        }
    }
    const decl_lines = decl_lines_buf[0..decl_count];

    var line_no: u32 = 0;
    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, ff.contents, offset, '\n')) |nl| {
        line_no += 1;
        const line = ff.contents[offset..nl];
        offset = nl + 1;

        // Skip this file's own declaration lines
        var is_decl = false;
        for (decl_lines) |dl| {
            if (dl == line_no) {
                is_decl = true;
                break;
            }
        }
        if (is_decl) continue;

        try collectLineCallTargets(targets, line);
    }
    // Last line without trailing newline
    if (offset < ff.contents.len) {
        line_no += 1;
        var is_decl = false;
        for (decl_lines) |dl| {
            if (dl == line_no) {
                is_decl = true;
                break;
            }
        }
        if (!is_decl) try collectLineCallTargets(targets, ff.contents[offset..]);
    }
}

fn collectLineCallTargets(targets: *std.StringHashMap(void), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '(') {
            var end = i;
            while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
            var start = end;
            while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
            if (start < end) {
                _ = try targets.put(line[start..end], {});
            }
        }
    }
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isImplicitEntry(name: []const u8) bool {
    for (implicit_entry_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Normalize a function body: extract lines between start and end, strip
/// comments and whitespace, then hash. Returns null if body too small.
fn computeBodyHash(contents: []const u8, func: core.types.FuncInfo) ?u64 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        if (line_no < func.start_line) continue;
        if (line_no > func.end_line) break;
        // Skip the declaration line itself — names differ between duplicates
        if (line_no == func.start_line) continue;
        var line = std.mem.trim(u8, raw, " \t\r");
        // Strip line comments
        if (std.mem.indexOf(u8, line, "//")) |ci| line = line[0..ci];
        // Strip inline string contents? v1: keep — hashing consistency matters more
        if (line.len == 0) continue;
        for (line) |c| {
            if (len >= buf.len) return null; // body too large to hash reliably
            if (c == ' ' or c == '\t') continue; // strip all whitespace
            buf[len] = c;
            len += 1;
        }
    }

    if (len < 20) return null; // too small to be meaningfully duplicated
    return std.hash.Wyhash.hash(0, buf[0..len]);
}

// ── Tests ─────────────────────────────────────────────────────

fn makeFunc(name: []const u8, start: u32, end: u32, is_public: bool) core.types.FuncInfo {
    return .{
        .name = name,
        .start_line = start,
        .end_line = end,
        .line_count = end - start + 1,
        .is_public = is_public,
    };
}

test "no functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try analyze(arena.allocator(), &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.total_functions);
    try std.testing.expectEqual(@as(f64, 0.0), result.redundancy_ratio);
}

test "all public functions are alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "pub fn a() void {}\npub fn b() void {}";
    const funcs = [_]core.types.FuncInfo{
        makeFunc("a", 1, 1, true),
        makeFunc("b", 2, 2, true),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 2), result.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 0.0), result.redundancy_ratio);
}

test "uncalled private function is dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "orphan" is defined but never called; "used" is called by entry
    const contents =
        \\pub fn entry() void {
        \\    used();
        \\}
        \\fn used() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("entry", 1, 3, true),
        makeFunc("used", 4, 4, false),
        makeFunc("orphan", 5, 5, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 1.0 / 3.0), result.dead_code_ratio);
    try std.testing.expectEqualStrings("src/lib.zig", result.dead_files[0]);
}

test "implicit entry names never dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "fn main() void {}";
    const funcs = [_]core.types.FuncInfo{makeFunc("main", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/main.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "methods never dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "impl Foo { fn method(&self) {} }";
    var funcs = [_]core.types.FuncInfo{makeFunc("method", 1, 1, false)};
    funcs[0].is_method = true;
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.rs", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "test files excluded from dead analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "fn helper() void {}";
    const funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib_test.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "duplicate bodies detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Two identical private functions in different files — both uncalled too
    const contents_a =
        \\fn dup() void {
        \\    const x = 1 + 2 + 3;
        \\    const y = x * 2;
        \\    _ = y;
        \\}
    ;
    const contents_b =
        \\fn dup2() void {
        \\    const x = 1 + 2 + 3;
        \\    const y = x * 2;
        \\    _ = y;
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("dup", 1, 4, false),
        makeFunc("dup2", 1, 4, false),
    };
    // dup is called by someone in file a; dup2 not — only duplication counts
    const contents_a_with_call = "pub fn user() void {\n    dup();\n}\ndup_body";
    _ = contents_a_with_call;
    const ff = [_]FileFuncs{
        .{ .file = "src/a.zig", .contents = contents_a, .funcs = funcs[0..1] },
        .{ .file = "src/b.zig", .contents = contents_b, .funcs = funcs[1..2] },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    // Both are dead AND duplicated: redundancy includes both signals
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "call target across files keeps function alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib_contents = "fn helper() void {}";
    const app_contents = "pub fn main() void {\n    helper();\n}";
    const lib_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const app_funcs = [_]core.types.FuncInfo{makeFunc("main", 1, 3, true)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/app.zig", .contents = app_contents, .funcs = &app_funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "call edges mark liveness without textual call sites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // helper is never textually called from main's body, but a call edge
    // (from external analysis) declares it alive
    const lib_contents = "fn helper() void {}";
    const lib_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const app_contents = "pub fn main() void {\n    other_stuff();\n}";
    const app_funcs = [_]core.types.FuncInfo{makeFunc("main", 1, 3, true)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/app.zig", .contents = app_contents, .funcs = &app_funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/app.zig", .from_func = "main", .to_file = "src/lib.zig", .to_func = "helper" },
    };
    const result = try analyze(arena.allocator(), &ff, &edges);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "body too small skipped from duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "fn a() void {}\nfn b() void {}";
    const funcs = [_]core.types.FuncInfo{
        makeFunc("a", 1, 1, false),
        makeFunc("b", 2, 2, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_functions);
    // Both a and b are dead though (uncalled, private)
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}
