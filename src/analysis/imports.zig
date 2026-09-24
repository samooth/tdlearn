const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Line-based import extraction for 6 languages.
/// No tree-sitter — plain string scanning per line, good enough for graph metrics.
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

        var lines = std.mem.splitScalar(u8, contents, '\n');
        const lang_kind = langId(lang);
        var in_block_comment = false;
        var in_triple_quote: u8 = 0;
        var in_template = false;
        var in_go_import_block = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            if (in_block_comment) {
                if (std.mem.indexOf(u8, line, "*/") != null) in_block_comment = false;
                continue;
            }
            if (in_triple_quote != 0) {
                if (containsDelimiter(line, in_triple_quote)) in_triple_quote = 0;
                continue;
            }
            if (in_template) {
                if (hasClosingBacktick(line)) in_template = false;
                continue;
            }
            if (lang_kind != .python and hasUnclosedBlockComment(line)) {
                in_block_comment = true;
                continue;
            }
            if (lang_kind == .python and hasUnclosedTripleQuote(line, '"')) {
                in_triple_quote = '"';
                continue;
            }
            if (lang_kind == .python and hasUnclosedTripleQuote(line, '\'')) {
                in_triple_quote = '\'';
                continue;
            }
            if ((lang_kind == .javascript or lang_kind == .typescript) and hasUnclosedTemplate(line)) {
                in_template = true;
                continue;
            }

            if (lang_kind != .c and lang_kind != .cpp and std.mem.startsWith(u8, line, "#")) continue;
            if (lang_kind == .go) {
                if (in_go_import_block and std.mem.eql(u8, line, ")")) in_go_import_block = false;
                if (!in_go_import_block and std.mem.startsWith(u8, line, "import") and
                    std.mem.indexOfScalar(u8, line, '(') != null)
                {
                    in_go_import_block = true;
                }
                if (!in_go_import_block and !std.mem.startsWith(u8, line, "import \"")) continue;
            }

            if (lang_kind == .python) {
                try extractPythonImports(allocator, &result, line);
                continue;
            }

            const raw: ?[]const u8 = switch (lang_kind) {
                .zig => extractZig(line),
                .rust => extractRust(line),
                .python => extractPython(line),
                .javascript, .typescript => extractJs(line),
                .go => extractGo(line),
                .c, .cpp => extractC(line),
                else => null,
            };

            if (raw) |r| {
                if (r.len > 0 and !contains(result.items, r)) {
                    try result.append(allocator, r);
                }
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    fn containsDelimiter(line: []const u8, delimiter: u8) bool {
        const text: []const u8 = if (delimiter == '"') "\"\"\"" else "'''";
        return std.mem.indexOf(u8, line, text) != null;
    }

    fn hasUnclosedTripleQuote(line: []const u8, delimiter: u8) bool {
        const text: []const u8 = if (delimiter == '"') "\"\"\"" else "'''";
        const first = std.mem.indexOf(u8, line, text) orelse return false;
        return std.mem.indexOfPos(u8, line, first + text.len, text) == null;
    }

    fn hasUnclosedBlockComment(line: []const u8) bool {
        var quote: u8 = 0;
        var escaped = false;
        var index: usize = 0;
        while (index < line.len) {
            const character = line[index];
            if (quote != 0) {
                if (character == quote and !escaped) quote = 0;
                escaped = character == '\\' and !escaped;
                if (character != '\\') escaped = false;
                index += 1;
                continue;
            }
            if (character == '"' or character == '\'' or character == '`') {
                quote = character;
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, line[index..], "/*")) {
                return std.mem.indexOfPos(u8, line, index + 2, "*/") == null;
            }
            if (std.mem.startsWith(u8, line[index..], "//")) return false;
            index += 1;
        }
        return false;
    }

    fn hasUnclosedTemplate(line: []const u8) bool {
        var open = false;
        var escaped = false;
        for (line) |character| {
            if (character == '`' and !escaped) open = !open;
            escaped = character == '\\' and !escaped;
            if (character != '\\') escaped = false;
        }
        return open;
    }

    fn hasClosingBacktick(line: []const u8) bool {
        var escaped = false;
        for (line) |character| {
            if (character == '`' and !escaped) return true;
            escaped = character == '\\' and !escaped;
            if (character != '\\') escaped = false;
        }
        return false;
    }

    fn findCodeMarker(line: []const u8, marker: []const u8) ?usize {
        var quote: u8 = 0;
        var escaped = false;
        var index: usize = 0;
        while (index < line.len) {
            const character = line[index];
            if (quote != 0) {
                if (character == quote and !escaped) quote = 0;
                escaped = character == '\\' and !escaped;
                if (character != '\\') escaped = false;
                index += 1;
                continue;
            }
            if (character == '/' and index + 1 < line.len and line[index + 1] == '/') return null;
            if (character == '/' and index + 1 < line.len and line[index + 1] == '*') return null;
            if (character == '"' or character == '\'' or character == '`') {
                quote = character;
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, line[index..], marker)) return index;
            index += 1;
        }
        return null;
    }

    fn contains(items: []const []const u8, target: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item, target)) return true;
        }
        return false;
    }

    // ── Zig: @import("module") ──
    fn extractZig(line: []const u8) ?[]const u8 {
        const marker = "@import(\"";
        const start = findCodeMarker(line, marker) orelse return null;
        const str_start = start + marker.len;
        const end = std.mem.indexOfPos(u8, line, str_start, "\"") orelse return null;
        return line[str_start..end];
    }

    // ── Rust: use a::b::c;  /  use a::{b, c};  /  mod foo; ──
    fn extractRust(line: []const u8) ?[]const u8 {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub use ")) {
            rest = rest["pub use ".len..];
        } else if (std.mem.startsWith(u8, rest, "use ")) {
            rest = rest["use ".len..];
        } else if (std.mem.startsWith(u8, rest, "pub mod ")) {
            rest = rest["pub mod ".len..];
        } else if (std.mem.startsWith(u8, rest, "mod ")) {
            rest = rest["mod ".len..];
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
        if (std.mem.startsWith(u8, line, "mod ") or std.mem.startsWith(u8, line, "pub mod ")) {
            if (!isRustModName(rest)) return null;
        }
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

    fn extractPythonImports(allocator: Allocator, result: *std.ArrayList([]const u8), line: []const u8) !void {
        if (std.mem.startsWith(u8, line, "import ")) {
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
        if (extractPython(line)) |module| try appendUnique(allocator, result, module);
    }

    fn appendUnique(allocator: Allocator, result: *std.ArrayList([]const u8), raw: []const u8) !void {
        if (raw.len > 0 and !contains(result.items, raw)) try result.append(allocator, raw);
    }

    // ── Python: import a.b.c  /  from a.b import c ──
    fn extractPython(line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "import ")) {
            const rest = std.mem.trim(u8, line[7..], " \t;");
            // "import a, b" → take first
            if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
                return std.mem.trim(u8, rest[0..comma], " \t;");
            }
            // "import a as b" → take module part
            if (std.mem.indexOf(u8, rest, " as ")) |as_kw| {
                return std.mem.trim(u8, rest[0..as_kw], " \t");
            }
            return rest;
        }
        if (std.mem.startsWith(u8, line, "from ")) {
            const rest = line[5..];
            const imp_kw = std.mem.indexOf(u8, rest, " import ") orelse return null;
            return std.mem.trim(u8, rest[0..imp_kw], " \t");
        }
        return null;
    }

    // ── JS/TS: from "..." import / import "..." / require("...") ──
    fn extractJs(line: []const u8) ?[]const u8 {
        if (extractQuoted(line, " from ")) |value| return value;
        if (extractQuoted(line, "import ")) |value| return value;
        if (extractQuoted(line, "require(")) |value| return value;
        if (extractQuoted(line, "import(")) |value| return value;
        return null;
    }

    fn extractQuoted(line: []const u8, marker: []const u8) ?[]const u8 {
        const marker_start = findCodeMarker(line, marker) orelse return null;
        const quote_start = marker_start + marker.len;
        if (quote_start >= line.len) return null;
        const quote = line[quote_start];
        if (quote != '"' and quote != '\'') return null;
        const value_start = quote_start + 1;
        const end = std.mem.indexOfScalarPos(u8, line, value_start, quote) orelse return null;
        return line[value_start..end];
    }

    // ── Go: import "mod"  /  "mod" or alias "mod" inside import block ──
    fn extractGo(line: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "import \"")) {
            const str_start = "import \"".len;
            const end = std.mem.indexOfPos(u8, trimmed, str_start, "\"") orelse return null;
            return trimmed[str_start..end];
        }
        // Inside import block: quoted path, possibly preceded by an alias.
        // Grab the substring between first and last quote: alias "path" → path
        const first = std.mem.indexOfScalar(u8, trimmed, '"') orelse return null;
        const last = std.mem.lastIndexOfScalar(u8, trimmed, '"') orelse return null;
        if (first == last) return null; // unbalanced
        if (last != trimmed.len - 1) return null; // trailing junk
        const inner = trimmed[first + 1 .. last];
        // Reject block open/close and non-path content
        if (inner.len == 0 or
            std.mem.indexOfScalar(u8, inner, '"') != null or
            std.mem.indexOfScalar(u8, inner, '(') != null)
        {
            return null;
        }
        return inner;
    }

    // ── C/C++: #include "..." (skip <...>) ──
    fn extractC(line: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#include \"")) return null;
        const str_start = "#include \"".len;
        const end = std.mem.indexOfPos(u8, trimmed, str_start, "\"") orelse return null;
        return trimmed[str_start..end];
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

// ── Tests ─────────────────────────────────────────────────────

test "zig imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\const std = @import("std");
        \\const core = @import("core");
        \\const metrics = @import("metrics/mod.zig");
        \\// comment @import("nope")
        \\const text = "@import(\"fake\")";
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
        \\const text = "import \\"literal\\"";
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
