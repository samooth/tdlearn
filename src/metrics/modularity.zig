const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Newman's modularity Q for a directed multigraph.
///
/// The partition is preassigned by `core.path_utils.moduleOf(path)`: each
/// source file belongs to its directory-derived module, not to a community
/// inferred by the algorithm. Import, call, and inheritance edges are all
/// included; repeated edges are retained as weighted multigraph edges.
/// Unknown endpoints return `error.InvalidGraphEdge`.
///
/// Q = (1/m) * [intra_module_edges - expected_intra_module_edges]
///
/// where expected_intra = sum over modules of (k_out_sum * k_in_sum / m).
/// An empty graph has Q = 1.0 by convention.
///
/// Returns Q in range [-0.5, 1.0].
/// 1.0 = perfect modularity (all edges within modules)
/// 0.0 = random (edges proportional to degree)
/// -0.5 = anti-modular (edges mostly between modules)
pub fn computeModularityQ(
    allocator: Allocator,
    import_edges: []const core.types.ImportEdge,
    call_edges: []const core.types.CallEdge,
    inherit_edges: []const core.types.InheritEdge,
    file_paths: []const []const u8,
) !f64 {
    const n = file_paths.len;
    const m = import_edges.len + call_edges.len + inherit_edges.len;
    if (n == 0) {
        if (m > 0) return error.InvalidGraphEdge;
        return 1.0;
    }

    // Build node index (path → id)
    var node_index = std.StringHashMap(usize).init(allocator);
    defer node_index.deinit();
    for (file_paths, 0..) |path, i| {
        if (node_index.contains(path)) return error.DuplicateNode;
        _ = try node_index.put(path, i);
    }

    if (m == 0) return 1.0;

    // Compute degree sums
    var k_out = try std.ArrayList(u32).initCapacity(allocator, n);
    defer k_out.deinit(allocator);
    var k_in = try std.ArrayList(u32).initCapacity(allocator, n);
    defer k_in.deinit(allocator);
    for (0..n) |_| {
        try k_out.append(allocator, 0);
        try k_in.append(allocator, 0);
    }

    // Count edges within modules and update degrees
    var actual_intra: f64 = 0.0;

    for (import_edges) |edge| {
        const from_id = node_index.get(edge.from_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;

        k_out.items[from_id] += 1;
        k_in.items[to_id] += 1;

        // Check if same module (same file = same module by default)
        if (std.mem.eql(u8, core.path_utils.moduleOf(edge.from_file), core.path_utils.moduleOf(edge.to_file))) {
            actual_intra += 1.0;
        }
    }

    for (call_edges) |edge| {
        const from_id = node_index.get(edge.from_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;

        k_out.items[from_id] += 1;
        k_in.items[to_id] += 1;

        if (std.mem.eql(u8, core.path_utils.moduleOf(edge.from_file), core.path_utils.moduleOf(edge.to_file))) {
            actual_intra += 1.0;
        }
    }

    for (inherit_edges) |edge| {
        const from_id = node_index.get(edge.child_file) orelse return error.InvalidGraphEdge;
        const to_id = node_index.get(edge.parent_file) orelse return error.InvalidGraphEdge;

        k_out.items[from_id] += 1;
        k_in.items[to_id] += 1;

        if (std.mem.eql(u8, core.path_utils.moduleOf(edge.child_file), core.path_utils.moduleOf(edge.parent_file))) {
            actual_intra += 1.0;
        }
    }

    // Compute expected intra-module edges per module
    // Group nodes by module
    var module_k_out = std.StringHashMap(f64).init(allocator);
    defer module_k_out.deinit();
    var module_k_in = std.StringHashMap(f64).init(allocator);
    defer module_k_in.deinit();
    var module_names = std.ArrayList([]const u8).empty;
    defer module_names.deinit(allocator);

    for (file_paths, 0..) |path, i| {
        const module = core.path_utils.moduleOf(path);
        if (module_k_out.getPtr(module) == null) {
            try module_k_out.put(module, 0.0);
            try module_k_in.put(module, 0.0);
            try module_names.append(allocator, module);
        }
        module_k_out.getPtr(module).?.* += @floatFromInt(k_out.items[i]);
        module_k_in.getPtr(module).?.* += @floatFromInt(k_in.items[i]);
    }

    std.sort.heap([]const u8, module_names.items, {}, stringLessThan);

    var expected_intra: f64 = 0.0;
    for (module_names.items) |module| {
        const mod_k_out_sum = module_k_out.get(module) orelse 0.0;
        const mod_k_in_sum = module_k_in.get(module) orelse 0.0;
        expected_intra += mod_k_out_sum * mod_k_in_sum / @as(f64, @floatFromInt(m));
    }

    // Q = (actual - expected) / m
    const q = (actual_intra - expected_intra) / @as(f64, @floatFromInt(m));

    // Clamp to [-0.5, 1.0]
    return @max(-0.5, @min(1.0, q));
}

/// Compute modularity score: (Q + 0.5) / 1.5
/// Maps Q from [-0.5, 1.0] to [0.0, 1.0].
pub fn modularityScore(q: f64) f64 {
    return (q + 0.5) / 1.5;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

// ── Tests ─────────────────────────────────────────────────────

test "no edges" {
    const files = [_][]const u8{ "a.zig", "b.zig" };
    const q = try computeModularityQ(
        std.testing.allocator,
        &.{},
        &.{},
        &.{},
        &files,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), q, 0.001);
}

test "all edges within module" {
    // Files in same directory under non-dominant dir → same module
    const files = [_][]const u8{ "analysis/a.zig", "analysis/b.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "analysis/a.zig", .to_file = "analysis/b.zig" },
    };
    const q = try computeModularityQ(
        std.testing.allocator,
        &edges,
        &.{},
        &.{},
        &files,
    );
    // All edges within same module = positive Q
    // (may be small for single edge, but should be >= 0)
    try std.testing.expect(q >= -0.1);
}

test "all edges between modules" {
    // Files in different dominant dirs → different modules
    const files = [_][]const u8{ "src/a.zig", "lib/b.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "lib/b.zig" },
    };
    const q = try computeModularityQ(
        std.testing.allocator,
        &edges,
        &.{},
        &.{},
        &files,
    );
    // All edges between different modules = low Q
    try std.testing.expect(q <= 0.0);
}

test "empty files" {
    const files = [_][]const u8{};
    const q = try computeModularityQ(
        std.testing.allocator,
        &.{},
        &.{},
        &.{},
        &files,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), q, 0.001);
}

test "unknown endpoints are rejected" {
    const files = [_][]const u8{"src/a.zig"};
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "src/missing.zig" },
    };
    try std.testing.expectError(
        error.InvalidGraphEdge,
        computeModularityQ(std.testing.allocator, &imports, &.{}, &.{}, &files),
    );
}

