const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("core");
const lang_registry = @import("lang_registry.zig");

const WalkEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

fn walkEntryLessThan(_: void, left: WalkEntry, right: WalkEntry) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

/// File system walker that builds a FileNode tree.
///
/// Usage:
///   var walker = try Walker.init(allocator, io, "/path/to/project");
///   defer walker.deinit();
///   const tree = try walker.walk();
///   // tree is a slice of FileNode with directory nesting
pub const Walker = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    root_path: []const u8,
    registry: lang_registry.LangRegistry,
    settings: core.settings.Settings,

    /// Live allocator — must be computed on demand (arena is self-referential;
    /// capturing `arena.allocator()` at init would dangle after struct copy).
    pub fn allocator(self: *Walker) Allocator {
        return self.arena.allocator();
    }

    pub fn init(parent_allocator: Allocator, io: Io, root_path: []const u8) !Walker {
        return initWithSettings(parent_allocator, io, root_path, .{});
    }

    pub fn initWithSettings(
        parent_allocator: Allocator,
        io: Io,
        root_path: []const u8,
        settings: core.settings.Settings,
    ) !Walker {
        var sanitized = settings;
        sanitized.sanitize();
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = io,
            .root_path = root_path,
            .registry = try lang_registry.LangRegistry.init(parent_allocator),
            .settings = sanitized,
        };
    }

    pub fn deinit(self: *Walker) void {
        self.registry.deinit();
        self.arena.deinit();
    }

    /// Walk the filesystem and build a flat list of FileNodes.
    pub fn walk(self: *Walker) ![]core.types.FileNode {
        var files: std.ArrayList(core.types.FileNode) = .empty;
        // Normalize root: "." or "./" → "" so paths come out as "src/main.zig", not "./src/main.zig"
        var root = self.root_path;
        while (std.mem.startsWith(u8, root, "./") or std.mem.startsWith(u8, root, ".\\")) root = root[2..];
        if (std.mem.eql(u8, root, ".")) root = "";
        try self.walkDir(if (root.len == 0) "." else root, &files);

        try normalizePaths(self.allocator(), files.items, self.root_path);
        return try files.toOwnedSlice(self.allocator());
    }

    fn normalizePaths(alloc: Allocator, files: []core.types.FileNode, root: []const u8) !void {
        const normalized_root = normalizeRoot(root);
        for (files) |*node| {
            node.path = try core.path_utils.canonicalRelative(alloc, relativePath(node.path, normalized_root));
            if (node.children) |children| try normalizePaths(alloc, children, normalized_root);
        }
    }

    fn normalizeRoot(root: []const u8) []const u8 {
        var result = root;
        while (std.mem.startsWith(u8, result, "./") or std.mem.startsWith(u8, result, ".\\")) result = result[2..];
        if (std.mem.eql(u8, result, ".")) return "";
        while (result.len > 1 and (result[result.len - 1] == '/' or result[result.len - 1] == '\\')) {
            result = result[0 .. result.len - 1];
        }
        return result;
    }

    fn relativePath(path: []const u8, root: []const u8) []const u8 {
        var result = path;
        while (std.mem.startsWith(u8, result, "./") or std.mem.startsWith(u8, result, ".\\")) result = result[2..];
        if (root.len == 0) return result;
        if ((std.mem.eql(u8, root, "/") or std.mem.eql(u8, root, "\\")) and
            result.len > 1 and (result[0] == '/' or result[0] == '\\')) return result[1..];
        if (result.len > root.len and
            std.mem.startsWith(u8, result, root) and
            (result[root.len] == '/' or result[root.len] == '\\'))
        {
            return result[root.len + 1 ..];
        }
        return result;
    }

    fn walkDir(self: *Walker, dir_path: []const u8, files: *std.ArrayList(core.types.FileNode)) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{
            .iterate = true,
        });
        defer dir.close(self.io);

        var entries = std.ArrayList(WalkEntry).empty;
        defer entries.deinit(self.allocator());
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            try entries.append(self.allocator(), .{
                .name = try self.allocator().dupe(u8, entry.name),
                .kind = entry.kind,
            });
        }
        std.sort.heap(WalkEntry, entries.items, {}, walkEntryLessThan);

        for (entries.items) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (entry.kind == .directory and lang_registry.LangRegistry.isExcludedDir(entry.name)) {
                continue;
            }

            const full_path = try std.fs.path.join(self.allocator(), &.{ dir_path, entry.name });
            defer self.allocator().free(full_path);

            const path_copy = try self.allocator().dupe(u8, full_path);
            const name_copy = entry.name;

            if (entry.kind == .directory) {
                // Recurse into subdirectory
                var child_files: std.ArrayList(core.types.FileNode) = .empty;
                errdefer {
                    for (child_files.items) |*node| {
                        if (node.children) |children| {
                            self.allocator().free(children);
                        }
                    }
                    child_files.deinit(self.allocator());
                }

                try self.walkDir(full_path, &child_files);

                const mtime: i64 = blk: {
                    const stat = dir.statFile(self.io, entry.name, .{}) catch break :blk @as(i64, 0);
                    break :blk @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
                };

                try files.append(self.allocator(), .{
                    .path = path_copy,
                    .name = name_copy,
                    .is_dir = true,
                    .mtime = mtime,
                    .lang = "",
                    .children = try child_files.toOwnedSlice(self.allocator()),
                });
            } else if (entry.kind == .file) {
                // Count lines
                const line_counts = try self.countLines(full_path);

                const lang = self.registry.detectLang(name_copy);

                try files.append(self.allocator(), .{
                    .path = path_copy,
                    .name = name_copy,
                    .is_dir = false,
                    .lines = line_counts.total,
                    .logic = line_counts.code,
                    .comments = line_counts.comments,
                    .blanks = line_counts.blanks,
                    .lang = lang,
                });
            }
        }
    }

    const LineCounts = struct {
        total: u32 = 0,
        code: u32 = 0,
        comments: u32 = 0,
        blanks: u32 = 0,
    };

    /// Count lines in a file: total, code, comments, blanks.
    /// Uses simple heuristic: blank lines have only whitespace, comment lines
    /// start with // or # or /* or --.
    fn countLines(self: *Walker, file_path: []const u8) !LineCounts {
        const file = try std.Io.Dir.cwd().openFile(self.io, file_path, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const max_bytes = self.settings.max_file_size_kb * 1024;
        if (stat.size > max_bytes) return error.FileTooLarge;
        if (stat.size == 0) return LineCounts{};

        const buf_size: usize = @intCast(stat.size);
        const buf = try self.allocator().alloc(u8, buf_size);
        defer self.allocator().free(buf);

        const bytes_read = try file.readPositionalAll(self.io, buf, 0);
        const contents = buf[0..bytes_read];

        var total: u32 = 0;
        var code: u32 = 0;
        var comments: u32 = 0;
        var blanks: u32 = 0;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            total += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) {
                blanks += 1;
            } else if (isCommentLine(trimmed)) {
                comments += 1;
            } else {
                code += 1;
            }
        }

        return .{
            .total = total,
            .code = code,
            .comments = comments,
            .blanks = blanks,
        };
    }

    fn isCommentLine(line: []const u8) bool {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        // Single-line comments
        if (std.mem.startsWith(u8, trimmed, "//")) return true;
        if (std.mem.startsWith(u8, trimmed, "#")) return true;
        if (std.mem.startsWith(u8, trimmed, "--")) return true;
        if (std.mem.startsWith(u8, trimmed, ";")) return true;
        if (std.mem.startsWith(u8, trimmed, "%")) return true;
        if (std.mem.startsWith(u8, trimmed, "'''")) return true;
        if (std.mem.startsWith(u8, trimmed, "\"\"\"")) return true;
        // Block comment start (count as comment line)
        if (std.mem.startsWith(u8, trimmed, "/*")) return true;
        if (std.mem.startsWith(u8, trimmed, "<!--")) return true;
        if (std.mem.startsWith(u8, trimmed, "{-")) return true;
        return false;
    }

    /// Get total line count across all files.
    pub fn totalLines(files: []const core.types.FileNode) u32 {
        var total: u32 = 0;
        for (files) |file| {
            if (!file.is_dir) {
                total += file.lines;
            }
            if (file.children) |children| {
                total += totalLines(children);
            }
        }
        return total;
    }

    /// Count source files (non-directory, non-excluded).
    pub fn countSourceFiles(files: []const core.types.FileNode) u32 {
        var count: u32 = 0;
        for (files) |file| {
            if (!file.is_dir) {
                count += 1;
            }
            if (file.children) |children| {
                count += countSourceFiles(children);
            }
        }
        return count;
    }

    /// Flatten the tree into a list of all source file paths (directories excluded).
    pub fn flattenFiles(files: []const core.types.FileNode, alloc: Allocator) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer result.deinit(alloc);
        try collectPathsStandalone(files, &result, alloc);
        return try result.toOwnedSlice(alloc);
    }

    fn collectPathsStandalone(files: []const core.types.FileNode, result: *std.ArrayList([]const u8), alloc: Allocator) !void {
        for (files) |file| {
            if (!file.is_dir) {
                try result.append(alloc, file.path);
            }
            if (file.children) |children| {
                try collectPathsStandalone(children, result, alloc);
            }
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "normalizes paths relative to scan root" {
    try std.testing.expectEqualStrings("src/main.zig", Walker.relativePath("/project/src/main.zig", "/project"));
    try std.testing.expectEqualStrings("src/main.zig", Walker.relativePath("project/src/main.zig", "project"));
    try std.testing.expectEqualStrings("src/main.zig", Walker.relativePath("./src/main.zig", ""));
    try std.testing.expectEqualStrings("tmp/main.zig", Walker.relativePath("/tmp/main.zig", "/"));
}

test "normalizes filesystem paths to canonical relative paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var nodes = [_]core.types.FileNode{
        .{ .path = "./src\\layout\\..\\main.zig", .name = "main.zig", .is_dir = false },
    };
    try Walker.normalizePaths(arena.allocator(), &nodes, "");
    try std.testing.expectEqualStrings("src/main.zig", nodes[0].path);
}

