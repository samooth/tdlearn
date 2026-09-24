const std = @import("std");
const Allocator = std.mem.Allocator;

const Extension = struct { ext: []const u8, lang: []const u8 };
const Filename = struct { name: []const u8, lang: []const u8 };

const extension_entries = [_]Extension{
    .{ .ext = "zig", .lang = "zig" },
    .{ .ext = "zon", .lang = "zig" },
    .{ .ext = "rs", .lang = "rust" },
    .{ .ext = "py", .lang = "python" },
    .{ .ext = "pyi", .lang = "python" },
    .{ .ext = "js", .lang = "javascript" },
    .{ .ext = "jsx", .lang = "javascript" },
    .{ .ext = "mjs", .lang = "javascript" },
    .{ .ext = "ts", .lang = "typescript" },
    .{ .ext = "tsx", .lang = "typescript" },
    .{ .ext = "mts", .lang = "typescript" },
    .{ .ext = "c", .lang = "c" },
    .{ .ext = "h", .lang = "c" },
    .{ .ext = "cpp", .lang = "cpp" },
    .{ .ext = "hpp", .lang = "cpp" },
    .{ .ext = "cc", .lang = "cpp" },
    .{ .ext = "cxx", .lang = "cpp" },
    .{ .ext = "hxx", .lang = "cpp" },
    .{ .ext = "cs", .lang = "c_sharp" },
    .{ .ext = "java", .lang = "java" },
    .{ .ext = "kt", .lang = "kotlin" },
    .{ .ext = "kts", .lang = "kotlin" },
    .{ .ext = "scala", .lang = "scala" },
    .{ .ext = "go", .lang = "go" },
    .{ .ext = "swift", .lang = "swift" },
    .{ .ext = "rb", .lang = "ruby" },
    .{ .ext = "erb", .lang = "ruby" },
    .{ .ext = "php", .lang = "php" },
    .{ .ext = "ex", .lang = "elixir" },
    .{ .ext = "exs", .lang = "elixir" },
    .{ .ext = "erl", .lang = "erlang" },
    .{ .ext = "hrl", .lang = "erlang" },
    .{ .ext = "hs", .lang = "haskell" },
    .{ .ext = "lua", .lang = "lua" },
    .{ .ext = "pl", .lang = "perl" },
    .{ .ext = "pm", .lang = "perl" },
    .{ .ext = "sh", .lang = "bash" },
    .{ .ext = "bash", .lang = "bash" },
    .{ .ext = "zsh", .lang = "bash" },
    .{ .ext = "html", .lang = "html" },
    .{ .ext = "htm", .lang = "html" },
    .{ .ext = "css", .lang = "css" },
    .{ .ext = "scss", .lang = "scss" },
    .{ .ext = "sass", .lang = "scss" },
    .{ .ext = "less", .lang = "css" },
    .{ .ext = "json", .lang = "json" },
    .{ .ext = "yaml", .lang = "yaml" },
    .{ .ext = "yml", .lang = "yaml" },
    .{ .ext = "toml", .lang = "toml" },
    .{ .ext = "xml", .lang = "xml" },
    .{ .ext = "csv", .lang = "csv" },
    .{ .ext = "ini", .lang = "ini" },
    .{ .ext = "env", .lang = "dotenv" },
    .{ .ext = "md", .lang = "markdown" },
    .{ .ext = "rst", .lang = "markdown" },
    .{ .ext = "txt", .lang = "text" },
    .{ .ext = "makefile", .lang = "makefile" },
    .{ .ext = "cmake", .lang = "cmake" },
    .{ .ext = "sql", .lang = "sql" },
    .{ .ext = "proto", .lang = "protobuf" },
    .{ .ext = "dockerfile", .lang = "dockerfile" },
    .{ .ext = "nix", .lang = "nix" },
    .{ .ext = "dart", .lang = "dart" },
    .{ .ext = "jl", .lang = "julia" },
    .{ .ext = "r", .lang = "r" },
    .{ .ext = "R", .lang = "r" },
    .{ .ext = "nim", .lang = "nim" },
    .{ .ext = "cr", .lang = "crystal" },
    .{ .ext = "v", .lang = "v" },
    .{ .ext = "ml", .lang = "ocaml" },
    .{ .ext = "mli", .lang = "ocaml" },
    .{ .ext = "fs", .lang = "f_sharp" },
    .{ .ext = "fsi", .lang = "f_sharp" },
    .{ .ext = "clj", .lang = "clojure" },
    .{ .ext = "cljs", .lang = "clojure" },
    .{ .ext = "groovy", .lang = "groovy" },
    .{ .ext = "sol", .lang = "solidity" },
    .{ .ext = "gd", .lang = "gdscript" },
    .{ .ext = "glsl", .lang = "glsl" },
    .{ .ext = "vert", .lang = "glsl" },
    .{ .ext = "frag", .lang = "glsl" },
    .{ .ext = "hcl", .lang = "hcl" },
    .{ .ext = "tf", .lang = "hcl" },
    .{ .ext = "vue", .lang = "vue" },
    .{ .ext = "svelte", .lang = "svelte" },
    .{ .ext = "m", .lang = "objectivec" },
    .{ .ext = "mm", .lang = "objectivec" },
    .{ .ext = "pas", .lang = "pascal" },
    .{ .ext = "pp", .lang = "pascal" },
    .{ .ext = "asm", .lang = "assembly" },
    .{ .ext = "s", .lang = "assembly" },
    .{ .ext = "cob", .lang = "cobol" },
    .{ .ext = "ps1", .lang = "powershell" },
};

