const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Dead code and duplication detection.
///
/// A function is dead when it is not public, a method, a test, an implicit
/// entry point, or reachable from a public/entry root through known calls.
///
/// Duplicates: functions with identical normalized bodies (whitespace and
/// comments stripped, strings preserved). Hash groups are verified by exact
/// normalized-body comparison. Bodies under 20 normalized chars are skipped.
pub const DeadCodeResult = struct {
    /// dead_funcs / total_funcs, [0, 1]
    dead_code_ratio: f64 = 0.0,
    /// duplicated function instances / total_funcs, [0, 1]
    duplication_ratio: f64 = 0.0,
    /// Functions that are dead or duplicated / total, clamped to [0, 1].
    /// With no extracted functions, use 1.0 as a conservative unknown.
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

const FunctionRecord = struct {
    file: []const u8,
    func: core.types.FuncInfo,
};

const LocalCall = struct {
    from: ?usize,
    callee: []const u8,
};

const BodyRecord = struct {
    id: usize,
    body: []const u8,
};

const DuplicateResult = struct {
    flags: []bool,
    count: u32,
};

const ScanState = struct {
    block_comment: bool = false,
    triple_quote: u8 = 0,
    template: bool = false,
};

/// Implicit entry point names that are never considered dead even if private.
const implicit_entry_names = [_][]const u8{
    "main",   "new",   "default", "init",      "setup",       "teardown",
    "run",    "start", "stop",    "build",     "configure",   "register",
    "update", "draw",  "render",  "serialize", "deserialize", "deinit",
    "drop",   "clone", "fmt",     "from",      "into",
};

/// Analyze dead code and duplication. Liveness starts at public/API and
/// conventional entry roots, then follows resolved and conservative textual
/// calls. Test files are excluded from production dead-code decisions.
pub fn analyze(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    call_edges: []const core.types.CallEdge,
) !DeadCodeResult {
    var records = std.ArrayList(FunctionRecord).empty;
    defer records.deinit(allocator);

    var local_calls = std.ArrayList(LocalCall).empty;
    defer local_calls.deinit(allocator);

    var referenced_names = std.StringHashMap(void).init(allocator);
    defer {
        var referenced_iter = referenced_names.iterator();
        while (referenced_iter.next()) |entry| allocator.free(entry.key_ptr.*);
        referenced_names.deinit();
    }

    for (file_funcs) |ff| {
        const record_start = records.items.len;
        for (ff.funcs) |func| {
            try records.append(allocator, .{
                .file = ff.file,
                .func = func,
            });
        }
        if (!isTestPath(ff.file)) {
            try collectLocalCalls(allocator, ff, record_start, &local_calls);
            try collectSymbolReferences(allocator, ff, &referenced_names);
        }
    }

    var reachable = try allocator.alloc(bool, records.items.len);
    defer allocator.free(reachable);
    @memset(reachable, false);

    for (records.items, 0..) |record, id| {
        if (isTestPath(record.file)) continue;
        if (record.func.is_public or isRootFunction(record) or referenced_names.contains(record.func.name)) reachable[id] = true;
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (call_edges) |edge| {
            if (isTestPath(edge.from_file) or isTestPath(edge.to_file)) continue;
            if (markCallTargets(records.items, reachable, edge.from_file, edge.from_func, edge.to_file, edge.to_func)) {
                changed = true;
            }
        }
        for (local_calls.items) |call| {
            if (markLocalTargets(records.items, reachable, call, call_edges)) changed = true;
        }
    }

    var dead_flags = try allocator.alloc(bool, records.items.len);
    defer allocator.free(dead_flags);
    @memset(dead_flags, false);

    var dead_files = std.ArrayList([]const u8).empty;
    errdefer dead_files.deinit(allocator);
    var dead_file_set = std.StringHashMap(void).init(allocator);
    defer dead_file_set.deinit();

    var dead: u32 = 0;
    for (records.items, 0..) |record, id| {
        if (isTestPath(record.file)) continue;
        if (record.func.is_public or record.func.is_method or isRootFunction(record)) continue;
        if (reachable[id]) continue;
        dead_flags[id] = true;
        dead += 1;
        if (!dead_file_set.contains(record.file)) {
            try dead_file_set.put(record.file, {});
            try dead_files.append(allocator, record.file);
        }
    }

    const duplicates = try collectDuplicateFlags(allocator, file_funcs, records.items);
    defer allocator.free(duplicates.flags);
    const duplicate_count = duplicates.count;
    const duplicate_flags = duplicates.flags;

    const total = std.math.cast(u32, records.items.len) orelse return error.IntegerOverflow;
    var redundant: u32 = 0;
    for (dead_flags, duplicate_flags) |is_dead, is_duplicate| {
        if (is_dead or is_duplicate) redundant += 1;
    }

    var result = DeadCodeResult{
        .total_functions = total,
        .dead_functions = dead,
        .duplicate_functions = duplicate_count,
        .dead_files = try dead_files.toOwnedSlice(allocator),
    };
    if (total == 0) {
        result.redundancy_ratio = 1.0;
        return result;
    }

    const total_f = @as(f64, @floatFromInt(total));
    result.dead_code_ratio = @as(f64, @floatFromInt(dead)) / total_f;
    result.duplication_ratio = @as(f64, @floatFromInt(duplicate_count)) / total_f;
    result.redundancy_ratio = @as(f64, @floatFromInt(redundant)) / total_f;
    return result;
}

fn collectLocalCalls(
    allocator: Allocator,
    ff: FileFuncs,
    record_start: usize,
    calls: *std.ArrayList(LocalCall),
) !void {
    var state = ScanState{};
    const python = isPythonFile(ff.file);
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, ff.contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (isDeclarationLine(ff.funcs, line_no)) continue;
        const from = enclosingFunctionIndex(ff.funcs, line_no);
        try scanLocalLine(allocator, line, python, &state, from, record_start, calls);
    }
}

