const std = @import("std");
const Allocator = std.mem.Allocator;

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

        // Register all known extensions
        const extensions = [_]struct { ext: []const u8, lang: []const u8 }{
            // Zig
            .{ .ext = "zig", .lang = "zig" },
            .{ .ext = "zon", .lang = "zig" },
            // Rust
            .{ .ext = "rs", .lang = "rust" },
            // Python
            .{ .ext = "py", .lang = "python" },
            .{ .ext = "pyi", .lang = "python" },
            // JavaScript / TypeScript
            .{ .ext = "js", .lang = "javascript" },
            .{ .ext = "jsx", .lang = "javascript" },
            .{ .ext = "mjs", .lang = "javascript" },
            .{ .ext = "ts", .lang = "typescript" },
            .{ .ext = "tsx", .lang = "typescript" },
            .{ .ext = "mts", .lang = "typescript" },
            // C / C++
            .{ .ext = "c", .lang = "c" },
            .{ .ext = "h", .lang = "c" },
            .{ .ext = "cpp", .lang = "cpp" },
            .{ .ext = "hpp", .lang = "cpp" },
            .{ .ext = "cc", .lang = "cpp" },
            .{ .ext = "cxx", .lang = "cpp" },
            .{ .ext = "hxx", .lang = "cpp" },
            // C#
            .{ .ext = "cs", .lang = "c_sharp" },
            // Java
            .{ .ext = "java", .lang = "java" },
            .{ .ext = "kt", .lang = "kotlin" },
            .{ .ext = "kts", .lang = "kotlin" },
            .{ .ext = "scala", .lang = "scala" },
            // Go
            .{ .ext = "go", .lang = "go" },
            // Swift
            .{ .ext = "swift", .lang = "swift" },
            // Ruby
            .{ .ext = "rb", .lang = "ruby" },
            .{ .ext = "erb", .lang = "ruby" },
            // PHP
            .{ .ext = "php", .lang = "php" },
            // Elixir
            .{ .ext = "ex", .lang = "elixir" },
            .{ .ext = "exs", .lang = "elixir" },
            // Erlang
            .{ .ext = "erl", .lang = "erlang" },
            .{ .ext = "hrl", .lang = "erlang" },
            // Haskell
            .{ .ext = "hs", .lang = "haskell" },
            // Lua
            .{ .ext = "lua", .lang = "lua" },
            // Perl
            .{ .ext = "pl", .lang = "perl" },
            .{ .ext = "pm", .lang = "perl" },
            // Shell
            .{ .ext = "sh", .lang = "bash" },
            .{ .ext = "bash", .lang = "bash" },
            .{ .ext = "zsh", .lang = "bash" },
            // Web
            .{ .ext = "html", .lang = "html" },
            .{ .ext = "htm", .lang = "html" },
            .{ .ext = "css", .lang = "css" },
            .{ .ext = "scss", .lang = "scss" },
            .{ .ext = "sass", .lang = "scss" },
            .{ .ext = "less", .lang = "css" },
            // Data
            .{ .ext = "json", .lang = "json" },
            .{ .ext = "yaml", .lang = "yaml" },
            .{ .ext = "yml", .lang = "yaml" },
            .{ .ext = "toml", .lang = "toml" },
            .{ .ext = "xml", .lang = "xml" },
            .{ .ext = "csv", .lang = "csv" },
            // Config
            .{ .ext = "ini", .lang = "ini" },
            .{ .ext = "env", .lang = "dotenv" },
            // Docs
            .{ .ext = "md", .lang = "markdown" },
            .{ .ext = "rst", .lang = "markdown" },
            .{ .ext = "txt", .lang = "text" },
            // Build
            .{ .ext = "makefile", .lang = "makefile" },
            .{ .ext = "cmake", .lang = "cmake" },
            // SQL
            .{ .ext = "sql", .lang = "sql" },
            // Protobuf
            .{ .ext = "proto", .lang = "protobuf" },
            // Docker
            .{ .ext = "dockerfile", .lang = "dockerfile" },
            // Nix
            .{ .ext = "nix", .lang = "nix" },
            // Dart
            .{ .ext = "dart", .lang = "dart" },
            // Julia
            .{ .ext = "jl", .lang = "julia" },
            // R
            .{ .ext = "r", .lang = "r" },
            .{ .ext = "R", .lang = "r" },
            // Nim
            .{ .ext = "nim", .lang = "nim" },
            // Crystal
            .{ .ext = "cr", .lang = "crystal" },
            // V
            .{ .ext = "v", .lang = "v" },
            // OCaml
            .{ .ext = "ml", .lang = "ocaml" },
            .{ .ext = "mli", .lang = "ocaml" },
            // F#
            .{ .ext = "fs", .lang = "f_sharp" },
            .{ .ext = "fsi", .lang = "f_sharp" },
            // Clojure
            .{ .ext = "clj", .lang = "clojure" },
            .{ .ext = "cljs", .lang = "clojure" },
            // Groovy
            .{ .ext = "groovy", .lang = "groovy" },
            // Solidity
            .{ .ext = "sol", .lang = "solidity" },
            // GDScript
            .{ .ext = "gd", .lang = "gdscript" },
            // GLSL
            .{ .ext = "glsl", .lang = "glsl" },
            .{ .ext = "vert", .lang = "glsl" },
            .{ .ext = "frag", .lang = "glsl" },
            // HCL
            .{ .ext = "hcl", .lang = "hcl" },
            .{ .ext = "tf", .lang = "hcl" },
            // Vue
            .{ .ext = "vue", .lang = "vue" },
            // Svelte
            .{ .ext = "svelte", .lang = "svelte" },
            // Objective-C
            .{ .ext = "m", .lang = "objectivec" },
            .{ .ext = "mm", .lang = "objectivec" },
            // Pascal
            .{ .ext = "pas", .lang = "pascal" },
            .{ .ext = "pp", .lang = "pascal" },
            // Assembly
            .{ .ext = "asm", .lang = "assembly" },
            .{ .ext = "s", .lang = "assembly" },
            // COBOL
            .{ .ext = "cob", .lang = "cobol" },
            // PowerShell
            .{ .ext = "ps1", .lang = "powershell" },
        };

        for (extensions) |entry| {
            _ = try map.put(entry.ext, entry.lang);
        }

        // Register filename-based detection (no extension)
        const filenames = [_]struct { name: []const u8, lang: []const u8 }{
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

        for (filenames) |entry| {
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
