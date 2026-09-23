const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Tarjan's Strongly Connected Components algorithm.
/// Finds cycles in the dependency graph. Self-loops are intentionally not
/// counted; only SCCs containing at least two nodes are circular dependencies.
/// Edge endpoints must belong to `nodes`; unknown endpoints return
/// `error.InvalidGraphEdge`.
pub fn detectCycles(
    allocator: Allocator,
    nodes: []const []const u8,
    edges: []const core.types.GraphEdge,
) !u32 {
    const n = nodes.len;
    for (edges) |edge| {
        if (edge.from >= n or edge.to >= n) return error.InvalidGraphEdge;
    }
    if (n == 0) return 0;

    // Build adjacency list
    var adj = try std.ArrayList(std.ArrayList(usize)).initCapacity(allocator, n);
    defer {
        for (adj.items) |*list| list.deinit(allocator);
        adj.deinit(allocator);
    }
    for (0..n) |_| {
        try adj.append(allocator, std.ArrayList(usize).empty);
    }

    for (edges) |edge| {
        try adj.items[edge.from].append(allocator, edge.to);
    }

    // Tarjan's algorithm (iterative)
    var index_counter: u32 = 0;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(allocator);
    var on_stack = try std.ArrayList(bool).initCapacity(allocator, n);
    defer on_stack.deinit(allocator);
    for (0..n) |_| {
        try on_stack.append(allocator, false);
    }
    var index_map = try std.ArrayList(?u32).initCapacity(allocator, n);
    defer index_map.deinit(allocator);
    for (0..n) |_| {
        try index_map.append(allocator, null);
    }
    var lowlink = try std.ArrayList(u32).initCapacity(allocator, n);
    defer lowlink.deinit(allocator);
    for (0..n) |_| {
        try lowlink.append(allocator, 0);
    }

    var cycle_count: u32 = 0;

    // DFS stack: (node, neighbor_index)
    var dfs_stack = std.ArrayList(struct { node: usize, next_neighbor: usize }).empty;
    defer dfs_stack.deinit(allocator);

    for (0..n) |start| {
        if (index_map.items[start] != null) continue;

        try dfs_stack.append(allocator, .{ .node = start, .next_neighbor = 0 });

        while (dfs_stack.items.len > 0) {
            const frame = &dfs_stack.items[dfs_stack.items.len - 1];
            const v = frame.node;

            if (index_map.items[v] == null) {
                // First time visiting this node
                index_map.items[v] = index_counter;
                lowlink.items[v] = index_counter;
                index_counter += 1;
                try stack.append(allocator, v);
                on_stack.items[v] = true;
            }

            // Process neighbors
            var processed = true;
            while (frame.next_neighbor < adj.items[v].items.len) {
                const w = adj.items[v].items[frame.next_neighbor];
                frame.next_neighbor += 1;

                if (index_map.items[w] == null) {
                    // Unvisited neighbor — push it
                    try dfs_stack.append(allocator, .{ .node = w, .next_neighbor = 0 });
                    processed = false;
                    break;
                } else if (on_stack.items[w]) {
                    // Neighbor on stack — update lowlink
                    const w_idx = index_map.items[w].?;
                    if (lowlink.items[v] > w_idx) {
                        lowlink.items[v] = w_idx;
                    }
                }
            }

            if (processed) {
                // All neighbors processed — backtrack
                if (lowlink.items[v] == index_map.items[v].?) {
                    // v is root of an SCC
                    var scc_size: u32 = 0;
                    while (stack.items.len > 0) {
                        const w = stack.items[stack.items.len - 1];
                        if (index_map.items[w].? < index_map.items[v].?) break;
                        _ = stack.pop();
                        on_stack.items[w] = false;
                        scc_size += 1;
                    }
                    if (scc_size > 1) {
                        cycle_count += 1;
                    }
                }

                // Update parent's lowlink
                if (dfs_stack.items.len > 1) {
                    const parent = &dfs_stack.items[dfs_stack.items.len - 2];
                    if (lowlink.items[parent.node] > lowlink.items[v]) {
                        lowlink.items[parent.node] = lowlink.items[v];
                    }
                }

                _ = dfs_stack.pop();
            }
        }
    }

    return cycle_count;
}

/// Compute acyclicity score: 1 / (1 + cycle_count).
/// Returns 1.0 for acyclic graphs, approaches 0.0 as cycles increase.
pub fn acyclicityScore(cycle_count: u32) f64 {
    return 1.0 / (1.0 + @as(f64, @floatFromInt(cycle_count)));
}

// ── Tests ─────────────────────────────────────────────────────

test "no cycles" {
    const nodes = [_][]const u8{ "a", "b", "c" };
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
    };
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "simple cycle" {
    const nodes = [_][]const u8{ "a", "b", "c" };
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 0 },
    };
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "self-loop" {
    const nodes = [_][]const u8{"a"};
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 0 },
    };
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    // Self-loop is an SCC of size 1, not counted as a cycle
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "invalid graph edge is rejected" {
    const nodes = [_][]const u8{"a"};
    const edges = [_]core.types.GraphEdge{.{ .from = 0, .to = 1 }};
    try std.testing.expectError(error.InvalidGraphEdge, detectCycles(std.testing.allocator, &nodes, &edges));
}

test "duplicate edges do not multiply cycle count" {
    const nodes = [_][]const u8{ "a", "b" };
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 0 },
        .{ .from = 1, .to = 0 },
    };
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "cycle count is independent of edge order" {
    const nodes = [_][]const u8{ "a", "b", "c" };
    const forward = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 0 },
    };
    const reverse = [_]core.types.GraphEdge{
        .{ .from = 2, .to = 0 },
        .{ .from = 1, .to = 2 },
        .{ .from = 0, .to = 1 },
    };
    try std.testing.expectEqual(
        try detectCycles(std.testing.allocator, &nodes, &forward),
        try detectCycles(std.testing.allocator, &nodes, &reverse),
    );
}

test "two separate cycles" {
    const nodes = [_][]const u8{ "a", "b", "c", "d" };
    const edges = [_]core.types.GraphEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 0 },
        .{ .from = 2, .to = 3 },
        .{ .from = 3, .to = 2 },
    };
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "acyclicity score" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), acyclicityScore(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), acyclicityScore(1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), acyclicityScore(3), 0.001);
}

test "empty graph" {
    const nodes = [_][]const u8{};
    const edges = [_]core.types.GraphEdge{};
    const count = try detectCycles(std.testing.allocator, &nodes, &edges);
    try std.testing.expectEqual(@as(u32, 0), count);
}
