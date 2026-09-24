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

const FunctionCounts = struct {
    total: u32,
    dead: u32,
    duplicates: u32,
    redundancy: f64,
};

const GraphMetrics = struct {
    cycle_count: u32,
    max_depth: u32,
};

/// Compute health report from a snapshot.
///
/// This is the master function that orchestrates all 5 root cause metrics
/// and produces a single quality signal [0, 10000].
/// `file_funcs` provides extracted functions + file contents for dead-code
/// analysis; pass `&.{}` when no function data is available (reports a
/// conservative redundancy ratio of 1.0).
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
    var total_lines: u64 = 0;
    for (file_lines.items) |line_count| {
        total_lines += @as(u64, line_count);
    }

    // 1. Modularity Q (all three edge types)
    const q = try modularity.computeModularityQ(
        allocator,
        import_edges,
        call_edges,
        inherit_edges,
        file_paths.items,
    );

    const graph_metrics = try computeGraphMetrics(
        allocator,
        file_paths.items,
        import_edges,
        call_edges,
        inherit_edges,
    );

    const gini = try computeEquality(allocator, file_funcs, file_lines.items);
    const function_counts = try computeFunctionCounts(allocator, file_funcs, call_edges);

    // Aggregate root causes
    const raw = RootCauseRaw{
        .modularity_q = q,
        .cycle_count = graph_metrics.cycle_count,
        .max_depth = graph_metrics.max_depth,
        .complexity_gini = gini,
        .redundancy_ratio = function_counts.redundancy,
    };

    const scores, const quality_signal = root_causes.computeRootCauseScores(raw);
    const bottleneck = root_causes.findBottleneck(scores);

    return .{
        .quality_signal = quality_signal,
        .quality_signal_int = @intFromFloat(quality_signal * 10000.0),
        .root_cause_raw = raw,
        .root_cause_scores = scores,
        .file_count = std.math.cast(u32, file_paths.items.len) orelse return error.IntegerOverflow,
        .line_count = std.math.cast(u32, total_lines) orelse return error.IntegerOverflow,
        .edge_count = std.math.cast(u32, import_edges.len + call_edges.len + inherit_edges.len) orelse return error.IntegerOverflow,
        .bottleneck = bottleneck,
        .total_functions = function_counts.total,
        .dead_functions = function_counts.dead,
        .duplicate_functions = function_counts.duplicates,
    };
}

fn computeGraphMetrics(
    allocator: Allocator,
    file_paths: []const []const u8,
    import_edges: []const core.types.ImportEdge,
    call_edges: []const core.types.CallEdge,
    inherit_edges: []const core.types.InheritEdge,
) !GraphMetrics {
    var node_index = std.StringHashMap(usize).init(allocator);
    defer node_index.deinit();
    for (file_paths, 0..) |path, index| {
        if (node_index.contains(path)) return error.DuplicateNode;
        _ = try node_index.put(path, index);
    }
    var cycle_edges = std.ArrayList(core.types.GraphEdge).empty;
    defer cycle_edges.deinit(allocator);
    var depth_edges = std.ArrayList(core.types.GraphEdge).empty;
    defer depth_edges.deinit(allocator);
    try appendGraphEdges(allocator, &node_index, import_edges, call_edges, inherit_edges, &cycle_edges, &depth_edges);
    const cycle_count = try acyclicity.detectCycles(allocator, file_paths, cycle_edges.items);
    var entry_points = std.ArrayList(usize).empty;
    defer entry_points.deinit(allocator);
    try selectEntryPoints(allocator, file_paths, import_edges, &node_index, &entry_points);
    const max_depth = try depth.computeMaxDepth(allocator, file_paths.len, entry_points.items, depth_edges.items);
    return .{ .cycle_count = cycle_count, .max_depth = max_depth };
}