const filename_entries = [_]Filename{
    .{ .name = "Makefile", .lang = "makefile" },
    .{ .name = "Dockerfile", .lang = "dockerfile" },
    .{ .name = "Gemfile", .lang = "ruby" },
    .{ .name = "Rakefile", .lang = "ruby" },
    .{ .name = "CMakeLists.txt", .lang = "cmake" },
    .{ .name = "Cargo.toml", .lang = "toml" },
    .{ .name = "build.zig", .lang = "zig" },
    .{ .name = "build.zig.zon", .lang = "zig" },
    .{ .name = "Justfile", .lang = "just" },
};

/// Language detection from file extensions.
/// Maps extensions to language names for display, coloring, and metric thresholds.
/// No tree-sitter integration yet — pure string matching.
pub const LangRegistry = struct {
    map: std.StringHashMap([]const u8),
    filename_map: std.StringHashMap([]const u8),
    allocator: Allocator,

    /// Create a new registry with all known language mappings.
    pub fn init(allocator: Allocator) !LangRegistry {
        var map = std.StringHashMap([]const u8).init(allocator);
        errdefer map.deinit();

        var filename_map = std.StringHashMap([]const u8).init(allocator);
        errdefer filename_map.deinit();

        for (extension_entries) |entry| {
            _ = try map.put(entry.ext, entry.lang);
        }

        for (filename_entries) |entry| {
            _ = try filename_map.put(entry.name, entry.lang);
        }

        return .{
            .map = map,
            .filename_map = filename_map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LangRegistry) void {
        self.map.deinit();
        self.filename_map.deinit();
    }

    /// Detect language from file extension.
    /// Returns "unknown" if not recognized.
    pub fn detectFromExt(self: *const LangRegistry, ext: []const u8) []const u8 {
        return self.map.get(ext) orelse "unknown";
    }

    /// Detect language from filename (for extensionless files like Makefile).
    /// Returns null if not a known filename.
    pub fn detectFromFilename(self: *const LangRegistry, filename: []const u8) ?[]const u8 {
        return self.filename_map.get(filename);
    }

    /// Detect language from a full path.
    /// Tries filename first (for Makefile, Dockerfile), then extension.
    pub fn detectLang(self: *const LangRegistry, path: []const u8) []const u8 {
        const filename = lastPathComponent(path);
        // Try filename-based detection first
        if (self.detectFromFilename(filename)) |lang| {
            return lang;
        }
        // Try extension-based detection
        if (extensionOf(path)) |ext| {
            return self.detectFromExt(ext);
        }
        return "unknown";
    }

    /// Check if a file extension is a known source code extension.
    pub fn isSourceFile(self: *const LangRegistry, path: []const u8) bool {
        const lang = self.detectLang(path);
        return !std.mem.eql(u8, lang, "unknown") and
            !std.mem.eql(u8, lang, "text") and
            !std.mem.eql(u8, lang, "json") and
            !std.mem.eql(u8, lang, "yaml") and
            !std.mem.eql(u8, lang, "toml") and
            !std.mem.eql(u8, lang, "xml") and
            !std.mem.eql(u8, lang, "csv") and
            !std.mem.eql(u8, lang, "ini") and
            !std.mem.eql(u8, lang, "dotenv");
    }

    /// Check if a directory should be excluded from scanning.
    pub fn isExcludedDir(dir_name: []const u8) bool {
        const excluded = [_][]const u8{
            ".git",         ".hg",         ".svn",
            "node_modules", "__pycache__", ".pytest_cache",
            "target",       "build",       "dist",
            ".zig-cache",   "zig-out",     ".cargo",
            ".gradle",      ".maven",      "vendor",
            ".bundle",      "Pods",        ".terraform",
            ".vagrant",     "elm-stuff",   ".tox",
            "coverage",     ".nyc_output", "__snapshots__",
            ".DS_Store",
        };
        for (excluded) |d| {
            if (std.mem.eql(u8, dir_name, d)) return true;
        }
        return false;
    }

    // ── Helpers ──

    fn lastPathComponent(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            return path[sep + 1 ..];
        }
        return path;
    }

    fn extensionOf(path: []const u8) ?[]const u8 {
        const filename = lastPathComponent(path);
        if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot| {
            if (dot + 1 < filename.len) {
                return filename[dot + 1 ..];
            }
        }
        return null;
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "detect rust file" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqualStrings("rust", reg.detectLang("src/main.rs"));
    try std.testing.expectEqualStrings("rust", reg.detectLang("lib/foo.rs"));
}

test "detect zig file" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqualStrings("zig", reg.detectLang("src/main.zig"));
    try std.testing.expectEqualStrings("zig", reg.detectLang("build.zig.zon"));
}

