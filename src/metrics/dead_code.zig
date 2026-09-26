const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Dead code and duplication detection.
///
/// A function is dead when it lives in a non-test file and is none of:
/// public, a method, a justified implicit entry point, referenced from its own
/// file, or reachable from a liveness root through known calls. Functions in
/// test files never contribute to production dead-code or duplicate findings.
///
/// Liveness roots:
///   - public functions and methods,
///   - justified implicit entry points (see `isRootFunction`),
///   - references *in the function's own file*, so a mention in file A never
///     keeps a same-named function in file B alive and a test probe in file A
///     cannot mask a same-named helper in file B,
///   - cross-file references that resolve unambiguously: production code in
///     another file mentions the name and exactly one production file defines
///     it, so the mention can only be about that file,
///   - resolved call edges, then conservative textual calls.
///
/// Duplicates: functions with identical normalized bodies (whitespace and
/// comments stripped, strings preserved). Hash groups are verified by exact
/// normalized-body comparison. Bodies under 20 normalized chars are skipped.
/// Functions that only test blocks of their own file reference are not
/// duplicate candidates.
///
/// Denominators: the three ratios divide by `production_functions`
/// (non-test files) so numerator and denominator always cover the same
/// population. `total_functions` additionally counts test-file functions and
/// is reported separately. With no production functions the dead/duplicate
/// counts are necessarily zero while the redundancy ratio is unknown, not
/// clean, so it falls back to 1.0.
///
/// Ownership: the result is a plain value that owns no memory, and every
/// allocation made while analyzing is released before `analyze` returns.
/// There is no `deinit` to call and nothing to free.
pub const DeadCodeResult = struct {
    /// dead_functions / production_functions, [0, 1]; 0.0 with no production
    /// functions, where the dead count is necessarily zero.
    dead_code_ratio: f64 = 0.0,
    /// duplicate_functions / production_functions, [0, 1]; 0.0 with no
    /// production functions, where the duplicate count is necessarily zero.
    duplication_ratio: f64 = 0.0,
    /// Functions that are dead or duplicated / production_functions, [0, 1];
    /// both sets are subsets of the production functions. Falls back to 1.0
    /// (unknown) when no production functions were extracted.
    redundancy_ratio: f64 = 0.0,
    /// Every extracted function, including test files, public API and methods.
    total_functions: u32 = 0,
    /// Functions in non-test files — the denominator of the ratios above.
    production_functions: u32 = 0,
    dead_functions: u32 = 0,
    duplicate_functions: u32 = 0,
};

/// Collected function with its file for cross-referencing.
/// Canonical definition lives in core.types.FileFuncs.
pub const FileFuncs = core.types.FileFuncs;

