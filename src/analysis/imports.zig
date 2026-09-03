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
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            // Skip line comments (except C, where '#' is a preprocessor directive)
            if (std.mem.startsWith(u8, line, "//")) continue;
            if (lang_kind != .c and lang_kind != .cpp and std.mem.startsWith(u8, line, "#")) continue;

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

    fn contains(items: []const []const u8, target: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item, target)) return true;
        }
        return false;
    }

    // ── Zig: @import("module") ──
    fn extractZig(line: []const u8) ?[]const u8 {
        const marker = "@import(\"";
        const start = std.mem.indexOf(u8, line, marker) orelse return null;
        const str_start = start + marker.len;
        const end = std.mem.indexOfPos(u8, line, str_start, "\"") orelse return null;
        return line[str_start..end];
    }

    // ── Rust: use a::b::c;  /  use a::{b, c};  /  mod foo; ──
    fn extractRust(line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "use ")) {
            const rest = std.mem.trim(u8, line[4..], " \t;");
            if (rest.len == 0) return null;
            // Strip braces: "a::{b, c}" → "a"
            if (std.mem.indexOfScalar(u8, rest, '{')) |brace| {
                return std.mem.trimEnd(u8, rest[0..brace], " \t:");
            }
            return rest;
        }
        if (std.mem.startsWith(u8, line, "mod ")) {
            const rest = std.mem.trim(u8, line[4..], " \t;");
            if (rest.len == 0 or !isRustModName(rest)) return null;
            return rest;
        }
        return null;
    }

    fn isRustModName(s: []const u8) bool {
        // mod foo; — single identifier, no dots/slashes/colons
        if (s.len == 0) return false;
        for (s) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return true;
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
        // import x from "mod"; / import "mod"; / export { x } from "mod";
        if (std.mem.indexOf(u8, line, " from \"")) |from_kw| {
            const str_start = from_kw + " from \"".len;
            const end = std.mem.indexOfPos(u8, line, str_start, "\"") orelse return null;
            return line[str_start..end];
        }
        if (std.mem.startsWith(u8, line, "import \"")) {
            const str_start = "import \"".len;
            const end = std.mem.indexOfPos(u8, line, str_start, "\"") orelse return null;
            return line[str_start..end];
        }
        // require("mod")
        if (std.mem.indexOf(u8, line, "require(\"")) |req| {
            const str_start = req + "require(\"".len;
            const end = std.mem.indexOfPos(u8, line, str_start, "\"") orelse return null;
            return line[str_start..end];
        }
        return null;
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
        \\pub fn main() {}
        \\// use nope;
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "rust");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("std::collections::HashMap", imports[0]);
    try std.testing.expectEqualStrings("crate::foo", imports[1]);
    try std.testing.expectEqualStrings("parser", imports[2]);
}

test "python imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import os
        \\import numpy as np
        \\from mypkg.sub import helper
        \\from .relative import thing
        \\# import nope
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 4), imports.len);
    try std.testing.expectEqualStrings("os", imports[0]);
    try std.testing.expectEqualStrings("numpy", imports[1]);
    try std.testing.expectEqualStrings("mypkg.sub", imports[2]);
    try std.testing.expectEqualStrings(".relative", imports[3]);
}

test "js imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\import x from "mod-a";
        \\import "side-effect";
        \\export { y } from "mod-b";
        \\const z = require("mod-c");
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "javascript");
    try std.testing.expectEqual(@as(usize, 4), imports.len);
    try std.testing.expectEqualStrings("mod-a", imports[0]);
    try std.testing.expectEqualStrings("side-effect", imports[1]);
    try std.testing.expectEqualStrings("mod-b", imports[2]);
    try std.testing.expectEqualStrings("mod-c", imports[3]);
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
        \\func main() {}
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
    ;
    const imports = try ImportExtractor.extract(arena.allocator(), src, "c");
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("local.h", imports[0]);
    try std.testing.expectEqualStrings("indented.h", imports[1]);
    try std.testing.expectEqualStrings("dir/other.h", imports[2]);
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
