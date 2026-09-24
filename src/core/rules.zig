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
    try validateTomlSyntax(allocator, contents);
    try toml.parse(contents);
    try validateToml(&toml);

    var config = RulesConfig{};
    parseConstraints(&toml, &config);
    try parseLayers(allocator, &toml, &config);
    try parseBoundaries(allocator, &toml, &config);
    try validateLayerConfig(config.layers);
    try validateBoundaryConfig(config.boundaries);
    return config;
}

fn parseConstraints(toml: *const toml_mod.Toml, config: *RulesConfig) void {
    const table = toml.table("constraints") orelse return;
    if (table.get("min_quality")) |value| config.constraints.min_quality = value.asFloat();
    if (table.get("min_modularity")) |value| config.constraints.min_modularity = value.asFloat();
    if (table.get("min_acyclicity")) |value| config.constraints.min_acyclicity = value.asFloat();
    if (table.get("min_depth")) |value| config.constraints.min_depth = value.asFloat();
    if (table.get("min_equality")) |value| config.constraints.min_equality = value.asFloat();
    if (table.get("min_redundancy")) |value| config.constraints.min_redundancy = value.asFloat();
    if (table.get("max_cycles")) |value| {
        if (value.asInt()) |number| config.constraints.max_cycles = @intCast(@max(0, number));
    }
    if (table.get("max_file_lines")) |value| {
        if (value.asInt()) |number| config.constraints.max_file_lines = @intCast(@max(0, number));
    }
    if (table.get("max_fn_lines")) |value| {
        if (value.asInt()) |number| config.constraints.max_fn_lines = @intCast(@max(0, number));
    }
}

fn parseLayers(allocator: Allocator, toml: *const toml_mod.Toml, config: *RulesConfig) !void {
    const table = toml.table("layers") orelse return;
    var layers = std.ArrayList(RulesConfig.Layer).empty;
    errdefer layers.deinit(allocator);
    for (table.array_entries.items, 0..) |entry, index| {
        var name: []const u8 = "";
        var paths: []const []const u8 = &.{};
        var order: u32 = @intCast(index);
        for (entry) |item| {
            if (std.mem.eql(u8, item.key, "name")) {
                if (item.value.asString()) |value| name = try allocator.dupe(u8, value);
                try validateLayerName(name);
            } else if (std.mem.eql(u8, item.key, "paths")) {
                if (item.value.asArray()) |values| {
                    var list = std.ArrayList([]const u8).empty;
                    for (values) |value| {
                        if (value.asString()) |pattern| {
                            try list.append(allocator, try normalizePattern(allocator, pattern));
                        }
                    }
                    paths = try list.toOwnedSlice(allocator);
                }
            } else if (std.mem.eql(u8, item.key, "order")) {
                if (item.value.asInt()) |value| order = @intCast(@max(0, value));
            }
        }
        try layers.append(allocator, .{ .name = name, .paths = paths, .order = order });
    }
    config.layers = try layers.toOwnedSlice(allocator);
}

fn parseBoundaries(allocator: Allocator, toml: *const toml_mod.Toml, config: *RulesConfig) !void {
    const table = toml.table("boundaries") orelse return;
    var boundaries = std.ArrayList(RulesConfig.Boundary).empty;
    errdefer boundaries.deinit(allocator);
    for (table.array_entries.items) |entry| {
        var from: []const u8 = "";
        var to: []const u8 = "";
        var reason: []const u8 = "";
        for (entry) |item| {
            if (std.mem.eql(u8, item.key, "from")) {
                if (item.value.asString()) |value| from = try normalizePattern(allocator, value);
            } else if (std.mem.eql(u8, item.key, "to")) {
                if (item.value.asString()) |value| to = try normalizePattern(allocator, value);
            } else if (std.mem.eql(u8, item.key, "reason")) {
                if (item.value.asString()) |value| reason = try allocator.dupe(u8, value);
            }
        }
        try boundaries.append(allocator, .{ .from = from, .to = to, .reason = reason });
    }
    config.boundaries = try boundaries.toOwnedSlice(allocator);
}

