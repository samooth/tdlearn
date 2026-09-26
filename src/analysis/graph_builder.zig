const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("core");
const imports_mod = @import("imports.zig");
const lang_registry = @import("lang_registry.zig");
const manifests = @import("manifests.zig");
const resolver_mod = @import("resolver.zig");

/// Build the import graph: read each source file, extract imports,
/// resolve them against the file list, produce deduplicated ImportEdges.
///
/// All allocations come from `allocator` — use an arena for one-shot scans.
pub const GraphBuilder = struct {
    /// Languages the import extractor can read (`imports.ImportExtractor`).
    const import_languages = [_][]const u8{
        "zig", "rust", "python", "javascript", "typescript", "go", "c", "cpp",
    };

    /// Extension → language, for exactly the languages above. This is the
    /// import-graph projection of `lang_registry.LangRegistry`: every extension
    /// the registry maps to an import-capable language appears here with the
    /// same name, and nothing else is scanned. The "detectLangFor agrees with
    /// lang_registry" test fails if the two ever drift apart (it was how .cxx
    /// and .hxx went missing).
    const ext_langs = [_]struct { e: []const u8, l: []const u8 }{
        .{ .e = "zig", .l = "zig" },
        .{ .e = "zon", .l = "zig" },
        .{ .e = "rs", .l = "rust" },
        .{ .e = "py", .l = "python" },
        .{ .e = "pyi", .l = "python" },
        .{ .e = "js", .l = "javascript" },
        .{ .e = "jsx", .l = "javascript" },
        .{ .e = "mjs", .l = "javascript" },
        .{ .e = "ts", .l = "typescript" },
        .{ .e = "tsx", .l = "typescript" },
        .{ .e = "mts", .l = "typescript" },
        .{ .e = "go", .l = "go" },
        .{ .e = "c", .l = "c" },
        .{ .e = "h", .l = "c" },
        .{ .e = "cpp", .l = "cpp" },
        .{ .e = "hpp", .l = "cpp" },
        .{ .e = "cc", .l = "cpp" },
        .{ .e = "cxx", .l = "cpp" },
        .{ .e = "hxx", .l = "cpp" },
    };

    /// Filenames without (or with) an extension the table above already knows.
    /// Mirrors lang_registry's filename-first lookup for import languages.
    const known_names = [_]struct { n: []const u8, l: []const u8 }{
        .{ .n = "build.zig", .l = "zig" },
        .{ .n = "build.zig.zon", .l = "zig" },
    };

    /// Build import edges from a flat list of source files.
    /// `file_paths` must all be non-directory paths relative to the scan root.
    pub fn buildImportEdges(
        allocator: Allocator,
        io: Io,
        file_paths: []const []const u8,
    ) ![]core.types.ImportEdge {
        return buildImportEdgesAtRoot(allocator, io, "", file_paths);
    }

    pub fn buildImportEdgesAtRoot(
        allocator: Allocator,
        io: Io,
        root_path: []const u8,
        file_paths: []const []const u8,
    ) ![]core.types.ImportEdge {
        return buildImportEdgesAtRootWithContents(allocator, io, root_path, file_paths, null);
    }

    pub fn buildImportEdgesAtRootWithContents(
        allocator: Allocator,
        io: Io,
        root_path: []const u8,
        file_paths: []const []const u8,
        contents_by_path: ?std.StringHashMap([]const u8),
    ) ![]core.types.ImportEdge {
        var edges = std.ArrayList(core.types.ImportEdge).empty;
        errdefer edges.deinit(allocator);
        var edge_set = std.StringHashMap(void).init(allocator);
        defer {
            var iter = edge_set.iterator();
            while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
            edge_set.deinit();
        }

        const aliases = try manifests.readPackageAliasesAtRoot(allocator, io, root_path, file_paths);
        var source_paths = std.ArrayList([]const u8).empty;
        defer source_paths.deinit(allocator);
        for (file_paths) |path| {
            if (!std.mem.eql(u8, detectLangFor(path), "unknown")) {
                try source_paths.append(allocator, path);
            }
        }

        var resolver = try resolver_mod.Resolver.initWithAliases(allocator, source_paths.items, aliases);
        defer resolver.deinit();

        for (source_paths.items) |path| {
            const lang = detectLangFor(path);
            const contents = if (contents_by_path) |contents_map|
                contents_map.get(path) orelse return error.FileNotFound
            else
                try readFile(allocator, io, root_path, path);
            const raw_imports = try imports_mod.ImportExtractor.extract(allocator, contents, lang);

            for (raw_imports) |raw| {
                if (try resolver.resolve(raw, path)) |target| {
                    if (std.mem.eql(u8, target, path)) continue; // skip self-import
                    const edge = core.types.ImportEdge{
                        .from_file = path,
                        .to_file = target,
                    };
                    try appendEdge(allocator, &edges, &edge_set, edge);
                }
            }
        }

        return try edges.toOwnedSlice(allocator);
    }

    /// Public wrapper: detect language for a file path (extension mapping).
    /// Returns "unknown" for anything the import extractor cannot read, which
    /// is also what excludes the file from the import graph.
    pub fn detectLangForFile(path: []const u8) []const u8 {
        return detectLangFor(path);
    }

    /// True when the language name is one the import extractor understands.
    pub fn isImportLanguage(lang: []const u8) bool {
        for (import_languages) |candidate| {
            if (std.mem.eql(u8, lang, candidate)) return true;
        }
        return false;
    }

    fn detectLangFor(path: []const u8) []const u8 {
        // Table-driven, allocation-free mirror of lang_registry's
        // filename-then-extension lookup, restricted to import languages.
        const name = core.path_utils.fileName(path);
        for (known_names) |k| {
            if (std.mem.eql(u8, name, k.n)) return k.l;
        }
        const ext = core.path_utils.extension(path);
        for (ext_langs) |m| {
            if (std.mem.eql(u8, ext, m.e)) return m.l;
        }
        return "unknown";
    }

    fn readFile(allocator: Allocator, io: Io, root_path: []const u8, path: []const u8) ![]const u8 {
        const full_path = if (root_path.len == 0) path else try std.mem.join(allocator, "/", &.{ root_path, path });
        const file = try std.Io.Dir.cwd().openFile(io, full_path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size > 2 * 1024 * 1024) return error.FileTooLarge;
        if (stat.size == 0) return &.{};

        const buf = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(buf);
        const bytes_read = try file.readPositionalAll(io, buf, 0);
        return buf[0..bytes_read];
    }

    fn appendEdge(
        allocator: Allocator,
        edges: *std.ArrayList(core.types.ImportEdge),
        edge_set: *std.StringHashMap(void),
        edge: core.types.ImportEdge,
    ) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ edge.from_file, edge.to_file });
        if (edge_set.contains(key)) {
            allocator.free(key);
            return;
        }
        errdefer allocator.free(key);
        try edge_set.put(key, {});
        errdefer _ = edge_set.remove(key);
        try edges.append(allocator, edge);
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "detectLangFor known extensions" {
    try std.testing.expectEqualStrings("zig", GraphBuilder.detectLangFor("src/main.zig"));
    try std.testing.expectEqualStrings("rust", GraphBuilder.detectLangFor("lib.rs"));
    try std.testing.expectEqualStrings("python", GraphBuilder.detectLangFor("app.py"));
    try std.testing.expectEqualStrings("typescript", GraphBuilder.detectLangFor("a.ts"));
    try std.testing.expectEqualStrings("go", GraphBuilder.detectLangFor("main.go"));
    try std.testing.expectEqualStrings("c", GraphBuilder.detectLangFor("main.c"));
    try std.testing.expectEqualStrings("cpp", GraphBuilder.detectLangFor("a.cpp"));
    try std.testing.expectEqualStrings("unknown", GraphBuilder.detectLangFor("README.md"));
}

