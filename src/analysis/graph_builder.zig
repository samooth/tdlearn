const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("core");
const imports_mod = @import("imports.zig");
const lang_registry = @import("lang_registry.zig");
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
        var edges = std.ArrayList(core.types.ImportEdge).empty;
        errdefer edges.deinit(allocator);

        var resolver = try resolver_mod.Resolver.init(allocator, file_paths);
        defer resolver.deinit();

        for (file_paths) |path| {
            const lang = detectLangFor(path);
            if (std.mem.eql(u8, lang, "unknown")) continue;

            const contents = (readFile(allocator, io, path) catch null) orelse continue;
            const raw_imports = try imports_mod.ImportExtractor.extract(allocator, contents, lang);

            for (raw_imports) |raw| {
                if (resolver.resolve(raw, path)) |target| {
                    if (std.mem.eql(u8, target, path)) continue; // skip self-import
                    const edge = core.types.ImportEdge{
                        .from_file = path,
                        .to_file = target,
                    };
                    if (!containsEdge(edges.items, edge)) {
                        try edges.append(allocator, edge);
                    }
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

    fn readFile(allocator: Allocator, io: Io, path: []const u8) !?[]const u8 {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);

        const stat = file.stat(io) catch return null;
        if (stat.size == 0 or stat.size > 2 * 1024 * 1024) return null; // skip empty / >2MB

        const buf = try allocator.alloc(u8, @intCast(stat.size));
        const bytes_read = file.readPositionalAll(io, buf, 0) catch {
            allocator.free(buf);
            return null;
        };
        return buf[0..bytes_read];
    }

    fn containsEdge(edges: []const core.types.ImportEdge, target: core.types.ImportEdge) bool {
        for (edges) |edge| {
            if (std.mem.eql(u8, edge.from_file, target.from_file) and
                std.mem.eql(u8, edge.to_file, target.to_file))
            {
                return true;
            }
        }
        return false;
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
