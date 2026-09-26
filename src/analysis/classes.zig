const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Line-based class/interface/struct extraction for the inheritance graph.
///
/// Every line is first run through `core.source_lexer.sanitizeLine` in
/// `.discard_literals` mode with a `State` that persists across lines, so
/// class-like text inside a string, template literal or comment is blanked out
/// — including the lines swallowed by an unterminated `/* */`, `"""` or
/// backtick literal. In that mode the lexer preserves each line's length and
/// layout, so every span detection finds in the sanitized line is a valid span
/// of `contents`; names and bases are re-sliced from the raw line instead of
/// aliasing the scratch buffer.
///
/// Per language:
///   Python  — `class X(Base1, Base2):`
///   Rust    — `trait X`, `struct X`, `enum X`; `impl<T> Trait for Type`
///             (trait impls become child=Type, parent=Trait)
///   JS/TS   — `export default class X extends Base`, `... implements I1, I2`
///   C/C++   — `class ns::X : public Y`, `struct X : Y`
///
/// Zig and Go have no inheritance — struct/interface kinds are detected
/// but produce no inherit edges.
///
/// Qualified names are keyed by their leaf (`ns::Base`, `ns.Base` and `Base`
/// are the same key), which is the only form a declaration can be extracted
/// under; two same-named types in different namespaces then read as
/// ambiguous, which `inherit_graph` refuses to resolve rather than guessing.
///
/// Returned ClassInfo slices point into `contents` (names and bases are
/// sub-slices); only the `ClassInfo` array and the per-declaration `bases`
/// arrays are owned by `allocator`.
pub const ClassExtractor = struct {
    /// A declaration found on one line. `name` and every `bases` entry are
    /// spans of the sanitized line; `bases` is a view into the caller's
    /// `BaseBuf` and is only valid while that buffer lives.
    const Decl = struct {
        name: []const u8,
        bases: []const []const u8 = &.{},
        kind: core.types.ClassKind = .class,
    };

    /// Fixed-capacity base-name collector. Keeping detection allocation-free
    /// lets `extract` translate detected spans back onto the raw line in one
    /// place; the eighth base is the cap, which no realistic declaration
    /// reaches (C++ multiple inheritance tops out well below it).
    const BaseBuf = struct {
        items: [8][]const u8 = undefined,
        len: usize = 0,

        fn add(self: *BaseBuf, base: []const u8) void {
            if (self.len == self.items.len) return;
            self.items[self.len] = base;
            self.len += 1;
        }

        fn slice(self: *const BaseBuf) []const []const u8 {
            return self.items[0..self.len];
        }
    };

    const TypeName = struct {
        name: []const u8,
        rest: []const u8,
    };

    /// Modifiers may appear in any order, so `export default` has to be tried
    /// before the shorter `export` prefix — otherwise `export default class X`
    /// reduces to `default class X` and the class is never recognised.
    const js_modifiers = [_][]const u8{
        "export default ", "export declare ", "export abstract ", "export ",
        "default ",        "declare ",        "abstract ",        "final ",
    };

    const cpp_access_specifiers = [_][]const u8{ "public ", "protected ", "private ", "virtual " };

    pub fn extract(allocator: Allocator, contents: []const u8, lang: []const u8) ![]core.types.ClassInfo {
        var classes = std.ArrayList(core.types.ClassInfo).empty;
        errdefer classes.deinit(allocator);

        var code = std.ArrayList(u8).empty;
        defer code.deinit(allocator);
        // Persists across lines: an unterminated literal or block comment
        // keeps swallowing the lines that follow it.
        var state = core.source_lexer.State{};

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            code.clearRetainingCapacity();
            try core.source_lexer.sanitizeLine(allocator, &code, raw_line, lexerLanguage(lang), .discard_literals, &state);
            // Discard mode is length-preserving; without that guarantee the
            // span translation in rawSpan() would be unsound.
            if (code.items.len != raw_line.len) continue;

            const line = std.mem.trim(u8, code.items, " \t\r");
            var base_buf = BaseBuf{};
            const decl = detectDecl(line, lang, &base_buf) orelse continue;
            try appendDecl(allocator, &classes, raw_line, code.items, decl);
        }

        return try classes.toOwnedSlice(allocator);
    }

    /// Re-slice a span of the sanitized line out of the raw line. Length-
    /// preserving sanitization means the offset carries over unchanged; the
    /// bounds check keeps the translation total.
    fn rawSpan(raw: []const u8, sanitized: []const u8, span: []const u8) ?[]const u8 {
        const offset = @intFromPtr(span.ptr) - @intFromPtr(sanitized.ptr);
        if (offset > raw.len or span.len > raw.len - offset) return null;
        return raw[offset..][0..span.len];
    }

    fn appendDecl(
        allocator: Allocator,
        classes: *std.ArrayList(core.types.ClassInfo),
        raw_line: []const u8,
        sanitized: []const u8,
        decl: Decl,
    ) !void {
        const name = rawSpan(raw_line, sanitized, decl.name) orelse return;

        var base_list = std.ArrayList([]const u8).empty;
        errdefer base_list.deinit(allocator);
        for (decl.bases) |base| {
            const mapped = rawSpan(raw_line, sanitized, base) orelse continue;
            if (mapped.len == 0) continue;
            try base_list.append(allocator, mapped);
        }

        try classes.append(allocator, .{
            .name = name,
            .bases = if (base_list.items.len == 0) null else try base_list.toOwnedSlice(allocator),
            .kind = decl.kind,
        });
    }

    fn detectDecl(line: []const u8, lang: []const u8, bases: *BaseBuf) ?Decl {
        if (std.mem.eql(u8, lang, "python")) return detectPythonClass(line, bases);
        if (std.mem.eql(u8, lang, "rust")) return detectRustItem(line, bases);
        if (isJsLang(lang)) return detectJsClass(line, bases);
        if (std.mem.eql(u8, lang, "cpp")) return detectCppClass(line, bases);
        if (std.mem.eql(u8, lang, "zig")) return detectZigType(line);
        if (std.mem.eql(u8, lang, "go")) return detectGoType(line);
        return null;
    }

    fn isJsLang(lang: []const u8) bool {
        return std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript");
    }

    /// Lexer dialect for `lang`. TypeScript shares the JavaScript one; C++ has
    /// no dialect of its own, and C/Go/C#/… fall back to generic string and
    /// comment handling.
    fn lexerLanguage(lang: []const u8) core.source_lexer.Language {
        if (std.mem.eql(u8, lang, "python")) return .python;
        if (std.mem.eql(u8, lang, "rust")) return .rust;
        if (isJsLang(lang)) return .javascript;
        if (std.mem.eql(u8, lang, "zig")) return .zig;
        if (std.mem.eql(u8, lang, "go")) return .go;
        if (std.mem.eql(u8, lang, "c") or std.mem.eql(u8, lang, "cpp")) return .c;
        return .other;
    }

    // Python: class X(Base1, Base2): — also `class X:` and kwonly `class X(Y, metaclass=ABC):`
    fn detectPythonClass(line: []const u8, bases: *BaseBuf) ?Decl {
        if (!std.mem.startsWith(u8, line, "class ")) return null;
        const rest = line["class ".len..];
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;

        if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse return null;
            var iter = std.mem.splitScalar(u8, rest[open + 1 .. close], ',');
            while (iter.next()) |raw_base| {
                const base = std.mem.trim(u8, raw_base, " \t");
                // Skip keyword args like metaclass=ABC — not a base class
                if (std.mem.indexOfScalar(u8, base, '=') != null) continue;
                if (base.len == 0) continue;
                bases.add(base);
            }
        }

        return .{ .name = name, .bases = bases.slice() };
    }

    // Rust: trait X, struct X, enum X, impl Trait for Type, impl Type
    fn detectRustItem(line: []const u8, bases: *BaseBuf) ?Decl {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub ")) rest = rest["pub ".len..];
        if (std.mem.startsWith(u8, rest, "pub(")) {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
        }

        if (std.mem.startsWith(u8, rest, "trait ")) return .{ .name = keywordName(rest, "trait ") orelse return null, .kind = .trait };
        if (std.mem.startsWith(u8, rest, "struct ")) return .{ .name = keywordName(rest, "struct ") orelse return null, .kind = .struct_kind };
        if (std.mem.startsWith(u8, rest, "enum ")) return .{ .name = keywordName(rest, "enum ") orelse return null, .kind = .enum_kind };
        if (std.mem.startsWith(u8, rest, "impl ") or std.mem.startsWith(u8, rest, "impl<")) {
            return detectRustImpl(rest["impl".len..], bases);
        }
        return null;
    }

    // Rust: impl<T> Trait for Type / impl<T> Type<T> / impl Trait for &'a mut Type
    fn detectRustImpl(imp: []const u8, bases: *BaseBuf) ?Decl {
        // `impl<T: Bound>` is a parameter list, not part of either name.
        const head = stripGenerics(std.mem.trimStart(u8, imp, " \t"));
        if (indexOfOutsideGenerics(head, " for ")) |kw| {
            const trait_name = rustTypeName(head[0..kw]) orelse return null;
            const type_name = rustTypeName(head[kw + " for ".len ..]) orelse return null;
            // Represent the impl as a class-like entry: the implementer
            // with the trait as a base.
            bases.add(trait_name);
            return .{ .name = type_name, .bases = bases.slice(), .kind = .struct_kind };
        }
        // Plain `impl Type` — inherent impl, no inheritance
        const type_name = rustTypeName(head) orelse return null;
        return .{ .name = type_name, .kind = .struct_kind };
    }

    /// Leaf type name of a Rust type expression: `dyn Iterator<Item = u8>` →
    /// `Iterator`, `&'a mut Vec<T>` → `Vec`, `fmt::Display` → `Display`.
    fn rustTypeName(seg: []const u8) ?[]const u8 {
        var rest = std.mem.trim(u8, seg, " \t");
        while (true) {
            if (std.mem.startsWith(u8, rest, "&")) {
                rest = std.mem.trimStart(u8, rest[1..], " \t");
            } else if (rest.len > 0 and rest[0] == '\'') {
                // Lifetime: `'a mut Foo` — drop the name, keep what follows.
                rest = std.mem.trimStart(u8, rest[1..], "abcdefghijklmnopqrstuvwxyz_");
                rest = std.mem.trimStart(u8, rest, " \t");
            } else if (std.mem.startsWith(u8, rest, "mut ")) {
                rest = rest["mut ".len..];
            } else if (std.mem.startsWith(u8, rest, "dyn ")) {
                rest = rest["dyn ".len..];
            } else break;
        }
        const parsed = scanTypeName(rest) orelse return null;
        return parsed.name;
    }

    /// Drop a leading generic argument list: `<T: Bound> Foo` → `Foo`.
    fn stripGenerics(seg: []const u8) []const u8 {
        if (seg.len == 0 or seg[0] != '<') return seg;
        const end = matchAngle(seg, 0) orelse return seg;
        return std.mem.trimStart(u8, seg[end..], " \t");
    }

    /// Index just past the `>` closing the `<` at `start`, or null when the
    /// brackets never balance.
    fn matchAngle(seg: []const u8, start: usize) ?usize {
        var depth: usize = 0;
        var i = start;
        while (i < seg.len) : (i += 1) {
            switch (seg[i]) {
                '<' => depth += 1,
                '>' => {
                    if (isArrow(seg, i)) continue;
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return null;
    }

    /// First `needle` occurrence that is not inside a `<...>` list, so a `->`
    /// arrow in a bound (`Fn() -> u32`) cannot swallow a later `for`.
    fn indexOfOutsideGenerics(seg: []const u8, needle: []const u8) ?usize {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < seg.len) : (i += 1) {
            switch (seg[i]) {
                '<' => depth += 1,
                '>' => if (!isArrow(seg, i) and depth > 0) {
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0 and std.mem.startsWith(u8, seg[i..], needle)) return i;
        }
        return null;
    }

    fn isArrow(seg: []const u8, i: usize) bool {
        return i > 0 and seg[i - 1] == '-';
    }

    // JS/TS: export default abstract class X extends Y implements A, B
    fn detectJsClass(line: []const u8, bases: *BaseBuf) ?Decl {
        const rest = stripJsModifiers(line);
        if (!std.mem.startsWith(u8, rest, "class ")) return null;
        const after = rest["class ".len..];
        const name = scanIdentifier(after) orelse return null;
        if (name.len == 0) return null;

        if (std.mem.indexOf(u8, after, " extends ")) |ext| {
            const seg = after[ext + " extends ".len ..];
            const base = scanBaseSegment(seg, " implements") orelse seg;
            const trimmed = leafName(std.mem.trim(u8, base, " \t{}"));
            if (trimmed.len > 0) bases.add(trimmed);
        }
        if (std.mem.indexOf(u8, after, " implements ")) |imp| {
            const seg = after[imp + " implements ".len ..];
            const list_str = scanBaseSegment(seg, "{") orelse seg;
            var iter = std.mem.splitScalar(u8, std.mem.trim(u8, list_str, " \t{"), ',');
            while (iter.next()) |iface| {
                const trimmed = leafName(std.mem.trim(u8, iface, " \t"));
                if (trimmed.len > 0) bases.add(trimmed);
            }
        }

        return .{ .name = name, .bases = bases.slice() };
    }

    fn stripJsModifiers(line: []const u8) []const u8 {
        var rest = line;
        while (true) {
            var stripped = false;
            for (js_modifiers) |modifier| {
                if (!std.mem.startsWith(u8, rest, modifier)) continue;
                rest = rest[modifier.len..];
                stripped = true;
                break;
            }
            if (!stripped) return rest;
        }
    }

    // C++: class ns::Foo : public Bar, private Baz {
    fn detectCppClass(line: []const u8, bases: *BaseBuf) ?Decl {
        // `template <class T> class Foo` needs a real parser; skip it.
        if (std.mem.startsWith(u8, line, "template")) return null;

        var rest = line;
        var kind: core.types.ClassKind = .class;
        if (std.mem.startsWith(u8, rest, "class ")) {
            rest = rest["class ".len..];
        } else if (std.mem.startsWith(u8, rest, "struct ")) {
            rest = rest["struct ".len..];
            kind = .struct_kind;
        } else return null;

        const parsed = scanTypeName(rest) orelse return null;
        if (parsed.name.len == 0) return null;

        // Only a `:` ahead of the body starts a base-specifier list; the one in
        // `ns::Foo` is already consumed by the name scan above.
        const tail = parsed.rest;
        if (std.mem.indexOfScalar(u8, tail, ':')) |colon| {
            const body = std.mem.indexOfScalar(u8, tail, '{');
            if (body == null or colon < body.?) {
                var iter = std.mem.splitScalar(u8, tail[colon + 1 .. body orelse tail.len], ',');
                while (iter.next()) |raw_base| {
                    const base = stripAccessSpecifiers(raw_base);
                    const named = scanTypeName(base) orelse continue;
                    if (named.name.len == 0) continue;
                    bases.add(named.name);
                }
            }
        }

        return .{ .name = parsed.name, .bases = bases.slice(), .kind = kind };
    }

    fn stripAccessSpecifiers(raw_base: []const u8) []const u8 {
        var base = std.mem.trim(u8, raw_base, " \t");
        inline for (cpp_access_specifiers) |spec| {
            if (std.mem.startsWith(u8, base, spec)) base = std.mem.trimStart(u8, base[spec.len..], " ");
        }
        return base;
    }

    /// Parse a possibly qualified, possibly templated type name:
    /// `ns::Outer::Foo<int>` → name `Foo` plus whatever follows it. The leaf
    /// is what the inherit graph matches on, so `class ns::Base` and a
    /// `public ns::Base` reference agree on one key; two same-named classes in
    /// different namespaces then simply read as ambiguous, which
    /// `inherit_graph` already refuses to resolve.
    fn scanTypeName(seg: []const u8) ?TypeName {
        var i: usize = 0;
        while (true) {
            const start = i;
            while (i < seg.len and isIdentChar(seg[i])) i += 1;
            if (i == start) return null;
            const name = seg[start..i];
            if (i + 1 < seg.len and seg[i] == ':' and seg[i + 1] == ':') {
                i += 2;
                continue;
            }
            if (i < seg.len and seg[i] == '<') {
                i = matchAngle(seg, i) orelse return .{ .name = name, .rest = seg[i..] };
            }
            return .{ .name = name, .rest = seg[i..] };
        }
    }

    /// Same leaf policy as `scanTypeName`, for references that are already
    /// isolated (JS/TS `ns.Base`, `a.b.Base`).
    fn leafName(qualified: []const u8) []const u8 {
        var name = qualified;
        if (std.mem.lastIndexOf(u8, name, "::")) |sep| name = name[sep + "::".len ..];
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |sep| name = name[sep + 1 ..];
        return name;
    }

    // Zig: no inheritance, but record type kinds for completeness
    fn detectZigType(line: []const u8) ?Decl {
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
    fn detectGoType(line: []const u8) ?Decl {
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

    fn keywordName(rest: []const u8, keyword: []const u8) ?[]const u8 {
        const name = scanIdentifier(rest[keyword.len..]) orelse return null;
        if (name.len == 0) return null;
        return name;
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

test "names and bases alias the source contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The blanked-out literal shifts every later byte, so this also checks the
    // offsets stay stable across the lexer's discarded region.
    var buf: [96]u8 = undefined;
    const contents = try std.fmt.bufPrint(&buf, "title = \"class Ghost(Base)\"\nclass Real(Base):\n", .{});
    const classes = try ClassExtractor.extract(arena.allocator(), contents, "python");
    try std.testing.expectEqual(@as(usize, 1), classes.len);

    const name = classes[0].name;
    try std.testing.expect(withinContents(contents, name));
    try std.testing.expectEqualStrings("Real", name);
    const base = classes[0].bases.?[0];
    try std.testing.expect(withinContents(contents, base));
    try std.testing.expectEqualStrings("Base", base);
}

fn withinContents(contents: []const u8, span: []const u8) bool {
    const start = @intFromPtr(contents.ptr);
    const span_start = @intFromPtr(span.ptr);
    return span_start >= start and span_start + span.len <= start + contents.len;
}

test "python comments and literals do not create classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\hint = "class Quoted(Shape)"
        \\count = 1  # class Hashed(Shape)
        \\/* class Blocked(Shape)
        \\   class StillBlocked(Shape)
        \\*/
        \\class Visible(Shape):
        \\"""
        \\class InsideDocstring(Shape)
        \\"""
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqualStrings("Visible", classes[0].name);
    try std.testing.expectEqualStrings("Shape", classes[0].bases.?[0]);
}

test "js strings and template literals do not create classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const quoted = 'class Quoted extends Shape';
        \\const quoted2 = "class Quoted2 implements Drawable";
        \\const tmpl = `class InTemplate extends Shape
        \\class AlsoInTemplate extends Shape`;
        \\// class Commented extends Shape
        \\class Visible extends Shape {}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqualStrings("Visible", classes[0].name);
    try std.testing.expectEqualStrings("Shape", classes[0].bases.?[0]);
}

test "cpp strings and comments do not create classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const char* doc = "class Quoted : public Shape";
        \\// class Commented : public Shape
        \\/* class Blocked : public Shape */
        \\class Visible : public Shape {
        \\};
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "cpp");
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqualStrings("Visible", classes[0].name);
    try std.testing.expectEqualStrings("Shape", classes[0].bases.?[0]);
}

test "js export default class ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\export default class App extends Base {}
        \\export default abstract class Mixed extends Base implements Drawable {}
        \\export declare class Declared implements Drawable {}
        \\export class Named {}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 4), classes.len);
    try std.testing.expectEqualStrings("App", classes[0].name);
    try std.testing.expectEqualStrings("Base", classes[0].bases.?[0]);
    try std.testing.expectEqualStrings("Mixed", classes[1].name);
    const mixed = classes[1].bases.?;
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expectEqualStrings("Base", mixed[0]);
    try std.testing.expectEqualStrings("Drawable", mixed[1]);
    try std.testing.expectEqualStrings("Declared", classes[2].name);
    try std.testing.expectEqualStrings("Drawable", classes[2].bases.?[0]);
    try std.testing.expectEqualStrings("Named", classes[3].name);
    try std.testing.expect(classes[3].bases == null);
}

