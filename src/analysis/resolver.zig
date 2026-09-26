const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const manifests = @import("manifests.zig");

/// Resolve raw import strings to file paths (ImportEdge).
///
/// Strategy (in order):
///   1. Rust `self::` / `super::` and Python dotted relatives (".mod", "..pkg"),
///      resolved against the importing file's dir
///   2. Path-relative "./foo" / "../foo", resolved against the importing file's dir
///   3. Package aliases (from Cargo.toml/package.json): `tdlearn_core::analysis`
///      → `tdlearn-core/src/lib.rs` dir + `analysis`
///   4. Standard-library guard: a bare `std`, `std::…`, `fmt`, `os`… never
///      resolves, so a project-local `std.zig` / `std.rs` does not steal
///      `@import("std")` / `use std::…`
///   5. Exact path match with extension appended (.zig, .rs, .py, .js, .ts, .go, .c, .h)
///   6. Suffix index: "core/types" matches "src/core/types.zig" (any prefix)
///
/// Standard libraries and external URLs resolve to nothing.
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
    ///
    /// The steps run in a fixed order and the standard-library guard sits in the
    /// middle of it, so the phases are split around that guard rather than
    /// around the syntax: the relative forms and package aliases must resolve
    /// first (so "./std.zig" and "crate::core" still work), and everything after
    /// the guard is unreachable for a bare stdlib name.
    pub fn resolve(self: *const Resolver, raw: []const u8, from_file: []const u8) !?[]const u8 {
        if (raw.len == 0) return null;

        // Scratch arena for normalization buffers (freed on return)
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const normalized_from = try normalizeSlashes(sa, from_file);

        // Language-specific relative forms: "self::x", "super::x", ".mod".
        // Tried before normalization because they are not paths yet.
        if (try self.resolveRustRelative(sa, raw, normalized_from)) |path| return path;
        if (try self.resolveDotRelative(sa, raw, normalized_from)) |path| return path;

        const normalized = try normalizeSeparators(sa, raw);
        if (normalized.len == 0) return null;

        if (try self.resolveDeclaredPaths(sa, normalized, normalized_from)) |path| return path;

        // The standard-library guard is terminal, not a filter: a bare stdlib
        // module reference never resolves to a scanned file.
        if (isStdlibImport(raw, normalized_from)) return null;

        // Exact / extension match, then suffix match on the raw module path.
        if (try self.matchWithExtensions(sa, normalized)) |path| return path;
        if (self.matchSuffixChain(normalized)) |path| return path;

        if (try self.resolveModuleForms(sa, normalized, normalized_from)) |path| return path;

        // An unresolved single identifier is the standard library or an external
        // package; a multi-segment path is an npm or go module. Neither becomes
        // an edge: inventing a dependency is worse than missing one.
        return null;
    }

    /// An import that names a location: a relative path or a package alias.
    fn resolveDeclaredPaths(
        self: *const Resolver,
        sa: Allocator,
        normalized: []const u8,
        normalized_from: []const u8,
    ) !?[]const u8 {
        // Relative path: ./foo or ../foo — resolve against from_file's dir
        if (isDotPath(normalized)) {
            const from_dir = core.path_utils.parentDir(normalized_from) orelse "";
            if (try self.resolveRelative(sa, normalized, from_dir)) |path| return path;
        }

        // Package alias: the first path segment names a known package
        // ("tdlearn_core/analysis" → "tdlearn-core/src/lib.rs" dir + analysis)
        if (try self.expandAlias(sa, normalized)) |expanded| {
            if (try self.matchWithExtensions(sa, expanded)) |path| return path;
            if (self.matchSuffixChain(expanded)) |path| return path;
        }
        return null;
    }

    /// An import that names a module rather than a location: the dotted form and
    /// the bare sibling reference.
    fn resolveModuleForms(
        self: *const Resolver,
        sa: Allocator,
        normalized: []const u8,
        normalized_from: []const u8,
    ) !?[]const u8 {
        // Dotted module paths (Python "mypkg.sub"): '.' → '/'
        if (std.mem.indexOfScalar(u8, normalized, '.') != null) {
            const buf = try sa.dupe(u8, normalized);
            for (buf) |*c| {
                if (c.* == '.') c.* = '/';
            }
            if (try self.matchWithExtensions(sa, buf)) |path| return path;
            if (self.matchSuffixChain(buf)) |path| return path;
        }

        // Bare module reference: resolve relative to the importing file's dir.
        // Covers Zig sibling imports: @import("lang_registry.zig") from
        // src/analysis/walker.zig
        const from_dir = core.path_utils.parentDir(normalized_from) orelse return null;
        if (from_dir.len == 0) return null;
        const joined = try std.mem.join(sa, "/", &.{ from_dir, normalized });
        if (try self.matchWithExtensions(sa, joined)) |path| return path;
        // Relative to parent dir + ../: deeper-package lookups
        if (self.matchSuffixChain(joined)) |path| return path;
        return null;
    }

    fn normalizeSlashes(allocator: Allocator, raw: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        const normalized = try allocator.dupe(u8, raw);
        for (normalized, 0..) |character, index| {
            if (character == '\\') normalized[index] = '/';
        }
        return normalized;
    }

    fn expandAlias(self: *const Resolver, allocator: Allocator, path: []const u8) !?[]const u8 {
        var end = path.len;
        while (end > 0) {
            if (self.alias_index.get(path[0..end])) |root_file| {
                if (end == path.len) return root_file;
                const rest = path[end + 1 ..];
                const root_dir = core.path_utils.parentDir(root_file) orelse return null;
                return try std.mem.join(allocator, "/", &.{ root_dir, rest });
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

    fn resolveRustRelative(self: *const Resolver, sa: Allocator, raw: []const u8, from_file: []const u8) !?[]const u8 {
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
            const relative = try std.mem.join(sa, "/", &.{ "..", rest });
            return self.resolveRelative(sa, relative, from_dir);
        }
        if (std.mem.startsWith(u8, raw, "super/")) {
            const rest = raw["super/".len..];
            if (rest.len == 0) return null;
            const relative = try std.mem.join(sa, "/", &.{ "..", rest });
            return self.resolveRelative(sa, relative, from_dir);
        }
        return null;
    }

    /// Python-style relative module: leading dots walk up the package tree and
    /// the rest is a dotted module path. `.helpers` → ./helpers,
    /// `..pkg.mod` → ../pkg/mod, `.` → the importing file's own package dir.
    /// Path-relative forms ("./x", "../x") are rejected so the generic
    /// relative branch keeps handling them.
    fn resolveDotRelative(self: *const Resolver, sa: Allocator, raw: []const u8, from_file: []const u8) !?[]const u8 {
        if (raw.len == 0 or raw[0] != '.') return null;
        var dots: usize = 0;
        while (dots < raw.len and raw[dots] == '.') : (dots += 1) {}
        if (dots == 0) return null;
        const rest = raw[dots..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '.')) return null;

        const from_dir = core.path_utils.parentDir(from_file) orelse return null;
        const module = if (std.mem.indexOfScalar(u8, rest, '.')) |_| blk: {
            const dotted = try sa.dupe(u8, rest);
            for (dotted) |*c| {
                if (c.* == '.') c.* = '/';
            }
            break :blk dotted;
        } else rest;

        // One leading dot is "this package": dots-1 parent hops, then the module.
        var relative = std.ArrayList(u8).empty;
        defer relative.deinit(sa);
        var hop: usize = 1;
        while (hop < dots) : (hop += 1) try relative.appendSlice(sa, "../");
        try relative.appendSlice(sa, module);
        return self.resolveRelative(sa, relative.items, from_dir);
    }

    fn resolveRelative(self: *const Resolver, sa: Allocator, raw: []const u8, from_dir: []const u8) !?[]const u8 {
        // raw starts with "./" or "../" (resolveDotRelative may omit the "./")
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(sa);

        if (from_dir.len > 0) {
            var iter = std.mem.splitScalar(u8, from_dir, '/');
            while (iter.next()) |p| {
                try parts.append(sa, p);
            }
        }

        var seg_iter = std.mem.splitScalar(u8, raw, '/');
        while (seg_iter.next()) |seg| {
            if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len > 0) _ = parts.pop();
                continue;
            }
            try parts.append(sa, seg);
        }

        const joined = try std.mem.join(sa, "/", parts.items);

        if (try self.matchWithExtensions(sa, joined)) |path| return path;
        if (self.matchSuffixChain(joined)) |path| return path;
        if (self.indexedPath(joined)) |resolved| return resolved;
        // Relative import might reference a package dir: "./core" → "core/mod.zig"
        if (self.indexedPath(stripExt(joined))) |resolved| return resolved;
        return null;
    }

    /// Try path as-is and with source extensions appended.
    /// "core/types" matches "core/types.zig", "core/types.rs", etc.
    fn matchWithExtensions(self: *const Resolver, allocator: Allocator, path: []const u8) !?[]const u8 {
        // Exact (already has extension)
        if (self.path_index.get(path)) |idx| return self.file_paths[idx];

        for (source_extensions) |ext| {
            const full = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, ext }) catch |err| return err;
            defer allocator.free(full);
            if (self.path_index.get(full)) |idx| return self.file_paths[idx];
        }
        return null;
    }

    /// Normalize module separators to '/': "a::b" → "a/b", "a.b" (python-style) kept.
    fn normalizeSeparators(allocator: Allocator, raw: []const u8) ![]const u8 {
        // Rust "crate::" prefix → strip to project root
        var s = raw;
        if (std.mem.startsWith(u8, s, "crate::")) s = s["crate::".len..];
        if (std.mem.startsWith(u8, s, "crate/")) s = s["crate/".len..];
        if (std.mem.eql(u8, s, "self")) return "";
        if (std.mem.eql(u8, s, "super")) return "";
        if (std.mem.eql(u8, s, "crate")) return "";

        if (std.mem.indexOfScalar(u8, s, ':') == null and
            std.mem.indexOfScalar(u8, s, '\\') == null)
        {
            return s;
        }

        const buf = try allocator.dupe(u8, s);
        for (buf, 0..) |c, i| {
            if (c == ':' or c == '\\') buf[i] = '/';
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

/// True for a path that explicitly walks into or up the tree: `./foo` or
/// `../foo`. A bare `.` or a leading dot on an identifier (`.helpers`) is not a
/// path here — that form belongs to the Python branch.
fn isDotPath(normalized: []const u8) bool {
    if (normalized.len < 2 or normalized[0] != '.') return false;
    return normalized[1] == '/' or normalized[1] == '.';
}

fn stripExt(path: []const u8) []const u8 {
    const stem = core.path_utils.stripExtension(path);
    return stem;
}

fn isPackageIndexFile(path: []const u8) bool {
    return core.path_utils.isPackageIndexPath(path);
}

/// Source-file extensions tried when an import has none, in preference order.
/// Mirrors the extension set `lang_registry`/`graph_builder` know about.
const source_extensions = [_][]const u8{
    ".zig", ".rs",  ".py", ".pyi", ".js", ".jsx", ".mjs", ".ts",
    ".tsx", ".mts", ".go", ".c",   ".h",  ".cpp", ".hpp", ".cc",
    ".cxx", ".hxx", ".m",  ".mm",
};

/// Languages whose bare module names are reserved by the toolchain. Anything
/// outside this list (or outside these languages) resolves as before, so a
/// project-local `core.zig` / `mypkg/…` still matches.
const ImportLang = enum { zig, rust, python, javascript, go, other };

/// Zig: `@import("std")` is the standard library by language rule, never a
/// local `std.zig`. "builtin" is likewise reserved. Note "core" is NOT
/// reserved for Zig — it is an ordinary local module name there.
const zig_stdlib = [_][]const u8{ "std", "builtin" };

/// Rust: the four sysroot crates are always the sysroot, never a local module.
/// Local code spells itself `crate::…`, which the prefix check keeps.
const rust_stdlib = [_][]const u8{ "std", "core", "alloc", "proc_macro" };

/// Python: modules resolved by the import system before the project can shadow
/// them for non-script entry points. Importing one is treated as stdlib.
const python_stdlib = [_][]const u8{
    "abc",        "argparse",   "asyncio",   "base64",      "collections",
    "contextlib", "copy",       "csv",       "dataclasses", "datetime",
    "enum",       "functools",  "glob",      "hashlib",     "http",
    "inspect",    "io",         "itertools", "json",        "logging",
    "math",       "os",         "pathlib",   "random",      "re",
    "shutil",     "signal",     "socket",    "sqlite3",     "string",
    "struct",     "subprocess", "sys",       "tempfile",    "textwrap",
    "threading",  "time",       "traceback", "typing",      "unittest",
    "urllib",     "uuid",       "warnings",
};

/// Node builtins, shared by JavaScript and TypeScript (both import them bare).
const javascript_stdlib = [_][]const u8{
    "assert",         "buffer",      "child_process", "cluster", "console",        "crypto",
    "dgram",          "dns",         "events",        "fs",      "http",           "http2",
    "https",          "module",      "net",           "os",      "path",           "perf_hooks",
    "process",        "querystring", "readline",      "stream",  "string_decoder", "timers",
    "tls",            "tty",         "url",           "util",    "v8",             "vm",
    "worker_threads", "zlib",
};

/// Go standard-library roots; sub-packages ("os/exec", "net/http") share them.
const go_stdlib = [_][]const u8{
    "bufio",   "bytes",   "context", "crypto", "embed",   "encoding", "errors",
    "flag",    "fmt",     "hash",    "html",   "image",   "index",    "io",
    "log",     "math",    "mime",    "net",    "os",      "path",     "plugin",
    "reflect", "regexp",  "runtime", "sort",   "strconv", "strings",  "sync",
    "syscall", "testing", "text",    "time",   "unicode", "unsafe",
};

/// Extension → the standard-library list that applies to files with it.
/// TypeScript/JavaScript share one list; C/C++ have none (their includes are
/// paths, not module names).
const import_lang_extensions = [_]struct { ext: []const u8, lang: ImportLang }{
    .{ .ext = "zig", .lang = .zig },
    .{ .ext = "zon", .lang = .zig },
    .{ .ext = "rs", .lang = .rust },
    .{ .ext = "py", .lang = .python },
    .{ .ext = "pyi", .lang = .python },
    .{ .ext = "js", .lang = .javascript },
    .{ .ext = "jsx", .lang = .javascript },
    .{ .ext = "mjs", .lang = .javascript },
    .{ .ext = "ts", .lang = .javascript },
    .{ .ext = "tsx", .lang = .javascript },
    .{ .ext = "mts", .lang = .javascript },
    .{ .ext = "go", .lang = .go },
};

fn importLangOf(path: []const u8) ImportLang {
    const ext = core.path_utils.extension(path);
    for (import_lang_extensions) |entry| {
        if (std.mem.eql(u8, ext, entry.ext)) return entry.lang;
    }
    return .other;
}

/// True when `raw` is a bare standard-library reference for the language of
/// `from_file` and must stay unresolved. Imports that carry a source extension
/// ("std.zig", "local.h") are explicit paths and are never blocked.
fn isStdlibImport(raw: []const u8, from_file: []const u8) bool {
    if (hasSourceExtension(raw)) return false;
    const roots: []const []const u8 = switch (importLangOf(from_file)) {
        .zig => &zig_stdlib,
        .rust => &rust_stdlib,
        .python => &python_stdlib,
        .javascript => &javascript_stdlib,
        .go => &go_stdlib,
        .other => return false,
    };
    const root = firstSegment(raw);
    if (root.len == 0) return false;
    for (roots) |candidate| {
        if (std.mem.eql(u8, root, candidate)) return true;
    }
    return false;
}

/// First path/module segment: "std::x" → "std", "os.path" → "os",
/// "example.com/pkg" → "example".
fn firstSegment(raw: []const u8) []const u8 {
    for (raw, 0..) |character, index| {
        if (character == '/' or character == ':' or character == '.') return raw[0..index];
    }
    return raw;
}

/// True when the last component of `raw` already carries a source extension,
/// i.e. the import names a concrete file rather than a module to look up.
fn hasSourceExtension(raw: []const u8) bool {
    const name = core.path_utils.fileName(std.mem.trimEnd(u8, raw, " \t\r;"));
    for (source_extensions) |ext| {
        if (name.len > ext.len and std.mem.endsWith(u8, name, ext)) return true;
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

    try std.testing.expectEqualStrings("src/core/types.zig", (try resolver.resolve("core/types", "src/main.zig")).?);
    try std.testing.expectEqualStrings("src/main.zig", (try resolver.resolve("src/main", "src/core/types.zig")).?);
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

    try std.testing.expectEqualStrings(long_path, (try resolver.resolve(long_stem, "src/main.zig")).?);
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

    try std.testing.expect((try resolver.resolve("types", "src/main.zig")) == null);
    try std.testing.expectEqualStrings("src/a/types.zig", (try resolver.resolve("a/types", "src/main.zig")).?);
    try std.testing.expect((try resolver.resolve("core", "src/main.zig")) == null);
    try std.testing.expectEqualStrings("src/a/core/mod.zig", (try resolver.resolve("a/core", "src/main.zig")).?);
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
        (try resolver.resolve("./types", "src/core/mod.zig")).?,
    );
    // ../core/types from src/main.zig → src/core/types.zig
    try std.testing.expectEqualStrings(
        "src/core/types.zig",
        (try resolver.resolve("../core/types", "src/main.zig")).?,
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
        (try resolver.resolve("../lib/tool", "src/main.ts")).?,
    );
    try std.testing.expectEqualStrings(
        "include/widget.hpp",
        (try resolver.resolve("../include/widget", "src/main.ts")).?,
    );
}

test "native separators and unicode paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.ts", "lib/café/tool.mjs" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings(
        "lib/café/tool.mjs",
        (try resolver.resolve("..\\lib\\café\\tool", "src\\main.ts")).?,
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
        (try resolver.resolve("self::helper", "src/parser/mod.rs")).?,
    );
    try std.testing.expectEqualStrings(
        "src/helper.rs",
        (try resolver.resolve("super::helper", "src/parser/mod.rs")).?,
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
        (try resolver.resolve("crate::parser", "src/main.rs")).?,
    );
    try std.testing.expect((try resolver.resolve("crate::", "src/main.rs")) == null);
}

test "stdlib returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{"src/main.zig"};
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect((try resolver.resolve("std", "src/main.zig")) == null);
    try std.testing.expect((try resolver.resolve("os", "app.py")) == null);
    try std.testing.expect((try resolver.resolve("fmt", "main.go")) == null);
    try std.testing.expect((try resolver.resolve("stdio.h", "main.c")) == null);
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
        (try resolver.resolve("parser", "src/main.rs")).?,
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
        (try resolver.resolve("example.com/project/internal/util", "main.go")).?,
    );
}