test "walk entries sort by name" {
    var entries = [_]WalkEntry{
        .{ .name = "z.zig", .kind = .file },
        .{ .name = "a.zig", .kind = .file },
        .{ .name = "m.zig", .kind = .file },
    };
    std.sort.heap(WalkEntry, &entries, {}, walkEntryLessThan);
    try std.testing.expectEqualStrings("a.zig", entries[0].name);
    try std.testing.expectEqualStrings("m.zig", entries[1].name);
    try std.testing.expectEqualStrings("z.zig", entries[2].name);
}

test "isCommentLine" {
    try std.testing.expect(Walker.isCommentLine("// this is a comment"));
    try std.testing.expect(Walker.isCommentLine("# python comment"));
    try std.testing.expect(Walker.isCommentLine("-- sql comment"));
    try std.testing.expect(Walker.isCommentLine("/* block start"));
    try std.testing.expect(Walker.isCommentLine("  // indented comment"));
    try std.testing.expect(!Walker.isCommentLine("let x = 1;"));
    try std.testing.expect(!Walker.isCommentLine("fn main() {}"));
    try std.testing.expect(!Walker.isCommentLine(""));
}

test "LineCounts for empty file" {
    // countLines returns defaults for missing files
    const counts = Walker.LineCounts{};
    try std.testing.expectEqual(@as(u32, 0), counts.total);
}

test "totalLines empty" {
    const files = [_]core.types.FileNode{};
    try std.testing.expectEqual(@as(u32, 0), Walker.totalLines(&files));
}

test "countSourceFiles empty" {
    const files = [_]core.types.FileNode{};
    try std.testing.expectEqual(@as(u32, 0), Walker.countSourceFiles(&files));
}
