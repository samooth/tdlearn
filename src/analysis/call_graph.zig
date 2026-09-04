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
        var edges = std.ArrayList(core.types.CallEdge).empty;
        errdefer edges.deinit(allocator);

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

        // Extract call sites per function and resolve
        for (file_funcs) |ff| {
            const sites = try extractCallSites(allocator, ff);
            defer allocator.free(sites);

            const imported = imports_by_file.get(ff.file);

            for (sites) |site| {
                // Find the enclosing function for the caller name
                const caller = enclosingFunc(ff.funcs, site.line) orelse continue;

                // 1. Same-file call — no cross-file edge
                if (hasLocalFunc(ff.funcs, site.callee)) continue;

                const candidates = fn_index.get(site.callee) orelse continue;

                // 2. Prefer a definition in a file that this file imports
                if (imported) |imp| {
                    var matched: ?FnEntry = null;
                    var public_matched: ?FnEntry = null;
                    for (candidates.items) |cand| {
                        var is_imported = false;
                        for (imp.items) |imp_file| {
                            if (std.mem.eql(u8, imp_file, cand.file)) {
                                is_imported = true;
                                break;
                            }
                        }
                        if (!is_imported) continue;
                        matched = cand;
                        if (cand.func.is_public and public_matched == null) {
                            public_matched = cand;
                        }
                    }
                    if (public_matched orelse matched) |target| {
                        try appendEdge(allocator, &edges, .{
                            .from_file = ff.file,
                            .from_func = caller.name,
                            .to_file = target.file,
                            .to_func = site.callee,
                        });
                        continue;
                    }
                }

                // 3. Unique public definition project-wide — plain calls only.
                // Qualified calls (`x.name(`) may be object dispatch, which
                // can't be distinguished from module access at line level.
                if (site.qualified) continue;
                var public_count: usize = 0;
                var public_target: ?FnEntry = null;
                for (candidates.items) |cand| {
                    if (cand.func.is_public) {
                        public_count += 1;
                        if (public_target == null) public_target = cand;
                    }
                }
                if (public_count == 1) {
                    const target = public_target.?;
                    try appendEdge(allocator, &edges, .{
                        .from_file = ff.file,
                        .from_func = caller.name,
                        .to_file = target.file,
                        .to_func = site.callee,
                    });
                }
            }
        }

        return try edges.toOwnedSlice(allocator);
    }

    const FnEntryList = std.ArrayList(FnEntry);
    const FnEntry = struct {
        file: []const u8,
        func: core.types.FuncInfo,
    };

    fn appendEdge(allocator: Allocator, edges: *std.ArrayList(core.types.CallEdge), edge: core.types.CallEdge) !void {
        for (edges.items) |existing| {
            if (std.mem.eql(u8, existing.from_file, edge.from_file) and
                std.mem.eql(u8, existing.from_func, edge.from_func) and
                std.mem.eql(u8, existing.to_file, edge.to_file) and
                std.mem.eql(u8, existing.to_func, edge.to_func))
            {
                return; // dedupe
            }
        }
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

/// Extract call sites: identifiers followed by '(' that are not
/// keywords, not this file's own declaration lines, and not
/// control-flow constructs.
/// Both plain `fn(` and qualified `mod.fn(` / `obj.fn(` calls are captured;
/// ambiguity between object dispatch and module access is resolved later
/// by the edge builder (import + unique-definition rules).
pub fn extractCallSites(allocator: Allocator, ff: core.types.FileFuncs) ![]CallSite {
    var sites = std.ArrayList(CallSite).empty;
    errdefer sites.deinit(allocator);

    var line_no: u32 = 0;
    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, ff.contents, offset, '\n')) |nl| {
        line_no += 1;
        const line = ff.contents[offset..nl];
        offset = nl + 1;
        try scanLine(allocator, &sites, ff.funcs, line, line_no);
    }
    if (offset < ff.contents.len) {
        line_no += 1;
        try scanLine(allocator, &sites, ff.funcs, ff.contents[offset..], line_no);
    }

    return try sites.toOwnedSlice(allocator);
}

fn scanLine(allocator: Allocator, sites: *std.ArrayList(CallSite), funcs: []const core.types.FuncInfo, line: []const u8, line_no: u32) !void {
    // Skip declaration lines — the declared name isn't a call
    for (funcs) |f| {
        if (f.start_line == line_no) return;
    }

    var in_string: u8 = 0;
    var prev: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string != 0) {
            if (c == in_string and prev != '\\') in_string = 0;
            prev = c;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            prev = c;
            continue;
        }
        if (c == '(') {
            // Scan backwards for the callee identifier
            var end = i;
            while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
            if (end == 0) {
                prev = c;
                continue;
            }
            var start = end;
            while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
            if (start < end) {
                const name = line[start..end];
                // The char before the identifier decides the flavor:
                //   `.` or `:` → qualified call (mod.func / obj.method)
                //   anything else → plain call
                const qualified = start > 0 and (line[start - 1] == '.' or line[start - 1] == ':');
                if (!qualified and isKeyword(name)) {
                    prev = c;
                    continue;
                }
                try sites.append(allocator, .{
                    .line = line_no,
                    .callee = name,
                    .qualified = qualified,
                });
            }
        }
        prev = c;
    }
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
