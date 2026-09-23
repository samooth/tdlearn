const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// Immutable scan result — a snapshot of the codebase at a point in time.
///
/// Contains all three dependency graphs (import, call, inherit) plus
/// the file tree and computed metrics. Thread-safe for concurrent reads.
///
/// Create via `Snapshot.scan()` or `Snapshot.fromFiles()`.
pub const Snapshot = struct {
    /// All scanned files
    files: []types.FileNode,
    /// Import/require dependency edges
    import_edges: []types.ImportEdge,
    /// Function call edges between files
    call_edges: []types.CallEdge,
    /// Inheritance/implementation edges
    inherit_edges: []types.InheritEdge,
    /// Detected entry points
    entry_points: []types.EntryPoint,
    /// File index for O(1) lookup
    file_index: std.StringHashMap(types.FileIndexEntry),
    /// Number of files scanned
    file_count: u32,
    /// Number of import edges
    import_edge_count: u32,
    /// Number of call edges
    call_edge_count: u32,
    /// Number of inherit edges
    inherit_edge_count: u32,
    /// Root path of the scan
    root_path: []const u8,
    /// Timestamp of when this snapshot was created
    timestamp: i64,
    /// Allocator used (for deinit)
    allocator: Allocator,

    /// Create a new snapshot from scanned files and graphs.
    pub fn init(
        allocator: Allocator,
        io: std.Io,
        root_path: []const u8,
        files: []types.FileNode,
        import_edges: []types.ImportEdge,
        call_edges: []types.CallEdge,
        inherit_edges: []types.InheritEdge,
        entry_points: []types.EntryPoint,
    ) !Snapshot {
        // Build file index
        var file_index = std.StringHashMap(types.FileIndexEntry).init(allocator);
        errdefer file_index.deinit();

        for (files) |*file| {
            if (!file.is_dir) {
                if (file_index.contains(file.path)) return error.DuplicateNode;
                try file_index.put(file.path, .{
                    .lines = file.lines,
                    .logic = file.logic,
                    .funcs = file.funcs,
                    .lang = file.lang,
                    .git_status = file.git_status,
                    .mtime = file.mtime,
                });
            }
        }

        return .{
            .files = files,
            .import_edges = import_edges,
            .call_edges = call_edges,
            .inherit_edges = inherit_edges,
            .entry_points = entry_points,
            .file_index = file_index,
            .file_count = std.math.cast(u32, files.len) orelse return error.IntegerOverflow,
            .import_edge_count = std.math.cast(u32, import_edges.len) orelse return error.IntegerOverflow,
            .call_edge_count = std.math.cast(u32, call_edges.len) orelse return error.IntegerOverflow,
            .inherit_edge_count = std.math.cast(u32, inherit_edges.len) orelse return error.IntegerOverflow,
            .root_path = root_path,
            .timestamp = blk: {
                const ts = std.Io.Clock.Timestamp.now(io, .real);
                break :blk @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
            },
            .allocator = allocator,
        };
    }

    /// Look up file metadata by path. Returns null if not found.
    pub fn getFile(self: *const Snapshot, path: []const u8) ?types.FileIndexEntry {
        return self.file_index.get(path);
    }

    /// Get all files that import from a given file (fan-in).
    /// The returned slice is owned by `allocator`.
    pub fn fanIn(self: *const Snapshot, allocator: Allocator, path: []const u8) ![]const types.ImportEdge {
        var result = std.ArrayList(types.ImportEdge).empty;
        errdefer result.deinit(allocator);
        for (self.import_edges) |edge| {
            if (std.mem.eql(u8, edge.to_file, path)) try result.append(allocator, edge);
        }
        return try result.toOwnedSlice(allocator);
    }

    /// Get all files that a given file imports (fan-out).
    /// The returned slice is owned by `allocator`.
    pub fn fanOut(self: *const Snapshot, allocator: Allocator, path: []const u8) ![]const types.ImportEdge {
        var result = std.ArrayList(types.ImportEdge).empty;
        errdefer result.deinit(allocator);
        for (self.import_edges) |edge| {
            if (std.mem.eql(u8, edge.from_file, path)) try result.append(allocator, edge);
        }
        return try result.toOwnedSlice(allocator);
    }

    /// Get the number of files in the snapshot.
    pub fn fileCount(self: *const Snapshot) u32 {
        return self.file_count;
    }

    /// Get the number of import edges.
    pub fn importEdgeCount(self: *const Snapshot) u32 {
        return self.import_edge_count;
    }

    /// Free all resources owned by this snapshot.
    pub fn deinit(self: *Snapshot) void {
        self.file_index.deinit();
        // Note: files and edges are allocated by the caller or scanner
        // The caller is responsible for freeing those arrays
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "Snapshot init and file lookup" {
    const allocator = std.testing.allocator;

    const files = try allocator.alloc(types.FileNode, 2);
    defer allocator.free(files);
    files[0] = .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false };
    files[1] = .{ .path = "src/lib.zig", .name = "lib.zig", .is_dir = false };

    var snap = try Snapshot.init(
        allocator,
        std.testing.io,
        ".",
        files,
        &.{},
        &.{},
        &.{},
        &.{},
    );
    defer snap.deinit();

    try std.testing.expectEqual(@as(u32, 2), snap.fileCount());
    try std.testing.expectEqual(@as(u32, 0), snap.importEdgeCount());

    const entry = snap.getFile("src/main.zig");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("", entry.?.lang); // not detected without a walker
    try std.testing.expectEqual(@as(u32, 0), entry.?.lines);
}

test "Snapshot with import edges" {
    const allocator = std.testing.allocator;

    const files = try allocator.alloc(types.FileNode, 2);
    defer allocator.free(files);
    files[0] = .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false };
    files[1] = .{ .path = "src/lib.zig", .name = "lib.zig", .is_dir = false };

    const edges = try allocator.alloc(types.ImportEdge, 1);
    defer allocator.free(edges);
    edges[0] = .{ .from_file = "src/main.zig", .to_file = "src/lib.zig" };

    var snap = try Snapshot.init(
        allocator,
        std.testing.io,
        ".",
        files,
        edges,
        &.{},
        &.{},
        &.{},
    );
    defer snap.deinit();

    try std.testing.expectEqual(@as(u32, 1), snap.importEdgeCount());
    try std.testing.expectEqualStrings("src/lib.zig", snap.import_edges[0].to_file);
    const fan_in = try snap.fanIn(allocator, "src/lib.zig");
    defer allocator.free(fan_in);
    try std.testing.expectEqual(@as(usize, 1), fan_in.len);
    const fan_out = try snap.fanOut(allocator, "src/main.zig");
    defer allocator.free(fan_out);
    try std.testing.expectEqual(@as(usize, 1), fan_out.len);
}

test "Snapshot propagates allocation failures" {
    var files = [_]types.FileNode{
        .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Snapshot.init(
        failing.allocator(),
        std.testing.io,
        ".",
        files[0..],
        &.{},
        &.{},
        &.{},
        &.{},
    ));
}

test "Snapshot rejects duplicate file paths" {
    const allocator = std.testing.allocator;
    var files = [_]types.FileNode{
        .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false },
        .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false },
    };
    try std.testing.expectError(error.DuplicateNode, Snapshot.init(
        allocator,
        std.testing.io,
        ".",
        files[0..],
        &.{},
        &.{},
        &.{},
        &.{},
    ));
}
