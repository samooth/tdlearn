const std = @import("std");
const Allocator = std.mem.Allocator;

/// Exponential-decay activity heatmap tracker.
///
/// Tracks file modification activity with ripple animations.
/// Heat decays exponentially over time, so recently modified files
/// appear brighter/hotter in the visualization.
///
/// Usage:
///   var heat = try HeatTracker.init(allocator, half_life);
///   defer heat.deinit();
///   heat.record("src/main.zig");
///   const value = heat.get("src/main.zig"); // 0.0 to MAX_HEAT
pub const HeatTracker = struct {
    /// Maximum heat value (capped)
    pub const MAX_HEAT: f64 = 5.0;
    /// Maximum trail entries before pruning
    pub const MAX_TRAIL: usize = 500;

    entries: std.StringHashMap(HeatEntry),
    trail: std.ArrayList(TrailEntry),
    allocator: Allocator,
    io: std.Io,
    half_life: f64,
    last_prune: i64,

    const HeatEntry = struct {
        value: f64,
        last_modified: i64, // seconds since epoch
    };

    pub const TrailEntry = struct {
        path: []const u8,
        x: f32,
        y: f32,
        timestamp: i64,
    };

    pub fn init(allocator: Allocator, io: std.Io, half_life: f64) !HeatTracker {
        if (!std.math.isFinite(half_life) or half_life <= 0.0) return error.InvalidHalfLife;
        return .{
            .entries = std.StringHashMap(HeatEntry).init(allocator),
            .trail = std.ArrayList(TrailEntry).empty,
            .allocator = allocator,
            .io = io,
            .half_life = half_life,
            .last_prune = 0,
        };
    }

    /// Current wall-clock seconds since epoch.
    fn nowSeconds(self: *const HeatTracker) i64 {
        const ts = std.Io.Clock.Timestamp.now(self.io, .real);
        return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
    }

    pub fn deinit(self: *HeatTracker) void {
        self.entries.deinit();
        self.trail.deinit(self.allocator);
    }

    /// Record activity for a file path. Increases heat by 1.0 (capped at MAX_HEAT).
    pub fn record(self: *HeatTracker, path: []const u8) !void {
        const now = self.nowSeconds();
        const entry = self.entries.get(path);
        const old_value = if (entry) |e| e.value else 0.0;
        const new_value = @min(old_value + 1.0, MAX_HEAT);

        try self.entries.put(path, .{
            .value = new_value,
            .last_modified = now,
        });
    }

    /// Get current heat value for a file path (0.0 if not tracked).
    pub fn get(self: *HeatTracker, path: []const u8) f64 {
        const entry = self.entries.get(path) orelse return 0.0;
        const now = self.nowSeconds();
        const elapsed_secs = @as(f64, @floatFromInt(now - entry.last_modified));
        return decay(entry.value, elapsed_secs, self.half_life);
    }

    /// Get heat value normalized to 0.0-1.0 range.
    pub fn getNormalized(self: *HeatTracker, path: []const u8) f64 {
        return self.get(path) / MAX_HEAT;
    }

    /// Record a trail entry for rendering ripple effects.
    pub fn recordTrail(self: *HeatTracker, path: []const u8, x: f32, y: f32) !void {
        if (self.trail.items.len >= MAX_TRAIL) {
            // Remove oldest entry
            _ = self.trail.orderedRemove(0);
        }
        try self.trail.append(self.allocator, .{
            .path = path,
            .x = x,
            .y = y,
            .timestamp = self.nowSeconds(),
        });
    }

    /// Prune old trail entries based on max age.
    pub fn pruneTrail(self: *HeatTracker, max_age_secs: f64) void {
        const now = self.nowSeconds();
        const cutoff = now - @as(i64, @intFromFloat(max_age_secs));
        var i: usize = 0;
        while (i < self.trail.items.len) {
            if (self.trail.items[i].timestamp < cutoff) {
                _ = self.trail.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get all active trail entries (for rendering).
    pub fn getTrail(self: *const HeatTracker) []TrailEntry {
        return self.trail.items;
    }

    /// Number of tracked files.
    pub fn count(self: *const HeatTracker) usize {
        return self.entries.count();
    }

    /// Decay function: exponential decay with half-life.
    fn decay(value: f64, elapsed_secs: f64, half_life: f64) f64 {
        if (half_life <= 0.0) return value;
        const lambda = @log(2.0) / half_life;
        return value * @exp(-lambda * elapsed_secs);
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "HeatTracker basic record and get" {
    var heat = try HeatTracker.init(std.testing.allocator, std.testing.io, 3.0);
    defer heat.deinit();

    try heat.record("src/main.zig");
    const value = heat.get("src/main.zig");
    try std.testing.expect(value > 0.0);
    try std.testing.expect(value <= HeatTracker.MAX_HEAT);
}

test "HeatTracker rejects invalid half-life" {
    try std.testing.expectError(error.InvalidHalfLife, HeatTracker.init(std.testing.allocator, std.testing.io, 0.0));
    try std.testing.expectError(error.InvalidHalfLife, HeatTracker.init(std.testing.allocator, std.testing.io, std.math.nan(f64)));
}

test "HeatTracker capped at MAX_HEAT" {
    var heat = try HeatTracker.init(std.testing.allocator, std.testing.io, 3.0);
    defer heat.deinit();

    // Record 10 times — should cap at MAX_HEAT
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try heat.record("src/main.zig");
    }
    const value = heat.get("src/main.zig");
    try std.testing.expect(value <= HeatTracker.MAX_HEAT);
}

test "HeatTracker untracked path returns 0" {
    var heat = try HeatTracker.init(std.testing.allocator, std.testing.io, 3.0);
    defer heat.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), heat.get("nonexistent.zig"));
}

test "HeatTracker normalization" {
    var heat = try HeatTracker.init(std.testing.allocator, std.testing.io, 3.0);
    defer heat.deinit();

    try heat.record("test.zig");
    const normalized = heat.getNormalized("test.zig");
    try std.testing.expect(normalized >= 0.0);
    try std.testing.expect(normalized <= 1.0);
}

test "HeatTracker trail" {
    var heat = try HeatTracker.init(std.testing.allocator, std.testing.io, 3.0);
    defer heat.deinit();

    try heat.recordTrail("src/main.zig", 100.0, 200.0);
    try heat.recordTrail("src/lib.zig", 300.0, 400.0);

    const trail = heat.getTrail();
    try std.testing.expectEqual(@as(usize, 2), trail.len);
    try std.testing.expectEqual(@as(f32, 100.0), trail[0].x);
    try std.testing.expectEqual(@as(f32, 400.0), trail[1].y);
}

test "HeatTracker decay" {
    // Test the decay function directly
    const half_life = 3.0;
    try std.testing.expectEqual(@as(f64, 5.0), HeatTracker.decay(5.0, 0.0, half_life));
    try std.testing.expect(HeatTracker.decay(5.0, 3.0, half_life) < 5.0);
    try std.testing.expect(HeatTracker.decay(5.0, 6.0, half_life) < 2.5);
}