test "rust impl with generic parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\impl<T> Display for Wrapper<T> {
        \\}
        \\
        \\impl<F: Fn() -> u32> Iterator for Pipeline {
        \\}
        \\
        \\impl<T: Into<String>> Borrow<Wrapper<T>> for Cache<T> {
        \\}
        \\
        \\impl<T> From<Vec<T>> for Wrapper<T> {
        \\}
        \\
        \\impl<T> Wrapper<T> {
        \\}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 5), classes.len);

    try std.testing.expectEqualStrings("Wrapper", classes[0].name);
    try std.testing.expectEqualStrings("Display", classes[0].bases.?[0]);

    // `->` inside a bound must not close the parameter list early
    try std.testing.expectEqualStrings("Pipeline", classes[1].name);
    try std.testing.expectEqualStrings("Iterator", classes[1].bases.?[0]);

    // trait that itself takes generic arguments
    try std.testing.expectEqualStrings("Cache", classes[2].name);
    try std.testing.expectEqualStrings("Borrow", classes[2].bases.?[0]);

    try std.testing.expectEqualStrings("Wrapper", classes[3].name);
    try std.testing.expectEqualStrings("From", classes[3].bases.?[0]);

    // inherent impl with generics — no bases
    try std.testing.expectEqualStrings("Wrapper", classes[4].name);
    try std.testing.expect(classes[4].bases == null);
}

