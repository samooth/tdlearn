const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const manifests = @import("manifests.zig");

/// Resolve raw import strings to file paths (ImportEdge).
///
/// Strategy (in order):
///   1. Relative paths (start with ./ or ../): resolve against importing file's dir
///   2. Package aliases (from Cargo.toml/package.json): `tdlearn_core::analysis`
///      → `tdlearn-core/src/lib.rs` dir + `analysis`
///   3. Exact path match with extension appended (.zig, .rs, .py, .js, .ts, .go, .c, .h)
///   4. Suffix index: "core/types" matches "src/core/types.zig" (any prefix)
///
/// Standard libraries ("std", "fmt", "os", external URLs) resolve to nothing.
pub const Resolver = struct {
    /// Map from file path (relative to root) → index in the file list.
    path_index: std.StringHashMap(usize),
    /// Map from module suffix → file index. "core/types" → src/core/types.zig
    /// Also registers package-index files: "core" → src/core/mod.rs
    suffix_index: std.StringHashMap(usize),
    ambiguous_suffixes: std.StringHashMap(void),
    /// Package-name aliases: crate/package name → root source file path.
    alias_index: std.StringHashMap([]const u8),
    /// All known file paths (borrowed).
    file_paths: []const []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, file_paths: []const []const u8) !Resolver {
        return initWithAliases(allocator, file_paths, &.{});
    }

    pub fn initWithAliases(
        allocator: Allocator,
        file_paths: []const []const u8,
        aliases: []const manifests.Alias,
    ) !Resolver {
        var path_index = std.StringHashMap(usize).init(allocator);
        errdefer path_index.deinit();
        var suffix_index = std.StringHashMap(usize).init(allocator);
        errdefer suffix_index.deinit();
        var ambiguous_suffixes = std.StringHashMap(void).init(allocator);
        errdefer ambiguous_suffixes.deinit();
        var alias_index = std.StringHashMap([]const u8).init(allocator);
        errdefer alias_index.deinit();

        for (file_paths, 0..) |path, i| {
            try path_index.put(path, i);

            // Register every suffix of the path (extension-stripped),
            // cutting leading components: "src/core/types.zig" →
            //   "src/core/types", "core/types", "types"
            const stem = stripExt(path);
            var suffix = stem;
            while (true) {
                const gop = try suffix_index.getOrPut(suffix);
                if (!gop.found_existing) {
                    gop.value_ptr.* = i;
                } else if (gop.value_ptr.* != i) {
                    try ambiguous_suffixes.put(suffix, {});
                }
                const sep = std.mem.indexOfScalar(u8, suffix, '/') orelse break;
                suffix = suffix[sep + 1 ..];
            }

            // Package-index files also register their parent directory,
            // including leading-stripped suffixes:
            // "src/parser/mod.rs" → "src/parser", "parser"
            if (isPackageIndexFile(path)) {
                if (core.path_utils.parentDir(path)) |parent| {
                    const parent_stem = stripExt(parent);
                    var parent_suffix = parent_stem;
                    while (true) {
                        const gop = try suffix_index.getOrPut(parent_suffix);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = i;
                        } else if (gop.value_ptr.* != i) {
                            try ambiguous_suffixes.put(parent_suffix, {});
                        }
                        const sep = std.mem.indexOfScalar(u8, parent_suffix, '/') orelse break;
                        parent_suffix = parent_suffix[sep + 1 ..];
                    }
                }
            }
        }

        for (aliases) |alias| {
            // Later aliases override earlier ones
            try alias_index.put(alias.name, alias.root_file);
        }

        return .{
            .path_index = path_index,
            .suffix_index = suffix_index,
            .ambiguous_suffixes = ambiguous_suffixes,
            .alias_index = alias_index,
            .file_paths = file_paths,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.path_index.deinit();
        self.suffix_index.deinit();
        self.ambiguous_suffixes.deinit();
        self.alias_index.deinit();
    }

    /// Resolve a raw import string from `from_file`.
    /// Returns the resolved file path, or null if it doesn't map to a scanned file.
    /// Caller owns nothing — returned slice points into the file list.
    /// Scratch allocations are arena-scoped per call.
    pub fn resolve(self: *const Resolver, raw: []const u8, from_file: []const u8) ?[]const u8 {
        if (raw.len == 0) return null;

        // Scratch arena for normalization buffers (freed on return)
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // 1. Relative path: ./foo or ../foo — resolve against from_file's dir
        if (raw[0] == '.' and raw.len >= 2 and (raw[1] == '/' or raw[1] == '.')) {
            const from_dir = core.path_utils.parentDir(from_file) orelse "";
            if (self.resolveRelative(sa, raw, from_dir)) |path| return path;
        }

        if (self.resolveRustRelative(sa, raw, from_file)) |path| return path;

        // 2. Normalize :: separators (Rust) to '/'
        const normalized = normalizeSeparators(sa, raw);
        if (normalized.len == 0) return null;

        // 2.5 Package alias: first path segment names a known package
        // ("tdlearn_core/analysis" → "tdlearn-core/src/lib.rs" dir + analysis)
        if (self.expandAlias(sa, normalized)) |expanded| {
            if (self.matchWithExtensions(sa, expanded)) |path| return path;
            if (self.matchSuffixChain(expanded)) |path| return path;
        }

        // 3. Exact / extension match, then suffix match on the raw module path
        if (self.matchWithExtensions(sa, normalized)) |path| return path;
        if (self.matchSuffixChain(normalized)) |path| return path;

        // 4. Dotted module paths (Python "mypkg.sub"): '.' → '/'
        if (std.mem.indexOfScalar(u8, normalized, '.') != null) {
            const buf = sa.dupe(u8, normalized) catch return null;
            for (buf) |*c| {
                if (c.* == '.') c.* = '/';
            }
            if (self.matchWithExtensions(sa, buf)) |path| return path;
            if (self.matchSuffixChain(buf)) |path| return path;
        }

        // 5. Bare module reference: resolve relative to the importing file's dir.
        // Covers Zig sibling imports: @import("lang_registry.zig") from src/analysis/walker.zig
        if (core.path_utils.parentDir(from_file)) |from_dir| {
            if (from_dir.len > 0) {
                const joined = std.mem.join(sa, "/", &.{ from_dir, normalized }) catch return null;
                if (self.matchWithExtensions(sa, joined)) |path| return path;
                // Relative to parent dir + ../: deeper-package lookups
                if (self.matchSuffixChain(joined)) |path| return path;
            }
        }

        // 6. Unresolved single identifiers are stdlib/external — return null.
        // Multi-segment paths (npm/go modules) also stay unresolved here.
        return null;
    }

    fn expandAlias(self: *const Resolver, allocator: Allocator, path: []const u8) ?[]const u8 {
        var end = path.len;
        while (end > 0) {
            if (self.alias_index.get(path[0..end])) |root_file| {
                if (end == path.len) return root_file;
                const rest = path[end + 1 ..];
                const root_dir = core.path_utils.parentDir(root_file) orelse return null;
                return std.mem.join(allocator, "/", &.{ root_dir, rest }) catch null;
            }
            const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return null;
            if (slash == 0) return null;
            end = slash;
        }
        return null;
    }

    /// Try progressively stripping leading components from the import path:
    /// "example.com/proj/internal/util" → "proj/internal/util" → "internal/util" → "util"
    fn matchSuffixChain(self: *const Resolver, path: []const u8) ?[]const u8 {
        var suffix = path;
        while (true) {
            if (self.indexedPath(suffix)) |resolved| return resolved;
            const sep = std.mem.indexOfScalar(u8, suffix, '/') orelse return null;
            suffix = suffix[sep + 1 ..];
            if (suffix.len == 0) return null;
        }
    }

    fn indexedPath(self: *const Resolver, suffix: []const u8) ?[]const u8 {
        if (self.ambiguous_suffixes.contains(suffix)) return null;
        if (self.suffix_index.get(suffix)) |idx| return self.file_paths[idx];
        return null;
    }

    fn resolveRustRelative(self: *const Resolver, sa: Allocator, raw: []const u8, from_file: []const u8) ?[]const u8 {
        const from_dir = core.path_utils.parentDir(from_file) orelse return null;
        if (std.mem.startsWith(u8, raw, "self::")) {
            const rest = raw["self::".len..];
            if (rest.len == 0) return null;
            return self.resolveRelative(sa, rest, from_dir);
        }
        if (std.mem.startsWith(u8, raw, "self/")) {
            const rest = raw["self/".len..];
            if (rest.len == 0) return null;
            return self.resolveRelative(sa, rest, from_dir);
        }
        if (std.mem.startsWith(u8, raw, "super::")) {
            const rest = raw["super::".len..];
            if (rest.len == 0) return null;
            const relative = std.mem.join(sa, "/", &.{ "..", rest }) catch return null;
            return self.resolveRelative(sa, relative, from_dir);
        }
        if (std.mem.startsWith(u8, raw, "super/")) {
            const rest = raw["super/".len..];
            if (rest.len == 0) return null;
            const relative = std.mem.join(sa, "/", &.{ "..", rest }) catch return null;
            return self.resolveRelative(sa, relative, from_dir);
        }
        return null;
    }

    fn resolveRelative(self: *const Resolver, sa: Allocator, raw: []const u8, from_dir: []const u8) ?[]const u8 {
        // raw starts with "./" or "../"
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(sa);

        if (from_dir.len > 0) {
            var iter = std.mem.splitScalar(u8, from_dir, '/');
            while (iter.next()) |p| {
                parts.append(sa, p) catch return null;
            }
        }

        var seg_iter = std.mem.splitScalar(u8, raw, '/');
        while (seg_iter.next()) |seg| {
            if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len > 0) _ = parts.pop();
                continue;
            }
            parts.append(sa, seg) catch return null;
        }

        const joined = std.mem.join(sa, "/", parts.items) catch return null;

        if (self.matchWithExtensions(sa, joined)) |path| return path;
        if (self.matchSuffixChain(joined)) |path| return path;
        if (self.indexedPath(joined)) |resolved| return resolved;
        // Relative import might reference a package dir: "./core" → "core/mod.zig"
        if (self.indexedPath(stripExt(joined))) |resolved| return resolved;
        return null;
    }

    /// Try path as-is and with source extensions appended.
    /// "core/types" matches "core/types.zig", "core/types.rs", etc.
    fn matchWithExtensions(self: *const Resolver, allocator: Allocator, path: []const u8) ?[]const u8 {
        // Exact (already has extension)
        if (self.path_index.get(path)) |idx| return self.file_paths[idx];

        const extensions = [_][]const u8{
            ".zig", ".rs", ".py", ".pyi", ".js",  ".jsx", ".mjs", ".ts",  ".tsx", ".mts",
            ".go",  ".c",  ".h",  ".cpp", ".hpp", ".cc",  ".cxx", ".hxx", ".m",   ".mm",
        };
        for (extensions) |ext| {
            const full = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, ext }) catch continue;
            defer allocator.free(full);
            if (self.path_index.get(full)) |idx| return self.file_paths[idx];
        }
        return null;
    }

    /// Normalize module separators to '/': "a::b" → "a/b", "a.b" (python-style) kept.
    fn normalizeSeparators(allocator: Allocator, raw: []const u8) []const u8 {
        // Rust "crate::" prefix → strip to project root
        var s = raw;
        if (std.mem.startsWith(u8, s, "crate::")) s = s["crate::".len..];
        if (std.mem.startsWith(u8, s, "crate/")) s = s["crate/".len..];
        if (std.mem.eql(u8, s, "self")) return "";
        if (std.mem.eql(u8, s, "super")) return "";
        if (std.mem.eql(u8, s, "crate")) return "";

        if (std.mem.indexOfScalar(u8, s, ':') == null) {
            return s; // fast path: no :: separators
        }

        // Replace :: with /
        const buf = allocator.dupe(u8, s) catch return s;
        for (buf, 0..) |c, i| {
            if (c == ':') buf[i] = '/';
        }
        // collapse "//" produced by "a::b"
        var out: usize = 0;
        for (buf, 0..) |c, i| {
            if (c == '/' and i > 0 and buf[i - 1] == '/' and out > 0 and buf[out - 1] == '/') continue;
            buf[out] = c;
            out += 1;
        }
        return buf[0..out];
    }
};

