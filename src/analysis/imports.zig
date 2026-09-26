const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Line-based import extraction for 6 languages.
/// No tree-sitter — plain string scanning per line, good enough for graph metrics.
///
/// Comment, string and template state comes from the shared lexer
/// (`core.source_lexer`), the same one function/class extraction uses. A
/// backtick inside a string or a line comment can therefore no longer open a
/// template literal that would hide every import below it, and unterminated
/// block comments, Python triple quotes and JS templates are tracked
/// byte-exactly instead of by per-line heuristics.
///
/// Every line is scanned twice: through the lexer to get a same-length `masked`
/// buffer (comment and literal bytes blanked to spaces) and against the
/// original text. A marker is only accepted when the masked copy still shows
/// it, i.e. when those bytes were real code; the import payload is sliced from
/// the original text because it lives inside a literal.
///
/// The extractor is stateless; pass an arena allocator since the returned
/// slices (and their contents) only need to live for graph building.
pub const ImportExtractor = struct {
    /// Extract raw import strings from source contents.
    /// `lang` is the detected language (e.g. "zig", "rust").
    /// Returned slices point into `contents` where possible; caller must keep
    /// contents alive or pass an arena that owns everything.
    pub fn extract(allocator: Allocator, contents: []const u8, lang: []const u8) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer result.deinit(allocator);

        const lang_kind = langId(lang);
        var lexer_state = core.source_lexer.State{};
        var in_go_import_block = false;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            // Same-length mask: every comment byte and every string/template
            // byte becomes a space, so a marker visible in `masked` is code.
            var masked = std.ArrayList(u8).empty;
            defer masked.deinit(allocator);
            try core.source_lexer.sanitizeLine(
                allocator,
                &masked,
                raw_line,
                lexerLanguage(lang_kind),
                .discard_literals,
                &lexer_state,
            );

            if (lang_kind == .go) {
                try extractGoLine(allocator, &result, raw_line, masked.items, &in_go_import_block);
                continue;
            }

            // No code on this line (blank, comment-only, or nothing but a
            // string literal) means no import keyword can start here.
            const start = codeStart(masked.items) orelse continue;
            const line = raw_line[start..];
            const code = masked.items[start..];

            if (lang_kind != .c and lang_kind != .cpp and std.mem.startsWith(u8, code, "#")) continue;

            if (lang_kind == .python) {
                try extractPythonImports(allocator, &result, line, code);
                continue;
            }

            const raw: ?[]const u8 = switch (lang_kind) {
                // Zig: @import("module")
                .zig => extractQuoted(line, code, "@import("),
                // Rust: use a::b;  /  mod foo;
                .rust => extractRust(line, code),
                // JS/TS: from "..." / import "..." / require("...") / import("...")
                .javascript, .typescript => extractJs(line, code),
                // C/C++: #include "local.h" — angle includes are skipped because
                // the char after the marker is not a quote.
                .c, .cpp => extractQuoted(line, code, "#include "),
                else => null,
            };

            if (raw) |r| {
                if (r.len > 0 and !contains(result.items, r)) try result.append(allocator, r);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// True when `extract` knows how to read imports for this language name.
    /// graph_builder uses it to keep its extension table and this module in sync.
    pub fn supportsLanguage(lang: []const u8) bool {
        return langId(lang) != .other;
    }

    // ── JS/TS: from "..." import / import "..." / require("...") ──
    fn extractJs(line: []const u8, code: []const u8) ?[]const u8 {
        if (extractQuoted(line, code, " from ")) |value| return value;
        if (extractQuoted(line, code, "import ")) |value| return value;
        if (extractQuoted(line, code, "require(")) |value| return value;
        if (extractQuoted(line, code, "import(")) |value| return value;
        return null;
    }

    /// First `"…"`/`'…'` directly after a `marker` occurrence that the lexer
    /// reported as code. The marker is matched on `code` (comment/literal-free)
    /// but the payload is read from `line`, where the literal still exists.
    fn extractQuoted(line: []const u8, code: []const u8, marker: []const u8) ?[]const u8 {
        var from: usize = 0;
        while (findCodeMarker(line, code, marker, from)) |marker_start| {
            const quote_start = marker_start + marker.len;
            if (quote_start < line.len) {
                const quote = line[quote_start];
                if (quote == '"' or quote == '\'') {
                    const value_start = quote_start + 1;
                    if (std.mem.indexOfScalarPos(u8, line, value_start, quote)) |end| {
                        return line[value_start..end];
                    }
                }
            }
            from = marker_start + 1;
        }
        return null;
    }

    /// First occurrence of `marker` at or after `from` that survived blanking.
    fn findCodeMarker(line: []const u8, code: []const u8, marker: []const u8, from: usize) ?usize {
        var index = from;
        while (std.mem.indexOfPos(u8, line, index, marker)) |at| {
            if (std.mem.startsWith(u8, code[at..], marker)) return at;
            index = at + 1;
        }
        return null;
    }

    // ── Rust: use a::b::c;  /  use a::{b, c};  /  mod foo; ──
    fn extractRust(line: []const u8, code: []const u8) ?[]const u8 {
        var rest: []const u8 = undefined;
        var is_mod = false;
        if (std.mem.startsWith(u8, code, "pub use ")) {
            rest = line["pub use ".len..];
        } else if (std.mem.startsWith(u8, code, "use ")) {
            rest = line["use ".len..];
        } else if (std.mem.startsWith(u8, code, "pub mod ")) {
            rest = line["pub mod ".len..];
            is_mod = true;
        } else if (std.mem.startsWith(u8, code, "mod ")) {
            rest = line["mod ".len..];
            is_mod = true;
        } else {
            return null;
        }

        rest = std.mem.trim(u8, rest, " \t;");
        if (rest.len == 0) return null;
        if (std.mem.indexOf(u8, rest, " as ")) |as_kw| {
            rest = std.mem.trim(u8, rest[0..as_kw], " \t");
        }
        if (std.mem.indexOfScalar(u8, rest, '{')) |brace| {
            rest = std.mem.trimEnd(u8, rest[0..brace], " \t:");
        }
        if (is_mod and !isRustModName(rest)) return null;
        return rest;
    }

    fn isRustModName(s: []const u8) bool {
        // mod foo; — single identifier, no dots/slashes/colons
        if (s.len == 0) return false;
        for (s) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return true;
    }

    // ── Python: import a.b.c  /  from a.b import c  /  from .x import y ──
    fn extractPythonImports(
        allocator: Allocator,
        result: *std.ArrayList([]const u8),
        line: []const u8,
        code: []const u8,
    ) !void {
        if (std.mem.startsWith(u8, code, "import ")) {
            const rest = std.mem.trim(u8, line["import ".len..], " \t;");
            var parts = std.mem.splitScalar(u8, rest, ',');
            while (parts.next()) |part| {
                var module = std.mem.trim(u8, part, " \t;");
                if (std.mem.indexOf(u8, module, " as ")) |as_kw| {
                    module = std.mem.trim(u8, module[0..as_kw], " \t");
                }
                if (module.len > 0) try appendUnique(allocator, result, module);
            }
            return;
        }
        if (extractPythonFrom(line, code)) |module| try appendUnique(allocator, result, module);
    }

    /// from a.b import c → "a.b". Leading dots of ".x" / "..x" are kept verbatim
    /// for the resolver, which turns them into parent hops.
    fn extractPythonFrom(line: []const u8, code: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, code, "from ")) return null;
        const offset = "from ".len;
        const imp_kw = std.mem.indexOf(u8, code[offset..], " import ") orelse return null;
        return std.mem.trim(u8, line[offset .. offset + imp_kw], " \t");
    }

    // ── Go: import "mod"  /  import ( … ) blocks ──
    fn extractGoLine(
        allocator: Allocator,
        result: *std.ArrayList([]const u8),
        line: []const u8,
        masked: []const u8,
        in_block: *bool,
    ) !void {
        // Trim the masked copy: a `)` or `import` inside a comment is blanked.
        const code = std.mem.trim(u8, masked, " \t\r");

        if (in_block.*) {
            if (std.mem.eql(u8, code, ")")) {
                in_block.* = false;
                return;
            }
            if (extractGoBlockEntry(line)) |raw| try appendUnique(allocator, result, raw);
            return;
        }

        if (std.mem.startsWith(u8, code, "import") and std.mem.indexOfScalar(u8, code, '(') != null) {
            in_block.* = true;
            return;
        }
        if (extractQuoted(line, masked, "import ")) |raw| try appendUnique(allocator, result, raw);
    }

    /// Inside `import ( … )`: a bare or aliased path, e.g. `"os"` or
    /// `alias "example.com/pkg"`. Anything else (comments, blank lines, code)
    /// is rejected instead of guessed at.
    fn extractGoBlockEntry(line: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return null;
        if (trimmed[0] == '/') return null; // comment
        const first = std.mem.indexOfScalar(u8, trimmed, '"') orelse return null;
        const last = std.mem.lastIndexOfScalar(u8, trimmed, '"') orelse return null;
        if (first == last) return null; // unbalanced
        if (last != trimmed.len - 1) return null; // trailing junk
        const alias = std.mem.trim(u8, trimmed[0..first], " \t");
        if (alias.len != 0 and !isGoAlias(alias)) return null;
        const inner = trimmed[first + 1 .. last];
        if (inner.len == 0 or
            std.mem.indexOfScalar(u8, inner, '"') != null or
            std.mem.indexOfScalar(u8, inner, '(') != null)
        {
            return null;
        }
        return inner;
    }

    fn isGoAlias(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '*') return false;
        }
        return true;
    }

    fn contains(items: []const []const u8, target: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item, target)) return true;
        }
        return false;
    }

    fn appendUnique(allocator: Allocator, result: *std.ArrayList([]const u8), raw: []const u8) !void {
        if (raw.len > 0 and !contains(result.items, raw)) try result.append(allocator, raw);
    }

    /// First index holding a real code byte, or null when the line is only
    /// whitespace, comments and literals.
    fn codeStart(masked: []const u8) ?usize {
        for (masked, 0..) |byte, index| {
            if (byte != ' ' and byte != '\t' and byte != '\r') return index;
        }
        return null;
    }
};

