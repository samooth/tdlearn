const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Tarjan's Strongly Connected Components algorithm.
/// Finds cycles in the dependency graph. Self-loops are intentionally not
/// counted; only SCCs containing at least two nodes are circular dependencies.
/// Edge endpoints must belong to `nodes`; unknown endpoints return
/// `error.InvalidGraphEdge`.
const DfsFrame = struct {
    node: usize,
    next_neighbor: usize,
};

const TarjanSolver = struct {
    allocator: Allocator,
    adj: []std.ArrayList(usize),
    stack: std.ArrayList(usize),
    on_stack: []bool,
    index_map: []?u32,
    lowlink: []u32,
    dfs_stack: std.ArrayList(DfsFrame),
    index_counter: u32 = 0,
    cycle_count: u32 = 0,

    fn init(allocator: Allocator, adj: []std.ArrayList(usize)) !TarjanSolver {
        var stack = std.ArrayList(usize).empty;
        errdefer stack.deinit(allocator);
        var dfs_stack = std.ArrayList(DfsFrame).empty;
        errdefer dfs_stack.deinit(allocator);
        const on_stack = try allocator.alloc(bool, adj.len);
        errdefer allocator.free(on_stack);
        @memset(on_stack, false);
        const index_map = try allocator.alloc(?u32, adj.len);
        errdefer allocator.free(index_map);
        @memset(index_map, null);
        const lowlink = try allocator.alloc(u32, adj.len);
        errdefer allocator.free(lowlink);
        @memset(lowlink, 0);
        return .{
            .allocator = allocator,
            .adj = adj,
            .stack = stack,
            .on_stack = on_stack,
            .index_map = index_map,
            .lowlink = lowlink,
            .dfs_stack = dfs_stack,
        };
    }

    fn deinit(self: *TarjanSolver) void {
        self.stack.deinit(self.allocator);
        self.dfs_stack.deinit(self.allocator);
        self.allocator.free(self.on_stack);
        self.allocator.free(self.index_map);
        self.allocator.free(self.lowlink);
    }

    fn run(self: *TarjanSolver) !u32 {
        for (0..self.adj.len) |start| {
            if (self.index_map[start] != null) continue;
            try self.dfs_stack.append(self.allocator, .{ .node = start, .next_neighbor = 0 });
            while (self.dfs_stack.items.len != 0) {
                const frame = &self.dfs_stack.items[self.dfs_stack.items.len - 1];
                const node = frame.node;
                if (self.index_map[node] == null) try self.enterNode(node);
                if (try self.processNeighbors(frame)) {
                    try self.finishNode(node);
                    _ = self.dfs_stack.pop();
                }
            }
        }
        return self.cycle_count;
    }

    fn enterNode(self: *TarjanSolver, node: usize) !void {
        if (self.index_counter == std.math.maxInt(u32)) return error.IntegerOverflow;
        self.index_map[node] = self.index_counter;
        self.lowlink[node] = self.index_counter;
        self.index_counter += 1;
        try self.stack.append(self.allocator, node);
        self.on_stack[node] = true;
    }

    fn processNeighbors(self: *TarjanSolver, frame: *DfsFrame) !bool {
        const node = frame.node;
        while (frame.next_neighbor < self.adj[node].items.len) {
            const neighbor = self.adj[node].items[frame.next_neighbor];
            frame.next_neighbor += 1;
            if (self.index_map[neighbor] == null) {
                try self.dfs_stack.append(self.allocator, .{ .node = neighbor, .next_neighbor = 0 });
                return false;
            }
            if (self.on_stack[neighbor]) {
                const neighbor_index = self.index_map[neighbor].?;
                if (self.lowlink[node] > neighbor_index) self.lowlink[node] = neighbor_index;
            }
        }
        return true;
    }

    fn finishNode(self: *TarjanSolver, node: usize) !void {
        if (self.lowlink[node] == self.index_map[node].?) {
            var scc_size: u32 = 0;
            while (self.stack.items.len != 0) {
                const member = self.stack.items[self.stack.items.len - 1];
                if (self.index_map[member].? < self.index_map[node].?) break;
                _ = self.stack.pop();
                self.on_stack[member] = false;
                if (scc_size == std.math.maxInt(u32)) return error.IntegerOverflow;
                scc_size += 1;
            }
            if (scc_size > 1) {
                if (self.cycle_count == std.math.maxInt(u32)) return error.IntegerOverflow;
                self.cycle_count += 1;
            }
        }
        if (self.dfs_stack.items.len > 1) {
            const parent = self.dfs_stack.items[self.dfs_stack.items.len - 2].node;
            if (self.lowlink[parent] > self.lowlink[node]) self.lowlink[parent] = self.lowlink[node];
        }
    }
};

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

    var adjacency = try std.ArrayList(std.ArrayList(usize)).initCapacity(allocator, n);
    defer {
        for (adjacency.items) |*list| list.deinit(allocator);
        adjacency.deinit(allocator);
    }
    for (0..n) |_| try adjacency.append(allocator, std.ArrayList(usize).empty);
    for (edges) |edge| try adjacency.items[edge.from].append(allocator, edge.to);

    var solver = try TarjanSolver.init(allocator, adjacency.items);
    defer solver.deinit();
    return solver.run();
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