fn appendGraphEdges(
    allocator: Allocator,
    node_index: *const std.StringHashMap(usize),
    import_edges: []const core.types.ImportEdge,
    call_edges: []const core.types.CallEdge,
    inherit_edges: []const core.types.InheritEdge,
    cycle_edges: *std.ArrayList(core.types.GraphEdge),
    depth_edges: *std.ArrayList(core.types.GraphEdge),
) !void {
    for (import_edges) |edge| {
        const from_id = node_index.get(edge.from_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;
        try cycle_edges.append(allocator, .{ .from = from_id, .to = to_id });
        try depth_edges.append(allocator, .{ .from = from_id, .to = to_id });
    }
    for (call_edges) |edge| {
        const from_id = node_index.get(edge.from_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;
        try cycle_edges.append(allocator, .{ .from = from_id, .to = to_id });
    }
    for (inherit_edges) |edge| {
        const from_id = node_index.get(edge.child_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.parent_file) orelse return error.InvalidGraphEdge;
        try cycle_edges.append(allocator, .{ .from = from_id, .to = to_id });
    }
}

fn selectEntryPoints(
    allocator: Allocator,
    file_paths: []const []const u8,
    import_edges: []const core.types.ImportEdge,
    node_index: *const std.StringHashMap(usize),
    entries: *std.ArrayList(usize),
) !void {
    for (file_paths, 0..) |path, index| {
        if (core.path_utils.isEntryPointPath(path)) try entries.append(allocator, index);
    }
    if (entries.items.len == 0 and import_edges.len > 0) {
        const incoming = try allocator.alloc(bool, file_paths.len);
        defer allocator.free(incoming);
        @memset(incoming, false);
        for (import_edges) |edge| {
            if (node_index.get(edge.to_file)) |to_id| incoming[to_id] = true;
        }
        for (incoming, 0..) |has_incoming, index| {
            if (!has_incoming) try entries.append(allocator, index);
        }
    }
    if (entries.items.len == 0 and file_paths.len != 0) try entries.append(allocator, 0);
}

fn computeEquality(
    allocator: Allocator,
    file_funcs: []const dead_code.FileFuncs,
    file_lines: []const u32,
) !f64 {
    var complexity_values = std.ArrayList(f64).empty;
    defer complexity_values.deinit(allocator);
    for (file_funcs) |file| {
        for (file.funcs) |func| {
            if (func.cyclomatic_complexity) |complexity| {
                try complexity_values.append(allocator, @floatFromInt(complexity));
            }
        }
    }
    if (complexity_values.items.len != 0) {
        return equality.computeFunctionComplexityGini(complexity_values.items);
    }
    return equality.computeFileSizeGini(file_lines);
}

fn computeFunctionCounts(
    allocator: Allocator,
    file_funcs: []const dead_code.FileFuncs,
    call_edges: []const core.types.CallEdge,
) !FunctionCounts {
    const result = try dead_code.analyze(allocator, file_funcs, call_edges);
    return .{
        .total = result.total_functions,
        .dead = result.dead_functions,
        .duplicates = result.duplicate_functions,
        .redundancy = result.redundancy_ratio,
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

test "compute_health supports more than 32 entry points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entry_count = 40;
    const files = try allocator.alloc(core.types.FileNode, entry_count + 1);
    const paths = try allocator.alloc([]const u8, entry_count + 1);

    for (0..entry_count) |i| {
        paths[i] = try std.fmt.allocPrint(allocator, "src/entry{d}/main.zig", .{i});
        files[i] = .{
            .path = paths[i],
            .name = "main.zig",
            .is_dir = false,
            .lines = 10,
        };
    }
    paths[entry_count] = "src/target.zig";
    files[entry_count] = .{
        .path = paths[entry_count],
        .name = "target.zig",
        .is_dir = false,
        .lines = 10,
    };

    const edges = [_]core.types.ImportEdge{
        .{ .from_file = paths[entry_count - 1], .to_file = paths[entry_count] },
    };
    const report = try computeHealth(allocator, files, &edges, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), report.root_cause_raw.max_depth);
}

test "compute_health uses function complexity for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const files = [_]core.types.FileNode{
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 100 },
        .{ .path = "src/b.zig", .name = "b.zig", .is_dir = false, .lines = 100 },
    };
    const equal_funcs = [_]core.types.FuncInfo{
        .{ .name = "a", .start_line = 1, .end_line = 1, .line_count = 1, .cyclomatic_complexity = 1, .is_public = true },
        .{ .name = "b", .start_line = 1, .end_line = 1, .line_count = 1, .cyclomatic_complexity = 1, .is_public = true },
    };
    const uneven_funcs = [_]core.types.FuncInfo{
        equal_funcs[0],
        .{ .name = "b", .start_line = 1, .end_line = 1, .line_count = 1, .cyclomatic_complexity = 8, .is_public = true },
    };
    const equal_file_funcs = [_]dead_code.FileFuncs{
        .{ .file = files[0].path, .contents = "pub fn a() void {}", .funcs = &equal_funcs },
        .{ .file = files[1].path, .contents = "pub fn b() void {}", .funcs = equal_funcs[1..2] },
    };
    const uneven_file_funcs = [_]dead_code.FileFuncs{
        equal_file_funcs[0],
        .{ .file = files[1].path, .contents = "pub fn b() void {}", .funcs = uneven_funcs[1..2] },
    };

    const equal_report = try computeHealth(allocator, &files, &.{}, &.{}, &.{}, &equal_file_funcs);
    const uneven_report = try computeHealth(allocator, &files, &.{}, &.{}, &.{}, &uneven_file_funcs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), equal_report.root_cause_raw.complexity_gini, 0.001);
    try std.testing.expect(uneven_report.root_cause_raw.complexity_gini > equal_report.root_cause_raw.complexity_gini);
}