fn stripExt(path: []const u8) []const u8 {
    const stem = core.path_utils.stripExtension(path);
    return stem;
}

fn isPackageIndexFile(path: []const u8) bool {
    const name = core.path_utils.fileName(path);
    const index_names = [_][]const u8{
        "mod.rs", "__init__.py", "index.js", "index.ts", "lib.rs", "mod.zig",
    };
    for (index_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────

test "exact path resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.zig", "src/core/types.zig" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("src/core/types.zig", resolver.resolve("core/types", "src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", resolver.resolve("src/main", "src/core/types.zig").?);
}

test "long paths resolve without fixed buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const component = try allocator.alloc(u8, 600);
    @memset(component, 'a');
    const long_path = try std.fmt.allocPrint(allocator, "src/{s}.zig", .{component});
    const long_stem = try std.fmt.allocPrint(allocator, "src/{s}", .{component});
    const paths = [_][]const u8{ "src/main.zig", long_path };
    var resolver = try Resolver.init(allocator, &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(long_path, resolver.resolve(long_stem, "src/main.zig").?);
}

test "ambiguous suffixes do not resolve arbitrarily" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "src/a/types.zig",
        "src/b/types.zig",
        "src/a/core/mod.zig",
        "src/b/core/mod.zig",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect(resolver.resolve("types", "src/main.zig") == null);
    try std.testing.expectEqualStrings("src/a/types.zig", resolver.resolve("a/types", "src/main.zig").?);
    try std.testing.expect(resolver.resolve("core", "src/main.zig") == null);
    try std.testing.expectEqualStrings("src/a/core/mod.zig", resolver.resolve("a/core", "src/main.zig").?);
}

test "relative resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/core/mod.zig", "src/core/types.zig", "src/main.zig" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    // ./types from src/core/mod.zig → src/core/types.zig
    try std.testing.expectEqualStrings(
        "src/core/types.zig",
        resolver.resolve("./types", "src/core/mod.zig").?,
    );
    // ../core/types from src/main.zig → src/core/types.zig
    try std.testing.expectEqualStrings(
        "src/core/types.zig",
        resolver.resolve("../core/types", "src/main.zig").?,
    );
}

