const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Line-based class/interface/struct extraction for the inheritance graph.
///
/// Per language:
///   Python  — `class X(Base1, Base2):`
///   Rust    — `trait X`, `struct X`, `enum X`; `impl Trait for Type`
///             (trait impls become child=Type, parent=Trait)
///   JS/TS   — `class X extends Base`, `... implements I1, I2`
///   C/C++   — `class X : public Y`, `struct X : Y`
///
/// Zig and Go have no inheritance — struct/interface kinds are detected
/// but produce no inherit edges.
///
/// Returned ClassInfo slices point into `contents` (names are sub-slices).
pub const ClassExtractor = struct {
    pub fn extract(allocator: Allocator, contents: []const u8, lang: []const u8) ![]core.types.ClassInfo {
        var classes = std.ArrayList(core.types.ClassInfo).empty;
        errdefer classes.deinit(allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var in_block_comment = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");

            if (in_block_comment) {
                if (std.mem.indexOf(u8, line, "*/") != null) in_block_comment = false;
                continue;
            }
            if (std.mem.startsWith(u8, line, "//")) continue;
            if (std.mem.startsWith(u8, line, "#") and !isCLang(lang)) continue;
            if (std.mem.startsWith(u8, line, "/*")) {
                if (std.mem.indexOf(u8, line, "*/") == null) in_block_comment = true;
                continue;
            }

            const decl = detectDecl(allocator, line, lang) orelse continue;
            try classes.append(allocator, decl);
        }

        return try classes.toOwnedSlice(allocator);
    }

    fn isCLang(lang: []const u8) bool {
        return std.mem.eql(u8, lang, "c") or std.mem.eql(u8, lang, "cpp");
    }

    fn detectDecl(allocator: Allocator, line: []const u8, lang: []const u8) ?core.types.ClassInfo {
        if (std.mem.eql(u8, lang, "python")) return detectPythonClass(allocator, line);
        if (std.mem.eql(u8, lang, "rust")) return detectRustItem(allocator, line);
        if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript")) return detectJsClass(allocator, line);
        if (std.mem.eql(u8, lang, "cpp")) return detectCppClass(allocator, line);
        if (std.mem.eql(u8, lang, "zig")) return detectZigType(line);
        if (std.mem.eql(u8, lang, "go")) return detectGoType(line);
        return null;
    }

    // Python: class X(Base1, Base2): — also `class X:` and kwonly `class X(Y, metaclass=M):`
    fn detectPythonClass(allocator: Allocator, line: []const u8) ?core.types.ClassInfo {
        if (!std.mem.startsWith(u8, line, "class ")) return null;
        const rest = line["class ".len..];
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;

        var bases: ?[][]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse return null;
            const base_str = rest[open + 1 .. close];
            var list = std.ArrayList([]const u8).empty;
            defer list.deinit(allocator);
            var iter = std.mem.splitScalar(u8, base_str, ',');
            while (iter.next()) |raw_base| {
                const base = std.mem.trim(u8, raw_base, " \t");
                // Skip keyword args like metaclass=ABC — not a base class
                if (std.mem.indexOfScalar(u8, base, '=') != null) continue;
                if (base.len == 0) continue;
                list.append(allocator, base) catch return null;
            }
            if (list.items.len > 0) {
                bases = list.toOwnedSlice(allocator) catch null;
            }
        }

        return .{
            .name = name,
            .bases = bases,
            .kind = .class,
        };
    }

    // Rust: trait X, struct X, enum X, impl Trait for Type, impl Type
    fn detectRustItem(allocator: Allocator, line: []const u8) ?core.types.ClassInfo {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub ")) rest = rest["pub ".len..];
        if (std.mem.startsWith(u8, rest, "pub(")) {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
        }

        if (std.mem.startsWith(u8, rest, "trait ")) {
            const name = scanIdentifier(rest["trait ".len..]) orelse return null;
            if (name.len == 0) return null;
            return .{ .name = name, .kind = .trait };
        }
        if (std.mem.startsWith(u8, rest, "struct ")) {
            const name = scanIdentifier(rest["struct ".len..]) orelse return null;
            if (name.len == 0) return null;
            return .{ .name = name, .kind = .struct_kind };
        }
        if (std.mem.startsWith(u8, rest, "enum ")) {
            const name = scanIdentifier(rest["enum ".len..]) orelse return null;
            if (name.len == 0) return null;
            return .{ .name = name, .kind = .enum_kind };
        }
        if (std.mem.startsWith(u8, rest, "impl ")) {
            const imp = rest["impl ".len..];
            const for_kw = std.mem.indexOf(u8, imp, " for ");
            if (for_kw) |kw| {
                const trait_name = std.mem.trim(u8, imp[0..kw], " \t<");
                const after = imp[kw + " for ".len ..];
                const type_name = scanIdentifier(std.mem.trimStart(u8, after, "<")) orelse return null;
                if (type_name.len == 0 or trait_name.len == 0) return null;
                // Represent the impl as a class-like entry: the implementer
                // with the trait as a base.
                var bases_buf = std.ArrayList([]const u8).empty;
                defer bases_buf.deinit(allocator);
                bases_buf.append(allocator, trait_name) catch return null;
                return .{
                    .name = type_name,
                    .bases = bases_buf.toOwnedSlice(allocator) catch null,
                    .kind = .struct_kind,
                };
            }
            // Plain `impl Type` — inherent impl, no inheritance
            const type_name = scanIdentifier(std.mem.trimStart(u8, imp, "<")) orelse return null;
            if (type_name.len == 0) return null;
            return .{ .name = type_name, .kind = .struct_kind };
        }
        return null;
    }

    // JS/TS: class X extends Y implements A, B
    fn detectJsClass(allocator: Allocator, line: []const u8) ?core.types.ClassInfo {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "export ")) rest = rest["export ".len..];
        if (std.mem.startsWith(u8, rest, "export default ")) rest = rest["export default ".len..];
        if (std.mem.startsWith(u8, rest, "abstract ")) rest = rest["abstract ".len..];
        if (!std.mem.startsWith(u8, rest, "class ")) return null;
        const after = rest["class ".len..];
        const name = scanIdentifier(after) orelse return null;
        if (name.len == 0) return null;

        var bases = std.ArrayList([]const u8).empty;
        defer bases.deinit(allocator);

        if (std.mem.indexOf(u8, after, " extends ")) |ext| {
            const seg = after[ext + " extends ".len ..];
            const base = scanBaseSegment(seg, " implements") orelse seg;
            const trimmed = std.mem.trim(u8, base, " \t{}");
            if (trimmed.len > 0) bases.append(allocator, trimmed) catch return null;
        }
        if (std.mem.indexOf(u8, after, " implements ")) |imp| {
            const seg = after[imp + " implements ".len ..];
            const list_str = scanBaseSegment(seg, "{") orelse seg;
            var iter = std.mem.splitScalar(u8, std.mem.trim(u8, list_str, " \t{"), ',');
            while (iter.next()) |iface| {
                const trimmed = std.mem.trim(u8, iface, " \t");
                if (trimmed.len > 0) bases.append(allocator, trimmed) catch return null;
            }
        }

        return .{
            .name = name,
            .bases = if (bases.items.len > 0) bases.toOwnedSlice(allocator) catch null else null,
            .kind = .class,
        };
    }

    // C++: class X : public Y, private Z {
    fn detectCppClass(allocator: Allocator, line: []const u8) ?core.types.ClassInfo {
        var rest = line;
        var is_struct = false;
        if (std.mem.startsWith(u8, rest, "class ")) {
            rest = rest["class ".len..];
        } else if (std.mem.startsWith(u8, rest, "struct ")) {
            rest = rest["struct ".len..];
            is_struct = true;
        } else return null;

        // Skip template declarations
        if (std.mem.startsWith(u8, rest, "template")) return null;

        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const brace = std.mem.indexOfScalar(u8, rest, '{');
        // Name must come before any colon-in-template or brace
        const name_end = @min(colon orelse rest.len, brace orelse rest.len);
        const name = scanIdentifier(rest[0..name_end]) orelse return null;
        if (name.len == 0) return null;

        var bases = std.ArrayList([]const u8).empty;
        defer bases.deinit(allocator);

        if (colon) |c| {
            if (brace == null or c < brace.?) {
                const base_str = rest[c + 1 .. brace orelse rest.len];
                var iter = std.mem.splitScalar(u8, base_str, ',');
                while (iter.next()) |raw_base| {
                    var base = std.mem.trim(u8, raw_base, " \t");
                    // strip access specifiers
                    inline for ([_][]const u8{ "public ", "protected ", "private ", "virtual " }) |spec| {
                        if (std.mem.startsWith(u8, base, spec)) base = std.mem.trimStart(u8, base[spec.len..], " ");
                    }
                    if (base.len > 0) bases.append(allocator, base) catch return null;
                }
            }
        }

        return .{
            .name = name,
            .bases = if (bases.items.len > 0) bases.toOwnedSlice(allocator) catch null else null,
            .kind = if (is_struct) .struct_kind else .class,
        };
    }

    // Zig: no inheritance, but record type kinds for completeness
    fn detectZigType(line: []const u8) ?core.types.ClassInfo {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub ")) rest = rest["pub ".len..];
        if (!std.mem.startsWith(u8, rest, "const ")) return null;
        const after = rest["const ".len..];
        const name = scanIdentifier(after) orelse return null;
        if (name.len == 0) return null;
        const tail = std.mem.trimStart(u8, after[name.len..], " \t=");
        if (std.mem.startsWith(u8, tail, "struct")) return .{ .name = name, .kind = .struct_kind };
        if (std.mem.startsWith(u8, tail, "union")) return .{ .name = name, .kind = .struct_kind };
        if (std.mem.startsWith(u8, tail, "enum")) return .{ .name = name, .kind = .enum_kind };
        if (std.mem.startsWith(u8, tail, "error")) return .{ .name = name, .kind = .enum_kind };
        return null;
    }

    // Go: type X struct { / type X interface {
    fn detectGoType(line: []const u8) ?core.types.ClassInfo {
        if (!std.mem.startsWith(u8, line, "type ")) return null;
        const after = line["type ".len..];
        const name = scanIdentifier(after) orelse return null;
        if (name.len == 0) return null;
        const tail = std.mem.trimStart(u8, after[name.len..], " \t");
        if (std.mem.startsWith(u8, tail, "struct")) return .{ .name = name, .kind = .struct_kind };
        if (std.mem.startsWith(u8, tail, "interface")) return .{ .name = name, .kind = .interface };
        return null;
    }

    /// Read up to a terminator or start-of-body, whichever comes first.
    fn scanBaseSegment(seg: []const u8, terminator: []const u8) ?[]const u8 {
        const term = std.mem.indexOf(u8, seg, terminator) orelse return null;
        return seg[0..term];
    }

    fn scanIdentifier(rest: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) i += 1;
        const start = i;
        while (i < rest.len and isIdentChar(rest[i])) i += 1;
        if (i == start) return null;
        return rest[start..i];
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "python class with bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\class Animal:
        \\    pass
        \\
        \\class Dog(Animal, Serializable, metaclass=ABC):
        \\    pass
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    try std.testing.expectEqualStrings("Animal", classes[0].name);
    try std.testing.expect(classes[0].bases == null);
    try std.testing.expectEqualStrings("Dog", classes[1].name);
    const bases = classes[1].bases.?;
    try std.testing.expectEqual(@as(usize, 2), bases.len);
    try std.testing.expectEqualStrings("Animal", bases[0]);
    try std.testing.expectEqualStrings("Serializable", bases[1]);
}