const Lang = enum { zig, rust, python, javascript, typescript, go, c, cpp, other };

fn langId(lang: []const u8) Lang {
    if (std.mem.eql(u8, lang, "zig")) return .zig;
    if (std.mem.eql(u8, lang, "rust")) return .rust;
    if (std.mem.eql(u8, lang, "python")) return .python;
    if (std.mem.eql(u8, lang, "javascript")) return .javascript;
    if (std.mem.eql(u8, lang, "typescript")) return .typescript;
    if (std.mem.eql(u8, lang, "go")) return .go;
    if (std.mem.eql(u8, lang, "c")) return .c;
    if (std.mem.eql(u8, lang, "cpp")) return .cpp;
    return .other;
}

/// The shared lexer has no typescript/cpp variants: both read as their
/// closest relative (templates for TS, C-style strings/comments for C++).
fn lexerLanguage(lang: Lang) core.source_lexer.Language {
    return switch (lang) {
        .zig => .zig,
        .rust => .rust,
        .python => .python,
        .javascript, .typescript => .javascript,
        .go => .go,
        .c, .cpp => .c,
        .other => .other,
    };
}

// ── Tests ─────────────────────────────────────────────────────

test "zig imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const std = @import("std");
        \\const core = @import("core");
        \\const metrics = @import("metrics/mod.zig");
        \\// comment @import("nope")
        \\const text = "@import(\"fake\")"
        \\fn main() void {}
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("std", imports[0]);
    try std.testing.expectEqualStrings("core", imports[1]);
    try std.testing.expectEqualStrings("metrics/mod.zig", imports[2]);
}