test "python from-import resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "app.py", "mypkg/sub.py" };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("mypkg/sub.py", (try resolver.resolve("mypkg.sub", "app.py")).?);
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
        (try resolver.resolve("tdlearn_core", "app.rs")).?,
    );
    try std.testing.expectEqualStrings(
        paths[1],
        (try resolver.resolve("tdlearn_core::analysis", "app.rs")).?,
    );
    try std.testing.expectEqualStrings(
        paths[3],
        (try resolver.resolve("left-pad/sub", "app.js")).?,
    );
    try std.testing.expectEqualStrings(
        paths[5],
        (try resolver.resolve("@acme/pkg/feature", "app.ts")).?,
    );
}

test "unknown import returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{"src/main.zig"};
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect((try resolver.resolve("nonexistent/module", "src/main.zig")) == null);
    try std.testing.expect((try resolver.resolve("left-pad", "app.js")) == null);
}

test "project-local std files do not capture stdlib imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "src/main.rs",
        "src/std.rs",
        "src/std/collections.rs",
        "src/core.rs",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    // `use std::…` and bare `std` are the sysroot, never src/std.rs
    try std.testing.expect((try resolver.resolve("std", "src/main.rs")) == null);
    try std.testing.expect((try resolver.resolve("std::collections::HashMap", "src/main.rs")) == null);
    try std.testing.expect((try resolver.resolve("core::mem", "src/main.rs")) == null);
    // …but the same local file is still reachable by explicit path
    try std.testing.expectEqualStrings(
        "src/std.rs",
        (try resolver.resolve("crate::std", "src/main.rs")).?,
    );
}

