const std = @import("std");
const Allocator = std.mem.Allocator;
const toml_mod = @import("toml.zig");

/// Architectural rules from `.tdlearn/rules.toml`.
///
/// Sections:
///   [constraints]   — numeric thresholds on health metrics
///   [[layers]]      — layer ordering. HIGHER order = more foundational;
///                     dependencies must flow from low order to high order
///                     (a file importing a layer with LOWER order than its
///                     own is a violation)
///   [[boundaries]]  — deny import rules (glob patterns)
pub const RulesConfig = struct {
    constraints: Constraints = .{},
    layers: []const Layer = &.{},
    boundaries: []const Boundary = &.{},

    pub const Constraints = struct {
        min_quality: ?f64 = null,
        min_modularity: ?f64 = null,
        min_acyclicity: ?f64 = null,
        min_depth: ?f64 = null,
        min_equality: ?f64 = null,
        min_redundancy: ?f64 = null,
        max_cycles: ?u32 = null,
        max_file_lines: ?u32 = null,
        max_fn_lines: ?u32 = null,
    };

    pub const Layer = struct {
        name: []const u8,
        paths: []const []const u8,
        order: u32,
    };

    pub const Boundary = struct {
        from: []const u8,
        to: []const u8,
        reason: []const u8 = "",
    };
};

pub const Severity = enum {
    warning,
    err,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .warning => "Warning",
            .err => "Error",
        };
    }
};

pub const Violation = struct {
    rule: []const u8,
    severity: Severity,
    message: []const u8,
    files: []const []const u8 = &.{},
};

pub const CheckInput = struct {
    /// Scaled health scores [0,1] (from HealthReport.root_cause_scores)
    quality_signal: f64,
    modularity: f64,
    acyclicity: f64,
    depth: f64,
    equality: f64,
    redundancy: f64,
    cycle_count: u32,
    max_file_lines: u32,
    max_fn_lines: u32,
    /// All import edges (from_file, to_file)
    import_edges: []const Edge,
    /// All scanned file paths
    file_paths: []const []const u8,

    pub const Edge = struct {
        from: []const u8,
        to: []const u8,
    };
};

pub const CheckResult = struct {
    rules_checked: u32 = 0,
    violations: []const Violation = &.{},
    pub fn pass(self: CheckResult) bool {
        for (self.violations) |v| {
            if (v.severity == .err) return false;
        }
        return true;
    }
};

/// Parse rules from `.tdlearn/rules.toml` contents.
pub fn parseRules(allocator: Allocator, contents: []const u8) !RulesConfig {
    var toml = toml_mod.Toml.init(allocator);
    defer toml.deinit();
    try toml.parse(contents);

    var config = RulesConfig{};

    // [constraints]
    if (toml.table("constraints")) |c| {
        if (c.get("min_quality")) |v| config.constraints.min_quality = v.asFloat();
        if (c.get("min_modularity")) |v| config.constraints.min_modularity = v.asFloat();
        if (c.get("min_acyclicity")) |v| config.constraints.min_acyclicity = v.asFloat();
        if (c.get("min_depth")) |v| config.constraints.min_depth = v.asFloat();
        if (c.get("min_equality")) |v| config.constraints.min_equality = v.asFloat();
        if (c.get("min_redundancy")) |v| config.constraints.min_redundancy = v.asFloat();
        if (c.get("max_cycles")) |v| {
            if (v.asInt()) |i| config.constraints.max_cycles = @intCast(@max(0, i));
        }
        if (c.get("max_file_lines")) |v| {
            if (v.asInt()) |i| config.constraints.max_file_lines = @intCast(@max(0, i));
        }
        if (c.get("max_fn_lines")) |v| {
            if (v.asInt()) |i| config.constraints.max_fn_lines = @intCast(@max(0, i));
        }
    }

    // [[layers]] — needs an arena to outlive `toml`; use a leaky approach:
    // copy strings into caller-owned arena passed as `allocator`.
    if (toml.table("layers")) |l| {
        var layers = std.ArrayList(RulesConfig.Layer).empty;
        errdefer layers.deinit(allocator);
        for (l.array_entries.items, 0..) |entry, idx| {
            var name: []const u8 = "";
            var paths: []const []const u8 = &.{};
            var order: u32 = @intCast(idx);
            for (entry) |kv| {
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (kv.value.asString()) |s| name = try allocator.dupe(u8, s);
                } else if (std.mem.eql(u8, kv.key, "paths")) {
                    if (kv.value.asArray()) |arr| {
                        var list = std.ArrayList([]const u8).empty;
                        for (arr) |item| {
                            if (item.asString()) |s| {
                                try list.append(allocator, try allocator.dupe(u8, s));
                            }
                        }
                        paths = try list.toOwnedSlice(allocator);
                    }
                } else if (std.mem.eql(u8, kv.key, "order")) {
                    if (kv.value.asInt()) |i| order = @intCast(@max(0, i));
                }
            }
            try layers.append(allocator, .{
                .name = name,
                .paths = paths,
                .order = order,
            });
        }
        config.layers = try layers.toOwnedSlice(allocator);
    }

    // [[boundaries]]
    if (toml.table("boundaries")) |b| {
        var boundaries = std.ArrayList(RulesConfig.Boundary).empty;
        errdefer boundaries.deinit(allocator);
        for (b.array_entries.items) |entry| {
            var from: []const u8 = "";
            var to: []const u8 = "";
            var reason: []const u8 = "";
            for (entry) |kv| {
                if (std.mem.eql(u8, kv.key, "from")) {
                    if (kv.value.asString()) |s| from = try allocator.dupe(u8, s);
                } else if (std.mem.eql(u8, kv.key, "to")) {
                    if (kv.value.asString()) |s| to = try allocator.dupe(u8, s);
                } else if (std.mem.eql(u8, kv.key, "reason")) {
                    if (kv.value.asString()) |s| reason = try allocator.dupe(u8, s);
                }
            }
            try boundaries.append(allocator, .{ .from = from, .to = to, .reason = reason });
        }
        config.boundaries = try boundaries.toOwnedSlice(allocator);
    }

    return config;
}