test "rust use and mod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\use std::collections::HashMap;
        \\use crate::foo::{Bar, Baz};
        \\mod parser;
        \\pub use helpers as support;
        \\pub mod config;
        \\pub fn main() {}
        \\// use nope;
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 5), imports.len);
    try std.testing.expectEqualStrings("std::collections::HashMap", imports[0]);
    try std.testing.expectEqualStrings("crate::foo", imports[1]);
    try std.testing.expectEqualStrings("parser", imports[2]);
    try std.testing.expectEqualStrings("helpers", imports[3]);
    try std.testing.expectEqualStrings("config", imports[4]);
}

test "python imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "import os, sys\n" ++
        "import numpy as np\n" ++
        "from mypkg.sub import helper\n" ++
        "from .relative import thing\n" ++
        "text = \"\"\"\n" ++
        "import fake\n" ++
        "\"\"\"\n" ++
        "import real2\n" ++
        "# import nope\n";
    const imports = try ImportExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 6), imports.len);
    try std.testing.expectEqualStrings("os", imports[0]);
    try std.testing.expectEqualStrings("sys", imports[1]);
    try std.testing.expectEqualStrings("numpy", imports[2]);
    try std.testing.expectEqualStrings("mypkg.sub", imports[3]);
    try std.testing.expectEqualStrings(".relative", imports[4]);
    try std.testing.expectEqualStrings("real2", imports[5]);
}