test "project-local std.zig does not capture @import(\"std\")" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "src/main.zig",
        "std.zig",
        "src/std.zig",
        "src/core/mod.zig",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect((try resolver.resolve("std", "src/main.zig")) == null);
    try std.testing.expect((try resolver.resolve("std", "std.zig")) == null);
    try std.testing.expect((try resolver.resolve("builtin", "src/main.zig")) == null);
    // "core" is an ordinary local module name in Zig
    try std.testing.expectEqualStrings("src/core/mod.zig", (try resolver.resolve("core", "src/main.zig")).?);
    // An explicit file path is never treated as a stdlib reference
    try std.testing.expectEqualStrings("std.zig", (try resolver.resolve("std.zig", "src/main.zig")).?);
    try std.testing.expectEqualStrings("src/std.zig", (try resolver.resolve("./std.zig", "src/main.zig")).?);
    try std.testing.expectEqualStrings("src/std.zig", (try resolver.resolve("../std.zig", "src/core/mod.zig")).?);
}

test "stdlib names of other languages stay unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "app.py",
        "os.py",
        "main.go",
        "fmt.go",
        "internal/util.go",
        "index.ts",
        "fs.ts",
        "main.cxx",
        "widget.hxx",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    try std.testing.expect((try resolver.resolve("os", "app.py")) == null);
    try std.testing.expect((try resolver.resolve("os.path", "app.py")) == null);
    try std.testing.expect((try resolver.resolve("json", "app.py")) == null);
    try std.testing.expect((try resolver.resolve("fmt", "main.go")) == null);
    try std.testing.expect((try resolver.resolve("os/exec", "main.go")) == null);
    try std.testing.expect((try resolver.resolve("fs", "index.ts")) == null);
    // Non-stdlib modules and explicit include paths are untouched
    try std.testing.expectEqualStrings(
        "internal/util.go",
        (try resolver.resolve("example.com/proj/internal/util", "main.go")).?,
    );
    try std.testing.expectEqualStrings(
        "widget.hxx",
        (try resolver.resolve("widget.hxx", "main.cxx")).?,
    );
}

