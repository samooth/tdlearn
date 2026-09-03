const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Adaptive module boundary detection.
///
/// Extract module name from a path using directory depth:
///   - Depth-3 when ≥3 directory levels exist (fine-grained sub-modules)
///   - Depth-2 when exactly 2 directory levels exist
///   - Parent directory for files under non-dominant dirs
///   - File stem for root-level files or files under dominant dirs (src, lib)
///
/// Examples (scanned from project root):
///   "src/layout/types.zig"          → "src/layout"
///   "src/layout/algo/squarify.zig"  → "src/layout/algo"
///   "src/main.zig"                  → "src/main"
///   "analysis/scanner.zig"          → "analysis"
///   "db.zig"                        → "db"
pub fn moduleOf(path: []const u8) []const u8 {
    // Find the first '/' to detect depth
    const first_sep = indexOf(path, '/') orelse return stripExtension(path);

    // Find second '/' to determine if we have depth >= 2
    const rest1 = path[first_sep + 1 ..];
    const second_sep = indexOf(rest1, '/') orelse {
        // Only one separator: depth-1
        return moduleOfSingleDir(path, first_sep);
    };

    const depth2_end = first_sep + 1 + second_sep;
    return moduleOfDeep(path, depth2_end);
}

/// Check if two file paths belong to the same module boundary.
pub fn isSameModule(path_a: []const u8, path_b: []const u8) bool {
    return mem.eql(u8, moduleOf(path_a), moduleOf(path_b));
}

/// Strip file extension, returning the stem.
/// Ensures the dot is after the last '/' to avoid stripping directory dots.
pub fn stripExtension(path: []const u8) []const u8 {
    const last_sep = if (indexOf(path, '/')) |i| i + 1 else 0;
    const stem = path[last_sep..];
    if (lastIndexOf(stem, '.')) |dot| {
        return path[0 .. last_sep + dot];
    }
    return path;
}

/// Get file extension (without the dot), or empty string if none.
pub fn extension(path: []const u8) []const u8 {
    const last_sep = if (indexOf(path, '/')) |i| i + 1 else 0;
    const stem = path[last_sep..];
    if (lastIndexOf(stem, '.')) |dot| {
        return stem[dot + 1 ..];
    }
    return "";
}

/// Get the file name (last path component).
pub fn fileName(path: []const u8) []const u8 {
    if (lastIndexOf(path, '/')) |sep| {
        return path[sep + 1 ..];
    }
    return path;
}

/// Get the parent directory of a path.
pub fn parentDir(path: []const u8) ?[]const u8 {
    if (lastIndexOf(path, '/')) |sep| {
        return path[0..sep];
    }
    return null;
}

/// Count the number of '/' separators in a path.
pub fn depth(path: []const u8) u32 {
    var count: u32 = 0;
    for (path) |c| {
        if (c == '/') count += 1;
    }
    return count;
}

// ── Internal helpers ──────────────────────────────────────────

fn moduleOfDeep(path: []const u8, depth2_end: usize) []const u8 {
    const after_depth2 = path[depth2_end + 1 ..];
    if (indexOf(after_depth2, '/')) |j| {
        return path[0 .. depth2_end + 1 + j];
    }
    return path[0..depth2_end];
}

fn moduleOfSingleDir(path: []const u8, first_sep: usize) []const u8 {
    const parent = path[0..first_sep];
    if (isDominantDir(parent)) {
        // "src/main.zig" → "src/main"
        if (lastIndexOf(path, '.')) |dot| {
            if (dot > first_sep) return path[0..dot];
        }
        return path;
    }
    return parent;
}

/// Directories that are "dominant" — flat files underneath get per-file modules.
pub fn isDominantDir(dir: []const u8) bool {
    const dominant_dirs = [_][]const u8{
        "src", "lib",      "app", "pkg", "cmd",
        "bin", "internal", "pkg",
    };
    for (dominant_dirs) |d| {
        if (mem.eql(u8, dir, d)) return true;
    }
    return false;
}