test "rust trait struct and impl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\pub trait Drawable {
        \\    fn draw(&self);
        \\}
        \\
        \\struct Circle {
        \\    r: f64,
        \\}
        \\
        \\impl Drawable for Circle {
        \\    fn draw(&self) {}
        \\}
        \\
        \\impl Circle {
        \\    fn area(&self) {}
        \\}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 4), classes.len);
    try std.testing.expectEqualStrings("Drawable", classes[0].name);
    try std.testing.expectEqual(core.types.ClassKind.trait, classes[0].kind);
    try std.testing.expectEqualStrings("Circle", classes[1].name);
    try std.testing.expectEqual(core.types.ClassKind.struct_kind, classes[1].kind);
    // impl Drawable for Circle → child Circle, parent Drawable
    try std.testing.expectEqualStrings("Circle", classes[2].name);
    const bases = classes[2].bases.?;
    try std.testing.expectEqual(@as(usize, 1), bases.len);
    try std.testing.expectEqualStrings("Drawable", bases[0]);
    // inherent impl — no bases
    try std.testing.expectEqualStrings("Circle", classes[3].name);
    try std.testing.expect(classes[3].bases == null);
}

test "js class extends and implements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\class Base {}
        \\export class Widget extends Base {}
        \\class Full extends Base implements Drawable, Serializable {}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "typescript");
    try std.testing.expectEqual(@as(usize, 3), classes.len);
    try std.testing.expectEqualStrings("Base", classes[0].name);
    try std.testing.expect(classes[0].bases == null);
    try std.testing.expectEqualStrings("Widget", classes[1].name);
    try std.testing.expectEqualStrings("Base", classes[1].bases.?[0]);
    const full_bases = classes[2].bases.?;
    try std.testing.expectEqual(@as(usize, 3), full_bases.len);
    try std.testing.expectEqualStrings("Base", full_bases[0]);
    try std.testing.expectEqualStrings("Drawable", full_bases[1]);
    try std.testing.expectEqualStrings("Serializable", full_bases[2]);
}

