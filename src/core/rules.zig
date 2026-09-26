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
        /// Per-function ceilings. Unlike `max_fn_lines`, which reports the
        /// single largest function, these report *every* offending function, so
        /// the result is a work list rather than a number to look up.
        max_cyclomatic: ?u32 = null,
        max_cognitive: ?u32 = null,
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
    /// What the violation is about, when the rule identifies one: today only
    /// the per-function complexity ceilings do, and it is the function name.
    /// `null` for aggregate and edge rules, so consumers can treat the field
    /// as "the offending symbol" without parsing the message.
    subject: ?[]const u8 = null,
    /// 1-based line of `subject` when the rule knows it, so a CI integration
    /// can annotate the exact line and so violations of the same file sort in
    /// source order instead of lexicographic order ("9" after "10").
    line: ?u32 = null,
};

/// One function's measured complexity, as the rules engine sees it. Declared
/// here rather than reused from the analysis layer because `core` is the
/// foundational layer and must not depend on `analysis`/`metrics`; `main`
/// maps the extracted functions onto this shape.
pub const FunctionComplexity = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    cyclomatic: u32,
    cognitive: u32,
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
    /// Every extracted function with its measured complexity, used by
    /// `max_cyclomatic` / `max_cognitive`. Functions with no complexity data
    /// are counted as 0 and therefore never violate a ceiling.
    functions: []const FunctionComplexity = &.{},
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
    if (table.get("max_cyclomatic")) |value| {
        if (value.asInt()) |number| config.constraints.max_cyclomatic = @intCast(@max(0, number));
    }
    if (table.get("max_cognitive")) |value| {
        if (value.asInt()) |number| config.constraints.max_cognitive = @intCast(@max(0, number));
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

/// A glob pattern is a sequence of `/`-separated segments, each of which may
/// contain `*`, `?` and backslash escapes. Rejected: empty or non-UTF-8 input,
/// absolute paths, Windows drive prefixes, empty/`.`/`..` segments, unbalanced
/// `[`/`]`, control characters, a trailing escape, and more than one `*` in a
/// segment unless the whole segment is exactly `**`.
fn validatePattern(pattern: []const u8) !void {
    if (pattern.len == 0 or !std.unicode.utf8ValidateSlice(pattern)) return error.InvalidRules;
    if (std.mem.startsWith(u8, pattern, "/")) return error.InvalidRules;
    if (pattern.len >= 2 and std.ascii.isAlphabetic(pattern[0]) and pattern[1] == ':') return error.InvalidRules;
    var segments = std.mem.splitScalar(u8, pattern, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidRules;
        try validatePatternSegment(segment);
    }
}

fn validatePatternSegment(segment: []const u8) !void {
    var stars: usize = 0;
    var index: usize = 0;
    while (index < segment.len) : (index += 1) {
        const c = segment[index];
        if (c == '\\') {
            if (index + 1 >= segment.len) return error.InvalidRules;
            index += 1;
            continue;
        }
        if (c == '*') {
            stars += 1;
            continue;
        }
        if (c == '?' or c == '[' or c == ']') {
            if (c == '[' or c == ']') return error.InvalidRules;
            continue;
        }
        if (c < 0x20 or c == 0x7f) return error.InvalidRules;
    }
    if (stars > 1 and !std.mem.eql(u8, segment, "**")) return error.InvalidRules;
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

/// A key already assigned in the current section, used to reject duplicates.
const SeenKey = struct {
    section: []const u8,
    key: []const u8,
};

fn validateTomlSyntax(allocator: Allocator, contents: []const u8) !void {
    var seen = std.ArrayList(SeenKey).empty;
    defer seen.deinit(allocator);
    var current_section: []const u8 = "";
    var array_section = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripTomlComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            const section = try sectionHeader(line, current_section, array_section);
            current_section = section.name;
            array_section = section.is_array;
            // A new section restarts the duplicate-key scope.
            seen.clearRetainingCapacity();
            continue;
        }

        const separator = findAssignment(line) orelse return error.InvalidRules;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        try validateAssignment(key, value);
        if (wasSeen(seen.items, current_section, key)) return error.InvalidRules;
        try seen.append(allocator, .{ .section = current_section, .key = key });
    }
}

const SectionHeader = struct {
    name: []const u8,
    is_array: bool,
};

/// Parse a `[name]` or `[[name]]` line. A `[name]` that repeats the current
/// non-array section is a duplicate-section error; the same name in a different
/// section, or repeated as an array of tables, is fine.
fn sectionHeader(line: []const u8, current_section: []const u8, array_section: bool) !SectionHeader {
    if (std.mem.startsWith(u8, line, "[[")) {
        if (line.len < 4 or !std.mem.endsWith(u8, line, "]]")) return error.InvalidRules;
        return .{
            .name = std.mem.trim(u8, line[2 .. line.len - 2], " \t"),
            .is_array = true,
        };
    }
    if (line.len < 2 or !std.mem.endsWith(u8, line, "]")) return error.InvalidRules;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (!array_section and current_section.len > 0 and std.mem.eql(u8, current_section, name)) {
        return error.InvalidRules;
    }
    return .{ .name = name, .is_array = false };
}

