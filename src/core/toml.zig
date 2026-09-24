const std = @import("std");
const Allocator = std.mem.Allocator;

/// Minimal TOML parser for tdlearn rules files.
///
/// Supports: [section], [[array-of-tables]], key = value where value is
/// string, integer, float, boolean, or array of strings/numbers.
/// Comments (#) and blank lines are skipped. Inline trailing comments
/// on value lines are stripped (outside quotes).
///
/// Not supported: multi-line strings, nested tables, dotted keys, dates.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]const Value {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }
};

/// A parsed table: section name → key → value.
/// Array-of-tables entries accumulate under the same section name as
/// `Table.array_entries` — each [[layers]] block appends one entry.
pub const Table = struct {
    name: []const u8,
    /// key → value (later keys override earlier ones)
    values: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// array-of-tables entries: each is a list of (key, value) pairs
    array_entries: std.ArrayList([]const KV),

    pub const KV = struct {
        key: []const u8,
        value: Value,
    };

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.values.get(key);
    }
};

pub const Toml = struct {
    allocator: Allocator,
    tables: std.ArrayList(Table),
    /// Scratch arena — all parsed strings/slices live here.
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) Toml {
        return .{
            .allocator = allocator,
            .tables = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Toml) void {
        for (self.tables.items) |*t| {
            t.values.deinit(self.arena.allocator());
            t.array_entries.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Parse TOML contents. All returned slices are arena-owned
    /// (valid until deinit).
    pub fn parse(self: *Toml, contents: []const u8) !void {
        const sa = self.arena.allocator();

        var current_table: ?*Table = null;
        var pending_array_table: ?*Table = null;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = stripComment(raw_line);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // [[array-of-tables]]
            if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "[[") and std.mem.endsWith(u8, trimmed, "]]")) {
                const name = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
                const t = try self.getOrMakeTable(sa, name);
                current_table = t;
                pending_array_table = t;
                // Start a new entry in the array-of-tables
                var entry = std.ArrayList(Table.KV).empty;
                try entry.append(sa, .{ .key = "__entry_marker__", .value = .{ .boolean = true } });
                const entry_slice = try entry.toOwnedSlice(sa);
                try t.array_entries.append(self.allocator, entry_slice);
                continue;
            }

            // [section]
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
                current_table = try self.getOrMakeTable(sa, name);
                pending_array_table = null;
                continue;
            }

            // key = value
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.MissingAssignment;
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const val_str = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            if (key.len == 0) return error.InvalidKey;
            if (val_str.len == 0) return error.EmptyValue;

            const value = try parseValue(sa, val_str);

            if (current_table == null) {
                // Keys before any section — put in a root table
                current_table = try self.getOrMakeTable(sa, "");
            }

            if (pending_array_table) |pt| {
                // Append into the current array entry (last one)
                const entries = pt.array_entries.items;
                if (entries.len > 0) {
                    const last = entries[entries.len - 1];
                    // Rebuild with new KV — slices are immutable, so copy
                    var list = std.ArrayList(Table.KV).empty;
                    for (last) |kv| {
                        if (std.mem.eql(u8, kv.key, key)) return error.DuplicateKey;
                        try list.append(sa, kv);
                    }
                    try list.append(sa, .{ .key = key, .value = value });
                    entries[entries.len - 1] = try list.toOwnedSlice(sa);
                }
            } else {
                if (current_table.?.values.contains(key)) return error.DuplicateKey;
                try current_table.?.values.put(sa, key, value);
            }
        }
    }

    /// Find a table by section name ("" = root), or null.
    pub fn table(self: *const Toml, name: []const u8) ?*const Table {
        for (self.tables.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    fn getOrMakeTable(self: *Toml, sa: Allocator, name: []const u8) !*Table {
        for (self.tables.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        const owned_name = try sa.dupe(u8, name);
        try self.tables.append(self.allocator, .{
            .name = owned_name,
            .values = .empty,
            .array_entries = .empty,
        });
        return &self.tables.items[self.tables.items.len - 1];
    }

    fn parseValue(sa: Allocator, s: []const u8) !Value {
        if (s.len == 0) return error.EmptyValue;
        if (s[0] == '"') {
            if (s.len < 2 or s[s.len - 1] != '"') return error.UnterminatedString;
            var escaped = false;
            var end: ?usize = null;
            for (s[1..], 1..) |character, index| {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (character == '\\') {
                    escaped = true;
                } else if (character == '"') {
                    end = index;
                    break;
                }
            }
            const close = end orelse return error.UnterminatedString;
            if (close != s.len - 1) return error.InvalidString;
            return Value{ .string = s[1..close] };
        }
        if (s[0] == '\'') return error.UnsupportedString;
        // Boolean
        if (std.mem.eql(u8, s, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, s, "false")) return Value{ .boolean = false };
        if (s[0] == '[') {
            if (s.len < 2 or s[s.len - 1] != ']') return error.UnterminatedArray;
            var items = std.ArrayList(Value).empty;
            var inner = s[1 .. s.len - 1];
            while (inner.len > 0) {
                inner = std.mem.trimStart(u8, inner, " \t,");
                if (inner.len == 0) break;
                // Find end of this item: quote close or comma at depth 0
                var i: usize = 0;
                var in_str = false;
                var escaped = false;
                var item_end: usize = inner.len;
                while (i < inner.len) : (i += 1) {
                    const c = inner[i];
                    if (in_str) {
                        if (c == '\\' and !escaped) {
                            escaped = true;
                        } else {
                            if (c == '"' and !escaped) in_str = false;
                            escaped = false;
                        }
                    } else if (c == '"') {
                        in_str = true;
                    } else if (c == ',') {
                        item_end = i;
                        break;
                    }
                }
                if (in_str) return error.UnterminatedString;
                const item = std.mem.trim(u8, inner[0..item_end], " \t");
                if (item.len == 0) return error.EmptyArrayItem;
                try items.append(sa, try parseValue(sa, item));
                inner = if (item_end < inner.len) inner[item_end + 1 ..] else inner[inner.len..];
            }
            return Value{ .array = try items.toOwnedSlice(sa) };
        }
        // Integer
        if (std.fmt.parseInt(i64, s, 10)) |i| {
            return Value{ .integer = i };
        } else |_| {}
        // Float
        if (std.fmt.parseFloat(f64, s)) |f| {
            return Value{ .float = f };
        } else |_| {}
        return error.InvalidValue;
    }

    /// Strip a trailing comment from a line, respecting double quotes.
    fn stripComment(line: []const u8) []const u8 {
        var in_str = false;
        var escaped = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (in_str) {
                if (c == '\\' and !escaped) {
                    escaped = true;
                } else {
                    if (c == '"' and !escaped) in_str = false;
                    escaped = false;
                }
            } else if (c == '"') {
                in_str = true;
            } else if (c == '#') {
                return line[0..i];
            }
        }
        return line;
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "parse key-values" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\name = "tdlearn"
        \\version = 3
        \\ratio = 0.75
        \\enabled = true
        \\disabled = false
    );
    const root = toml.table("").?;
    try std.testing.expectEqualStrings("tdlearn", root.get("name").?.asString().?);
    try std.testing.expectEqual(@as(i64, 3), root.get("version").?.asInt().?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), root.get("ratio").?.asFloat().?, 0.001);
    try std.testing.expectEqual(true, root.get("enabled").?.asBool().?);
    try std.testing.expectEqual(false, root.get("disabled").?.asBool().?);
}

