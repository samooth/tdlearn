const std = @import("std");

// ═══════════════════════════════════════════════════════════════
// File node — represents a file or directory in the project tree
// ═══════════════════════════════════════════════════════════════

pub const FileNode = struct {
    /// Relative path from scan root (e.g. "src/layout/types.zig")
    path: []const u8,
    /// File or directory name (last path component)
    name: []const u8,
    /// True if this node represents a directory
    is_dir: bool,
    /// Total line count (code + comments + blanks)
    lines: u32 = 0,
    /// Lines of executable logic (excludes comments and blanks)
    logic: u32 = 0,
    /// Comment line count
    comments: u32 = 0,
    /// Blank line count
    blanks: u32 = 0,
    /// Number of functions/methods detected by the parser
    funcs: u32 = 0,
    /// Last modification time as Unix epoch seconds
    mtime: i64 = 0,
    /// Git status: .added, .modified, .deleted, .untracked, .none
    git_status: GitStatus = .none,
    /// Detected programming language (e.g. "rust", "typescript")
    lang: []const u8 = "",
    /// Structural analysis results if file was parsed
    structural_analysis: ?StructuralAnalysis = null,
    /// Child nodes (only present for directories)
    children: ?[]FileNode = null,
};

pub const GitStatus = enum {
    none,
    added,
    modified,
    deleted,
    untracked,
    renamed,
    copied,
};

// ═══════════════════════════════════════════════════════════════
// Structural analysis — results for a single parsed file
// ═══════════════════════════════════════════════════════════════

pub const StructuralAnalysis = struct {
    /// Detected functions with line ranges and complexity
    functions: ?[]FuncInfo = null,
    /// Detected classes, interfaces, and type definitions
    classes: ?[]ClassInfo = null,
    /// Import/require targets extracted from source
    imports: ?[]ImportTarget = null,
    /// Call-site identifiers detected in the file
    call_sites: ?[]CallSite = null,
    /// Semantic tags for classification (e.g. "test", "config", "entry")
    tags: ?[]Tag = null,
    /// Comment line count from tree-sitter AST (internal, not serialized)
    comment_lines: u32 = 0,
};

pub const Tag = enum {
    test_file,
    config,
    entry,
    benchmark,
    example,
    generated,
    vendored,
};

// ═══════════════════════════════════════════════════════════════
// Function info — a single function or method
// ═══════════════════════════════════════════════════════════════

pub const FuncInfo = struct {
    /// Function name
    name: []const u8,
    /// Start line (1-based)
    start_line: u32,
    /// End line (1-based)
    end_line: u32,
    /// Line count (end_line - start_line + 1)
    line_count: u32,
    /// Cyclomatic complexity (extended: includes boolean operators)
    cyclomatic_complexity: ?u32 = null,
    /// Cognitive complexity (SonarSource 2016): nesting-weighted branch count
    cognitive_complexity: ?u32 = null,
    /// Parameter count (excluding self/this)
    param_count: ?u32 = null,
    /// Body hash for duplication detection
    body_hash: ?u64 = null,
    /// Whether this function is publicly visible (pub/export/public)
    is_public: bool = false,
    /// Whether this function is a method (has self/this parameter)
    is_method: bool = false,
};

// ═══════════════════════════════════════════════════════════════
// Class info — a class, interface, or type definition
// ═══════════════════════════════════════════════════════════════

pub const ClassInfo = struct {
    /// Class/interface/type name
    name: []const u8,
    /// Method names defined in this class
    methods: ?[]MethodSummary = null,
    /// Base classes / parent types (for inheritance graph)
    bases: ?[][]const u8 = null,
    /// Kind: .class, .interface, .type, .struct, .enum, .trait
    kind: ClassKind = .class,
};

pub const ClassKind = enum {
    class,
    interface,
    type,
    struct_kind,
    enum_kind,
    trait,
};

pub const MethodSummary = struct {
    name: []const u8,
    is_public: bool = false,
};

