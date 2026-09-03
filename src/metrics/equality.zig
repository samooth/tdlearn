const std = @import("std");
const Allocator = std.mem.Allocator;

/// Gini coefficient for inequality measurement.
///
/// G = (1/n) * sum_{i=1}^{n} [(2*i - n - 1) * x_i] / sum(x)
///
/// Returns 0.0 for perfect equality (all values equal), 1.0 for maximum inequality.
pub fn giniCoefficient(values: []const f64) f64 {
    if (values.len <= 1) return 0.0;

    // Sort values ascending
    var sorted = std.ArrayList(f64).initCapacity(std.heap.page_allocator, values.len) catch return 0.0;
    defer sorted.deinit(std.heap.page_allocator);
    for (values) |v| {
        sorted.append(std.heap.page_allocator, v) catch return 0.0;
    }
    std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));

    // Compute total
    var total: f64 = 0.0;
    for (sorted.items) |v| {
        total += v;
    }
    if (total == 0.0) return 0.0;

    // Compute Gini
    const n = @as(f64, @floatFromInt(sorted.items.len));
    var numerator: f64 = 0.0;
    for (sorted.items, 0..) |v, i| {
        const idx = @as(f64, @floatFromInt(i + 1));
        numerator += (2.0 * idx - n - 1.0) * v;
    }

    const gini = numerator / (n * total);
    return @max(0.0, @min(1.0, gini));
}

/// Compute complexity Gini: inequality of cyclomatic complexity across functions.
/// Falls back to file line counts if no CC data.
pub fn computeComplexityGini(file_lines: []const u32) f64 {
    if (file_lines.len <= 1) return 0.0;

    var values = std.ArrayList(f64).initCapacity(std.heap.page_allocator, file_lines.len) catch return 0.0;
    defer values.deinit(std.heap.page_allocator);
    for (file_lines) |v| {
        values.append(std.heap.page_allocator, @floatFromInt(v)) catch return 0.0;
    }

    return giniCoefficient(values.items);
}

// ── Tests ─────────────────────────────────────────────────────

test "gini equal values" {
    const values = [_]f64{ 10.0, 10.0, 10.0, 10.0 };
    const gini = giniCoefficient(&values);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), gini, 0.001);
}

test "gini unequal values" {
    const values = [_]f64{ 1.0, 1.0, 1.0, 100.0 };
    const gini = giniCoefficient(&values);
    try std.testing.expect(gini > 0.5);
}

test "gini single value" {
    const values = [_]f64{42.0};
    const gini = giniCoefficient(&values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "gini empty" {
    const values = [_]f64{};
    const gini = giniCoefficient(&values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "gini all zeros" {
    const values = [_]f64{ 0.0, 0.0, 0.0 };
    const gini = giniCoefficient(&values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "complexity gini equal files" {
    const lines = [_]u32{ 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeComplexityGini(&lines), 0.001);
}