test "detectLangFor covers cxx and hxx" {
    try std.testing.expectEqualStrings("cpp", GraphBuilder.detectLangFor("src/widget.cxx"));
    try std.testing.expectEqualStrings("cpp", GraphBuilder.detectLangFor("src/widget.hxx"));
    try std.testing.expectEqualStrings("cpp", GraphBuilder.detectLangFor("src/widget.cc"));
    try std.testing.expectEqualStrings("cpp", GraphBuilder.detectLangFor("src/widget.hpp"));
    try std.testing.expectEqualStrings("c", GraphBuilder.detectLangFor("src/widget.h"));
    try std.testing.expectEqualStrings("zig", GraphBuilder.detectLangFor("build.zig.zon"));
    try std.testing.expectEqualStrings("zig", GraphBuilder.detectLangFor("build.zig"));
}

test "detectLangFor agrees with lang_registry" {
    var registry = try lang_registry.LangRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Every extension in the graph_builder table must be classified exactly as
    // lang_registry classifies it. This is the guard that caught .cxx/.hxx
    // being silently dropped from the import graph.
    for (GraphBuilder.ext_langs) |entry| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "src/sample.{s}", .{entry.e});
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings(
            registry.detectLang(path),
            GraphBuilder.detectLangForFile(path),
        );
    }
    for (GraphBuilder.known_names) |entry| {
        try std.testing.expectEqualStrings(
            registry.detectLang(entry.n),
            GraphBuilder.detectLangForFile(entry.n),
        );
    }

    // …and languages lang_registry knows but the extractor cannot read stay
    // out of the import graph instead of being mis-detected.
    const not_importable = [_][]const u8{
        "notes.md",   "data.json", "conf.toml", "app.swift", "Main.java",
        "lib.rb",     "mod.scala", "main.lua",  "q.rs.bk",   "Makefile",
        "Dockerfile", "query.sql", "page.html", "x.pas",     "y.ml",
    };
    for (not_importable) |path| {
        const detected = GraphBuilder.detectLangForFile(path);
        try std.testing.expectEqualStrings("unknown", detected);
        try std.testing.expect(!GraphBuilder.isImportLanguage(detected));
    }
}