/// Check a scan against rules. Returns violations (empty = pass).
pub fn checkRules(allocator: Allocator, config: *const RulesConfig, input: *const CheckInput) !CheckResult {
    var violations = std.ArrayList(Violation).empty;
    errdefer violations.deinit(allocator);

    const c = &config.constraints;
    var checked: u32 = 0;

    // ── Constraint checks ──
    if (c.min_quality) |min| {
        checked += 1;
        if (input.quality_signal < min) {
            try violations.append(allocator, .{
                .rule = "min_quality",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "quality {d:.3} < required {d:.3}", .{ input.quality_signal, min }),
            });
        }
    }
    if (c.min_modularity) |min| {
        checked += 1;
        if (input.modularity < min) {
            try violations.append(allocator, .{
                .rule = "min_modularity",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "modularity {d:.3} < required {d:.3}", .{ input.modularity, min }),
            });
        }
    }
    if (c.min_acyclicity) |min| {
        checked += 1;
        if (input.acyclicity < min) {
            try violations.append(allocator, .{
                .rule = "min_acyclicity",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "acyclicity {d:.3} < required {d:.3} ({d} cycles)", .{ input.acyclicity, min, input.cycle_count }),
            });
        }
    }
    if (c.min_depth) |min| {
        checked += 1;
        if (input.depth < min) {
            try violations.append(allocator, .{
                .rule = "min_depth",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "depth score {d:.3} < required {d:.3}", .{ input.depth, min }),
            });
        }
    }
    if (c.min_equality) |min| {
        checked += 1;
        if (input.equality < min) {
            try violations.append(allocator, .{
                .rule = "min_equality",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "equality {d:.3} < required {d:.3}", .{ input.equality, min }),
            });
        }
    }
    if (c.min_redundancy) |min| {
        checked += 1;
        if (input.redundancy < min) {
            try violations.append(allocator, .{
                .rule = "min_redundancy",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "redundancy {d:.3} < required {d:.3}", .{ input.redundancy, min }),
            });
        }
    }
    if (c.max_cycles) |max| {
        checked += 1;
        if (input.cycle_count > max) {
            try violations.append(allocator, .{
                .rule = "max_cycles",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "{d} cycles > allowed {d}", .{ input.cycle_count, max }),
            });
        }
    }
    if (c.max_file_lines) |max| {
        checked += 1;
        if (input.max_file_lines > max) {
            try violations.append(allocator, .{
                .rule = "max_file_lines",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "largest file has {d} lines > allowed {d}", .{ input.max_file_lines, max }),
            });
        }
    }
    if (c.max_fn_lines) |max| {
        checked += 1;
        if (input.max_fn_lines > max) {
            try violations.append(allocator, .{
                .rule = "max_fn_lines",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "largest function has {d} lines > allowed {d}", .{ input.max_fn_lines, max }),
            });
        }
    }

    // ── Layer rule ──
    // Semantics: HIGHER order = more foundational (core/infra at the top).
    // Violation when the importing file's layer order is GREATER than the
    // imported file's order (foundational code reaching up into presentation).
    // Dependencies should flow downward: low order → high order.
    if (config.layers.len >= 2) {
        checked += 1;
        for (input.import_edges) |edge| {
            const from_layer = layerOf(config.layers, edge.from) orelse continue;
            const to_layer = layerOf(config.layers, edge.to) orelse continue;
            // Violation when importer sits at a HIGHER order (less foundational)
            // than the imported module.
            if (from_layer.order > to_layer.order) {
                const files = try allocator.alloc([]const u8, 2);
                files[0] = edge.from;
                files[1] = edge.to;
                try violations.append(allocator, .{
                    .rule = "layer_order",
                    .severity = .err,
                    .message = try std.fmt.allocPrint(allocator, "layer '{s}' (order {d}) imports '{s}' (order {d})", .{ from_layer.name, from_layer.order, to_layer.name, to_layer.order }),
                    .files = files,
                });
            }
        }
    }

    // ── Boundary rules: deny from→to glob pairs ──
    for (config.boundaries) |b| {
        checked += 1;
        for (input.import_edges) |edge| {
            if (globMatch(b.from, edge.from) and globMatch(b.to, edge.to)) {
                const files = try allocator.alloc([]const u8, 2);
                files[0] = edge.from;
                files[1] = edge.to;
                try violations.append(allocator, .{
                    .rule = "boundary",
                    .severity = .err,
                    .message = try std.fmt.allocPrint(allocator, "{s} must not import {s}{s}{s}", .{
                        edge.from,
                        edge.to,
                        if (b.reason.len > 0) " — " else "",
                        b.reason,
                    }),
                    .files = files,
                });
            }
        }
    }

    return .{
        .rules_checked = checked,
        .violations = try violations.toOwnedSlice(allocator),
    };
}