const FunctionRecord = struct {
    file: []const u8,
    /// Index of `file` in the `file_funcs` input, for file-scoped lookups.
    file_index: usize,
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

const DeadSummary = struct {
    flags: []bool,
    count: u32,
};

const ScanState = core.source_lexer.State;

/// Free a hash map whose keys are owned copies of the looked-up text.
fn deinitOwnedKeys(comptime V: type, allocator: Allocator, map: *std.StringHashMap(V)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

// ── Reference index ───────────────────────────────────────────

/// Where one file mentions one name.
const ReferenceKind = struct {
    /// Mentioned outside any test block (a call or a bare use).
    production: bool = false,
    /// Mentioned inside a test block of the same file.
    test_only: bool = false,
};

/// Project-wide view of a name. Definition counts make cross-file resolution
/// explicit instead of relying on a project-wide bare-name set: a mention only
/// reaches another file when the name has a single production definition.
const SymbolUsage = struct {
    /// Production files that declare the name (one per file, not per decl).
    defining_files: u32 = 0,
    /// Index of one declaring file; meaningful when `defining_files > 0`.
    defining_file: usize = 0,
    /// Files that mention the name outside a test block.
    production_mentioning_files: u32 = 0,
};

/// File-scoped symbol references, one map per input file plus a project-wide
/// usage table. Every key is owned by the index.
const ReferenceIndex = struct {
    allocator: Allocator,
    /// Per input file: the names that file mentions.
    per_file: []std.StringHashMap(ReferenceKind),
    /// name → project-wide usage counters.
    usage: std.StringHashMap(SymbolUsage),

    fn init(allocator: Allocator, file_count: usize) !ReferenceIndex {
        const per_file = try allocator.alloc(std.StringHashMap(ReferenceKind), file_count);
        errdefer allocator.free(per_file);
        var ready: usize = 0;
        errdefer {
            for (per_file[0..ready]) |*map| deinitOwnedKeys(ReferenceKind, allocator, map);
        }
        for (per_file) |*map| {
            map.* = std.StringHashMap(ReferenceKind).init(allocator);
            ready += 1;
        }
        return .{
            .allocator = allocator,
            .per_file = per_file,
            .usage = std.StringHashMap(SymbolUsage).init(allocator),
        };
    }

    fn deinit(self: *ReferenceIndex) void {
        for (self.per_file) |*map| deinitOwnedKeys(ReferenceKind, self.allocator, map);
        self.allocator.free(self.per_file);
        deinitOwnedKeys(SymbolUsage, self.allocator, &self.usage);
    }

    /// Record which names the file declares. Test files are skipped: a
    /// production reference can never resolve to a test-file definition, so
    /// counting them would only make cross-file resolution needlessly vague.
    fn noteDefinitions(self: *ReferenceIndex, file_index: usize, ff: FileFuncs) !void {
        if (isTestPath(ff.file)) return;
        var declared = std.StringHashMap(void).init(self.allocator);
        defer declared.deinit();
        for (ff.funcs) |func| {
            // Borrowed keys: the map lives no longer than this loop body.
            if (declared.contains(func.name)) continue;
            try declared.put(func.name, {});
            const usage = try self.usageEntry(func.name);
            if (usage.defining_files == 0) usage.defining_file = file_index;
            usage.defining_files += 1;
        }
    }

    /// Record every name the file mentions, tagged with its test context.
    fn collect(self: *ReferenceIndex, file_index: usize, ff: FileFuncs) !void {
        var state = ScanState{};
        const language: core.source_lexer.Language = if (isPythonFile(ff.file)) .python else .javascript;
        var tests = TestBlockTracker{};
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, ff.contents, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            tests.update(line);
            if (isDeclarationLine(ff.funcs, line_no)) continue;
            var code = std.ArrayList(u8).empty;
            defer code.deinit(self.allocator);
            // OOM is never swallowed: skipping a line would hide it.
            try core.source_lexer.sanitizeLine(
                self.allocator,
                &code,
                line,
                language,
                .discard_literals,
                &state,
            );
            var index: usize = 0;
            while (index < code.items.len) {
                if (!isIdentChar(code.items[index])) {
                    index += 1;
                    continue;
                }
                const start = index;
                while (index < code.items.len and isIdentChar(code.items[index])) index += 1;
                try self.mention(file_index, code.items[start..index], tests.inTest());
            }
        }
    }

    /// True when the function's own file mentions its name, in any context.
    fn referencedInFile(self: *const ReferenceIndex, file_index: usize, name: []const u8) bool {
        return self.per_file[file_index].contains(name);
    }

    /// True when production code in another file mentions the name and this
    /// file is its only production definer, so that mention can only be about
    /// this file. Ambiguous names (two or more definers) resolve to nothing,
    /// and test-block mentions never cross a file boundary at all.
    fn referencedFromOtherFile(self: *const ReferenceIndex, file_index: usize, name: []const u8) bool {
        const usage = self.usage.get(name) orelse return false;
        if (usage.defining_files != 1 or usage.defining_file != file_index) return false;
        var production_elsewhere = usage.production_mentioning_files;
        if (self.per_file[file_index].get(name)) |kind| {
            if (kind.production) production_elsewhere -= 1;
        }
        return production_elsewhere > 0;
    }

    /// True when the function is only reachable from test blocks: its own file
    /// mentions it from a test block, and no production line in the project
    /// mentions the name.
    fn testOnlyInProject(self: *const ReferenceIndex, file_index: usize, name: []const u8) bool {
        const kind = self.per_file[file_index].get(name) orelse return false;
        if (!kind.test_only or kind.production) return false;
        const usage = self.usage.get(name) orelse return false;
        return usage.production_mentioning_files == 0;
    }

    fn mention(self: *ReferenceIndex, file_index: usize, name: []const u8, in_test: bool) !void {
        const map = &self.per_file[file_index];
        if (map.getPtr(name)) |existing| {
            setKind(existing, in_test);
            return;
        }
        // The usage entry is resolved first: both it and the insertion below
        // can fail, and `owned` must not be published to the map until every
        // fallible step succeeded, or the errdefer would free a live key.
        const usage = try self.usageEntry(name);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const entry = try map.getOrPut(owned);
        if (entry.found_existing) {
            self.allocator.free(owned);
            setKind(entry.value_ptr, in_test);
            return;
        }
        setKind(entry.value_ptr, in_test);
        if (!in_test) usage.production_mentioning_files += 1;
    }

    /// Insert a usage entry for `name`, copying the key it will keep.
    fn usageEntry(self: *ReferenceIndex, name: []const u8) !*SymbolUsage {
        if (self.usage.getPtr(name)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const entry = try self.usage.getOrPut(owned);
        if (entry.found_existing) {
            // Unreachable: `getPtr` just missed the key. Keep the existing
            // counters instead of resetting them, and drop the unused copy.
            self.allocator.free(owned);
            return entry.value_ptr;
        }
        entry.value_ptr.* = .{};
        return entry.value_ptr;
    }
};

fn setKind(kind: *ReferenceKind, in_test: bool) void {
    if (in_test) {
        kind.test_only = true;
    } else {
        kind.production = true;
    }
}

/// Indentation-based tracking of the test block a line belongs to.
/// A block starts at a test declaration and ends at the next non-empty line
/// indented no deeper than the declaration.
const TestBlockTracker = struct {
    indent: ?usize = null,

    fn update(self: *TestBlockTracker, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (self.indent) |indent| {
            if (trimmed.len != 0 and lineIndent(line) <= indent and !isTestBlockStart(trimmed)) {
                self.indent = null;
            }
        }
        if (self.indent == null and isTestBlockStart(trimmed)) {
            self.indent = lineIndent(line);
        }
    }

    fn inTest(self: *const TestBlockTracker) bool {
        return self.indent != null;
    }
};

fn isTestBlockStart(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test{") or
        std.mem.startsWith(u8, line, "test(") or std.mem.startsWith(u8, line, "it(") or
        std.mem.startsWith(u8, line, "describe(") or std.mem.startsWith(u8, line, "def test_") or
        std.mem.startsWith(u8, line, "func Test")) return true;
    return false;
}

fn lineIndent(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return index;
}

// ── Entry points ──────────────────────────────────────────────

/// Names a language runtime invokes with no call site, in any file.
/// Deliberately minimal: conventions that are always reached by an explicit
/// call (`init`, `new`, `update`, `render`, `clone`, `deinit`, ...) stay out,
/// so they are only alive when a call or reference exists.
const runtime_entry_names = [_][]const u8{
    "main", // process entry point: C, C++, Rust, Go, JavaScript, Python
    "__main__", // Python module entry point
};

/// Python protocol methods the interpreter invokes on the object itself.
const python_protocol_names = [_][]const u8{
    "__init__", "__new__", // object construction
    "__del__", // garbage-collection hook
    "__enter__", "__exit__", // `with` statement
    "__call__", // instance call
};

/// Go invokes every package `init` function with no call site.
const go_runtime_names = [_][]const u8{"init"};

/// Names that mean "entry" only inside a conventional entry path
/// (`index.js`, `app.py`, `build.zig`, ...). Elsewhere they are ordinary
/// private helpers and are judged like any other.
const entry_file_names = [_][]const u8{
    "index", // page or module export
    "app", // application bootstrap
    "build", // build script entry
};

fn isRootFunction(record: FunctionRecord) bool {
    const name = record.func.name;
    if (isNameIn(&runtime_entry_names, name)) return true;
    if (isPythonFile(record.file)) return isNameIn(&python_protocol_names, name);
    if (isGoFile(record.file)) return isNameIn(&go_runtime_names, name);
    if (!core.path_utils.isEntryPointPath(record.file)) return false;
    return isNameIn(&entry_file_names, name);
}

fn isNameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

// ── Analysis ─────────────────────────────────────────────────

/// Analyze dead code and duplication. Liveness starts at public/API, methods,
/// justified implicit entry roots and file-scoped symbol references, then
/// follows resolved and conservative textual calls. Test files are excluded
/// from production dead-code decisions.
///
/// `allocator` funds all working memory and every allocation is released
/// before returning; `OutOfMemory` is propagated rather than swallowed.
pub fn analyze(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    call_edges: []const core.types.CallEdge,
) !DeadCodeResult {
    var records = std.ArrayList(FunctionRecord).empty;
    defer records.deinit(allocator);

    var local_calls = std.ArrayList(LocalCall).empty;
    defer {
        for (local_calls.items) |call| allocator.free(call.callee);
        local_calls.deinit(allocator);
    }

    var references = try ReferenceIndex.init(allocator, file_funcs.len);
    defer references.deinit();

    try collectRecordsAndReferences(allocator, file_funcs, &records, &local_calls, &references);

    const reachable = try allocator.alloc(bool, records.items.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    propagateReachability(
        records.items,
        reachable,
        call_edges,
        local_calls.items,
        &references,
    );

    const dead = try collectDeadSummary(allocator, records.items, reachable);
    defer allocator.free(dead.flags);

    const duplicates = try collectDuplicateFlags(allocator, file_funcs, records.items, &references);
    defer allocator.free(duplicates.flags);

    return buildResult(records.items, dead, duplicates);
}

fn buildResult(records: []const FunctionRecord, dead: DeadSummary, duplicates: DuplicateResult) !DeadCodeResult {
    var production_records: usize = 0;
    for (records) |record| {
        if (!isTestPath(record.file)) production_records += 1;
    }
    var result = DeadCodeResult{
        .total_functions = std.math.cast(u32, records.len) orelse return error.IntegerOverflow,
        .production_functions = std.math.cast(u32, production_records) orelse return error.IntegerOverflow,
        .dead_functions = dead.count,
        .duplicate_functions = duplicates.count,
    };
    if (production_records == 0) {
        // No production functions: the dead and duplicate counts are
        // necessarily zero, and redundancy is unknown rather than clean.
        result.redundancy_ratio = 1.0;
        return result;
    }
    var redundant: usize = 0;
    for (dead.flags, duplicates.flags) |is_dead, is_duplicate| {
        if (is_dead or is_duplicate) redundant += 1;
    }
    const denominator = @as(f64, @floatFromInt(production_records));
    result.dead_code_ratio = @as(f64, @floatFromInt(dead.count)) / denominator;
    result.duplication_ratio = @as(f64, @floatFromInt(duplicates.count)) / denominator;
    result.redundancy_ratio = @as(f64, @floatFromInt(redundant)) / denominator;
    return result;
}

fn collectRecordsAndReferences(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    records: *std.ArrayList(FunctionRecord),
    local_calls: *std.ArrayList(LocalCall),
    references: *ReferenceIndex,
) !void {
    for (file_funcs, 0..) |ff, file_index| {
        const record_start = records.items.len;
        for (ff.funcs) |func| {
            try records.append(allocator, .{ .file = ff.file, .file_index = file_index, .func = func });
        }
        // Test files are excluded from production liveness, calls, references
        // and duplicate candidates, so nothing below applies to them.
        if (isTestPath(ff.file)) continue;
        try references.noteDefinitions(file_index, ff);
        try references.collect(file_index, ff);
        try collectLocalCalls(allocator, ff, record_start, local_calls);
    }
}

fn propagateReachability(
    records: []const FunctionRecord,
    reachable: []bool,
    call_edges: []const core.types.CallEdge,
    local_calls: []const LocalCall,
    references: *const ReferenceIndex,
) void {
    for (records, 0..) |record, id| {
        if (isTestPath(record.file)) continue;
        if (record.func.is_public or record.func.is_method or isRootFunction(record)) {
            reachable[id] = true;
            continue;
        }
        if (references.referencedInFile(record.file_index, record.func.name) or
            references.referencedFromOtherFile(record.file_index, record.func.name)) reachable[id] = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (call_edges) |edge| {
            if (isTestPath(edge.from_file) or isTestPath(edge.to_file)) continue;
            if (markCallTargets(records, reachable, edge.from_file, edge.from_func, edge.to_file, edge.to_func)) changed = true;
        }
        for (local_calls) |call| {
            if (markLocalTargets(records, reachable, call, call_edges)) changed = true;
        }
    }
}

fn collectDeadSummary(
    allocator: Allocator,
    records: []const FunctionRecord,
    reachable: []const bool,
) !DeadSummary {
    const flags = try allocator.alloc(bool, records.len);
    errdefer allocator.free(flags);
    @memset(flags, false);
    var count: u32 = 0;
    for (records, 0..) |record, id| {
        if (isTestPath(record.file)) continue;
        if (record.func.is_public or record.func.is_method or isRootFunction(record)) continue;
        if (reachable[id]) continue;
        flags[id] = true;
        count += 1;
    }
    return .{ .flags = flags, .count = count };
}

fn collectLocalCalls(
    allocator: Allocator,
    ff: FileFuncs,
    record_start: usize,
    calls: *std.ArrayList(LocalCall),
) !void {
    var state = ScanState{};
    const python = isPythonFile(ff.file);
    var tests = TestBlockTracker{};
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, ff.contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        tests.update(line);
        // Test-block calls are test references, not production call edges:
        // they stay file-scoped instead of reaching same-named functions in
        // other files.
        if (tests.inTest()) continue;
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
    var code = std.ArrayList(u8).empty;
    defer code.deinit(allocator);
    const language: core.source_lexer.Language = if (python) .python else .javascript;
    try core.source_lexer.sanitizeLine(allocator, &code, line, language, .discard_literals, state);

    var index: usize = 0;
    while (index < code.items.len) : (index += 1) {
        if (code.items[index] != '(') continue;

        var end = index;
        while (end > 0 and (code.items[end - 1] == ' ' or code.items[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and isIdentChar(code.items[start - 1])) start -= 1;
        if (start == end) continue;
        const name = code.items[start..end];
        if (isCallKeyword(name)) continue;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try calls.append(allocator, .{
            .from = if (from) |func_index| record_start + func_index else null,
            .callee = owned_name,
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

fn isGoFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".go");
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
    references: *const ReferenceIndex,
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
    for (file_funcs, 0..) |ff, file_index| {
        for (ff.funcs, 0..) |func, func_index| {
            const record = record_start + func_index;
            if (isTestPath(ff.file) or hasOverlappingFunction(ff.funcs, func_index)) continue;
            // A body only test blocks of this file reach is test scaffolding,
            // not duplication of production code.
            if (!func.is_public and !func.is_method and
                references.testOnlyInProject(file_index, func.name)) continue;
            const body = try normalizeBody(allocator, ff.contents, func, ff.file) orelse continue;
            // Armed before the group lookup: a failed lookup must not strand
            // the normalized body.
            errdefer allocator.free(body);
            const hash = std.hash.Wyhash.hash(0, body);
            const gop = try body_groups.getOrPut(hash);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
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
    const language: core.source_lexer.Language = if (python) .python else .javascript;
    return core.source_lexer.sanitizeLine(allocator, output, line, language, .preserve_literals, state);
}