fn scanLocalLine(
    allocator: Allocator,
    line: []const u8,
    python: bool,
    state: *ScanState,
    from: ?usize,
    record_start: usize,
    calls: *std.ArrayList(LocalCall),
) !void {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (state.block_comment) {
            if (index + 1 < line.len and line[index] == '*' and line[index + 1] == '/') {
                state.block_comment = false;
                index += 1;
            }
            continue;
        }
        if (state.triple_quote != 0) {
            if (index + 2 < line.len and line[index] == state.triple_quote and
                line[index + 1] == state.triple_quote and line[index + 2] == state.triple_quote)
            {
                state.triple_quote = 0;
                index += 2;
            }
            continue;
        }
        if (state.template) {
            if (line[index] == '`') state.template = false;
            continue;
        }
        if (line[index] == '/' and index + 1 < line.len and line[index + 1] == '/') break;
        if (line[index] == '/' and index + 1 < line.len and line[index + 1] == '*') {
            state.block_comment = true;
            index += 1;
            continue;
        }
        if (python and line[index] == '#') break;
        if (index + 2 < line.len and
            ((line[index] == '"' and line[index + 1] == '"' and line[index + 2] == '"') or
                (line[index] == '\'' and line[index + 1] == '\'' and line[index + 2] == '\'')))
        {
            state.triple_quote = line[index];
            index += 2;
            continue;
        }
        if (line[index] == '"' or line[index] == '\'') {
            const quote = line[index];
            index += 1;
            while (index < line.len) : (index += 1) {
                if (line[index] == '\\' and index + 1 < line.len) {
                    index += 1;
                } else if (line[index] == quote) {
                    break;
                }
            }
            continue;
        }
        if (line[index] == '`') {
            state.template = true;
            continue;
        }
        if (line[index] != '(') continue;

        var end = index;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
        if (start == end) continue;
        const name = line[start..end];
        if (isCallKeyword(name)) continue;
        try calls.append(allocator, .{
            .from = if (from) |func_index| record_start + func_index else null,
            .callee = name,
        });
    }
}