fn validateLayerConfig(layers: []const RulesConfig.Layer) !void {
    for (layers, 0..) |layer, layer_index| {
        try validateLayerName(layer.name);
        for (layer.paths, 0..) |pattern, path_index| {
            try validatePattern(pattern);
            for (layer.paths[0..path_index]) |previous| {
                if (std.mem.eql(u8, previous, pattern)) return error.InvalidRules;
            }
            for (layers[0..layer_index]) |previous_layer| {
                for (previous_layer.paths) |previous_pattern| {
                    if (std.mem.eql(u8, previous_pattern, pattern)) return error.InvalidRules;
                }
            }
        }
        for (layers[0..layer_index]) |previous_layer| {
            if (std.mem.eql(u8, previous_layer.name, layer.name)) return error.InvalidRules;
        }
    }
}

fn validateBoundaryConfig(boundaries: []const RulesConfig.Boundary) !void {
    for (boundaries, 0..) |boundary, index| {
        try validatePattern(boundary.from);
        try validatePattern(boundary.to);
        for (boundaries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.from, boundary.from) and
                std.mem.eql(u8, previous.to, boundary.to)) return error.InvalidRules;
        }
    }
}

fn validateLayerName(name: []const u8) !void {
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidRules;
    for (name) |character| {
        if (character <= 0x20 or character == 0x7f or
            character == '/' or character == '\\' or character == '*' or
            character == '?' or character == '[' or character == ']') return error.InvalidRules;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidRules;
}

fn validatePattern(pattern: []const u8) !void {
    if (pattern.len == 0 or !std.unicode.utf8ValidateSlice(pattern)) return error.InvalidRules;
    if (std.mem.startsWith(u8, pattern, "/")) return error.InvalidRules;
    if (pattern.len >= 2 and std.ascii.isAlphabetic(pattern[0]) and pattern[1] == ':') return error.InvalidRules;
    var segments = std.mem.splitScalar(u8, pattern, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidRules;
        var stars: usize = 0;
        var index: usize = 0;
        while (index < segment.len) : (index += 1) {
            if (segment[index] == '\\') {
                if (index + 1 >= segment.len) return error.InvalidRules;
                index += 1;
                continue;
            }
            if (segment[index] == '*') {
                stars += 1;
            } else if (segment[index] == '?') {
                continue;
            } else if (segment[index] == '[' or segment[index] == ']') {
                return error.InvalidRules;
            } else if (segment[index] < 0x20 or segment[index] == 0x7f) {
                return error.InvalidRules;
            }
        }
        if (stars > 1 and !std.mem.eql(u8, segment, "**")) return error.InvalidRules;
    }
}

fn normalizePattern(allocator: Allocator, pattern: []const u8) ![]const u8 {
    var normalized = std.ArrayList(u8).empty;
    errdefer normalized.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '\\' and index + 1 < pattern.len and
            (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == '/') and
            (pattern[index + 1] == '*' or pattern[index + 1] == '?' or
                pattern[index + 1] == '[' or pattern[index + 1] == ']' or pattern[index + 1] == '\\'))
        {
            try normalized.append(allocator, '\\');
        } else if (pattern[index] == '\\') {
            try normalized.append(allocator, '/');
        } else {
            try normalized.append(allocator, pattern[index]);
        }
    }
    try validatePattern(normalized.items);
    return try normalized.toOwnedSlice(allocator);
}

fn validateInputPath(path: []const u8) !void {
    if (path.len == 0 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return error.InvalidPath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
    }
}

fn validateTomlSyntax(allocator: Allocator, contents: []const u8) !void {
    const SeenKey = struct {
        section: []const u8,
        key: []const u8,
    };
    var seen = std.ArrayList(SeenKey).empty;
    defer seen.deinit(allocator);
    var current_section: []const u8 = "";
    var array_section = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripTomlComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.startsWith(u8, line, "[[")) {
                if (line.len < 4 or !std.mem.endsWith(u8, line, "]]")) return error.InvalidRules;
                current_section = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
                array_section = true;
                seen.clearRetainingCapacity();
            } else {
                if (line.len < 2 or !std.mem.endsWith(u8, line, "]")) return error.InvalidRules;
                const next_section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
                if (!array_section and current_section.len > 0 and
                    std.mem.eql(u8, current_section, next_section))
                {
                    return error.InvalidRules;
                }
                current_section = next_section;
                array_section = false;
                seen.clearRetainingCapacity();
            }
            continue;
        }

        const separator = findAssignment(line) orelse return error.InvalidRules;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidRules;
        if (value[0] == '\'') return error.InvalidRules;
        if (value[0] == '"' and !hasClosingQuote(value)) return error.InvalidRules;
        if (value[0] == '[' and !hasClosingBracket(value)) return error.InvalidRules;

        for (seen.items) |entry| {
            if (std.mem.eql(u8, entry.section, current_section) and
                std.mem.eql(u8, entry.key, key))
            {
                return error.InvalidRules;
            }
        }
        try seen.append(allocator, .{ .section = current_section, .key = key });
    }
}

