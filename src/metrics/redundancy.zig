const std = @import("std");
const Allocator = std.mem.Allocator;

/// Shannon entropy normalized to [0, 1].
///
/// H = -sum(p_i * log2(p_i)) / log2(N)
///
/// Returns 0.0 for uniform distribution (all equal), 1.0 for maximum entropy.
pub fn shannonEntropyNormalized(values: []const f64) f64 {
    if (values.len <= 1) return 0.0;

    // Compute total
    var total: f64 = 0.0;
    for (values) |v| {
        total += v;
    }
    if (total == 0.0) return 0.0;

    // Compute entropy
    var entropy: f64 = 0.0;
    for (values) |v| {
        if (v > 0.0) {
            const p = v / total;
            entropy -= p * std.math.log2(f64, p);
        }
    }

    // Normalize by log2(N)
    const max_entropy = std.math.log2(f64, @floatFromInt(values.len));
    if (max_entropy == 0.0) return 0.0;

    return entropy / max_entropy;
}

/// Compute structural entropy: normalized Shannon entropy of file sizes.
/// Returns 1.0 for 0-1 files (trivially consistent).
pub fn computeStructuralEntropy(allocator: Allocator, file_lines: []const u32) !f64 {
    if (file_lines.len <= 1) return 1.0;

    var f64_values = std.ArrayList(f64).initCapacity(allocator, file_lines.len);
    defer f64_values.deinit(allocator);
    for (file_lines) |value| {
        try f64_values.append(allocator, @floatFromInt(value));
    }

    return shannonEntropyNormalized(f64_values.items);
}

// ── Tests ─────────────────────────────────────────────────────

test "shannon entropy uniform" {
    const values = [_]f64{ 1.0, 1.0, 1.0, 1.0 };
    const entropy = shannonEntropyNormalized(&values);
    // Uniform distribution should have max entropy (1.0)
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entropy, 0.001);
}

test "shannon entropy skewed" {
    const values = [_]f64{ 100.0, 1.0, 1.0, 1.0 };
    const entropy = shannonEntropyNormalized(&values);
    // Skewed distribution should have lower entropy
    try std.testing.expect(entropy < 0.5);
}

test "shannon entropy single value" {
    const values = [_]f64{42.0};
    const entropy = shannonEntropyNormalized(&values);
    try std.testing.expectEqual(@as(f64, 0.0), entropy);
}

test "shannon entropy empty" {
    const values = [_]f64{};
    const entropy = shannonEntropyNormalized(&values);
    try std.testing.expectEqual(@as(f64, 0.0), entropy);
}

test "shannon entropy all zeros" {
    const values = [_]f64{ 0.0, 0.0, 0.0 };
    const entropy = shannonEntropyNormalized(&values);
    try std.testing.expectEqual(@as(f64, 0.0), entropy);
}

test "structural entropy single file" {
    const lines = [_]u32{100};
    try std.testing.expectEqual(@as(f64, 1.0), try computeStructuralEntropy(std.testing.allocator, &lines));
}

test "structural entropy propagates allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const lines = [_]u32{ 100, 200 };
    try std.testing.expectError(error.OutOfMemory, computeStructuralEntropy(failing.allocator(), &lines));
}

test "structural entropy equal files" {
    const lines = [_]u32{ 100, 100, 100, 100 };
    const entropy = try computeStructuralEntropy(std.testing.allocator, &lines);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entropy, 0.001);
}