test "cpp class inheritance with access specifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\class Shape {
        \\public:
        \\    virtual ~Shape();
        \\};
        \\
        \\class Circle : public Shape {
        \\};
        \\
        \\struct Tag : private Shape {};
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "cpp");
    try std.testing.expectEqual(@as(usize, 3), classes.len);
    try std.testing.expectEqualStrings("Shape", classes[0].name);
    const circle_bases = classes[1].bases.?;
    try std.testing.expectEqual(@as(usize, 1), circle_bases.len);
    try std.testing.expectEqualStrings("Shape", circle_bases[0]);
    // struct with private access — specifier stripped
    try std.testing.expectEqualStrings("Tag", classes[2].name);
    try std.testing.expectEqualStrings("Shape", classes[2].bases.?[0]);
}

test "zig types detected without bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\pub const FileNode = struct {
        \\    path: []const u8,
        \\};
        \\const Color = enum { red, green };
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    try std.testing.expectEqualStrings("FileNode", classes[0].name);
    try std.testing.expectEqual(core.types.ClassKind.struct_kind, classes[0].kind);
    try std.testing.expect(classes[0].bases == null); // no inheritance in Zig
    try std.testing.expectEqual(core.types.ClassKind.enum_kind, classes[1].kind);
}

test "go struct and interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\type Reader interface {
        \\    Read(p []byte) (n int, err error)
        \\}
        \\type File struct {
        \\    name string
        \\}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "go");
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    try std.testing.expectEqual(core.types.ClassKind.interface, classes[0].kind);
    try std.testing.expectEqual(core.types.ClassKind.struct_kind, classes[1].kind);
}

test "unknown language yields nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const classes = try ClassExtractor.extract(arena.allocator(), "class Foo:", "ruby");
    try std.testing.expectEqual(@as(usize, 0), classes.len);
}

test "block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\/*
        \\class Hidden(Shape):
        \\*/
        \\class Visible(Shape):
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqualStrings("Visible", classes[0].name);
}