test "python relative imports resolve inside the package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{
        "app.py",
        "os.py",
        "pkg/__init__.py",
        "pkg/other.py",
        "pkg/sub/__init__.py",
        "pkg/sub/deep.py",
        "pkg/sub/sibling.py",
    };
    var resolver = try Resolver.init(arena.allocator(), &paths);
    defer resolver.deinit();

    // from .sibling import x
    try std.testing.expectEqualStrings(
        "pkg/sub/sibling.py",
        (try resolver.resolve(".sibling", "pkg/sub/deep.py")).?,
    );
    // from ..other import x
    try std.testing.expectEqualStrings(
        "pkg/other.py",
        (try resolver.resolve("..other", "pkg/sub/deep.py")).?,
    );
    // from .sub.sibling import x — dotted module after the dot
    try std.testing.expectEqualStrings(
        "pkg/sub/sibling.py",
        (try resolver.resolve(".sub.sibling", "pkg/other.py")).?,
    );
    // from . import x → the package itself
    try std.testing.expectEqualStrings(
        "pkg/sub/__init__.py",
        (try resolver.resolve(".", "pkg/sub/deep.py")).?,
    );
    // from .. import x → the parent package
    try std.testing.expectEqualStrings(
        "pkg/__init__.py",
        (try resolver.resolve("..", "pkg/sub/deep.py")).?,
    );
    // A top-level module has no package dir, and stdlib names stay blocked.
    try std.testing.expect((try resolver.resolve(".helper", "app.py")) == null);
    try std.testing.expect((try resolver.resolve("os", "app.py")) == null);
    // Path-relative forms keep their own meaning.
    try std.testing.expectEqualStrings(
        "pkg/other.py",
        (try resolver.resolve("../other.py", "pkg/sub/deep.py")).?,
    );
}

test "stdlib guard helpers" {
    // Explicit source extensions are never stdlib references.
    try std.testing.expect(hasSourceExtension("std.zig"));
    try std.testing.expect(hasSourceExtension("dir/local.h"));
    try std.testing.expect(!hasSourceExtension("std"));
    try std.testing.expect(!hasSourceExtension("mod"));
    try std.testing.expect(!hasSourceExtension("os.path"));

    try std.testing.expectEqualStrings("std", firstSegment("std::mem"));
    try std.testing.expectEqualStrings("os", firstSegment("os.path"));
    try std.testing.expectEqualStrings("example", firstSegment("example.com/pkg"));
    try std.testing.expectEqualStrings("@scope", firstSegment("@scope/pkg"));
}
