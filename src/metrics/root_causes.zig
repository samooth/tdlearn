const std = @import("std");
const Allocator = std.mem.Allocator;

/// Root cause scores and quality signal aggregation.
///
/// Normalizes raw metrics to [0, 1] and computes geometric mean.
pub const RootCauseRaw = struct {
    modularity_q: f64 = 0.0,
    cycle_count: u32 = 0,
    max_depth: u32 = 0,
    complexity_gini: f64 = 0.0,
    redundancy_ratio: f64 = 0.0,
};

pub const RootCauseScores = struct {
    modularity: f64 = 0.0,
    acyclicity: f64 = 0.0,
    depth: f64 = 0.0,
    equality: f64 = 0.0,
    redundancy: f64 = 0.0,
};

pub const HealthReport = struct {
    quality_signal: f64 = 0.0,
    quality_signal_int: u32 = 0,
    root_cause_raw: RootCauseRaw = .{},
    root_cause_scores: RootCauseScores = .{},
    file_count: u32 = 0,
    line_count: u32 = 0,
    edge_count: u32 = 0,
    bottleneck: []const u8 = "",
};

/// Normalize raw metrics to [0, 1] scores and compute geometric mean.
///
/// Normalization rules:
/// - Modularity Q: (Q + 0.5) / 1.5  → [-0.5, 1.0] maps to [0, 1]
/// - Acyclicity: 1 / (1 + cycles)     → sigmoid (unbounded)
/// - Depth: 1 / (1 + depth / 8)       → sigmoid (midpoint=8)
/// - Equality: 1 - Gini               → direct invert
/// - Redundancy: 1 - ratio            → direct invert
pub fn computeRootCauseScores(raw: RootCauseRaw) struct { RootCauseScores, f64 } {
    const modularity = (raw.modularity_q + 0.5) / 1.5;
    const acyclicity = 1.0 / (1.0 + @as(f64, @floatFromInt(raw.cycle_count)));
    const depth = 1.0 / (1.0 + @as(f64, @floatFromInt(raw.max_depth)) / 8.0);
    const equality = 1.0 - raw.complexity_gini;
    const redundancy = 1.0 - raw.redundancy_ratio;

    const scores = RootCauseScores{
        .modularity = modularity,
        .acyclicity = acyclicity,
        .depth = depth,
        .equality = equality,
        .redundancy = redundancy,
    };

    // Geometric mean (floor each at 0.01 to prevent collapse)
    const values = [5]f64{
        @max(0.01, modularity),
        @max(0.01, acyclicity),
        @max(0.01, depth),
        @max(0.01, equality),
        @max(0.01, redundancy),
    };

    var product: f64 = 1.0;
    for (values) |v| {
        product *= v;
    }

    const quality_signal = std.math.pow(f64, product, 1.0 / 5.0);

    return .{ scores, quality_signal };
}

/// Find the bottleneck (lowest-scoring root cause).
pub fn findBottleneck(scores: RootCauseScores) []const u8 {
    const metrics_list = [_]struct { name: []const u8, score: f64 }{
        .{ .name = "modularity", .score = scores.modularity },
        .{ .name = "acyclicity", .score = scores.acyclicity },
        .{ .name = "depth", .score = scores.depth },
        .{ .name = "equality", .score = scores.equality },
        .{ .name = "redundancy", .score = scores.redundancy },
    };

    var min_name: []const u8 = "modularity";
    var min_score = metrics_list[0].score;

    for (metrics_list[1..]) |m| {
        if (m.score < min_score) {
            min_score = m.score;
            min_name = m.name;
        }
    }

    return min_name;
}

// ── Tests ─────────────────────────────────────────────────────

test "perfect quality" {
    const raw = RootCauseRaw{
        .modularity_q = 1.0,
        .cycle_count = 0,
        .max_depth = 0,
        .complexity_gini = 0.0,
        .redundancy_ratio = 0.0,
    };
    const scores, const signal = computeRootCauseScores(raw);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), signal, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), scores.modularity, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), scores.acyclicity, 0.001);
}

test "degraded quality" {
    const raw = RootCauseRaw{
        .modularity_q = 0.0,
        .cycle_count = 5,
        .max_depth = 10,
        .complexity_gini = 0.5,
        .redundancy_ratio = 0.3,
    };
    const scores, const signal = computeRootCauseScores(raw);
    try std.testing.expect(signal < 0.8);
    try std.testing.expect(scores.acyclicity < 0.5);
}

test "bottleneck detection" {
    const scores = RootCauseScores{
        .modularity = 0.8,
        .acyclicity = 1.0,
        .depth = 0.9,
        .equality = 0.3,
        .redundancy = 0.95,
    };
    const bottleneck = findBottleneck(scores);
    try std.testing.expectEqualStrings("equality", bottleneck);
}

test "quality signal integer" {
    const raw = RootCauseRaw{
        .modularity_q = 0.5,
        .cycle_count = 0,
        .max_depth = 2,
        .complexity_gini = 0.2,
        .redundancy_ratio = 0.1,
    };
    const result = computeRootCauseScores(raw);
    const signal_int = @as(u32, @intFromFloat(result[1] * 10000.0));
    try std.testing.expect(signal_int > 0);
    try std.testing.expect(signal_int <= 10000);
}