test "js imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import x from "mod-a";
        \\import "side-effect";
        \\export { y } from "mod-b";
        \\const z = require("mod-c");
        \\import single from 'mod-single';
        \\const dynamic = import('mod-dynamic');
        \\const text = "import fake from 'not-a-module'";
        \\import {
        \\    first,
        \\    second,
        \\} from "mod-multiline";
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 7), imports.len);
    try std.testing.expectEqualStrings("mod-a", imports[0]);
    try std.testing.expectEqualStrings("side-effect", imports[1]);
    try std.testing.expectEqualStrings("mod-b", imports[2]);
    try std.testing.expectEqualStrings("mod-c", imports[3]);
    try std.testing.expectEqualStrings("mod-single", imports[4]);
    try std.testing.expectEqualStrings("mod-dynamic", imports[5]);
    try std.testing.expectEqualStrings("mod-multiline", imports[6]);
}

test "go imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import "fmt"
        \\import (
        \\    "os"
        \\    alias "example.com/pkg"
        \\)
        \\func main() { const text = "not-an-import"; }
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "go");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("fmt", imports[0]);
    try std.testing.expectEqualStrings("os", imports[1]);
    try std.testing.expectEqualStrings("example.com/pkg", imports[2]);
}

test "c includes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\#include <stdio.h>
        \\#include "local.h"
        \\  #include "indented.h"
        \\#include "dir/other.h"
        \\/*
        \\#include "fake.h"
        \\*/
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "c");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("local.h", imports[0]);
    try std.testing.expectEqualStrings("indented.h", imports[1]);
    try std.testing.expectEqualStrings("dir/other.h", imports[2]);
}

test "typescript and cpp import variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const typescript =
        \\import type { Config } from "types";
        \\import {
        \\    first,
        \\    second,
        \\} from "pkg";
        \\const lazy = import("dynamic");
        \\// import "commented";
        \\const text = "import \"literal\"";
    ;
    const ts_imports = try ImportExtractor.extract(arena.allocator(), typescript, "typescript");
    try std.testing.expectEqual(@as(usize, 3), ts_imports.len);
    try std.testing.expectEqualStrings("types", ts_imports[0]);
    try std.testing.expectEqualStrings("pkg", ts_imports[1]);
    try std.testing.expectEqualStrings("dynamic", ts_imports[2]);

    const cpp =
        \\#include <vector>
        \\#include "local.hpp"
        \\/*
        \\#include "commented.hpp"
        \\*/
    ;
    const cpp_imports = try ImportExtractor.extract(arena.allocator(), cpp, "cpp");
    try std.testing.expectEqual(@as(usize, 1), cpp_imports.len);
    try std.testing.expectEqualStrings("local.hpp", cpp_imports[0]);
}

test "unknown language yields nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const imports = try ImportExtractor.extract(arena.allocator(), "import whatever", "ruby");
    try std.testing.expectEqual(@as(usize, 0), imports.len);
}

test "dedup imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const a = @import("std");
        \\const b = @import("std");
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 1), imports.len);
}

test "backticks in comments and strings do not hide later imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import "mod-a"; // don't ` panic
        \\const note = "a ` backtick in a string";
        \\import "mod-b";
        \\const text = "import \"fake\"";
        \\import "mod-c";
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("mod-a", imports[0]);
    try std.testing.expectEqualStrings("mod-b", imports[1]);
    try std.testing.expectEqualStrings("mod-c", imports[2]);
}

