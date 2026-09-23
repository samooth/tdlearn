const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const DepthSolver = struct {
    adj: []std.ArrayList(usize),
    state: []u8,
    memo: []u32,

    fn visit(self: *DepthSolver, node: usize) !u32 {
        if (self.state[node] == 2) return self.memo[node];
        if (self.state[node] == 1) return 0;
        self.state[node] = 1;

        var longest: u32 = 0;
        for (self.adj[node].items) |neighbor| {
            if (self.state[neighbor] == 1) continue;
            const child_depth = try self.visit(neighbor);
            if (child_depth < std.math.maxInt(u32)) {
                longest = @max(longest, child_depth + 1);
            }
        }

        self.state[node] = 2;
        self.memo[node] = longest;
        return longest;
    }
};

/// Compute maximum dependency depth from entry points using longest-path DFS.
///
/// Depth is the longest simple path from any entry point to a leaf in the import graph.
/// Entry points have depth 0. Files not reachable from entry points are ignored.
/// Cycle edges do not add repeated nodes to a path.
///
/// Returns the maximum depth found.
pub fn computeMaxDepth(
    allocator: Allocator,
    node_count: usize,
    entry_points: []const usize,
    edges: []const core.types.GraphEdge,
) !u32 {
    if (node_count == 0 or entry_points.len == 0) return 0;
    for (entry_points) |entry_point| {
        if (entry_point >= node_count) return error.InvalidEntryPoint;
    }
    for (edges) |edge| {
        if (edge.from >= node_count or edge.to >= node_count) return error.InvalidGraphEdge;
    }

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

    const state = try allocator.alloc(u8, node_count);
    defer allocator.free(state);
    @memset(state, 0);
    const memo = try allocator.alloc(u32, node_count);
    defer allocator.free(memo);
    @memset(memo, 0);

    var solver = DepthSolver{
        .adj = adj.items,
        .state = state,
        .memo = memo,
    };

    var max_depth: u32 = 0;
    for (entry_points) |entry_point| {
        max_depth = @max(max_depth, try solver.visit(entry_point));
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

test "longest path ignores shortcut distance" {
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 3 },
        .{ .from = 0, .to = 3 },
    };
    const d = try computeMaxDepth(std.testing.allocator, 4, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 3), d);
}

test "cycle does not loop forever" {
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 0 },
    };
    const d = try computeMaxDepth(std.testing.allocator, 3, &eps, &edges);
    try std.testing.expectEqual(@as(u32, 2), d);
}

test "invalid graph indices are rejected" {
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{.{ .from = 0, .to = 2 }};
    try std.testing.expectError(error.InvalidGraphEdge, computeMaxDepth(std.testing.allocator, 2, &eps, &edges));
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
    // Only node 0 is entry; disconnected nodes are ignored.
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