test "compute_health does not reward missing function data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const report = try computeHealth(arena.allocator(), &.{}, &.{}, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(f64, 1.0), report.root_cause_raw.redundancy_ratio);
    try std.testing.expectEqual(@as(f64, 0.0), report.root_cause_scores.redundancy);
}

test "compute_health detects cycles in call and inheritance unions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const files = [_]core.types.FileNode{
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 1 },
        .{ .path = "src/b.zig", .name = "b.zig", .is_dir = false, .lines = 1 },
    };
    const calls = [_]core.types.CallEdge{
        .{ .from_file = files[0].path, .from_func = "a", .to_file = files[1].path, .to_func = "b" },
        .{ .from_file = files[1].path, .from_func = "b", .to_file = files[0].path, .to_func = "a" },
    };
    const call_report = try computeHealth(allocator, &files, &.{}, &calls, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), call_report.root_cause_raw.cycle_count);

    const inheritance = [_]core.types.InheritEdge{
        .{ .child_file = files[0].path, .child_class = "A", .parent_file = files[1].path, .parent_class = "B" },
        .{ .child_file = files[1].path, .child_class = "B", .parent_file = files[0].path, .parent_class = "A" },
    };
    const inheritance_report = try computeHealth(allocator, &files, &.{}, &.{}, &inheritance, &.{});
    try std.testing.expectEqual(@as(u32, 1), inheritance_report.root_cause_raw.cycle_count);
}

test "compute_health rejects unknown graph endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]core.types.FileNode{
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 1 },
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = files[0].path, .to_file = "src/missing.zig" },
    };
    try std.testing.expectError(
        error.InvalidGraphEdge,
        computeHealth(arena.allocator(), &files, &imports, &.{}, &.{}, &.{}),
    );
}

test "compute_health rejects duplicate file nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]core.types.FileNode{
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 1 },
        .{ .path = "src/a.zig", .name = "a.zig", .is_dir = false, .lines = 1 },
    };
    try std.testing.expectError(
        error.DuplicateNode,
        computeHealth(arena.allocator(), &files, &.{}, &.{}, &.{}, &.{}),
    );
}