fn isDeclarationLine(funcs: []const core.types.FuncInfo, line_no: u32) bool {
    for (funcs) |func| {
        if (func.start_line == line_no) return true;
    }
    return false;
}

fn enclosingFunctionIndex(funcs: []const core.types.FuncInfo, line_no: u32) ?usize {
    var best: ?usize = null;
    var best_size: u32 = std.math.maxInt(u32);
    for (funcs, 0..) |func, index| {
        if (line_no < func.start_line or line_no > func.end_line) continue;
        const size = func.end_line - func.start_line;
        if (best == null or size < best_size) {
            best = index;
            best_size = size;
        }
    }
    return best;
}

fn isCallKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "if",     "while", "for",    "switch", "catch", "return", "fn",    "match",    "loop",
        "unsafe", "as",    "elif",   "def",    "class", "lambda", "print", "function", "go",
        "defer",  "func",  "sizeof",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isImplicitEntry(name: []const u8) bool {
    for (implicit_entry_names) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn isRootFunction(record: FunctionRecord) bool {
    if (isImplicitEntry(record.func.name)) return true;
    if (!core.path_utils.isEntryPointPath(record.file)) return false;
    const entry_names = [_][]const u8{ "main", "index", "app", "__main__", "build" };
    for (entry_names) |name| {
        if (std.mem.eql(u8, record.func.name, name)) return true;
    }
    return false;
}

fn isTestPath(path: []const u8) bool {
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (isTestComponent(component)) return true;
    }
    return false;
}

fn isTestComponent(component: []const u8) bool {
    if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests") or
        std.mem.eql(u8, component, "__tests__")) return true;
    var parts = std.mem.splitScalar(u8, component, '.');
    var first = true;
    var stem: []const u8 = component;
    while (parts.next()) |part| {
        if (first) {
            stem = part;
            first = false;
            continue;
        }
        if (std.mem.eql(u8, part, "test") or std.mem.eql(u8, part, "spec")) return true;
    }
    if (std.mem.eql(u8, stem, "test") or std.mem.eql(u8, stem, "tests") or
        std.mem.eql(u8, stem, "__tests__") or std.mem.eql(u8, stem, "spec") or
        std.mem.startsWith(u8, stem, "test_") or std.mem.startsWith(u8, stem, "test-")) return true;
    if (std.mem.endsWith(u8, stem, "_test") or std.mem.endsWith(u8, stem, "_tests") or
        std.mem.endsWith(u8, stem, "_spec")) return true;
    return false;
}

fn isPythonFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".py");
}

fn markCallTargets(
    records: []const FunctionRecord,
    reachable: []bool,
    from_file: []const u8,
    from_func: []const u8,
    to_file: []const u8,
    to_func: []const u8,
) bool {
    var changed = false;
    for (records, 0..) |source, source_id| {
        if (!reachable[source_id]) continue;
        if (!std.mem.eql(u8, source.file, from_file) or !std.mem.eql(u8, source.func.name, from_func)) continue;
        for (records, 0..) |target, target_id| {
            if (reachable[target_id]) continue;
            if (!std.mem.eql(u8, target.func.name, to_func)) continue;
            if (to_file.len > 0 and !std.mem.eql(u8, target.file, to_file)) continue;
            reachable[target_id] = true;
            changed = true;
        }
    }
    return changed;
}

fn markLocalTargets(
    records: []const FunctionRecord,
    reachable: []bool,
    call: LocalCall,
    call_edges: []const core.types.CallEdge,
) bool {
    var changed = false;
    if (call.from) |from_id| {
        if (from_id >= records.len or !reachable[from_id]) return false;
    }
    const source_file = if (call.from) |from_id| records[from_id].file else "";
    const source_name = if (call.from) |from_id| records[from_id].func.name else "";
    var has_local_target = false;
    for (records) |target| {
        if (call.from != null and std.mem.eql(u8, target.file, source_file) and
            std.mem.eql(u8, target.func.name, call.callee))
        {
            has_local_target = true;
            break;
        }
    }
    var has_resolved_edge = false;
    if (call.from != null) {
        for (call_edges) |edge| {
            if (std.mem.eql(u8, edge.from_file, source_file) and
                std.mem.eql(u8, edge.from_func, source_name) and
                std.mem.eql(u8, edge.to_func, call.callee))
            {
                has_resolved_edge = true;
                break;
            }
        }
    }
    for (records, 0..) |target, target_id| {
        if (reachable[target_id]) continue;
        if (call.from != null and has_local_target and !std.mem.eql(u8, target.file, source_file)) continue;
        if (call.from != null and !has_local_target and has_resolved_edge) continue;
        if (!std.mem.eql(u8, target.func.name, call.callee)) continue;
        reachable[target_id] = true;
        changed = true;
    }
    return changed;
}