fn stripTomlComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |character, index| {
        if (in_string) {
            if (character == '\\' and !escaped) {
                escaped = true;
            } else {
                if (character == '"' and !escaped) in_string = false;
                escaped = false;
            }
        } else if (character == '"') {
            in_string = true;
        } else if (character == '#') {
            return line[0..index];
        }
    }
    return line;
}

fn findAssignment(line: []const u8) ?usize {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |character, index| {
        if (in_string) {
            if (character == '\\' and !escaped) {
                escaped = true;
            } else {
                if (character == '"' and !escaped) in_string = false;
                escaped = false;
            }
        } else if (character == '"') {
            in_string = true;
        } else if (character == '=') {
            return index;
        }
    }
    return null;
}

fn hasClosingQuote(value: []const u8) bool {
    if (value.len < 2) return false;
    var escaped = false;
    for (value[1..], 1..) |character, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (character == '\\') {
            escaped = true;
        } else if (character == '"') {
            return index + 1 == value.len;
        }
    }
    return false;
}

fn hasClosingBracket(value: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (value) |character| {
        if (in_string) {
            if (character == '\\' and !escaped) {
                escaped = true;
            } else {
                if (character == '"' and !escaped) in_string = false;
                escaped = false;
            }
            continue;
        }
        if (character == '"') {
            in_string = true;
        } else if (character == '[') {
            depth += 1;
        } else if (character == ']') {
            if (depth == 0) return false;
            depth -= 1;
        }
    }
    return depth == 0 and !in_string;
}

fn validateToml(toml: *const toml_mod.Toml) !void {
    for (toml.tables.items) |*table| {
        if (std.mem.eql(u8, table.name, "constraints")) {
            try validateConstraints(table);
        } else if (std.mem.eql(u8, table.name, "layers")) {
            if (table.values.count() != 0) return error.InvalidRules;
            try validateLayers(table);
        } else if (std.mem.eql(u8, table.name, "boundaries")) {
            if (table.values.count() != 0) return error.InvalidRules;
            try validateBoundaries(table);
        } else if (std.mem.eql(u8, table.name, "")) {
            if (table.values.count() != 0) return error.InvalidRules;
        } else {
            return error.InvalidRules;
        }
    }
}

fn validateConstraints(table: *const toml_mod.Table) !void {
    for (table.values.keys()) |key| {
        const value = table.get(key).?;
        if (isScoreKey(key)) {
            _ = try scoreValue(value);
        } else if (isUnsignedKey(key)) {
            _ = try unsignedValue(value);
        } else {
            return error.InvalidRules;
        }
    }
}

fn validateLayers(table: *const toml_mod.Table) !void {
    for (table.array_entries.items) |entry| {
        var has_name = false;
        var has_paths = false;
        var has_order = false;
        for (entry) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) {
                if (has_name) return error.InvalidRules;
                has_name = true;
                _ = try nonEmptyString(kv.value);
            } else if (std.mem.eql(u8, kv.key, "paths")) {
                if (has_paths) return error.InvalidRules;
                has_paths = true;
                const values = kv.value.asArray() orelse return error.InvalidRules;
                if (values.len == 0) return error.InvalidRules;
                for (values) |value| _ = try nonEmptyString(value);
            } else if (std.mem.eql(u8, kv.key, "order")) {
                if (has_order) return error.InvalidRules;
                has_order = true;
                _ = try unsignedValue(kv.value);
            } else if (!std.mem.eql(u8, kv.key, "__entry_marker__")) {
                return error.InvalidRules;
            }
        }
        if (!has_name or !has_paths or !has_order) return error.InvalidRules;
    }
}

