const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const functions_mod = @import("functions.zig");

/// Build the call graph: extract call sites per function from each file,
/// resolve callee identifiers to (file, function) targets, and emit
/// file-level CallEdges.
///
/// Resolution rules for a callee name invoked from file F:
///   1. Skipped — same-file calls don't produce cross-file edges
///   2. If F imports file T and T defines a function with that name
///      (public preferred), emit F.func → T.func
///   3. If exactly one file project-wide defines that name publicly,
///      emit an edge to it (unique-public fallback)
///   4. Otherwise unresolved (stdlib, external, dynamic) — dropped
///
/// All allocations come from `allocator` — use an arena for one-shot scans.
pub const CallGraphBuilder = struct {
    /// Build call edges from extracted per-file functions.
    /// `import_edges` are the resolved file-level import edges.
    pub fn buildCallEdges(
        allocator: Allocator,
        file_funcs: []const core.types.FileFuncs,
        import_edges: []const core.types.ImportEdge,
    ) ![]core.types.CallEdge {
        return buildCallEdgesWithLimit(allocator, file_funcs, import_edges, 0);
    }

    pub fn buildCallEdgesWithLimit(
        allocator: Allocator,
        file_funcs: []const core.types.FileFuncs,
        import_edges: []const core.types.ImportEdge,
        max_call_targets: u32,
    ) ![]core.types.CallEdge {
        var edges = std.ArrayList(core.types.CallEdge).empty;
        errdefer edges.deinit(allocator);
        var edge_set = EdgeSet.init(allocator);
        defer edge_set.deinit();

        // Index 1: function name → list of (file, func) entries
        var fn_index = std.StringHashMap(*FnEntryList).init(allocator);
        defer {
            var iter = fn_index.iterator();
            while (iter.next()) |e| {
                e.value_ptr.*.deinit(allocator);
                allocator.destroy(e.value_ptr.*);
            }
            fn_index.deinit();
        }

        // Index 2: file path → list of imported file paths
        var imports_by_file = std.StringHashMap(*std.ArrayList([]const u8)).init(allocator);
        defer {
            var iter2 = imports_by_file.iterator();
            while (iter2.next()) |e| {
                e.value_ptr.*.deinit(allocator);
                allocator.destroy(e.value_ptr.*);
            }
            imports_by_file.deinit();
        }

        // Build the function index
        for (file_funcs) |ff| {
            for (ff.funcs) |func| {
                const gop = try fn_index.getOrPut(func.name);
                if (!gop.found_existing) {
                    const list = try allocator.create(FnEntryList);
                    list.* = .empty;
                    gop.value_ptr.* = list;
                }
                try gop.value_ptr.*.append(allocator, .{
                    .file = ff.file,
                    .func = func,
                });
            }
        }

        // Build the imports index
        for (import_edges) |edge| {
            const gop = try imports_by_file.getOrPut(edge.from_file);
            if (!gop.found_existing) {
                const list = try allocator.create(std.ArrayList([]const u8));
                list.* = .empty;
                gop.value_ptr.* = list;
            }
            try gop.value_ptr.*.append(allocator, edge.to_file);
        }

        try appendResolvedEdges(
            allocator,
            file_funcs,
            &fn_index,
            &imports_by_file,
            max_call_targets,
            &edges,
            &edge_set,
        );

        return try edges.toOwnedSlice(allocator);
    }

    const EdgeSet = struct {
        map: std.StringHashMap(void),
        allocator: Allocator,

        fn init(allocator: Allocator) EdgeSet {
            return .{ .map = std.StringHashMap(void).init(allocator), .allocator = allocator };
        }

        fn deinit(self: *EdgeSet) void {
            var iter = self.map.iterator();
            while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.map.deinit();
        }
    };

    const FnEntryList = std.ArrayList(FnEntry);
    const FnEntry = struct {
        file: []const u8,
        func: core.types.FuncInfo,
    };

    /// Per-caller budget of call targets. `max_call_targets == 0` means
    /// unlimited, and the budget is consumed by every call site — resolved or
    /// not — so a function cannot exceed the cap by calling names that do not
    /// resolve.
    const CallBudget = struct {
        counts: std.StringHashMap(u32),
        limit: u32,
        enabled: bool,

        fn init(allocator: Allocator, limit: u32) CallBudget {
            return .{
                .counts = std.StringHashMap(u32).init(allocator),
                .limit = limit,
                .enabled = limit > 0,
            };
        }

        fn deinit(self: *CallBudget) void {
            self.counts.deinit();
        }

        /// Returns false when this caller has already used its budget.
        fn consume(self: *CallBudget, caller: []const u8) !bool {
            if (!self.enabled) return true;
            const count = self.counts.get(caller) orelse 0;
            if (count >= self.limit) return false;
            try self.counts.put(caller, count + 1);
            return true;
        }
    };

    fn appendResolvedEdges(
        allocator: Allocator,
        file_funcs: []const core.types.FileFuncs,
        fn_index: *const std.StringHashMap(*FnEntryList),
        imports_by_file: *const std.StringHashMap(*std.ArrayList([]const u8)),
        max_call_targets: u32,
        edges: *std.ArrayList(core.types.CallEdge),
        edge_set: *EdgeSet,
    ) !void {
        for (file_funcs) |ff| {
            const sites = try extractCallSites(allocator, ff);
            defer allocator.free(sites);
            const imported = imports_by_file.get(ff.file);
            var budget = CallBudget.init(allocator, max_call_targets);
            defer budget.deinit();
            for (sites) |site| {
                const caller = enclosingFunc(ff.funcs, site.line) orelse continue;
                if (!try budget.consume(caller.name)) continue;
                if (hasLocalFunc(ff.funcs, site.callee)) continue;
                const candidates = fn_index.get(site.callee) orelse continue;
                const target = resolveTarget(candidates, imported, site.qualified) orelse continue;
                try appendEdge(allocator, edges, edge_set, .{
                    .from_file = ff.file,
                    .from_func = caller.name,
                    .to_file = target.file,
                    .to_func = site.callee,
                });
            }
        }
    }

    /// Resolution policy, in order of decreasing confidence:
    ///   1. a candidate in a file this module explicitly imports,
    ///   2. nothing, for a qualified call like `obj.method()` — the receiver
    ///      would have to be resolved to know where it points,
    ///   3. a name that maps to exactly one public function in the whole index.
    /// Anything less certain stays unresolved rather than becoming an invented
    /// edge.
    fn resolveTarget(
        candidates: *const FnEntryList,
        imported: ?*const std.ArrayList([]const u8),
        qualified: bool,
    ) ?FnEntry {
        if (imported) |files| {
            if (pickImported(candidates, files.items)) |target| return target;
        }
        if (qualified) return null;
        return pickSolePublic(candidates);
    }

    /// A public imported candidate wins; otherwise the last imported one does.
    fn pickImported(candidates: *const FnEntryList, files: []const []const u8) ?FnEntry {
        var matched: ?FnEntry = null;
        var public_matched: ?FnEntry = null;
        for (candidates.items) |cand| {
            if (!isImportedFrom(files, cand.file)) continue;
            matched = cand;
            if (cand.func.is_public and public_matched == null) public_matched = cand;
        }
        return public_matched orelse matched;
    }

    fn isImportedFrom(files: []const []const u8, file: []const u8) bool {
        for (files) |imported_file| {
            if (std.mem.eql(u8, imported_file, file)) return true;
        }
        return false;
    }

    /// Only an unambiguous name resolves: two public functions with the same
    /// name are ambiguous, not a target.
    fn pickSolePublic(candidates: *const FnEntryList) ?FnEntry {
        var public_count: usize = 0;
        var public_target: ?FnEntry = null;
        for (candidates.items) |cand| {
            if (!cand.func.is_public) continue;
            public_count += 1;
            if (public_target == null) public_target = cand;
        }
        if (public_count != 1) return null;
        return public_target;
    }

    fn appendEdge(
        allocator: Allocator,
        edges: *std.ArrayList(core.types.CallEdge),
        edge_set: *EdgeSet,
        edge: core.types.CallEdge,
    ) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}\x00{s}", .{ edge.from_file, edge.from_func, edge.to_file, edge.to_func });
        if (edge_set.map.contains(key)) {
            allocator.free(key);
            return;
        }
        errdefer allocator.free(key);
        try edge_set.map.put(key, {});
        errdefer _ = edge_set.map.remove(key);
        try edges.append(allocator, edge);
    }

    fn hasLocalFunc(funcs: []const core.types.FuncInfo, name: []const u8) bool {
        for (funcs) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    fn enclosingFunc(funcs: []const core.types.FuncInfo, line: u32) ?core.types.FuncInfo {
        for (funcs) |f| {
            if (line >= f.start_line and line <= f.end_line) return f;
        }
        return null;
    }
};

