const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

pub const acyclicity = @import("acyclicity.zig");
pub const dead_code = @import("dead_code.zig");
pub const depth = @import("depth.zig");
pub const equality = @import("equality.zig");
pub const modularity = @import("modularity.zig");
pub const redundancy = @import("redundancy.zig");
pub const root_causes = @import("root_causes.zig");

pub const HealthReport = root_causes.HealthReport;
pub const RootCauseRaw = root_causes.RootCauseRaw;
pub const RootCauseScores = root_causes.RootCauseScores;

/// Compute health report from a snapshot.
///
/// This is the master function that orchestrates all 5 root cause metrics
/// and produces a single quality signal [0, 10000].
/// `file_funcs` provides extracted functions + file contents for dead-code
/// analysis; pass `&.{}` to skip redundancy (reports ratio 0).
pub fn computeHealth(
    allocator: Allocator,
    files: []const core.types.FileNode,
    import_edges: []const core.types.ImportEdge,
    call_edges: []const core.types.CallEdge,
    inherit_edges: []const core.types.InheritEdge,
    file_funcs: []const dead_code.FileFuncs,
) !HealthReport {
    // Flatten file paths
    var file_paths = std.ArrayList([]const u8).empty;
    defer file_paths.deinit(allocator);
    try collectPaths(allocator, files, &file_paths);

    // Collect file line counts
    var file_lines = std.ArrayList(u32).empty;
    defer file_lines.deinit(allocator);
    try collectLineCounts(allocator, files, &file_lines);

    // Count total lines
    var total_lines: u32 = 0;
    for (file_lines.items) |l| {
        total_lines += l;
    }

    // 1. Modularity Q (all three edge types)
    const q = try modularity.computeModularityQ(
        allocator,
        import_edges,
        call_edges,
        inherit_edges,
        file_paths.items,
    );

    // 2. Cycle detection (acyclicity)
    // Build node-indexed edges for Tarjan
    var node_index = std.StringHashMap(usize).init(allocator);
    defer node_index.deinit();
    for (file_paths.items, 0..) |path, i| {
        _ = try node_index.put(path, i);
    }

    var tarjan_edges = std.ArrayList(core.types.GraphEdge).empty;
    defer tarjan_edges.deinit(allocator);
    for (import_edges) |edge| {
        const from_id = node_index.get(edge.from_file) orelse continue;
        const to_id = node_index.get(edge.to_file) orelse continue;
        try tarjan_edges.append(allocator, .{ .from = from_id, .to = to_id });
    }

    const cycle_count = try acyclicity.detectCycles(
        allocator,
        file_paths.items,
        tarjan_edges.items,
    );

    // 3. Depth from entry points
    // Prefer conventional entry files (main.*, index.*, build.zig, ...);
    // fall back to files with no incoming import edges.
    var entry_points_buf: [32]usize = undefined;
    var ep_count: usize = 0;
    {
        // Pass 1: conventional entry-point paths
        for (file_paths.items, 0..) |path, i| {
            if (core.path_utils.isEntryPointPath(path)) {
                if (ep_count < entry_points_buf.len) {
                    entry_points_buf[ep_count] = i;
                    ep_count += 1;
                }
            }
        }

        // Pass 2 (fallback): no incoming edges
        if (ep_count == 0 and import_edges.len > 0) {
            const incoming = try allocator.alloc(bool, file_paths.items.len);
            defer allocator.free(incoming);
            @memset(incoming, false);
            for (import_edges) |edge| {
                if (node_index.get(edge.to_file)) |to_id| {
                    incoming[to_id] = true;
                }
            }
            for (incoming, 0..) |has_incoming, i| {
                if (!has_incoming and ep_count < entry_points_buf.len) {
                    entry_points_buf[ep_count] = i;
                    ep_count += 1;
                }
            }
        }

        // Pass 3 (last resort): first file
        if (ep_count == 0 and file_paths.items.len > 0) {
            entry_points_buf[0] = 0;
            ep_count = 1;
        }
    }
    const entry_points: []const usize = entry_points_buf[0..ep_count];

    const max_depth = try depth.computeMaxDepth(
        allocator,
        file_paths.items.len,
        entry_points,
        tarjan_edges.items,
    );

    // 4. Complexity Gini (equality)
    const gini = equality.computeComplexityGini(file_lines.items);

    // 5. Redundancy: dead code + duplicates
    var total_funcs: u32 = 0;
    var dead_funcs: u32 = 0;
    var dup_funcs: u32 = 0;
    const redundancy_ratio: f64 = blk: {
        if (file_funcs.len == 0) break :blk 0.0;
        const dc = try dead_code.analyze(allocator, file_funcs, call_edges);
        total_funcs = dc.total_functions;
        dead_funcs = dc.dead_functions;
        dup_funcs = dc.duplicate_functions;
        break :blk dc.redundancy_ratio;
    };

    // Aggregate root causes
    const raw = RootCauseRaw{
        .modularity_q = q,
        .cycle_count = cycle_count,
        .max_depth = max_depth,
        .complexity_gini = gini,
        .redundancy_ratio = redundancy_ratio,
    };

    const scores, const quality_signal = root_causes.computeRootCauseScores(raw);
    const bottleneck = root_causes.findBottleneck(scores);

    return .{
        .quality_signal = quality_signal,
        .quality_signal_int = @intFromFloat(quality_signal * 10000.0),
        .root_cause_raw = raw,
        .root_cause_scores = scores,
        .file_count = @intCast(file_paths.items.len),
        .line_count = total_lines,
        .edge_count = @intCast(import_edges.len + call_edges.len + inherit_edges.len),
        .bottleneck = bottleneck,
        .total_functions = total_funcs,
        .dead_functions = dead_funcs,
        .duplicate_functions = dup_funcs,
    };
}

