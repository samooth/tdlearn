const std = @import("std");
const Allocator = std.mem.Allocator;

/// Quality gate baseline — stored at `.tdlearn/baseline.json`.
///
/// `gate --save` writes the current metrics; `gate` compares a fresh
/// scan against the saved baseline and fails on regression.
pub const Baseline = struct {
    schema_version: u32 = 1,
    quality_signal: f64 = 0.0,
    cycle_count: u32 = 0,
    max_depth: u32 = 0,
    total_functions: u32 = 0,
    dead_functions: u32 = 0,
    duplicate_functions: u32 = 0,

    pub const degradation_tolerance = 0.02;

    pub fn validate(self: Baseline) !void {
        if (self.schema_version != 1) return error.UnsupportedBaselineSchema;
        if (!std.math.isFinite(self.quality_signal) or self.quality_signal < 0.0 or self.quality_signal > 1.0) {
            return error.InvalidBaseline;
        }
    }

    /// Compare current metrics against this baseline.
    /// Returns a list of degradation descriptions (empty = no regression).
    pub fn diff(self: Baseline, current: Baseline, allocator: Allocator) ![]const []const u8 {
        var violations = std.ArrayList([]const u8).empty;
        errdefer violations.deinit(allocator);

        if (current.quality_signal < self.quality_signal - degradation_tolerance) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Quality signal dropped: {d:.3} -> {d:.3}",
                .{ self.quality_signal, current.quality_signal },
            ));
        }
        if (current.cycle_count > self.cycle_count) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Cycle count increased: {d} -> {d}",
                .{ self.cycle_count, current.cycle_count },
            ));
        }
        if (current.max_depth > self.max_depth) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Max depth increased: {d} -> {d}",
                .{ self.max_depth, current.max_depth },
            ));
        }
        if (current.dead_functions > self.dead_functions) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Dead functions increased: {d} -> {d}",
                .{ self.dead_functions, current.dead_functions },
            ));
        }
        if (current.duplicate_functions > self.duplicate_functions) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Duplicated functions increased: {d} -> {d}",
                .{ self.duplicate_functions, current.duplicate_functions },
            ));
        }

        return try violations.toOwnedSlice(allocator);
    }
};

/// Serialize a baseline to pretty JSON.
pub fn writeBaseline(allocator: Allocator, baseline: Baseline) ![]u8 {
    try baseline.validate();
    return std.json.Stringify.valueAlloc(allocator, baseline, .{ .whitespace = .indent_2 });
}

/// Parse a baseline from JSON contents.
pub fn readBaseline(allocator: Allocator, contents: []const u8) !Baseline {
    var parsed = try std.json.parseFromSlice(Baseline, allocator, contents, .{});
    defer parsed.deinit();
    try parsed.value.validate();
    return parsed.value;
}

// ── Tests ─────────────────────────────────────────────────────

test "baseline JSON round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const original = Baseline{
        .quality_signal = 0.7729,
        .cycle_count = 0,
        .max_depth = 2,
        .total_functions = 121,
        .dead_functions = 3,
        .duplicate_functions = 1,
    };

    const json = try writeBaseline(a, original);
    const restored = try readBaseline(a, json);

    try std.testing.expectApproxEqAbs(original.quality_signal, restored.quality_signal, 0.0001);
    try std.testing.expectEqual(original.cycle_count, restored.cycle_count);
    try std.testing.expectEqual(original.max_depth, restored.max_depth);
    try std.testing.expectEqual(original.total_functions, restored.total_functions);
    try std.testing.expectEqual(original.dead_functions, restored.dead_functions);
    try std.testing.expectEqual(original.duplicate_functions, restored.duplicate_functions);
}

test "no degradation when identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Baseline{ .quality_signal = 0.8, .cycle_count = 1, .max_depth = 3 };
    const violations = try b.diff(b, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "quality drop detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = Baseline{ .quality_signal = 0.80 };
    const after = Baseline{ .quality_signal = 0.70 };
    const violations = try before.diff(after, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expect(std.mem.indexOf(u8, violations[0], "Quality signal dropped") != null);
}

test "small quality drop tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = Baseline{ .quality_signal = 0.80 };
    // 0.01 drop < 0.02 tolerance
    const after = Baseline{ .quality_signal = 0.79 };
    const violations = try before.diff(after, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "cycle count increase detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = Baseline{ .quality_signal = 0.8, .cycle_count = 0 };
    const after = Baseline{ .quality_signal = 0.8, .cycle_count = 2 };
    const violations = try before.diff(after, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expect(std.mem.indexOf(u8, violations[0], "Cycle count") != null);
}

test "improvements are not violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = Baseline{
        .quality_signal = 0.5,
        .cycle_count = 5,
        .max_depth = 10,
        .dead_functions = 20,
        .duplicate_functions = 8,
    };
    const after = Baseline{
        .quality_signal = 0.9,
        .cycle_count = 0,
        .max_depth = 2,
        .dead_functions = 0,
        .duplicate_functions = 0,
    };
    const violations = try before.diff(after, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "baseline rejects invalid schema and score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedBaselineSchema, readBaseline(
        arena.allocator(),
        "{\"schema_version\": 2, \"quality_signal\": 0.5}",
    ));
    try std.testing.expectError(error.InvalidBaseline, readBaseline(
        arena.allocator(),
        "{\"schema_version\": 1, \"quality_signal\": 1.5}",
    ));
    try std.testing.expectError(error.InvalidBaseline, writeBaseline(
        arena.allocator(),
        .{ .quality_signal = -0.1 },
    ));
}

test "parse legacy/baseline json with missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Partial JSON — defaults fill the rest
    const json = "{\"quality_signal\": 0.5, \"cycle_count\": 1}";
    const b = try readBaseline(arena.allocator(), json);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.quality_signal, 0.001);
    try std.testing.expectEqual(@as(u32, 1), b.cycle_count);
    try std.testing.expectEqual(@as(u32, 0), b.max_depth);
}