const CallSite = struct {
    line: u32,
    callee: []const u8,
    /// True for receiver/module-style calls: `x.name(` or `x::name(`.
    /// Object dispatch can't be traced, so qualified calls only resolve
    /// through the imported-file rule — never the unique-public fallback.
    qualified: bool = false,
};

/// Extract call sites: identifiers followed by '(' that are not keywords, not
/// this file's own declaration lines, and not inside a comment or a string.
/// Both plain `fn(` and qualified `mod.fn(` / `obj.fn(` calls are captured;
/// ambiguity between object dispatch and module access is resolved later by the
/// edge builder (import + unique-definition rules).
///
/// Every line is masked with the shared lexer before it is scanned, so a `(`
/// inside a comment or a literal cannot be read as a call. The identifier is
/// then sliced out of the *original* line: the mask is byte-for-byte the same
/// length as its input (pinned by the "discard mode preserves length" test in
/// `core/source_lexer.zig`), so both agree on offsets, and the returned name is
/// a stable view of the file contents rather than of scratch space.
pub fn extractCallSites(allocator: Allocator, ff: core.types.FileFuncs) ![]CallSite {
    var sites = std.ArrayList(CallSite).empty;
    errdefer sites.deinit(allocator);

    const language = lexerLanguage(ff.lang);
    // The lexer state is threaded across lines on purpose: a block comment or
    // a multi-line literal that starts on one line must keep masking the
    // following lines, which a per-line scan cannot know.
    var state = core.source_lexer.State{};
    var masked = std.ArrayList(u8).empty;
    defer masked.deinit(allocator);

    var line_no: u32 = 0;
    var offset: usize = 0;
    while (offset < ff.contents.len) {
        const nl = std.mem.indexOfScalarPos(u8, ff.contents, offset, '\n') orelse ff.contents.len;
        line_no += 1;
        const line = ff.contents[offset..nl];
        masked.clearRetainingCapacity();
        try core.source_lexer.sanitizeLine(allocator, &masked, line, language, .discard_literals, &state);
        std.debug.assert(masked.items.len == line.len);
        try scanLine(allocator, &sites, ff.funcs, masked.items, line, line_no);
        offset = nl + 1;
    }

    return try sites.toOwnedSlice(allocator);
}