// ═══════════════════════════════════════════════════════════════
// Import and call targets
// ═══════════════════════════════════════════════════════════════

pub const ImportTarget = struct {
    /// Raw import string from source (e.g. "std.fs", "./helper", "react")
    raw: []const u8,
    /// Resolved file path (if resolution succeeded)
    resolved_path: ?[]const u8 = null,
    /// Import kind: .direct, .relative, .package, .standard_lib
    kind: ImportKind = .direct,
};

pub const ImportKind = enum {
    direct,
    relative,
    package,
    standard_lib,
};

pub const CallSite = struct {
    /// Caller function name
    caller: []const u8,
    /// Callee function or symbol name
    callee: []const u8,
    /// Line number of the call site
    line: u32,
};

/// Functions extracted from one file, paired with the file path and its
/// full contents — the shared input format for call-graph building and
/// dead-code analysis.
pub const FileFuncs = struct {
    file: []const u8,
    contents: []const u8,
    funcs: []const FuncInfo,
};

// ═══════════════════════════════════════════════════════════════
// Graph edge types — dependency relationships between files
// ═══════════════════════════════════════════════════════════════

/// Generic graph edge (from → to) used by metrics algorithms.
pub const GraphEdge = struct {
    from: usize,
    to: usize,
};

pub const ImportEdge = struct {
    from_file: []const u8,
    to_file: []const u8,
};

pub const CallEdge = struct {
    from_file: []const u8,
    from_func: []const u8,
    to_file: []const u8,
    to_func: []const u8,
};

pub const InheritEdge = struct {
    child_file: []const u8,
    child_class: []const u8,
    parent_file: []const u8,
    parent_class: []const u8,
};

// ═══════════════════════════════════════════════════════════════
// Entry points — detected application entry points
// ═══════════════════════════════════════════════════════════════

pub const EntryPoint = struct {
    file: []const u8,
    func: []const u8,
    lang: []const u8,
    confidence: Confidence,
};

pub const Confidence = enum {
    high,
    low,
};

// ═══════════════════════════════════════════════════════════════
// File index — cached O(1) lookup metadata
// ═══════════════════════════════════════════════════════════════

pub const FileIndexEntry = struct {
    lines: u32,
    logic: u32,
    funcs: u32,
    lang: []const u8,
    git_status: GitStatus,
    mtime: i64,
};

// ═══════════════════════════════════════════════════════════════
// Error types
// ═══════════════════════════════════════════════════════════════

pub const ScanError = error{
    IoError,
    PathError,
    ParseError,
    OutOfMemory,
    InvalidUtf8,
};

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

test "FileNode default values" {
    const node = FileNode{
        .path = "src/main.zig",
        .name = "main.zig",
        .is_dir = false,
    };
    try std.testing.expectEqual(@as(u32, 0), node.lines);
    try std.testing.expectEqual(@as(u32, 0), node.logic);
    try std.testing.expect(!node.is_dir);
    try std.testing.expectEqualStrings("", node.lang);
}

test "GitStatus enum values" {
    try std.testing.expectEqual(GitStatus.none, .none);
    try std.testing.expectEqual(GitStatus.added, .added);
    try std.testing.expectEqual(GitStatus.modified, .modified);
}

test "ImportEdge stores paths" {
    const edge = ImportEdge{
        .from_file = "src/main.zig",
        .to_file = "src/core/types.zig",
    };
    try std.testing.expectEqualStrings("src/main.zig", edge.from_file);
    try std.testing.expectEqualStrings("src/core/types.zig", edge.to_file);
}

test "FuncInfo defaults" {
    const func = FuncInfo{
        .name = "main",
        .start_line = 1,
        .end_line = 10,
        .line_count = 10,
    };
    try std.testing.expectEqual(@as(?u32, null), func.cyclomatic_complexity);
    try std.testing.expect(!func.is_public);
    try std.testing.expect(!func.is_method);
}
