const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Compute maximum dependency depth from entry points using BFS.
///
/// Depth is the longest path from any entry point to a leaf in the import graph.
/// Entry points have depth 0. Files not reachable from entry points get depth = max_depth.
///
/// Returns the maximum depth found.
pub fn computeMaxDepth(
    allocator: Allocator,
    node_count: usize,
    entry_points: []const usize,
    edges: []const core.types.GraphEdge,
) !u32 {
    if (node_count == 0 or entry_points.len == 0) return 0;

    // Build forward adjacency list (from → to)
    var adj = try std.ArrayList(std.ArrayList(usize)).initCapacity(allocator, node_count);
    defer {
        for (adj.items) |*list| list.deinit(allocator);
        adj.deinit(allocator);
    }
    for (0..node_count) |_| {
        try adj.append(allocator, std.ArrayList(usize).empty);
    }

    for (edges) |edge| {
        try adj.items[edge.from].append(allocator, edge.to);
    }

    // BFS from entry points
    var depth = try std.ArrayList(u32).initCapacity(allocator, node_count);
    defer depth.deinit(allocator);
    for (0..node_count) |_| {
        try depth.append(allocator, std.math.maxInt(u32));
    }

    var queue = std.ArrayList(usize).empty;
    defer queue.deinit(allocator);

    for (entry_points) |ep| {
        depth.items[ep] = 0;
        try queue.append(allocator, ep);
    }

    var max_depth: u32 = 0;
    var head: usize = 0;
    while (head < queue.items.len) {
        const v = queue.items[head];
        head += 1;
        const d = depth.items[v];
        if (d > max_depth) max_depth = d;

        for (adj.items[v].items) |u| {
            if (depth.items[u] == std.math.maxInt(u32)) {
                depth.items[u] = d + 1;
                try queue.append(allocator, u);
            }
        }
    }

    return max_depth;
}

/// Compute depth score: 1 / (1 + max_depth / 8).
/// Returns 1.0 for depth 0, 0.5 for depth 8, approaches 0 for deep graphs.
pub fn depthScore(max_depth: u32) f64 {
    return 1.0 / (1.0 + @as(f64, @floatFromInt(max_depth)) / 8.0);
}

// ── Tests ─────────────────────────────────────────────────────

test "empty graph" {
    const eps = [_]usize{};
    const edges = [_]core.types.GraphEdge{};
    const d = try computeMaxDepth(std.testing.allocator, 0, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 0), d);
}

test "single node" {
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{};
    const d = try computeMaxDepth(std.testing.allocator, 1, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 0), d);
}

test "linear chain" {
    // 0 → 1 → 2 → 3
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 3 },
    };
    const d = try computeMaxDepth(std.testing.allocator, 4, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 3), d);
}

test "diamond graph" {
    // 0 → 1, 0 → 2, 1 → 3, 2 → 3
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 0, .to = 2 },
        .{ .from = 1, .to = 3 },
        .{ .from = 2, .to = 3 },
    };
    const d = try computeMaxDepth(std.testing.allocator, 4, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 2), d);
}

test "disconnected nodes" {
    // Only node 0 is entry, nodes 1-2 are disconnected
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{};
    const d = try computeMaxDepth(std.testing.allocator, 3, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 0), d);
}

test "depth score" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), depthScore(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), depthScore(8), 0.001);
    // depthScore(16) = 1/(1+2) = 0.333...
    try std.testing.expect(depthScore(16) < 0.4);
}
