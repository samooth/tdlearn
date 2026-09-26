const std = @import("std");
const Allocator = std.mem.Allocator;

/// Gini coefficient for inequality measurement.
///
/// G = (1/n) * sum_{i=1}^{n} [(2*i - n - 1) * x_i] / sum(x)
///
/// Returns 0.0 for perfect equality (all values equal), 1.0 for maximum inequality.
pub fn giniCoefficient(allocator: Allocator, values: []const f64) !f64 {
    if (values.len <= 1) return 0.0;

    var sorted = try std.ArrayList(f64).initCapacity(allocator, values.len);
    defer sorted.deinit(allocator);
    for (values) |value| try sorted.append(allocator, value);
    std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));

    var total: f64 = 0.0;
    for (sorted.items) |value| total += value;
    if (total == 0.0) return 0.0;

    const n = @as(f64, @floatFromInt(sorted.items.len));
    var numerator: f64 = 0.0;
    for (sorted.items, 0..) |value, index| {
        const rank = @as(f64, @floatFromInt(index + 1));
        numerator += (2.0 * rank - n - 1.0) * value;
    }

    const gini = numerator / (n * total);
    return @max(0.0, @min(1.0, gini));
}

pub fn computeFunctionComplexityGini(allocator: Allocator, complexities: []const f64) !f64 {
    return giniCoefficient(allocator, complexities);
}

pub fn computeFileSizeGini(allocator: Allocator, file_lines: []const u32) !f64 {
    if (file_lines.len <= 1) return 0.0;
    var values = try std.ArrayList(f64).initCapacity(allocator, file_lines.len);
    defer values.deinit(allocator);
    for (file_lines) |value| try values.append(allocator, @floatFromInt(value));
    return giniCoefficient(allocator, values.items);
}

// ── Tests ─────────────────────────────────────────────────────

test "gini equal values" {
    const values = [_]f64{ 10.0, 10.0, 10.0, 10.0 };
    const gini = try giniCoefficient(std.testing.allocator, &values);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), gini, 0.001);
}

test "gini unequal values" {
    const values = [_]f64{ 1.0, 1.0, 1.0, 100.0 };
    const gini = try giniCoefficient(std.testing.allocator, &values);
    try std.testing.expect(gini > 0.5);
}

test "gini single value" {
    const values = [_]f64{42.0};
    const gini = try giniCoefficient(std.testing.allocator, &values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "gini empty" {
    const values = [_]f64{};
    const gini = try giniCoefficient(std.testing.allocator, &values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "gini all zeros" {
    const values = [_]f64{ 0.0, 0.0, 0.0 };
    const gini = try giniCoefficient(std.testing.allocator, &values);
    try std.testing.expectEqual(@as(f64, 0.0), gini);
}

test "function complexity gini responds to branches" {
    const equal = [_]f64{ 1.0, 1.0, 1.0 };
    const uneven = [_]f64{ 1.0, 1.0, 8.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), try computeFunctionComplexityGini(std.testing.allocator, &equal), 0.001);
    try std.testing.expect((try computeFunctionComplexityGini(std.testing.allocator, &uneven)) > 0.4);
}

test "file size gini equal files" {
    const lines = [_]u32{ 100, 100, 100 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), try computeFileSizeGini(std.testing.allocator, &lines), 0.001);
}

test "gini propagates out of memory instead of reporting perfect equality" {
    const values = [_]f64{ 1.0, 1.0, 8.0 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, giniCoefficient(failing.allocator(), &values));
}

test "file size gini propagates out of memory" {
    const lines = [_]u32{ 1, 2, 900 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, computeFileSizeGini(failing.allocator(), &lines));
}