fn collectPaths(allocator: Allocator, files: []const core.types.FileNode, paths: *std.ArrayList([]const u8)) !void {
    for (files) |file| {
        if (!file.is_dir) {
            try paths.append(allocator, file.path);
        }
        if (file.children) |children| {
            try collectPaths(allocator, children, paths);
        }
    }
}

fn collectLineCounts(allocator: Allocator, files: []const core.types.FileNode, lines: *std.ArrayList(u32)) !void {
    for (files) |file| {
        if (!file.is_dir) {
            try lines.append(allocator, file.lines);
        }
        if (file.children) |children| {
            try collectLineCounts(allocator, children, lines);
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────

test "compute_health empty project" {
    const files = [_]core.types.FileNode{};
    const report = try computeHealth(
        std.testing.allocator,
        &files,
        &.{},
        &.{},
        &.{},
        &.{},
    );
    try std.testing.expect(report.quality_signal > 0.0);
    try std.testing.expect(report.file_count == 0);
}

test "compute_health single file" {
    const files = [_]core.types.FileNode{
        .{ .path = "main.zig", .name = "main.zig", .is_dir = false, .lines = 100 },
    };
    const report = try computeHealth(
        std.testing.allocator,
        &files,
        &.{},
        &.{},
        &.{},
        &.{},
    );
    try std.testing.expect(report.quality_signal > 0.0);
    try std.testing.expectEqual(@as(u32, 1), report.file_count);
    try std.testing.expectEqual(@as(u32, 100), report.line_count);
}

test "compute_health with edges" {
    const files = [_]core.types.FileNode{
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 50 },
        .{ .path = "src/b.zig", .name = "b.zig", .is_dir = false, .lines = 50 },
    };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "src/b.zig" },
    };
    const report = try computeHealth(
        std.testing.allocator,
        &files,
        &edges,
        &.{},
        &.{},
        &.{},
    );
    try std.testing.expect(report.quality_signal > 0.0);
    try std.testing.expectEqual(@as(u32, 1), report.edge_count);
}

test "compute_health depth from conventional entry" {
    // Entry (main.zig) listed LAST — conventional detection must find it
    // regardless of ordering, giving depth 1 (main → util).
    const files = [_]core.types.FileNode{
        .{ .path = "src/util.zig", .name = "util.zig", .is_dir = false, .lines = 50 },
        .{ .path = "src/lib.zig", .name = "lib.zig", .is_dir = false, .lines = 50 },
        .{ .path = "src/main.zig", .name = "main.zig", .is_dir = false, .lines = 50 },
    };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/main.zig", .to_file = "src/lib.zig" },
        .{ .from_file = "src/lib.zig", .to_file = "src/util.zig" },
    };
    const report = try computeHealth(
        std.testing.allocator,
        &files,
        &edges,
        &.{},
        &.{},
        &.{},
    );
    // main → lib → util = max depth 2 from the conventional entry
    try std.testing.expectEqual(@as(u32, 2), report.root_cause_raw.max_depth);
}