test "empty graph rejects edges with unknown endpoints" {
    const files = [_][]const u8{};
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "missing-a.zig", .to_file = "missing-b.zig" },
    };
    try std.testing.expectError(
        error.InvalidGraphEdge,
        computeModularityQ(std.testing.allocator, &edges, &.{}, &.{}, &files),
    );
}

test "duplicate file paths are rejected" {
    const files = [_][]const u8{ "src/a.zig", "src/a.zig" };
    try std.testing.expectError(
        error.DuplicateNode,
        computeModularityQ(std.testing.allocator, &.{}, &.{}, &.{}, &files),
    );
}

test "partition aggregation is deterministic" {
    const files = [_][]const u8{ "src/a.zig", "lib/b.zig", "src/c.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/a.zig", .to_file = "lib/b.zig" },
        .{ .from_file = "lib/b.zig", .to_file = "src/c.zig" },
    };
    const reversed_files = [_][]const u8{ "src/c.zig", "lib/b.zig", "src/a.zig" };
    const reversed_edges = [_]core.types.ImportEdge{
        .{ .from_file = "lib/b.zig", .to_file = "src/c.zig" },
        .{ .from_file = "src/a.zig", .to_file = "lib/b.zig" },
    };
    const q = try computeModularityQ(std.testing.allocator, &edges, &.{}, &.{}, &files);
    const reversed_q = try computeModularityQ(std.testing.allocator, &reversed_edges, &.{}, &.{}, &reversed_files);
    try std.testing.expectApproxEqAbs(q, reversed_q, 0.000001);
}

test "repeated edges are retained as weights" {
    const files = [_][]const u8{ "src/a/one.zig", "src/a/two.zig", "lib/b.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = files[0], .to_file = files[1] },
        .{ .from_file = files[2], .to_file = files[0] },
        .{ .from_file = files[1], .to_file = files[2] },
    };
    const weighted_edges = [_]core.types.ImportEdge{
        edges[0], edges[0], edges[1], edges[2],
    };
    const q = try computeModularityQ(std.testing.allocator, &edges, &.{}, &.{}, &files);
    const weighted_q = try computeModularityQ(std.testing.allocator, &weighted_edges, &.{}, &.{}, &files);
    try std.testing.expect(weighted_q > q);
}

test "modularity score mapping" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), modularityScore(-0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), modularityScore(0.25), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), modularityScore(1.0), 0.001);
}
