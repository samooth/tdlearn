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
    try std.testing.expectEqual(@as(?u32, null), func.cognitive_complexity);
    try std.testing.expectEqual(@as(?u32, null), func.param_count);
    try std.testing.expect(!func.is_public);
    try std.testing.expect(!func.is_method);
}

test "ClassInfo defaults" {
    const class = ClassInfo{ .name = "Shape" };
    try std.testing.expectEqualStrings("Shape", class.name);
    try std.testing.expectEqual(@as(?[][]const u8, null), class.bases);
    try std.testing.expectEqual(ClassKind.class, class.kind);
}