fn hasOverlappingFunction(funcs: []const core.types.FuncInfo, index: usize) bool {
    const current = funcs[index];
    for (funcs, 0..) |other, other_index| {
        if (other_index == index) continue;
        if (current.start_line <= other.end_line and other.start_line <= current.end_line) return true;
    }
    return false;
}

fn normalizeBody(allocator: Allocator, contents: []const u8, func: core.types.FuncInfo, file: []const u8) !?[]const u8 {
    var normalized = std.ArrayList(u8).empty;
    errdefer normalized.deinit(allocator);
    var state = ScanState{};
    const python = isPythonFile(file);
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (line_no <= func.start_line) continue;
        if (line_no > func.end_line) break;
        try normalizeLine(allocator, &normalized, line, python, &state);
    }
    if (normalized.items.len < 20) {
        normalized.deinit(allocator);
        return null;
    }
    return try normalized.toOwnedSlice(allocator);
}

fn collectDuplicateFlags(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    records: []const FunctionRecord,
) !DuplicateResult {
    var body_groups = std.AutoHashMap(u64, std.ArrayList(BodyRecord)).init(allocator);
    defer {
        var iter = body_groups.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |body| allocator.free(body.body);
            entry.value_ptr.deinit(allocator);
        }
        body_groups.deinit();
    }

    const flags = try allocator.alloc(bool, records.len);
    errdefer allocator.free(flags);
    @memset(flags, false);

    var record_start: usize = 0;
    for (file_funcs) |ff| {
        for (ff.funcs, 0..) |func, func_index| {
            const record = record_start + func_index;
            if (isTestPath(ff.file) or hasOverlappingFunction(ff.funcs, func_index)) continue;
            const body = try normalizeBody(allocator, ff.contents, func, ff.file) orelse continue;
            const hash = std.hash.Wyhash.hash(0, body);
            const gop = try body_groups.getOrPut(hash);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            errdefer allocator.free(body);
            try gop.value_ptr.append(allocator, .{ .id = record, .body = body });
        }
        record_start += ff.funcs.len;
    }

    var count: u32 = 0;
    var groups = body_groups.iterator();
    while (groups.next()) |entry| {
        const group = entry.value_ptr.items;
        for (group, 0..) |body, index| {
            for (group[0..index]) |previous| {
                if (std.mem.eql(u8, previous.body, body.body)) {
                    flags[body.id] = true;
                    count += 1;
                    break;
                }
            }
        }
    }
    return .{ .flags = flags, .count = count };
}