test "relative resolution supports additional extensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.ts", "lib/tool.mjs", "include/widget.hpp" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        "lib/tool.mjs",
        resolver.resolve("../lib/tool", "src/main.ts").?,
    );
    try std.testing.expectEqualStrings(
        "include/widget.hpp",
        resolver.resolve("../include/widget", "src/main.ts").?,
    );
}

test "rust self and super prefixes resolve relatively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "src/parser/mod.rs",
        "src/parser/helper.rs",
        "src/helper.rs",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        "src/parser/helper.rs",
        resolver.resolve("self::helper", "src/parser/mod.rs").?,
    );
    try std.testing.expectEqualStrings(
        "src/helper.rs",
        resolver.resolve("super::helper", "src/parser/mod.rs").?,
    );
}

test "rust crate prefix stripped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.rs", "src/parser/mod.rs" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        "src/parser/mod.rs",
        resolver.resolve("crate::parser", "src/main.rs").?,
    );
    try std.testing.expect(resolver.resolve("crate::", "src/main.rs") == null);
}

test "stdlib returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{"src/main.zig"};
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect(resolver.resolve("std", "src/main.zig") == null);
    try std.testing.expect(resolver.resolve("os", "app.py") == null);
    try std.testing.expect(resolver.resolve("fmt", "main.go") == null);
    try std.testing.expect(resolver.resolve("stdio.h", "main.c") == null);
}