fn validateBoundaries(table: *const toml_mod.Table) !void {
    for (table.array_entries.items) |entry| {
        var has_from = false;
        var has_to = false;
        var has_reason = false;
        for (entry) |kv| {
            if (std.mem.eql(u8, kv.key, "from")) {
                if (has_from) return error.InvalidRules;
                has_from = true;
                _ = try nonEmptyString(kv.value);
            } else if (std.mem.eql(u8, kv.key, "to")) {
                if (has_to) return error.InvalidRules;
                has_to = true;
                _ = try nonEmptyString(kv.value);
            } else if (std.mem.eql(u8, kv.key, "reason")) {
                if (has_reason) return error.InvalidRules;
                has_reason = true;
                if (kv.value.asString() == null) return error.InvalidRules;
            } else if (!std.mem.eql(u8, kv.key, "__entry_marker__")) {
                return error.InvalidRules;
            }
        }
        if (!has_from or !has_to) return error.InvalidRules;
    }
}

fn isScoreKey(key: []const u8) bool {
    const keys = [_][]const u8{
        "min_quality",
        "min_modularity",
        "min_acyclicity",
        "min_depth",
        "min_equality",
        "min_redundancy",
    };
    for (keys) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

fn isUnsignedKey(key: []const u8) bool {
    const keys = [_][]const u8{ "max_cycles", "max_file_lines", "max_fn_lines" };
    for (keys) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

fn scoreValue(value: toml_mod.Value) !f64 {
    const score: f64 = switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => return error.InvalidRules,
    };
    if (!std.math.isFinite(score) or score < 0.0 or score > 1.0) return error.InvalidRules;
    return score;
}

fn unsignedValue(value: toml_mod.Value) !u32 {
    const number = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidRules,
    };
    if (number < 0 or number > @as(i64, std.math.maxInt(u32))) return error.InvalidRules;
    return @intCast(number);
}

fn nonEmptyString(value: toml_mod.Value) ![]const u8 {
    const string = value.asString() orelse return error.InvalidRules;
    if (string.len == 0) return error.InvalidRules;
    return string;
}

/// Check a scan against rules. Returns violations (empty = pass).
pub fn checkRules(allocator: Allocator, config: *const RulesConfig, input: *const CheckInput) !CheckResult {
    var violations = std.ArrayList(Violation).empty;
    defer violations.deinit(allocator);

    try validateLayerConfig(config.layers);
    try validateBoundaryConfig(config.boundaries);
    for (input.file_paths) |path| try validateInputPath(path);
    for (input.import_edges) |edge| {
        try validateInputPath(edge.from);
        try validateInputPath(edge.to);
    }

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

    for (input.file_paths) |path| _ = try layerOf(config.layers, path);

    // ── Layer rule ──
    // Semantics: HIGHER order = more foundational (core/infra at the top).
    // Violation when the importing file's layer order is GREATER than the
    // imported file's order (foundational code reaching up into presentation).
    // Dependencies should flow downward: low order → high order.
    if (config.layers.len >= 2) {
        checked += 1;
        for (input.import_edges) |edge| {
            const from_layer = (try layerOf(config.layers, edge.from)) orelse continue;
            const to_layer = (try layerOf(config.layers, edge.to)) orelse continue;
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

    std.sort.heap(Violation, violations.items, {}, violationLessThan);
    var unique = std.ArrayList(Violation).empty;
    defer unique.deinit(allocator);
    for (violations.items) |violation| {
        if (unique.items.len > 0 and sameViolation(unique.items[unique.items.len - 1], violation)) continue;
        try unique.append(allocator, violation);
    }

    return .{
        .rules_checked = checked,
        .violations = try unique.toOwnedSlice(allocator),
    };
}

fn violationLessThan(_: void, left: Violation, right: Violation) bool {
    const rule_order = std.mem.order(u8, left.rule, right.rule);
    if (rule_order == .lt) return true;
    if (rule_order == .gt) return false;
    const from_order = std.mem.order(u8, fileAt(left, 0), fileAt(right, 0));
    if (from_order == .lt) return true;
    if (from_order == .gt) return false;
    const to_order = std.mem.order(u8, fileAt(left, 1), fileAt(right, 1));
    if (to_order == .lt) return true;
    if (to_order == .gt) return false;
    return std.mem.lessThan(u8, left.message, right.message);
}

fn sameViolation(left: Violation, right: Violation) bool {
    if (!std.mem.eql(u8, left.rule, right.rule) or left.files.len != right.files.len) return false;
    for (left.files, 0..) |file, index| {
        if (!std.mem.eql(u8, file, right.files[index])) return false;
    }
    return true;
}

fn fileAt(violation: Violation, index: usize) []const u8 {
    return if (index < violation.files.len) violation.files[index] else "";
}

/// Find the unique layer whose paths match the file.
fn layerOf(layers: []const RulesConfig.Layer, path: []const u8) !?*const RulesConfig.Layer {
    var found: ?*const RulesConfig.Layer = null;
    for (layers) |*layer| {
        for (layer.paths) |pattern| {
            if (!globMatch(pattern, path)) continue;
            if (found != null) return error.AmbiguousLayer;
            found = layer;
            break;
        }
    }
    return found;
}

fn pathBaseName(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[separator + 1 ..];
}

/// Glob matcher supporting exact paths, `*` within one segment, `**` across
/// segments, and `?` for one UTF-8 codepoint. A backslash escapes the next
/// pattern byte. Rule files normalize ordinary Windows separators to `/`;
/// literal paths supplied to the checker must already be root-relative `/`
/// paths. Invalid, absolute, and traversal patterns are rejected at parse time.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, path)) return true;
    if (matchSegments(pattern, path)) return true;
    if (std.mem.indexOfScalar(u8, pattern, '\\') != null and matchSegmentsNative(pattern, 0, path, 0)) return true;

    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        return matchSegment(pattern, pathBaseName(path));
    }

    if (std.mem.indexOfScalar(u8, pattern, '*') == null and
        std.mem.indexOfScalar(u8, pattern, '?') == null and
        path.len > pattern.len and
        std.mem.startsWith(u8, path, pattern) and
        path[pattern.len] == '/')
    {
        return true;
    }

    return false;
}