fn validateAssignment(key: []const u8, value: []const u8) !void {
    if (key.len == 0 or value.len == 0) return error.InvalidRules;
    if (value[0] == '\'') return error.InvalidRules;
    if (value[0] == '"' and !hasClosingQuote(value)) return error.InvalidRules;
    if (value[0] == '[' and !hasClosingBracket(value)) return error.InvalidRules;
}

fn wasSeen(seen: []const SeenKey, section: []const u8, key: []const u8) bool {
    for (seen) |entry| {
        if (std.mem.eql(u8, entry.section, section) and std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
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
    const keys = [_][]const u8{
        "max_cycles",
        "max_file_lines",
        "max_fn_lines",
        "max_cyclomatic",
        "max_cognitive",
    };
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

fn checkLayerRules(
    allocator: Allocator,
    layers: []const RulesConfig.Layer,
    input: *const CheckInput,
    violations: *std.ArrayList(Violation),
    checked: *u32,
) !void {
    for (input.file_paths) |path| _ = try layerOf(layers, path);
    if (layers.len < 2) return;
    checked.* += 1;
    for (input.import_edges) |edge| {
        const from_layer = (try layerOf(layers, edge.from)) orelse continue;
        const to_layer = (try layerOf(layers, edge.to)) orelse continue;
        if (from_layer.order <= to_layer.order) continue;
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

fn checkBoundaryRules(
    allocator: Allocator,
    boundaries: []const RulesConfig.Boundary,
    input: *const CheckInput,
    violations: *std.ArrayList(Violation),
    checked: *u32,
) !void {
    for (boundaries) |boundary| {
        checked.* += 1;
        for (input.import_edges) |edge| {
            if (!globMatch(boundary.from, edge.from) or !globMatch(boundary.to, edge.to)) continue;
            const files = try allocator.alloc([]const u8, 2);
            files[0] = edge.from;
            files[1] = edge.to;
            try violations.append(allocator, .{
                .rule = "boundary",
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "{s} must not import {s}{s}{s}", .{
                    edge.from,
                    edge.to,
                    if (boundary.reason.len > 0) " — " else "",
                    boundary.reason,
                }),
                .files = files,
            });
        }
    }
}

/// A `min_*` floor: the rule name, how it reads in a message, the observed
/// value and the configured floor (null when the rule is not set).
const ScoreFloor = struct {
    key: []const u8,
    label: []const u8,
    observed: f64,
    min: ?f64,
};

fn checkConstraintRules(
    allocator: Allocator,
    constraints: *const RulesConfig.Constraints,
    input: *const CheckInput,
    violations: *std.ArrayList(Violation),
    checked: *u32,
) !void {
    try checkScoreFloors(allocator, constraints, input, violations, checked);
    try checkCeilings(allocator, constraints, input, violations, checked);
}

/// The six `min_*` floors. Every score floor in one table, so adding a root
/// cause means adding a row instead of another six-line copy of the same shape.
fn checkScoreFloors(
    allocator: Allocator,
    constraints: *const RulesConfig.Constraints,
    input: *const CheckInput,
    violations: *std.ArrayList(Violation),
    checked: *u32,
) !void {
    const floors = [_]ScoreFloor{
        .{ .key = "min_quality", .label = "quality", .observed = input.quality_signal, .min = constraints.min_quality },
        .{ .key = "min_modularity", .label = "modularity", .observed = input.modularity, .min = constraints.min_modularity },
        .{ .key = "min_acyclicity", .label = "acyclicity", .observed = input.acyclicity, .min = constraints.min_acyclicity },
        .{ .key = "min_depth", .label = "depth score", .observed = input.depth, .min = constraints.min_depth },
        .{ .key = "min_equality", .label = "equality", .observed = input.equality, .min = constraints.min_equality },
        .{ .key = "min_redundancy", .label = "redundancy", .observed = input.redundancy, .min = constraints.min_redundancy },
    };
    for (floors) |floor| {
        const min = floor.min orelse continue;
        checked.* += 1;
        if (floor.observed >= min) continue;
        // Acyclicity is the one score with a second, countable fact behind it.
        if (std.mem.eql(u8, floor.key, "min_acyclicity")) {
            try violations.append(allocator, .{
                .rule = floor.key,
                .severity = .err,
                .message = try std.fmt.allocPrint(allocator, "{s} {d:.3} < required {d:.3} ({d} cycles)", .{ floor.label, floor.observed, min, input.cycle_count }),
            });
            continue;
        }
        try violations.append(allocator, .{
            .rule = floor.key,
            .severity = .err,
            .message = try std.fmt.allocPrint(allocator, "{s} {d:.3} < required {d:.3}", .{ floor.label, floor.observed, min }),
        });
    }
}

/// The `max_*` ceilings. Cycles, file size and function size report the single
/// largest value; the two complexity ceilings report every offending function,
/// because the number of offenders is the work list.
fn checkCeilings(
    allocator: Allocator,
    constraints: *const RulesConfig.Constraints,
    input: *const CheckInput,
    violations: *std.ArrayList(Violation),
    checked: *u32,
) !void {
    if (constraints.max_cycles) |max| {
        checked.* += 1;
        if (input.cycle_count > max) try violations.append(allocator, .{
            .rule = "max_cycles",
            .severity = .err,
            .message = try std.fmt.allocPrint(allocator, "{d} cycles > allowed {d}", .{ input.cycle_count, max }),
        });
    }
    if (constraints.max_file_lines) |max| {
        checked.* += 1;
        if (input.max_file_lines > max) try violations.append(allocator, .{
            .rule = "max_file_lines",
            .severity = .err,
            .message = try std.fmt.allocPrint(allocator, "largest file has {d} lines > allowed {d}", .{ input.max_file_lines, max }),
        });
    }
    if (constraints.max_fn_lines) |max| {
        checked.* += 1;
        if (input.max_fn_lines > max) try violations.append(allocator, .{
            .rule = "max_fn_lines",
            .severity = .err,
            .message = try std.fmt.allocPrint(allocator, "largest function has {d} lines > allowed {d}", .{ input.max_fn_lines, max }),
        });
    }
    if (constraints.max_cyclomatic) |max| {
        checked.* += 1;
        try checkComplexityCeiling(allocator, input.functions, max, .cyclomatic, violations);
    }
    if (constraints.max_cognitive) |max| {
        checked.* += 1;
        try checkComplexityCeiling(allocator, input.functions, max, .cognitive, violations);
    }
}

/// Which complexity number a ceiling applies to. Keeping it as an enum rather
/// than a field pointer means the two ceilings cannot drift apart in how they
/// read, count or report a function.
const ComplexityKind = enum {
    cyclomatic,
    cognitive,

    /// Must equal the configuration key that sets this ceiling, so a violation
    /// names the knob the user has to edit.
    fn ruleName(self: ComplexityKind) []const u8 {
        return switch (self) {
            .cyclomatic => "max_cyclomatic",
            .cognitive => "max_cognitive",
        };
    }

    fn label(self: ComplexityKind) []const u8 {
        return switch (self) {
            .cyclomatic => "cyclomatic complexity",
            .cognitive => "cognitive complexity",
        };
    }

    fn of(self: ComplexityKind, function: FunctionComplexity) u32 {
        return switch (self) {
            .cyclomatic => function.cyclomatic,
            .cognitive => function.cognitive,
        };
    }
};

/// Emit one violation per function over the ceiling, naming the file, the
/// line, the function and both numbers, so the message is enough to act on
/// and a JSON consumer can group by `from` + `subject` without parsing text.
fn checkComplexityCeiling(
    allocator: Allocator,
    functions: []const FunctionComplexity,
    max: u32,
    kind: ComplexityKind,
    violations: *std.ArrayList(Violation),
) !void {
    for (functions) |function| {
        const value = kind.of(function);
        if (value <= max) continue;
        const files = try allocator.alloc([]const u8, 1);
        files[0] = function.file;
        try violations.append(allocator, .{
            .rule = kind.ruleName(),
            .severity = .err,
            .message = try std.fmt.allocPrint(allocator, "{s}:{d}: {s} has {s} {d} > allowed {d}", .{
                function.file,
                function.line,
                function.name,
                kind.label(),
                value,
                max,
            }),
            .files = files,
            .subject = function.name,
            .line = function.line,
        });
    }
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
    // Function paths end up in violation messages and in the JSON `from`
    // field, so they are held to the same canonical shape as every other path
    // the rules engine accepts.
    for (input.functions) |function| try validateInputPath(function.file);

    const c = &config.constraints;
    var checked: u32 = 0;

    try checkConstraintRules(allocator, c, input, &violations, &checked);

    try checkLayerRules(allocator, config.layers, input, &violations, &checked);
    try checkBoundaryRules(allocator, config.boundaries, input, &violations, &checked);

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
    // Same file and rule: source order when both violations know their line.
    if (left.line != null and right.line != null and left.line.? != right.line.?) {
        return left.line.? < right.line.?;
    }
    return std.mem.lessThan(u8, left.message, right.message);
}

/// Two violations are the same finding only when rule, subject, files *and*
/// message agree. Comparing files alone is not enough: the per-function
/// complexity ceilings emit several violations that share a rule and a file
/// and differ only by function, and those must all survive deduplication.
fn sameViolation(left: Violation, right: Violation) bool {
    if (!std.mem.eql(u8, left.rule, right.rule) or left.files.len != right.files.len) return false;
    if (!std.mem.eql(u8, left.message, right.message)) return false;
    if ((left.subject == null) != (right.subject == null)) return false;
    if (left.subject) |subject| {
        if (!std.mem.eql(u8, subject, right.subject.?)) return false;
    }
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