test "unterminated template hides only what follows inside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import "before";
        \\const tpl = `starts here
        \\import "inside";
        \\still going`;
        \\import "after";
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("before", imports[0]);
    try std.testing.expectEqualStrings("after", imports[1]);
}

test "block comment opened mid line hides following lines only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const a = @import("real");
        \\/* const b = @import("hidden");
        \\const c = @import("also-hidden");
        \\*/
        \\const d = @import("real-too");
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("real", imports[0]);
    try std.testing.expectEqualStrings("real-too", imports[1]);
}

test "block comment close lets the rest of the line count as code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\/*
        \\*/ const done = @import("after-close");
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("after-close", imports[0]);
}

test "rust use inside a block comment is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\/*
        \\use hidden::thing;
        \\*/
        \\use real::thing;
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("real::thing", imports[0]);
}

test "go import block ignores comments and code lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import (
        \\    // "commented/pkg"
        \\    _ "example.com/blank"
        \\    . "example.com/dot"
        \\    x := "not-an-import"
        \\)
        \\import "tail"
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "go");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("example.com/blank", imports[0]);
    try std.testing.expectEqualStrings("example.com/dot", imports[1]);
    try std.testing.expectEqualStrings("tail", imports[2]);
}

test "python relative imports are captured verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\from . import sibling
        \\from .helpers import tool
        \\from ..pkg.mod import thing
        \\from ...deep.mod import other
        \\import plain.sub
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 5), imports.len);
    try std.testing.expectEqualStrings(".", imports[0]);
    try std.testing.expectEqualStrings(".helpers", imports[1]);
    try std.testing.expectEqualStrings("..pkg.mod", imports[2]);
    try std.testing.expectEqualStrings("...deep.mod", imports[3]);
    try std.testing.expectEqualStrings("plain.sub", imports[4]);
}

test "python docstrings and parenthesised imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\'''doc'''
        \\from pkg import (
        \\    one,
        \\    two,
        \\)
        \\def f():
        \\    '''inner'''
        \\    import inner_mod
        \\    return inner_mod
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("pkg", imports[0]);
    try std.testing.expectEqualStrings("inner_mod", imports[1]);
}

test "lexer mask preserves line length for every language" {
    const lines = [_]struct { lang: Lang, text: []const u8 }{
        .{ .lang = .zig, .text = "const s = \"a\\\"b\"; // x" },
        .{ .lang = .rust, .text = "let s = r#\"raw \"quoted\" text\"#;" },
        .{ .lang = .python, .text = "s = '''triple\nquoted'''" },
        .{ .lang = .javascript, .text = "const t = `a ${b} c`;" },
        .{ .lang = .go, .text = "s := `raw` // trailing" },
        .{ .lang = .c, .text = "const char c = '\\'';" },
        .{ .lang = .cpp, .text = "auto s = R\"(raw \"x\")\";" },
    };
    for (lines) |entry| {
        var state = core.source_lexer.State{};
        var it = std.mem.splitScalar(u8, entry.text, '\n');
        while (it.next()) |line| {
            var masked = std.ArrayList(u8).empty;
            defer masked.deinit(std.testing.allocator);
            try core.source_lexer.sanitizeLine(
                std.testing.allocator,
                &masked,
                line,
                lexerLanguage(entry.lang),
                .discard_literals,
                &state,
            );
            try std.testing.expectEqual(line.len, masked.items.len);
        }
    }
}

test "supportsLanguage covers the extracted languages" {
    try std.testing.expect(ImportExtractor.supportsLanguage("zig"));
    try std.testing.expect(ImportExtractor.supportsLanguage("rust"));
    try std.testing.expect(ImportExtractor.supportsLanguage("python"));
    try std.testing.expect(ImportExtractor.supportsLanguage("javascript"));
    try std.testing.expect(ImportExtractor.supportsLanguage("typescript"));
    try std.testing.expect(ImportExtractor.supportsLanguage("go"));
    try std.testing.expect(ImportExtractor.supportsLanguage("c"));
    try std.testing.expect(ImportExtractor.supportsLanguage("cpp"));
    try std.testing.expect(!ImportExtractor.supportsLanguage("ruby"));
    try std.testing.expect(!ImportExtractor.supportsLanguage("unknown"));
}