test "detected languages are all import-capable" {
    const samples = [_][]const u8{
        "a.zig", "a.zon", "a.rs",  "a.py",    "a.pyi", "a.js",
        "a.jsx", "a.mjs", "a.ts",  "a.tsx",   "a.mts", "a.go",
        "a.c",   "a.h",   "a.cpp", "a.hpp",   "a.cc",  "a.cxx",
        "a.hxx", "a.rb",  "a.md",  "unknown",
    };
    for (samples) |path| {
        const detected = GraphBuilder.detectLangForFile(path);
        if (std.mem.eql(u8, detected, "unknown")) continue;
        try std.testing.expect(GraphBuilder.isImportLanguage(detected));
        try std.testing.expect(imports_mod.ImportExtractor.supportsLanguage(detected));
    }
}

test "cxx and hxx files take part in the import graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = [_][]const u8{
        "src/main.cxx",
        "src/widget.hxx",
        "src/shape.h",
        "src/notes.md",
    };
    var contents = std.StringHashMap([]const u8).init(allocator);
    try contents.put("src/main.cxx",
        \\#include "widget.hxx"
        \\#include <vector>
        \\#include "shape.h"
        \\
    );
    try contents.put("src/widget.hxx", "#pragma once\n");
    try contents.put("src/shape.h", "#pragma once\n");
    try contents.put("src/notes.md", "#include \"ignored.hxx\"\n");

    const edges = try GraphBuilder.buildImportEdgesAtRootWithContents(
        allocator,
        std.testing.io,
        "",
        &paths,
        contents,
    );

    // One edge per quoted include that names a scanned file; the angle-bracket
    // include and the markdown file contribute nothing.
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqualStrings("src/main.cxx", edges[0].from_file);
    try std.testing.expectEqualStrings("src/widget.hxx", edges[0].to_file);
    try std.testing.expectEqualStrings("src/shape.h", edges[1].to_file);
}

test "local std file does not become a graph edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = [_][]const u8{ "src/main.zig", "src/std.zig" };
    var contents = std.StringHashMap([]const u8).init(allocator);
    try contents.put("src/main.zig", "const std = @import(\"std\");\nconst local = @import(\"std.zig\");\n");
    try contents.put("src/std.zig", "pub const version = 1;\n");

    const edges = try GraphBuilder.buildImportEdgesAtRootWithContents(
        allocator,
        std.testing.io,
        "",
        &paths,
        contents,
    );
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/std.zig", edges[0].to_file);
}

test "python relative imports produce edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = [_][]const u8{
        "pkg/__init__.py",
        "pkg/sub/__init__.py",
        "pkg/sub/deep.py",
        "pkg/sub/sibling.py",
    };
    var contents = std.StringHashMap([]const u8).init(allocator);
    try contents.put("pkg/sub/deep.py",
        \\from .sibling import helper
        \\from .. import top
        \\import os
        \\
    );
    try contents.put("pkg/sub/sibling.py", "def helper():\n    pass\n");
    try contents.put("pkg/__init__.py", "");
    try contents.put("pkg/sub/__init__.py", "");

    const edges = try GraphBuilder.buildImportEdgesAtRootWithContents(
        allocator,
        std.testing.io,
        "",
        &paths,
        contents,
    );
    // Two relative imports resolve; "os" is stdlib and stays out of the graph.
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqualStrings("pkg/sub/deep.py", edges[0].from_file);
    try std.testing.expectEqualStrings("pkg/sub/sibling.py", edges[0].to_file);
    try std.testing.expectEqualStrings("pkg/__init__.py", edges[1].to_file);
}
