const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const DepthSolver = struct {
    adj: []std.ArrayList(usize),
    state: []u8,
    memo: []u32,
    next: []usize,

    fn visit(self: *DepthSolver, node: usize) !u32 {
        if (self.state[node] == 2) return self.memo[node];
        if (self.state[node] == 1) return 0;
        self.state[node] = 1;

        var longest: u32 = 0;
        for (self.adj[node].items) |neighbor| {
            if (self.state[neighbor] == 1) continue;
            const child_depth = try self.visit(neighbor);
            if (child_depth < std.math.maxInt(u32) and child_depth + 1 > longest) {
                longest = child_depth + 1;
                self.next[node] = neighbor;
            }
        }

        self.state[node] = 2;
        self.memo[node] = longest;
        return longest;
    }
};

pub const LongestPath = struct {
    depth: u32,
    nodes: []usize,
};

pub fn computeLongestPath(
    allocator: Allocator,
    node_count: usize,
    entry_points: []const usize,
    edges: []const core.types.GraphEdge,
) !LongestPath {
    if (node_count == 0 or entry_points.len == 0) return .{ .depth = 0, .nodes = &.{} };
    try validateGraph(node_count, entry_points, edges);
    const adj = try buildAdjacency(allocator, node_count, edges);
    defer deinitAdjacency(allocator, adj);

    const state = try allocator.alloc(u8, node_count);
    defer allocator.free(state);
    @memset(state, 0);
    const memo = try allocator.alloc(u32, node_count);
    defer allocator.free(memo);
    @memset(memo, 0);
    const next = try allocator.alloc(usize, node_count);
    defer allocator.free(next);
    @memset(next, std.math.maxInt(usize));

    var solver = DepthSolver{
        .adj = adj,
        .state = state,
        .memo = memo,
        .next = next,
    };
    var best_depth: u32 = 0;
    var best_entry = entry_points[0];
    for (entry_points) |entry_point| {
        const candidate = try solver.visit(entry_point);
        if (candidate > best_depth) {
            best_depth = candidate;
            best_entry = entry_point;
        }
    }

    var path = std.ArrayList(usize).empty;
    errdefer path.deinit(allocator);
    var current = best_entry;
    while (true) {
        try path.append(allocator, current);
        const following = solver.next[current];
        if (following == std.math.maxInt(usize)) break;
        current = following;
    }
    return .{ .depth = best_depth, .nodes = try path.toOwnedSlice(allocator) };
}

pub fn computeMaxDepth(
    allocator: Allocator,
    node_count: usize,
    entry_points: []const usize,
    edges: []const core.types.GraphEdge,
) !u32 {
    const result = try computeLongestPath(allocator, node_count, entry_points, edges);
    if (result.nodes.len != 0) allocator.free(result.nodes);
    return result.depth;
}

fn validateGraph(
    node_count: usize,
    entry_points: []const usize,
    edges: []const core.types.GraphEdge,
) !void {
    for (entry_points) |entry_point| {
        if (entry_point >= node_count) return error.InvalidEntryPoint;
    }
    for (edges) |edge| {
        if (edge.from >= node_count or edge.to >= node_count) return error.InvalidGraphEdge;
    }
}

fn buildAdjacency(
    allocator: Allocator,
    node_count: usize,
    edges: []const core.types.GraphEdge,
) ![]std.ArrayList(usize) {
    var adjacency = try std.ArrayList(std.ArrayList(usize)).initCapacity(allocator, node_count);
    errdefer {
        for (adjacency.items) |*list| list.deinit(allocator);
        adjacency.deinit(allocator);
    }
    for (0..node_count) |_| {
        try adjacency.append(allocator, std.ArrayList(usize).empty);
    }
    for (edges) |edge| {
        try adjacency.items[edge.from].append(allocator, edge.to);
    }
    return try adjacency.toOwnedSlice(allocator);
}

fn deinitAdjacency(allocator: Allocator, adjacency: []std.ArrayList(usize)) void {
    for (adjacency) |*list| list.deinit(allocator);
    allocator.free(adjacency);
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

test "longest path exposes dependency chain" {
    const eps = [_]usize{0};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 3 },
        .{ .from = 0, .to = 3 },
    };
    const result = try computeLongestPath(std.testing.allocator, 4, &eps, &edges);
    defer std.testing.allocator.free(result.nodes);
    try std.testing.expectEqual(@as(u32, 3), result.depth);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, result.nodes);
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