fn normalizeLine(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    python: bool,
    state: *ScanState,
) !void {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (state.block_comment) {
            if (index + 1 < line.len and line[index] == '*' and line[index + 1] == '/') {
                state.block_comment = false;
                index += 1;
            }
            continue;
        }
        if (state.triple_quote != 0) {
            if (index + 2 < line.len and line[index] == state.triple_quote and
                line[index + 1] == state.triple_quote and line[index + 2] == state.triple_quote)
            {
                state.triple_quote = 0;
                index += 2;
            } else {
                try output.append(allocator, line[index]);
            }
            continue;
        }
        if (state.template) {
            if (line[index] == '`') {
                try output.append(allocator, '`');
                state.template = false;
            } else {
                try output.append(allocator, line[index]);
            }
            continue;
        }
        if (line[index] == '/' and index + 1 < line.len and line[index + 1] == '/') {
            appendSeparator(allocator, output) catch return error.OutOfMemory;
            break;
        }
        if (line[index] == '/' and index + 1 < line.len and line[index + 1] == '*') {
            appendSeparator(allocator, output) catch return error.OutOfMemory;
            state.block_comment = true;
            index += 1;
            continue;
        }
        if (python and line[index] == '#') {
            appendSeparator(allocator, output) catch return error.OutOfMemory;
            break;
        }
        if (index + 2 < line.len and
            ((line[index] == '"' and line[index + 1] == '"' and line[index + 2] == '"') or
                (line[index] == '\'' and line[index + 1] == '\'' and line[index + 2] == '\'')))
        {
            try output.append(allocator, line[index]);
            state.triple_quote = line[index];
            index += 2;
            continue;
        }
        if (line[index] == '"' or line[index] == '\'') {
            const quote = line[index];
            try output.append(allocator, quote);
            index += 1;
            while (index < line.len) : (index += 1) {
                try output.append(allocator, line[index]);
                if (line[index] == '\\' and index + 1 < line.len) {
                    index += 1;
                    try output.append(allocator, line[index]);
                } else if (line[index] == quote) {
                    break;
                }
            }
            continue;
        }
        if (line[index] == '`') {
            try output.append(allocator, '`');
            state.template = true;
            continue;
        }
        if (std.ascii.isWhitespace(line[index])) {
            appendSeparator(allocator, output) catch return error.OutOfMemory;
        } else {
            try output.append(allocator, line[index]);
        }
    }
}

fn appendSeparator(allocator: Allocator, output: *std.ArrayList(u8)) !void {
    if (output.items.len == 0 or output.items[output.items.len - 1] == ' ') return;
    try output.append(allocator, ' ');
}

fn collectSymbolReferences(
    allocator: Allocator,
    ff: FileFuncs,
    names: *std.StringHashMap(void),
) !void {
    var state = ScanState{};
    const python = isPythonFile(ff.file);
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, ff.contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (isDeclarationLine(ff.funcs, line_no)) continue;
        var code = std.ArrayList(u8).empty;
        defer code.deinit(allocator);
        normalizeLine(allocator, &code, line, python, &state) catch continue;
        var index: usize = 0;
        while (index < code.items.len) {
            if (!isIdentChar(code.items[index])) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < code.items.len and isIdentChar(code.items[index])) index += 1;
            const name = code.items[start..index];
            var lookahead = index;
            while (lookahead < code.items.len and std.ascii.isWhitespace(code.items[lookahead])) lookahead += 1;
            if (lookahead < code.items.len and code.items[lookahead] == '(') continue;
            if (names.contains(name)) continue;
            const owned = try allocator.dupe(u8, name);
            errdefer allocator.free(owned);
            try names.put(owned, {});
        }
    }
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
    try std.testing.expectEqual(@as(f64, 1.0), result.redundancy_ratio);
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