/// Find the first layer whose paths match the file.
fn layerOf(layers: []const RulesConfig.Layer, path: []const u8) ?*const RulesConfig.Layer {
    for (layers) |*l| {
        for (l.paths) |pattern| {
            if (globMatch(pattern, path)) return l;
        }
    }
    return null;
}

/// Glob matcher supporting:
///   exact match, `*` (single segment), `**` (any depth),
///   `dir/**`, `dir/*`, `dir/prefix...`
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, pattern, path)) return true;

    // "dir/**" or "dir/**/*" — everything under dir
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        return std.mem.startsWith(u8, path, prefix) and
            (std.mem.eql(u8, path, prefix) or
            (path.len > prefix.len and path[prefix.len] == '/'));
    }
    if (std.mem.endsWith(u8, pattern, "/**/*")) {
        const prefix = pattern[0 .. pattern.len - 5];
        return std.mem.startsWith(u8, path, prefix) and
            path.len > prefix.len and path[prefix.len] == '/';
    }

    // "dir/*" — single-segment children
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 2];
        if (!std.mem.startsWith(u8, path, prefix)) return false;
        if (path.len <= prefix.len or path[prefix.len] != '/') return false;
        const rest = path[prefix.len + 1 ..];
        return std.mem.indexOfScalar(u8, rest, '/') == null;
    }

    // "*.ext" — any file with that extension
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const ext = pattern[1..];
        return std.mem.endsWith(u8, path, ext);
    }

    // Directory prefix: "src/core" matches "src/core/anything"
    if (std.mem.startsWith(u8, path, pattern) and
        path.len > pattern.len and
        path[pattern.len] == '/')
    {
        return true;
    }

    // Single `*` wildcard within the last segment: "src/foo*.zig"
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star| {
        if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') == null) {
            const prefix = pattern[0..star];
            const suffix = pattern[star + 1 ..];
            return std.mem.startsWith(u8, path, prefix) and
                std.mem.endsWith(u8, path, suffix) and
                path.len >= prefix.len + suffix.len;
        }
    }

    return false;
}