fn lexerLanguage(lang: []const u8) core.source_lexer.Language {
    if (std.mem.eql(u8, lang, "zig")) return .zig;
    if (std.mem.eql(u8, lang, "rust")) return .rust;
    if (std.mem.eql(u8, lang, "python")) return .python;
    if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript")) return .javascript;
    if (std.mem.eql(u8, lang, "go")) return .go;
    if (std.mem.eql(u8, lang, "c") or std.mem.eql(u8, lang, "cpp")) return .c;
    return .other;
}

/// Scan one masked line for calls, taking the callee from `line` (the original
/// text) at the offsets `masked` reported.
fn scanLine(
    allocator: Allocator,
    sites: *std.ArrayList(CallSite),
    funcs: []const core.types.FuncInfo,
    masked: []const u8,
    line: []const u8,
    line_no: u32,
) !void {
    // Skip declaration lines — the declared name isn't a call
    for (funcs) |f| {
        if (f.start_line == line_no) return;
    }

    var i: usize = 0;
    while (i < masked.len) : (i += 1) {
        if (masked[i] != '(') continue;
        const range = calleeRange(masked, i) orelse continue;
        // The character before the identifier decides the flavor:
        //   `.` or `:` → qualified call (mod.func / obj.method)
        //   anything else → plain call
        const qualified = range.start > 0 and (masked[range.start - 1] == '.' or masked[range.start - 1] == ':');
        if (!qualified and isKeyword(line[range.start..range.end])) continue;
        try sites.append(allocator, .{
            .line = line_no,
            .callee = line[range.start..range.end],
            .qualified = qualified,
        });
    }
}