test "detect typescript" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqualStrings("typescript", reg.detectLang("src/app.ts"));
    try std.testing.expectEqualStrings("typescript", reg.detectLang("src/app.tsx"));
}

test "detect from filename" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqualStrings("makefile", reg.detectLang("Makefile"));
    try std.testing.expectEqualStrings("dockerfile", reg.detectLang("Dockerfile"));
    try std.testing.expectEqualStrings("ruby", reg.detectLang("Gemfile"));
}

test "unknown extension" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqualStrings("unknown", reg.detectLang("file.xyz123"));
}

test "is_source_file" {
    var reg = try LangRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.isSourceFile("main.zig"));
    try std.testing.expect(reg.isSourceFile("lib.rs"));
    try std.testing.expect(!reg.isSourceFile("data.json"));
    try std.testing.expect(!reg.isSourceFile("readme.txt"));
}

test "is_excluded_dir" {
    try std.testing.expect(LangRegistry.isExcludedDir(".git"));
    try std.testing.expect(LangRegistry.isExcludedDir("node_modules"));
    try std.testing.expect(LangRegistry.isExcludedDir("__pycache__"));
    try std.testing.expect(!LangRegistry.isExcludedDir("src"));
    try std.testing.expect(!LangRegistry.isExcludedDir("lib"));
}
