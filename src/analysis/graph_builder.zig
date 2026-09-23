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
                if (resolver.resolve(raw, path)) |target| {
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
    pub fn detectLangForFile(path: []const u8) []const u8 {
        return detectLangFor(path);
    }

    fn detectLangFor(path: []const u8) []const u8 {
        // Uses the shared registry logic without allocating a registry instance:
        // extension + known-filename mapping mirrors lang_registry.
        const name = core.path_utils.fileName(path);
        const known = [_]struct { n: []const u8, l: []const u8 }{
            .{ .n = "build.zig.zon", .l = "zig" },
        };
        for (known) |k| {
            if (std.mem.eql(u8, name, k.n)) return k.l;
        }
        const ext = core.path_utils.extension(path);
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
        };
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