/// Byte range of the identifier immediately before the `(` at `paren`, or null
/// when the call has no callee (a bare `(`, a grouping paren, or a keyword).
const CalleeRange = struct { start: usize, end: usize };

fn calleeRange(code: []const u8, paren: usize) ?CalleeRange {
    var end = paren;
    while (end > 0 and (code[end - 1] == ' ' or code[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and isIdentChar(code[start - 1])) start -= 1;
    if (start == end) return null;
    return .{ .start = start, .end = end };
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        // Zig
        "if",    "while", "for",    "switch", "catch",  "return", "fn",
        // Rust
        "if",    "while", "for",    "match",  "loop",   "unsafe", "as",
        // Python
        "if",    "elif",  "while",  "for",    "def",    "class",  "lambda",
        "print",
        // JS
        "if",    "while",  "for",    "switch", "catch",  "function",
        // Go
        "if",    "for",   "switch", "go",     "defer",  "func",   "return",
        // C
        "if",    "while", "for",    "switch", "sizeof", "return",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
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

test "call sites extracted per line, decl lines skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn caller() u32 {
        \\    const x = helper(1) + other();
        \\    return x;
        \\}
        \\fn helper(v: u32) u32 {
        \\    return v;
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("caller", 1, 3, true),
        makeFunc("helper", 5, 7, false),
    };
    const ff = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = contents,
        .funcs = &funcs,
    };
    const sites = try extractCallSites(arena.allocator(), ff);
    defer arena.allocator().free(sites);
    // helper( and other( on line 2; decl lines 1 and 5 skipped
    try std.testing.expectEqual(@as(usize, 2), sites.len);
    try std.testing.expectEqualStrings("helper", sites[0].callee);
    try std.testing.expectEqualStrings("other", sites[1].callee);
    try std.testing.expectEqual(@as(u32, 2), sites[0].line);
}

test "keywords skipped, methods captured as qualified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn f() void {
        \\    if (cond()) {
        \\        obj.method();
        \\        plain();
        \\    }
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{makeFunc("f", 1, 6, true)};
    const ff = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = contents,
        .funcs = &funcs,
    };
    const sites = try extractCallSites(arena.allocator(), ff);
    defer arena.allocator().free(sites);
    // `if` is keyword (skipped); cond, method, plain are calls.
    // `method` is qualified — resolution filters it later if ambiguous.
    try std.testing.expectEqual(@as(usize, 3), sites.len);
    try std.testing.expectEqualStrings("cond", sites[0].callee);
    try std.testing.expect(sites[0].qualified == false);
    try std.testing.expectEqualStrings("method", sites[1].callee);
    try std.testing.expect(sites[1].qualified == true);
    try std.testing.expectEqualStrings("plain", sites[2].callee);
    try std.testing.expect(sites[2].qualified == false);
}

test "qualified cross-module call resolves via import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Zig-style: const helper_mod = @import("helper.zig"); helper_mod.run();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    helper_mod.run();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn run() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("run", 1, 1, true)},
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "src/b.zig" },
    };
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b }, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("run", edges[0].to_func);
    try std.testing.expectEqualStrings("src/b.zig", edges[0].to_file);
}

test "qualified object dispatch unresolved without import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // obj.run() where run is public in exactly one file — but the call is
    // receiver-style, so the unique-public fallback must NOT fire
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    obj.run();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn run() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("run", 1, 1, true)},
    };
    // No import edge — qualified calls stay unresolved
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b }, &.{});
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "call strings ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents =
        \\pub fn f() void {
        \\    const s = "hello( world";
        \\    real();
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{makeFunc("f", 1, 3, true)};
    const ff = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = contents,
        .funcs = &funcs,
    };
    const sites = try extractCallSites(arena.allocator(), ff);
    defer arena.allocator().free(sites);
    try std.testing.expectEqual(@as(usize, 1), sites.len);
    try std.testing.expectEqualStrings("real", sites[0].callee);
}

test "cross-file edge via import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    helper();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn helper() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("helper", 1, 1, true)},
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "src/b.zig" },
    };
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b }, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/a.zig", edges[0].from_file);
    try std.testing.expectEqualStrings("caller", edges[0].from_func);
    try std.testing.expectEqualStrings("src/b.zig", edges[0].to_file);
    try std.testing.expectEqualStrings("helper", edges[0].to_func);
}