test "parse sections" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\[constraints]
        \\min_quality = 0.6
        \\max_cycles = 0
        \\
        \\[other]
        \\key = "value"
    );
    const constraints = toml.table("constraints").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), constraints.get("min_quality").?.asFloat().?, 0.001);
    try std.testing.expectEqual(@as(i64, 0), constraints.get("max_cycles").?.asInt().?);
    const other = toml.table("other").?;
    try std.testing.expectEqualStrings("value", other.get("key").?.asString().?);
}

test "parse string array" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\[section]
        \\paths = ["src/core/*", "src/lib/**"]
        \\nums = [1, 2, 3]
    );
    const s = toml.table("section").?;
    const paths = s.get("paths").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("src/core/*", paths[0].asString().?);
    try std.testing.expectEqualStrings("src/lib/**", paths[1].asString().?);
    const nums = s.get("nums").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 3), nums.len);
    try std.testing.expectEqual(@as(i64, 2), nums[1].asInt().?);
}

test "parse array of tables" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\[[layers]]
        \\name = "core"
        \\order = 0
        \\
        \\[[layers]]
        \\name = "renderer"
        \\order = 2
        \\
        \\[[boundaries]]
        \\from = "src/renderer/*"
        \\to = "src/analysis/*"
    );
    const layers = toml.table("layers").?;
    try std.testing.expectEqual(@as(usize, 2), layers.array_entries.items.len);
    // First layer
    const l0 = layers.array_entries.items[0];
    var name0: []const u8 = "";
    var order0: i64 = -1;
    for (l0) |kv| {
        if (std.mem.eql(u8, kv.key, "name")) name0 = kv.value.asString().?;
        if (std.mem.eql(u8, kv.key, "order")) order0 = kv.value.asInt().?;
    }
    try std.testing.expectEqualStrings("core", name0);
    try std.testing.expectEqual(@as(i64, 0), order0);
    // Second layer
    const l1 = layers.array_entries.items[1];
    var name1: []const u8 = "";
    for (l1) |kv| {
        if (std.mem.eql(u8, kv.key, "name")) name1 = kv.value.asString().?;
    }
    try std.testing.expectEqualStrings("renderer", name1);

    const boundaries = toml.table("boundaries").?;
    try std.testing.expectEqual(@as(usize, 1), boundaries.array_entries.items.len);
}

test "comments and blank lines" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\# Full line comment
        \\
        \\key = "value" # trailing comment
        \\url = "http://x#y" # hash inside string stays
    );
    const root = toml.table("").?;
    try std.testing.expectEqualStrings("value", root.get("key").?.asString().?);
    try std.testing.expectEqualStrings("http://x#y", root.get("url").?.asString().?);
}

test "negative numbers" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try toml.parse(
        \\x = -5
        \\y = -0.5
    );
    const root = toml.table("").?;
    try std.testing.expectEqual(@as(i64, -5), root.get("x").?.asInt().?);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), root.get("y").?.asFloat().?, 0.001);
}

test "reject malformed assignments" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try std.testing.expectError(error.MissingAssignment, toml.parse("value"));
    try std.testing.expectError(error.EmptyValue, toml.parse("key ="));
    try std.testing.expectError(error.UnterminatedString, toml.parse("key = \"value"));
    try std.testing.expectError(error.UnterminatedArray, toml.parse("key = [1, 2"));
    try std.testing.expectError(error.InvalidValue, toml.parse("key = value"));
}

test "reject duplicate keys" {
    var toml = Toml.init(std.testing.allocator);
    defer toml.deinit();
    try std.testing.expectError(error.DuplicateKey, toml.parse(
        \\[a]
        \\k = 1
        \\k = 2
    ));
}