test "package index files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.rs", "src/parser/mod.rs" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    // "parser" should resolve to src/parser/mod.rs
    try std.testing.expectEqualStrings(
        "src/parser/mod.rs",
        resolver.resolve("parser", "src/main.rs").?,
    );
}

test "go dotted module import via suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "main.go", "internal/util.go" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    // Go: import "example.com/project/internal/util" — suffix match
    try std.testing.expectEqualStrings(
        "internal/util.go",
        resolver.resolve("example.com/project/internal/util", "main.go").?,
    );
}

test "python from-import resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "app.py", "mypkg/sub.py" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("mypkg/sub.py", resolver.resolve("mypkg.sub", "app.py").?);
}

test "package aliases resolve roots and subpaths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "crates/core/src/lib.rs",
        "crates/core/src/analysis.rs",
        "packages/left-pad/lib/main.js",
        "packages/left-pad/lib/sub.js",
        "vendor/acme/pkg/src/lib.rs",
        "vendor/acme/pkg/src/feature.rs",
    };
    const aliases = [_]manifests.Alias{
        .{ .name = "tdlearn_core", .root_file = paths[0] },
        .{ .name = "left-pad", .root_file = paths[2] },
        .{ .name = "@acme/pkg", .root_file = paths[4] },
    };
    var resolver = try Resolver.initWithAliases(arena.allocator(), &paths, &aliases);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        paths[0],
        resolver.resolve("tdlearn_core", "app.rs").?,
    );
    try std.testing.expectEqualStrings(
        paths[1],
        resolver.resolve("tdlearn_core::analysis", "app.rs").?,
    );
    try std.testing.expectEqualStrings(
        paths[3],
        resolver.resolve("left-pad/sub", "app.js").?,
    );
    try std.testing.expectEqualStrings(
        paths[5],
        resolver.resolve("@acme/pkg/feature", "app.ts").?,
    );
}

test "unknown import returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{"src/main.zig"};
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect(resolver.resolve("nonexistent/module", "src/main.zig") == null);
    try std.testing.expect(resolver.resolve("left-pad", "app.js") == null);
}