test "same-file call produces no edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    helper();\n}\nfn helper() void {}",
        .funcs = &[_]core.types.FuncInfo{
            makeFunc("caller", 1, 3, true),
            makeFunc("helper", 4, 4, false),
        },
    };
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{a}, &.{});
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "unique public fallback resolves without import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    util();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn util() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("util", 1, 1, true)},
    };
    // No import edge between a and b — unique-public rule kicks in
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b }, &.{});
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/b.zig", edges[0].to_file);
}

test "ambiguous public names unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    util();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn util() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("util", 1, 1, true)},
    };
    const c = core.types.FileFuncs{
        .file = "src/c.zig",
        .contents = "pub fn util() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("util", 1, 1, true)},
    };
    // util is public in two files, no import — ambiguous, dropped
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b, c }, &.{});
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "call target limit is enforced per caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller = core.types.FileFuncs{
        .file = "src/caller.zig",
        .contents = "pub fn caller() void {\n    first();\n    second();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 4, true)},
    };
    const first = core.types.FileFuncs{
        .file = "src/first.zig",
        .contents = "pub fn first() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("first", 1, 1, true)},
    };
    const second = core.types.FileFuncs{
        .file = "src/second.zig",
        .contents = "pub fn second() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("second", 1, 1, true)},
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = caller.file, .to_file = first.file },
        .{ .from_file = caller.file, .to_file = second.file },
    };
    const edges = try CallGraphBuilder.buildCallEdgesWithLimit(arena.allocator(), &.{ caller, first, second }, &imports, 1);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("first", edges[0].to_func);
}

test "dedup identical call edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = "pub fn caller() void {\n    helper();\n    helper();\n}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("caller", 1, 3, true)},
    };
    const b = core.types.FileFuncs{
        .file = "src/b.zig",
        .contents = "pub fn helper() void {}",
        .funcs = &[_]core.types.FuncInfo{makeFunc("helper", 1, 1, true)},
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "src/b.zig" },
    };
    const edges = try CallGraphBuilder.buildCallEdges(arena.allocator(), &.{ a, b }, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
}

test "calls inside comments and multi-line literals are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The scanner used to track strings by hand and ignore comments entirely,
    // so every call below used to be reported as a real call.
    const contents =
        \\// notACall();
        \\pub fn f() void {
        \\    /* alsoNotACall();
        \\       stillNotACall(); */
        \\    const text =
        \\        \\rawNotACall();
        \\    ;
        \\    real();
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{makeFunc("f", 2, 9, true)};
    const ff = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = contents,
        .funcs = &funcs,
        .lang = "zig",
    };
    const sites = try extractCallSites(arena.allocator(), ff);
    defer arena.allocator().free(sites);
    try std.testing.expectEqual(@as(usize, 1), sites.len);
    try std.testing.expectEqualStrings("real", sites[0].callee);
    try std.testing.expectEqual(@as(u32, 8), sites[0].line);
}

test "callee names point into the file contents, not into scratch space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The masked line is scratch space reused per line, so a callee sliced out
    // of the mask would be overwritten by the following line. Callers rely on
    // these names outliving the scan (the call graph keeps them in edges).
    const contents = "pub fn f() void {\n    alpha();\n    beta();\n}\n";
    const funcs = [_]core.types.FuncInfo{makeFunc("f", 1, 4, true)};
    const ff = core.types.FileFuncs{
        .file = "src/a.zig",
        .contents = contents,
        .funcs = &funcs,
        .lang = "zig",
    };
    const sites = try extractCallSites(arena.allocator(), ff);
    defer arena.allocator().free(sites);
    try std.testing.expectEqual(@as(usize, 2), sites.len);
    try std.testing.expectEqualStrings("alpha", sites[0].callee);
    try std.testing.expectEqualStrings("beta", sites[1].callee);
    // Both names must be views inside the contents buffer itself.
    const base = @intFromPtr(contents.ptr);
    const limit = base + contents.len;
    for (sites) |site| {
        const start = @intFromPtr(site.callee.ptr);
        try std.testing.expect(start >= base);
        try std.testing.expect(start + site.callee.len <= limit);
    }
}