fn matchSegmentsNative(pattern: []const u8, pattern_start: usize, path: []const u8, path_start: usize) bool {
    if (pattern_start >= pattern.len) return path_start >= path.len;
    const pattern_end = nativeSegmentEnd(pattern, pattern_start);
    const segment = pattern[pattern_start..pattern_end];
    if (std.mem.eql(u8, segment, "**")) {
        const next_pattern = if (pattern_end < pattern.len) pattern_end + 1 else pattern_end;
        if (next_pattern >= pattern.len) return true;
        var current = path_start;
        while (true) {
            if (matchSegmentsNative(pattern, next_pattern, path, current)) return true;
            if (current >= path.len) return false;
            const end = segmentEnd(path, current);
            current = if (end < path.len) end + 1 else end;
        }
    }
    if (path_start >= path.len) return false;
    const path_end = segmentEnd(path, path_start);
    if (!matchSegment(segment, path[path_start..path_end])) return false;
    const next_pattern = if (pattern_end < pattern.len) pattern_end + 1 else pattern_end;
    const next_path = if (path_end < path.len) path_end + 1 else path_end;
    return matchSegmentsNative(pattern, next_pattern, path, next_path);
}

fn nativeSegmentEnd(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len and value[index] != '/' and value[index] != '\\') : (index += 1) {}
    return index;
}

fn matchSegments(pattern: []const u8, path: []const u8) bool {
    return matchSegmentsAt(pattern, 0, path, 0);
}

fn matchSegmentsAt(pattern: []const u8, pattern_start: usize, path: []const u8, path_start: usize) bool {
    if (pattern_start >= pattern.len) return path_start >= path.len;

    const pattern_end = segmentEnd(pattern, pattern_start);
    const segment = pattern[pattern_start..pattern_end];
    if (std.mem.eql(u8, segment, "**")) {
        const next_pattern = if (pattern_end < pattern.len) pattern_end + 1 else pattern_end;
        if (next_pattern >= pattern.len) return true;

        var current = path_start;
        while (true) {
            if (matchSegmentsAt(pattern, next_pattern, path, current)) return true;
            if (current >= path.len) return false;
            const end = segmentEnd(path, current);
            current = if (end < path.len) end + 1 else end;
        }
    }

    if (path_start >= path.len) return false;
    const path_end = segmentEnd(path, path_start);
    if (!matchSegment(segment, path[path_start..path_end])) return false;
    const next_pattern = if (pattern_end < pattern.len) pattern_end + 1 else pattern_end;
    const next_path = if (path_end < path.len) path_end + 1 else path_end;
    return matchSegmentsAt(pattern, next_pattern, path, next_path);
}

fn segmentEnd(value: []const u8, start: usize) usize {
    const relative_end = std.mem.indexOfScalarPos(u8, value, start, '/') orelse return value.len;
    return relative_end;
}