/// Find index of first occurrence of byte in slice.
fn indexOf(slice: []const u8, byte: u8) ?usize {
    for (slice, 0..) |c, i| {
        if (c == byte) return i;
    }
    return null;
}

/// Find index of last occurrence of byte in slice.
fn lastIndexOf(slice: []const u8, byte: u8) ?usize {
    var i: usize = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == byte) return i;
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────

test "depth_2_grouping" {
    try std.testing.expectEqualStrings("src/layout", moduleOf("src/layout/types.zig"));
    try std.testing.expectEqualStrings("frontend/components", moduleOf("frontend/components/btn.js"));
}

test "depth_3_grouping" {
    try std.testing.expectEqualStrings("src/layout/algo", moduleOf("src/layout/algo/squarify.zig"));
    try std.testing.expectEqualStrings("src/metrics/arch", moduleOf("src/metrics/arch/graph.zig"));
    // Deeper nesting still caps at depth-3
    try std.testing.expectEqualStrings("a/b/c", moduleOf("a/b/c/d/e.zig"));
}

test "dominant_dir_flat_files" {
    try std.testing.expectEqualStrings("src/main", moduleOf("src/main.zig"));
    try std.testing.expectEqualStrings("src/settings", moduleOf("src/settings.zig"));
    try std.testing.expectEqualStrings("lib/utils", moduleOf("lib/utils.zig"));
}

test "non_dominant_dir_groups_by_parent" {
    try std.testing.expectEqualStrings("analysis", moduleOf("analysis/scanner.zig"));
    try std.testing.expectEqualStrings("analysis", moduleOf("analysis/parser.zig"));
    try std.testing.expectEqualStrings("metrics", moduleOf("metrics/arch.zig"));
    try std.testing.expectEqualStrings("core", moduleOf("core/types.zig"));
}

test "root_level_files" {
    try std.testing.expectEqualStrings("db", moduleOf("db.zig"));
    try std.testing.expectEqualStrings("main", moduleOf("main.zig"));
}

test "strip_extension" {
    try std.testing.expectEqualStrings("src/main", stripExtension("src/main.zig"));
    try std.testing.expectEqualStrings("foo.bar", stripExtension("foo.bar.baz"));
    try std.testing.expectEqualStrings("noext", stripExtension("noext"));
}

test "extension" {
    try std.testing.expectEqualStrings("zig", extension("main.zig"));
    try std.testing.expectEqualStrings("toml", extension("config.toml"));
    try std.testing.expectEqualStrings("", extension("Makefile"));
}

test "file_name" {
    try std.testing.expectEqualStrings("main.zig", fileName("src/main.zig"));
    try std.testing.expectEqualStrings("types.zig", fileName("a/b/c/types.zig"));
}

test "parent_dir" {
    try std.testing.expectEqualStrings("src/main.zig" ++ "", (parentDir("src/main.zig/foo") orelse ""));
    try std.testing.expect(parentDir("main.zig") == null);
}

test "is_same_module" {
    try std.testing.expect(isSameModule("src/metrics/arch/graph.zig", "src/metrics/arch/tests.zig"));
    try std.testing.expect(!isSameModule("src/metrics/arch/graph.zig", "src/metrics/evo/mod.zig"));
    try std.testing.expect(isSameModule("analysis/scanner.zig", "analysis/parser.zig"));
    try std.testing.expect(!isSameModule("analysis/scanner.zig", "metrics/arch.zig"));
}

test "depth counting" {
    try std.testing.expectEqual(@as(u32, 0), depth("main.zig"));
    try std.testing.expectEqual(@as(u32, 1), depth("src/main.zig"));
    try std.testing.expectEqual(@as(u32, 2), depth("src/layout/types.zig"));
    try std.testing.expectEqual(@as(u32, 3), depth("a/b/c/d.zig"));
}