test "rust qualified trait path resolves to its leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\impl fmt::Display for Parser {
        \\}
        \\
        \\impl crate::traits::Drawable for Canvas {
        \\}
        \\
        \\impl Write for dyn Debug {
        \\}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 3), classes.len);
    try std.testing.expectEqualStrings("Parser", classes[0].name);
    try std.testing.expectEqualStrings("Display", classes[0].bases.?[0]);
    try std.testing.expectEqualStrings("Canvas", classes[1].name);
    try std.testing.expectEqualStrings("Drawable", classes[1].bases.?[0]);
    try std.testing.expectEqualStrings("Debug", classes[2].name);
    try std.testing.expectEqualStrings("Write", classes[2].bases.?[0]);
}

test "cpp namespace qualified class names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\namespace ns {
        \\class Base {
        \\};
        \\}
        \\
        \\class ns::Derived : public ns::Base {
        \\};
        \\
        \\class ns::Outer::Inner {};
        \\
        \\class Boxed : public ns::Base, private ns::Outer {};
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "cpp");
    try std.testing.expectEqual(@as(usize, 4), classes.len);
    // the namespace itself is not a class, and the `::` never becomes a base
    try std.testing.expectEqualStrings("Base", classes[0].name);
    try std.testing.expect(classes[0].bases == null);
    try std.testing.expectEqualStrings("Derived", classes[1].name);
    try std.testing.expectEqualStrings("Base", classes[1].bases.?[0]);
    try std.testing.expectEqualStrings("Inner", classes[2].name);
    try std.testing.expect(classes[2].bases == null);
    try std.testing.expectEqualStrings("Boxed", classes[3].name);
    const boxed = classes[3].bases.?;
    try std.testing.expectEqual(@as(usize, 2), boxed.len);
    try std.testing.expectEqualStrings("Base", boxed[0]);
    try std.testing.expectEqualStrings("Outer", boxed[1]);
}

test "cpp templated class name skips its arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\class ns::Holder<int> : public ns::Base {
        \\};
        \\class ns::Pair<int, ns::Base> {};
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "cpp");
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    try std.testing.expectEqualStrings("Holder", classes[0].name);
    try std.testing.expectEqualStrings("Base", classes[0].bases.?[0]);
    try std.testing.expectEqualStrings("Pair", classes[1].name);
    try std.testing.expect(classes[1].bases == null);
}

test "js qualified base names resolve to their leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\class G extends ns.Base implements ns.Drawable, a.b.Serializable {}
    ;
    const classes = try ClassExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqualStrings("G", classes[0].name);
    const bases = classes[0].bases.?;
    try std.testing.expectEqual(@as(usize, 3), bases.len);
    try std.testing.expectEqualStrings("Base", bases[0]);
    try std.testing.expectEqualStrings("Drawable", bases[1]);
    try std.testing.expectEqualStrings("Serializable", bases[2]);
}