fn matchSegment(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var star_text_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '\\' and
            pattern_index + 1 < pattern.len)
        {
            if (pattern[pattern_index + 1] != text[text_index]) {
                if (star_index) |star| {
                    pattern_index = star + 1;
                    star_text_index += 1;
                    if (star_text_index > text.len) return false;
                    text_index = star_text_index;
                    continue;
                }
                return false;
            }
            pattern_index += 2;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '?') {
            const length = utf8SequenceLength(text[text_index]) orelse return false;
            if (length > text.len - text_index) return false;
            pattern_index += 1;
            text_index += length;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == text[text_index]) {
            pattern_index += 1;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            star_text_index = text_index;
            pattern_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_text_index += 1;
            if (star_text_index > text.len) return false;
            text_index = star_text_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn utf8SequenceLength(first: u8) ?usize {
    return switch (first) {
        0x00...0x7f => 1,
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => null,
    };
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

test "glob escapes and unicode wildcards" {
    try std.testing.expect(globMatch("src/\\*.zig", "src/*.zig"));
    try std.testing.expect(!globMatch("src/\\*.zig", "src/file.zig"));
    try std.testing.expect(globMatch("src/?.zig", "src/é.zig"));
    try std.testing.expect(!globMatch("src/?.zig", "src/éé.zig"));
    try std.testing.expect(globMatch("src/Ж*.zig", "src/Журнал.zig"));
    try std.testing.expect(globMatch("src\\core\\*.zig", "src/core/file.zig"));
}

test "glob segment boundaries" {
    try std.testing.expect(globMatch("src/**/test.zig", "src/a/b/test.zig"));
    try std.testing.expect(!globMatch("src/*/test.zig", "src/a/b/test.zig"));
    try std.testing.expect(globMatch("**/*.zig", "a/b.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/a/b.zig"));
    try std.testing.expect(globMatch("src/core", "src/core/types.zig"));
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

test "parse rules rejects invalid values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 1.5
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\max_cycles = -1
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\unknown = 1
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality 0.7
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = "0.7
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.7
        \\min_quality = 0.8
    ));
}

test "parse rules rejects incomplete layers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
    ));
}

test "parse rules normalizes Windows separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src\core\types.zig", "src\core\*.zig", "src/\*.zig"]
        \\order = 0
    );
    try std.testing.expectEqualStrings("src/core/types.zig", config.layers[0].paths[0]);
    try std.testing.expectEqualStrings("src/core/*.zig", config.layers[0].paths[1]);
    try std.testing.expectEqualStrings("src/\\*.zig", config.layers[0].paths[2]);
}

test "parse rules rejects invalid layer names and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "bad name"
        \\paths = ["src/**"]
        \\order = 0
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["/absolute/**"]
        \\order = 0
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/../outside/**"]
        \\order = 0
    ));
}

test "parse rules rejects duplicate layer names and patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "core"
        \\paths = ["lib/**"]
        \\order = 1
    ));
    try std.testing.expectError(error.InvalidRules, parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/**"]
        \\order = 1
    ));
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

test "ambiguous layers are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/*"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/**"]
        \\order = 1
    );
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
        .import_edges = &.{},
        .file_paths = &[_][]const u8{"src/file.zig"},
    };
    try std.testing.expectError(error.AmbiguousLayer, checkRules(arena.allocator(), &config, &input));
}

test "violations are deduplicated and deterministically ordered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(),
        \\[[boundaries]]
        \\from = "src/**"
        \\to = "lib/**"
        \\
        \\[[boundaries]]
        \\from = "src/*"
        \\to = "lib/*"
    );
    const edges = [_]CheckInput.Edge{
        .{ .from = "src/z.zig", .to = "lib/b.zig" },
        .{ .from = "src/a.zig", .to = "lib/a.zig" },
        .{ .from = "src/z.zig", .to = "lib/b.zig" },
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
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
    try std.testing.expectEqualStrings("src/a.zig", result.violations[0].files[0]);
    try std.testing.expectEqualStrings("src/z.zig", result.violations[1].files[0]);
}

test "check rules rejects absolute input paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parseRules(arena.allocator(), "[constraints]\nmin_quality = 0.5");
    const edges = [_]CheckInput.Edge{.{ .from = "/tmp/a.zig", .to = "src/b.zig" }};
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
    try std.testing.expectError(error.InvalidPath, checkRules(arena.allocator(), &config, &input));
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