test "function references used as callbacks are alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn api() void {
        \\    register(callback);
        \\}
        \\fn callback() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("callback", 4, 4, false),
        makeFunc("orphan", 5, 5, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
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
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "test path matching does not use arbitrary substrings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const latest_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const test_funcs = [_]core.types.FuncInfo{makeFunc("test_helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/latest.zig", .contents = "fn helper() void {}", .funcs = &latest_funcs },
        .{ .file = "src/test.zig", .contents = "fn test_helper() void {}", .funcs = &test_funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "liveness follows reachable callers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn api() void {}
        \\fn orphan_caller() void {}
        \\fn leaf() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 1, true),
        makeFunc("orphan_caller", 2, 2, false),
        makeFunc("leaf", 3, 3, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/lib.zig", .from_func = "orphan_caller", .to_file = "src/lib.zig", .to_func = "leaf" },
    };
    const result = try analyze(arena.allocator(), &ff, &edges);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "public API roots keep transitive local calls alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn api() void {
        \\    private_a();
        \\}
        \\fn private_a() void {
        \\    private_b();
        \\}
        \\fn private_b() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("private_a", 4, 6, false),
        makeFunc("private_b", 7, 7, false),
        makeFunc("orphan", 8, 8, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "resolved symbols keep only the selected target alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller_contents = "pub fn api() void {\n    helper();\n}";
    const target_contents = "fn helper() void {\n    const value = 1 + 2 + 3;\n    _ = value;\n}";
    const other_contents = "fn helper() void {\n    const value = 4 + 5 + 6;\n    _ = value;\n}";
    const caller_funcs = [_]core.types.FuncInfo{makeFunc("api", 1, 3, true)};
    const target_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const other_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/caller.zig", .contents = caller_contents, .funcs = &caller_funcs },
        .{ .file = "src/target.zig", .contents = target_contents, .funcs = &target_funcs },
        .{ .file = "src/other.zig", .contents = other_contents, .funcs = &other_funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/caller.zig", .from_func = "api", .to_file = "src/target.zig", .to_func = "helper" },
    };
    const result = try analyze(arena.allocator(), &ff, &edges);
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "declaration scanning is not capped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var contents = std.ArrayList(u8).empty;
    var funcs = std.ArrayList(core.types.FuncInfo).empty;
    for (0..65) |index| {
        const line = try std.fmt.allocPrint(arena.allocator(), "fn helper{d}() void {{}}\n", .{index});
        try contents.appendSlice(arena.allocator(), line);
        try funcs.append(arena.allocator(), makeFunc("helper", @intCast(index + 1), @intCast(index + 1), false));
    }
    const ff = [_]FileFuncs{
        .{ .file = "src/generated.zig", .contents = contents.items, .funcs = funcs.items },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 65), result.total_functions);
    try std.testing.expectEqual(@as(u32, 65), result.dead_functions);
}

test "normalized bodies ignore comments but preserve string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents_a =
        \\fn first() void {
        \\    // comment A
        \\    const text = "same";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const contents_b =
        \\fn second() void {
        \\    /* comment B */
        \\    const text = "same";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const contents_c =
        \\fn third() void {
        \\    // comment C
        \\    const text = "different";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const funcs_a = [_]core.types.FuncInfo{makeFunc("first", 1, 5, false)};
    const funcs_b = [_]core.types.FuncInfo{makeFunc("second", 1, 5, false)};
    const funcs_c = [_]core.types.FuncInfo{makeFunc("third", 1, 5, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/a.zig", .contents = contents_a, .funcs = &funcs_a },
        .{ .file = "src/b.zig", .contents = contents_b, .funcs = &funcs_b },
        .{ .file = "src/c.zig", .contents = contents_c, .funcs = &funcs_c },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "large normalized bodies are compared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first = std.ArrayList(u8).empty;
    var second = std.ArrayList(u8).empty;
    try first.appendSlice(arena.allocator(), "fn first() void {\n");
    try second.appendSlice(arena.allocator(), "fn second() void {\n");
    for (0..200) |index| {
        const line = try std.fmt.allocPrint(arena.allocator(), "    const value{d} = 1 + 2;\n", .{index});
        try first.appendSlice(arena.allocator(), line);
        try second.appendSlice(arena.allocator(), line);
    }
    try first.appendSlice(arena.allocator(), "}\n");
    try second.appendSlice(arena.allocator(), "}\n");
    const first_funcs = [_]core.types.FuncInfo{makeFunc("first", 1, 202, false)};
    const second_funcs = [_]core.types.FuncInfo{makeFunc("second", 1, 202, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/first.zig", .contents = first.items, .funcs = &first_funcs },
        .{ .file = "src/second.zig", .contents = second.items, .funcs = &second_funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "overlapping function bodies are excluded from duplicate matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\fn outer() void {
        \\    fn inner() void {
        \\        const value = 1 + 2 + 3;
        \\        _ = value;
        \\    }
        \\    _ = inner;
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("outer", 1, 6, false),
        makeFunc("inner", 2, 4, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/nested.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_functions);
}