// ── Tests ─────────────────────────────────────────────────────

test "glob match basics" {
    try std.testing.expect(globMatch("src/core/types.zig", "src/core/types.zig"));
    try std.testing.expect(!globMatch("src/core", "src/metrics/mod.zig"));
    try std.testing.expect(globMatch("src/core", "src/core/types.zig"));
    try std.testing.expect(globMatch("src/core/**", "src/core/deep/nested/file.zig"));
    try std.testing.expect(globMatch("src/core/**", "src/core/types.zig"));
    try std.testing.expect(globMatch("src/**/*", "src/anything/deep.zig"));
    try std.testing.expect(globMatch("src/*", "src/top.zig"));
    try std.testing.expect(!globMatch("src/*", "src/sub/deep.zig"));
    try std.testing.expect(globMatch("*.zig", "any/file.zig"));
    try std.testing.expect(!globMatch("*.zig", "file.rs"));
    try std.testing.expect(globMatch("src/foo*.zig", "src/foobar.zig"));
    try std.testing.expect(!globMatch("src/foo*.zig", "src/bar.zig"));
}

test "parse rules constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.7
        \\max_cycles = 0
        \\max_file_lines = 500
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), config.constraints.min_quality.?, 0.001);
    try std.testing.expectEqual(@as(u32, 0), config.constraints.max_cycles.?);
    try std.testing.expectEqual(@as(u32, 500), config.constraints.max_file_lines.?);
    try std.testing.expect(config.constraints.min_modularity == null);
}

test "parse layers and boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/core/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/app/**", "src/main.zig"]
        \\order = 1
        \\
        \\[[boundaries]]
        \\from = "src/app/**"
        \\to = "src/renderer/**"
        \\reason = "app must not draw"
    );
    try std.testing.expectEqual(@as(usize, 2), config.layers.len);
    try std.testing.expectEqualStrings("core", config.layers[0].name);
    try std.testing.expectEqual(@as(u32, 0), config.layers[0].order);
    try std.testing.expectEqual(@as(u32, 1), config.layers[1].order);
    try std.testing.expectEqual(@as(usize, 1), config.boundaries.len);
    try std.testing.expectEqualStrings("app must not draw", config.boundaries[0].reason);
}

test "check constraints pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.5
        \\max_cycles = 2
    );
    const input = CheckInput{
        .quality_signal = 0.8,
        .modularity = 0.6,
        .acyclicity = 1.0,
        .depth = 0.9,
        .equality = 0.7,
        .redundancy = 0.95,
        .cycle_count = 1,
        .max_file_lines = 100,
        .max_fn_lines = 50,
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(result.pass());
    try std.testing.expectEqual(@as(u32, 2), result.rules_checked);
}

test "check constraints fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.9
        \\max_cycles = 0
    );
    const input = CheckInput{
        .quality_signal = 0.5,
        .modularity = 0.5,
        .acyclicity = 0.5,
        .depth = 0.5,
        .equality = 0.5,
        .redundancy = 0.5,
        .cycle_count = 3,
        .max_file_lines = 100,
        .max_fn_lines = 50,
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    // Both min_quality and max_cycles violated
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
}

test "layer order violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/core/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/app/**"]
        \\order = 1
    );
    // app (order 1) imports core (order 0) — violation: 1 > 0
    // core (order 0) imports app (order 1) — OK: 0 < 1
    const edges = [_]CheckInput.Edge{
        .{ .from = "src/app/main.zig", .to = "src/core/types.zig" },
        .{ .from = "src/core/types.zig", .to = "src/app/main.zig" },
    };
    const input = CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    const result = try checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqualStrings("layer_order", result.violations[0].rule);
}

test "boundary violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[boundaries]]
        \\from = "src/renderer/**"
        \\to = "src/analysis/**"
    );
    const edges = [_]CheckInput.Edge{
        .{ .from = "src/renderer/panel.zig", .to = "src/analysis/walker.zig" },
        .{ .from = "src/renderer/panel.zig", .to = "src/core/types.zig" },
    };
    const input = CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    const result = try checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqualStrings("boundary", result.violations[0].rule);
}
