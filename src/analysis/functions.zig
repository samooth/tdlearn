const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// Line-based function/method extraction for dead-code and duplication analysis.
/// Detects declarations, public visibility, and body extents (brace matching
/// where the language uses braces; indentation fallback otherwise).
pub const FunctionExtractor = struct {
    /// Extract functions from source contents.
    /// Returned FuncInfo slices point into `contents` (names are sub-slices).
    pub fn extract(allocator: Allocator, contents: []const u8, lang: []const u8) ![]core.types.FuncInfo {
        var funcs = std.ArrayList(core.types.FuncInfo).empty;
        errdefer funcs.deinit(allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: u32 = 0;
        var scan_state = ComplexityState{};
        while (lines.next()) |raw_line| {
            line_no += 1;
            var code = std.ArrayList(u8).empty;
            defer code.deinit(allocator);
            try sanitizeLine(allocator, &code, raw_line, lang, &scan_state);
            const line = std.mem.trim(u8, code.items, " \t\r");

            const base_decl = detectDecl(line, lang) orelse continue;
            var decl = base_decl;
            const start_indent = indentation(raw_line);
            if (langKind(lang) == .python) {
                decl.is_method = start_indent > 0;
            }

            // Find body end via brace matching or Python indentation.
            const end_line = try findBodyEnd(allocator, contents, line_no, decl.open_brace, start_indent, lang);
            const complexity = try computeComplexity(allocator, contents, line_no, end_line, lang);
            const is_public = decl.pub_keyword;
            var line_start: usize = 0;
            while (line_start < raw_line.len and (raw_line[line_start] == ' ' or raw_line[line_start] == '\t')) : (line_start += 1) {}
            const stable_offset = line_start + decl.name_offset;
            if (stable_offset + decl.name.len > raw_line.len) continue;
            const stable_name = raw_line[stable_offset .. stable_offset + decl.name.len];

            try funcs.append(allocator, .{
                .name = stable_name,
                .start_line = line_no,
                .end_line = end_line,
                .line_count = end_line - line_no + 1,
                .cyclomatic_complexity = complexity.cyclomatic,
                .cognitive_complexity = complexity.cognitive,
                .param_count = complexity.params,
                .is_public = is_public,
                .is_method = decl.is_method,
            });
        }

        return try funcs.toOwnedSlice(allocator);
    }

    const Decl = struct {
        name: []const u8,
        name_offset: usize,
        pub_keyword: bool,
        is_method: bool,
        open_brace: bool,
    };

    fn nameOffset(line: []const u8, name: []const u8) usize {
        return @intFromPtr(name.ptr) - @intFromPtr(line.ptr);
    }

    const Complexity = struct {
        cyclomatic: u32 = 1,
        cognitive: u32 = 0,
        params: u32 = 0,
    };

    /// Detect a function declaration on this line for the given language.
    fn detectDecl(line: []const u8, lang: []const u8) ?Decl {
        const kind = langKind(lang);
        switch (kind) {
            .zig => return detectZigFn(line),
            .rust => return detectRustFn(line),
            .python => return detectPythonFn(line),
            .js => return detectJsFn(line),
            .go => return detectGoFn(line),
            .c => return detectCFn(line),
            .other => return null,
        }
    }

    // Zig: [pub] fn name(...) [!]
    fn detectZigFn(line: []const u8) ?Decl {
        var rest = line;
        var is_pub = false;
        if (std.mem.startsWith(u8, rest, "pub ")) {
            is_pub = true;
            rest = rest[4..];
        }
        // Export variants: export fn, inline fn, pub inline fn
        while (true) {
            if (std.mem.startsWith(u8, rest, "export ")) {
                rest = rest[7..];
                is_pub = true;
            } else if (std.mem.startsWith(u8, rest, "inline ")) {
                rest = rest[7..];
            } else break;
        }
        if (!std.mem.startsWith(u8, rest, "fn ")) return null;
        rest = rest[3..];
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;
        // Must be followed by ( to be a function
        const after = std.mem.trimStart(u8, rest[name.len..], " \t");
        if (after.len == 0 or after[0] != '(') return null;
        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = is_pub,
            .is_method = false, // Zig methods aren't distinguishable syntactically at line level
            .open_brace = true,
        };
    }

    // Rust: [pub] fn name / [pub] async fn name
    fn detectRustFn(line: []const u8) ?Decl {
        var rest = line;
        var is_pub = false;
        if (std.mem.startsWith(u8, rest, "pub ")) {
            is_pub = true;
            rest = rest[4..];
            // pub(crate) fn, pub(super) fn — space already consumed above
            if (std.mem.startsWith(u8, rest, "(")) {
                const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
                rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
            }
        } else if (std.mem.startsWith(u8, rest, "pub(")) {
            // pub(crate)/pub(super)/pub(in path) with no space after pub
            is_pub = true;
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
        }
        if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];
        if (std.mem.startsWith(u8, rest, "const ")) rest = rest[6..];
        if (std.mem.startsWith(u8, rest, "unsafe ")) rest = rest[7..];
        if (std.mem.startsWith(u8, rest, "extern ")) {
            const quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
            const quote_end = std.mem.indexOfScalarPos(u8, rest, quote + 1, '"') orelse return null;
            rest = rest[quote_end + 1 ..];
            rest = std.mem.trimStart(u8, rest, " ");
        }
        if (!std.mem.startsWith(u8, rest, "fn ")) return null;
        rest = rest[3..];
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;
        var after = std.mem.trimStart(u8, rest[name.len..], " \t");
        if (after.len != 0 and after[0] == '<') {
            const close = std.mem.indexOfScalar(u8, after, '>') orelse return null;
            after = std.mem.trimStart(u8, after[close + 1 ..], " \t");
        }
        if (after.len == 0 or after[0] != '(') return null;
        // Method heuristic: receiver &self or &mut self in params
        const is_method = std.mem.indexOf(u8, after, "&self") != null or
            std.mem.indexOf(u8, after, "self: ") != null;
        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = is_pub,
            .is_method = is_method,
            .open_brace = true,
        };
    }

    // Python: [async] def name(  /  class Name: (is_method via self param — approximated false)
    fn detectPythonFn(line: []const u8) ?Decl {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];
        if (!std.mem.startsWith(u8, rest, "def ")) return null;
        rest = rest[4..];
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;
        const after = std.mem.trimStart(u8, rest[name.len..], " \t");
        if (after.len == 0 or after[0] != '(') return null;
        // Indented def = method (approximation: leading whitespace was trimmed,
        // so check original line via name offset — skip; treat top-level only)
        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = false, // Python has no visibility
            .is_method = false,
            .open_brace = false, // indentation-based
        };
    }

    // JS/TS: [export] function name(  /  [export] async function name(
    fn detectJsFn(line: []const u8) ?Decl {
        var rest = line;
        var is_pub = false;
        if (std.mem.startsWith(u8, rest, "export default ")) {
            is_pub = true;
            rest = std.mem.trimStart(u8, rest["export default ".len..], " ");
        } else if (std.mem.startsWith(u8, rest, "export ")) {
            is_pub = true;
            rest = std.mem.trimStart(u8, rest["export ".len..], " ");
        }
        if (std.mem.startsWith(u8, rest, "async ")) rest = rest["async ".len..];
        if (!std.mem.startsWith(u8, rest, "function")) return null;
        rest = rest["function".len..];
        // Generator: function* name
        var was_generator = false;
        if (rest.len > 0 and rest[0] == '*') {
            was_generator = true;
            rest = std.mem.trimStart(u8, rest[1..], " ");
        }
        // Require a separator after `function` (functionName( is a call, not a decl)
        if (!was_generator) {
            if (rest.len == 0 or rest[0] != ' ') return null;
            rest = std.mem.trimStart(u8, rest, " ");
        }
        if (rest.len == 0) return null;
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;
        var after = std.mem.trimStart(u8, rest[name.len..], " \t");
        if (after.len != 0 and after[0] == '<') {
            const close = std.mem.indexOfScalar(u8, after, '>') orelse return null;
            after = std.mem.trimStart(u8, after[close + 1 ..], " \t");
        }
        if (after.len == 0 or after[0] != '(') return null;
        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = is_pub,
            .is_method = false,
            .open_brace = true,
        };
    }

    // Go: func name(  /  func (r *T) name( → method
    fn detectGoFn(line: []const u8) ?Decl {
        if (!std.mem.startsWith(u8, line, "func ")) return null;
        var rest = line[5..];
        var is_method = false;
        // Method receiver: func (r *Type) name(
        if (rest.len > 0 and rest[0] == '(') {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            // Heuristic: receiver parens contain a type, not a param list.
            // Real functions have a name before '(': we check if content between
            // the first parens contains a space/identifier pattern typical of receivers.
            const receiver = std.mem.trim(u8, rest[1..close], " \t");
            // Receiver is short ("r *T", "t Type") and followed by an identifier + '('
            const after_recv = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
            const name = scanIdentifier(after_recv) orelse return null;
            if (name.len == 0) return null;
            const after_name = std.mem.trimStart(u8, after_recv[name.len..], " \t");
            if (after_name.len == 0 or after_name[0] != '(') return null;
            _ = receiver;
            is_method = true;
            return .{
                .name = name,
                .name_offset = nameOffset(line, name),
                .pub_keyword = isExportedGo(name),
                .is_method = is_method,
                .open_brace = true,
            };
        }
        const name = scanIdentifier(rest) orelse return null;
        if (name.len == 0) return null;
        const after = std.mem.trimStart(u8, rest[name.len..], " \t");
        if (after.len == 0 or after[0] != '(') return null;
        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = isExportedGo(name),
            .is_method = false,
            .open_brace = true,
        };
    }

    // C/C++: [static] type name( — heuristic: word( at end, not keywords, ends with {
    fn detectCFn(line: []const u8) ?Decl {
        // Skip preprocessor and common non-function lines
        if (std.mem.startsWith(u8, line, "#")) return null;
        if (std.mem.startsWith(u8, line, "typedef ")) return null;
        if (std.mem.startsWith(u8, line, "using ")) return null;
        if (std.mem.startsWith(u8, line, "class ")) return null;
        if (std.mem.startsWith(u8, line, "struct ")) return null;
        if (std.mem.startsWith(u8, line, "enum ")) return null;
        if (std.mem.startsWith(u8, line, "return ")) return null;
        if (std.mem.startsWith(u8, line, "if")) return null;
        if (std.mem.startsWith(u8, line, "for")) return null;
        if (std.mem.startsWith(u8, line, "while")) return null;
        if (std.mem.startsWith(u8, line, "switch")) return null;

        // Find "name(" where name is an identifier at a word boundary,
        // and the line ends with `{` or the paren group closes then `{`
        const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
        if (open_paren == 0) return null;
        var name_end = open_paren;
        while (name_end > 0 and (line[name_end - 1] == ' ' or line[name_end - 1] == '\t')) name_end -= 1;
        if (name_end == 0) return null;
        var name_start = name_end;
        while (name_start > 0 and isIdentChar(line[name_start - 1])) name_start -= 1;
        const name = line[name_start..name_end];
        if (name.len == 0) return null;
        if (isCKeyword(name)) return null;

        // Require the line to close parens and open a brace (same line)
        const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
        if (close_paren < open_paren) return null;
        const tail = std.mem.trim(u8, line[close_paren + 1 ..], " \t");
        if (tail.len == 0 or tail[0] != '{') return null;

        return .{
            .name = name,
            .name_offset = nameOffset(line, name),
            .pub_keyword = !std.mem.startsWith(u8, line, "static "),
            .is_method = false,
            .open_brace = true,
        };
    }

    fn isExportedGo(name: []const u8) bool {
        // Go: exported = starts with uppercase
        return name.len > 0 and std.ascii.isUpper(name[0]);
    }

    fn isCKeyword(name: []const u8) bool {
        const kws = [_][]const u8{ "if", "for", "while", "switch", "return", "sizeof", "defined" };
        for (kws) |k| {
            if (std.mem.eql(u8, name, k)) return true;
        }
        return false;
    }

    const ComplexityState = core.source_lexer.State;

    fn computeComplexity(
        allocator: Allocator,
        contents: []const u8,
        start_line: u32,
        end_line: u32,
        lang: []const u8,
    ) !Complexity {
        var result = Complexity{};
        var state = ComplexityState{};
        var nesting: u32 = 0;
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            if (line_no < start_line) continue;
            if (line_no > end_line) break;

            var code = std.ArrayList(u8).empty;
            defer code.deinit(allocator);
            try sanitizeLine(allocator, &code, raw, lang, &state);

            const branches = countBranches(code.items);
            if (branches > 0) {
                result.cyclomatic += branches;
                result.cognitive += branches * (nesting + 1);
            }
            const boolean_operators = countBooleanOperators(code.items);
            result.cyclomatic += boolean_operators;
            result.cognitive += boolean_operators;

            if (langKind(lang) == .python) {
                nesting = indentation(raw) / 4;
            } else {
                const updated = updateBraceDepth(nesting, code.items);
                nesting = if (line_no == start_line and updated > 0) updated - 1 else updated;
            }
        }
        result.params = countParameters(contents, start_line);
        return result;
    }

    fn sanitizeLine(
        allocator: Allocator,
        output: *std.ArrayList(u8),
        raw: []const u8,
        lang: []const u8,
        state: *ComplexityState,
    ) !void {
        return core.source_lexer.sanitizeLine(allocator, output, raw, lexerLanguage(lang), .discard_literals, state);
    }

    fn lexerLanguage(lang: []const u8) core.source_lexer.Language {
        return switch (langKind(lang)) {
            .zig => .zig,
            .rust => .rust,
            .python => .python,
            .js => .javascript,
            .go => .go,
            .c => .c,
            .other => .other,
        };
    }

    fn countBranches(code: []const u8) u32 {
        var count: u32 = 0;
        var tokens = std.mem.tokenizeAny(u8, code, " \t\r\n(),{}[];");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "if") or
                std.mem.eql(u8, token, "for") or
                std.mem.eql(u8, token, "while") or
                std.mem.eql(u8, token, "case") or
                std.mem.eql(u8, token, "catch") or
                std.mem.eql(u8, token, "except") or
                std.mem.eql(u8, token, "elif") or
                std.mem.eql(u8, token, "elsif"))
            {
                count += 1;
            }
        }
        return count;
    }

    fn countBooleanOperators(code: []const u8) u32 {
        var count: u32 = 0;
        var index: usize = 0;
        while (index + 1 < code.len) : (index += 1) {
            if ((code[index] == '&' and code[index + 1] == '&') or
                (code[index] == '|' and code[index + 1] == '|'))
            {
                count += 1;
                index += 1;
            }
        }
        var tokens = std.mem.tokenizeAny(u8, code, " \t\r\n(),{}[];");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "and") or std.mem.eql(u8, token, "or")) count += 1;
        }
        return count;
    }

    fn updateBraceDepth(current: u32, code: []const u8) u32 {
        var depth: i32 = @intCast(current);
        for (code) |character| {
            if (character == '{') {
                depth += 1;
            } else if (character == '}') {
                depth -= 1;
            }
        }
        return if (depth < 0) 0 else @intCast(depth);
    }

    fn countParameters(contents: []const u8, start_line: u32) u32 {
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (line_no != start_line) continue;
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return 0;
            var depth: u32 = 0;
            var close: ?usize = null;
            var index = open;
            while (index < line.len) : (index += 1) {
                if (line[index] == '(') depth += 1;
                if (line[index] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        close = index;
                        break;
                    }
                }
            }
            const end = close orelse return 0;
            if (end <= open + 1) return 0;
            var count: u32 = 0;
            var part_start = open + 1;
            index = open + 1;
            depth = 0;
            while (index <= end) : (index += 1) {
                if (index == end or (line[index] == ',' and depth == 0)) {
                    const part = std.mem.trim(u8, line[part_start..index], " \t");
                    if (part.len > 0 and !isSelfParameter(part)) count += 1;
                    part_start = index + 1;
                } else if (line[index] == '(' or line[index] == '[' or line[index] == '{') {
                    depth += 1;
                } else if (line[index] == ')' or line[index] == ']' or line[index] == '}') {
                    if (depth > 0) depth -= 1;
                }
            }
            return count;
        }
        return 0;
    }

    fn isSelfParameter(part: []const u8) bool {
        var value = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, value, "&")) value = std.mem.trimStart(u8, value[1..], " \t");
        if (std.mem.startsWith(u8, value, "mut ")) value = std.mem.trimStart(u8, value[4..], " \t");
        return std.mem.eql(u8, value, "self") or
            std.mem.startsWith(u8, value, "self:") or
            std.mem.eql(u8, value, "this") or
            std.mem.startsWith(u8, value, "this:");
    }

    fn indentation(line: []const u8) u32 {
        var result: u32 = 0;
        for (line) |character| {
            if (character == ' ') {
                result += 1;
            } else if (character == '\t') {
                result += 4;
            } else {
                break;
            }
        }
        return result;
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn scanIdentifier(rest: []const u8) ?[]const u8 {
        // Skip whitespace, then read identifier chars
        var i: usize = 0;
        while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) i += 1;
        const start = i;
        while (i < rest.len and isIdentChar(rest[i])) i += 1;
        if (i == start) return null;
        return rest[start..i];
    }

    /// Find the last line of a function body by brace matching from the decl line.
    /// For indentation languages (python) uses the next same-or-lower indent boundary.
    fn findBodyEnd(
        allocator: Allocator,
        contents: []const u8,
        start_line: u32,
        uses_braces: bool,
        start_indent: u32,
        lang: []const u8,
    ) !u32 {
        var total_lines: u32 = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |_| total_lines += 1;

        if (!uses_braces) {
            var line_no: u32 = 0;
            var last_content_line = start_line;
            var iter = std.mem.splitScalar(u8, contents, '\n');
            while (iter.next()) |raw| {
                line_no += 1;
                if (line_no <= start_line) continue;
                const trimmed = std.mem.trim(u8, raw, " \t\r");
                if (trimmed.len == 0) continue;
                if (indentation(raw) <= start_indent) return last_content_line;
                last_content_line = line_no;
            }
            return last_content_line;
        }

        // Brace matching on comment- and literal-free code. The lexer state
        // persists across lines so multi-line strings and raw literals do not
        // desynchronise the depth counter.
        var state = ComplexityState{};
        var code = std.ArrayList(u8).empty;
        defer code.deinit(allocator);
        var depth: i32 = 0;
        var seen_open = false;
        var line_no: u32 = 0;
        var iter = std.mem.splitScalar(u8, contents, '\n');
        while (iter.next()) |raw| {
            line_no += 1;
            if (line_no < start_line) continue;
            code.clearRetainingCapacity();
            try sanitizeLine(allocator, &code, raw, lang, &state);
            for (code.items) |c| {
                if (c == '{') {
                    depth += 1;
                    seen_open = true;
                } else if (c == '}') {
                    depth -= 1;
                    if (seen_open and depth <= 0) return line_no;
                }
            }
        }
        return total_lines;
    }
};

const LangKind = enum { zig, rust, python, js, go, c, other };

fn langKind(lang: []const u8) LangKind {
    if (std.mem.eql(u8, lang, "zig")) return .zig;
    if (std.mem.eql(u8, lang, "rust")) return .rust;
    if (std.mem.eql(u8, lang, "python")) return .python;
    if (std.mem.eql(u8, lang, "javascript")) return .js;
    if (std.mem.eql(u8, lang, "typescript")) return .js;
    if (std.mem.eql(u8, lang, "go")) return .go;
    if (std.mem.eql(u8, lang, "c")) return .c;
    if (std.mem.eql(u8, lang, "cpp")) return .c;
    return .other;
}

// ── Tests ─────────────────────────────────────────────────────

test "zig function extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\pub fn computeHealth(a: u32) !u32 {
        \\    return a + 1;
        \\}
        \\fn helper() void {}
        \\pub export fn entry() void {}
        \\const x = 1;
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 3), funcs.len);
    try std.testing.expectEqualStrings("computeHealth", funcs[0].name);
    try std.testing.expect(funcs[0].is_public);
    try std.testing.expectEqualStrings("helper", funcs[1].name);
    try std.testing.expect(!funcs[1].is_public);
    try std.testing.expectEqualStrings("entry", funcs[2].name);
    try std.testing.expect(funcs[2].is_public);
}

test "zig function body extent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\pub fn outer() void {
        \\    const inner = struct {
        \\        field: u32,
        \\    };
        \\    _ = inner;
        \\}
        \\fn after() void {}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 2), funcs.len);
    // outer spans lines 1-6 despite nested braces
    try std.testing.expectEqual(@as(u32, 1), funcs[0].start_line);
    try std.testing.expectEqual(@as(u32, 6), funcs[0].end_line);
    try std.testing.expectEqual(@as(u32, 6), funcs[0].line_count);
    try std.testing.expectEqual(@as(u32, 7), funcs[1].start_line);
}

test "function complexity counts branches nesting and parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\fn classify(value: u32) u32 {
        \\    if (value > 0) {
        \\        if (value > 10) return 2;
        \\    } else {
        \\        return 1;
        \\    }
        \\    for (0..value) |_| {}
        \\    return 0;
        \\}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(u32, 4), funcs[0].cyclomatic_complexity.?);
    try std.testing.expectEqual(@as(u32, 4), funcs[0].cognitive_complexity.?);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].param_count.?);
}

test "function complexity ignores branches in comments and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\fn describe() void {
        \\    const text = "if (ready) for (;;)";
        \\    // while (pending)
        \\    /* case 1 */
        \\}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(u32, 1), funcs[0].cyclomatic_complexity.?);
    try std.testing.expectEqual(@as(u32, 0), funcs[0].cognitive_complexity.?);
}

test "function parameters exclude borrowed self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\fn classify(&self, value: u32) u32 {
        \\    return value;
        \\}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(u32, 1), funcs[0].param_count.?);
}

test "rust function extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\pub fn public_fn(x: i32) -> i32 { x }
        \\fn private_fn() {}
        \\pub(crate) fn crate_fn() {}
        \\pub async fn async_fn() {}
        \\struct Foo;
        \\impl Foo {
        \\    pub fn method(&self) {}
        \\}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "rust");
    // 5 functions: public_fn, private_fn, crate_fn, async_fn, method (inside impl)
    try std.testing.expectEqual(@as(usize, 5), funcs.len);
    try std.testing.expectEqualStrings("public_fn", funcs[0].name);
    try std.testing.expect(funcs[0].is_public);
    try std.testing.expectEqualStrings("private_fn", funcs[1].name);
    try std.testing.expect(!funcs[1].is_public);
    try std.testing.expectEqualStrings("crate_fn", funcs[2].name);
    try std.testing.expect(funcs[2].is_public);
    try std.testing.expectEqualStrings("async_fn", funcs[3].name);
    try std.testing.expectEqualStrings("method", funcs[4].name);
    try std.testing.expect(funcs[4].is_method);
}

test "python def extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\def top_level(a, b):
        \\    return a + b
        \\
        \\async def async_fn():
        \\    pass
        \\
        \\class Thing:
        \\    def method(self):
        \\        pass
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 3), funcs.len);
    try std.testing.expectEqualStrings("top_level", funcs[0].name);
    try std.testing.expect(!funcs[0].is_method);
    try std.testing.expect(funcs[0].end_line < funcs[1].start_line);
    try std.testing.expectEqualStrings("async_fn", funcs[1].name);
    try std.testing.expectEqualStrings("method", funcs[2].name);
    try std.testing.expect(funcs[2].is_method);
}

test "python function extents stop at next definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        "def first():\n" ++
        "    value = 1\n" ++
        "\n" ++
        "def second():\n" ++
        "    return value\n";
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "python");
    try std.testing.expectEqual(@as(usize, 2), funcs.len);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].start_line);
    try std.testing.expectEqual(@as(u32, 2), funcs[0].end_line);
    try std.testing.expectEqual(@as(u32, 2), funcs[0].line_count);
    try std.testing.expectEqual(@as(u32, 4), funcs[1].start_line);
    try std.testing.expectEqual(@as(u32, 5), funcs[1].end_line);
}

test "js function extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\function plain() {}
        \\export function exported() {}
        \\export default function defaultExport() {}
        \\async function asyncFn() {}
        \\const arrow = () => {};
        \\function* generator() {}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "javascript");
    // Arrow functions not detected (v1 limitation)
    try std.testing.expectEqual(@as(usize, 5), funcs.len);
    try std.testing.expectEqualStrings("plain", funcs[0].name);
    try std.testing.expectEqualStrings("exported", funcs[1].name);
    try std.testing.expect(funcs[1].is_public);
    try std.testing.expectEqualStrings("defaultExport", funcs[2].name);
    try std.testing.expectEqualStrings("asyncFn", funcs[3].name);
    try std.testing.expectEqualStrings("generator", funcs[4].name);
}

test "language matrix handles typescript rust generics and c++" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const typescript =
        \\export function typed(value: string): string { return value; }
        \\function internal<T>(value: T): T { return value; }
        \\interface Result { value: string }
    ;
    const ts_funcs = try FunctionExtractor.extract(arena.allocator(), typescript, "typescript");
    try std.testing.expectEqual(@as(usize, 2), ts_funcs.len);
    try std.testing.expectEqualStrings("typed", ts_funcs[0].name);
    try std.testing.expect(ts_funcs[0].is_public);
    try std.testing.expectEqualStrings("internal", ts_funcs[1].name);

    const rust =
        \\pub fn parse<T>(value: T) -> Option<T> {
        \\    Some(value)
        \\}
    ;
    const rust_funcs = try FunctionExtractor.extract(arena.allocator(), rust, "rust");
    try std.testing.expectEqual(@as(usize, 1), rust_funcs.len);
    try std.testing.expectEqualStrings("parse", rust_funcs[0].name);
    try std.testing.expect(rust_funcs[0].is_public);

    const cpp =
        \\#include "header.hpp"
        \\class Thing {
        \\public:
        \\    void method() {}
        \\};
        \\static int add(int a, int b) { return a + b; }
    ;
    const cpp_funcs = try FunctionExtractor.extract(arena.allocator(), cpp, "cpp");
    try std.testing.expectEqual(@as(usize, 2), cpp_funcs.len);
    try std.testing.expectEqualStrings("method", cpp_funcs[0].name);
    try std.testing.expectEqualStrings("add", cpp_funcs[1].name);
    try std.testing.expect(!cpp_funcs[1].is_public);
}

test "go function and method extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\func Exported() {}
        \\func private() {}
        \\func (r *Receiver) Method() {}
        \\type Foo struct{}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "go");
    try std.testing.expectEqual(@as(usize, 3), funcs.len);
    try std.testing.expectEqualStrings("Exported", funcs[0].name);
    try std.testing.expect(funcs[0].is_public);
    try std.testing.expectEqualStrings("private", funcs[1].name);
    try std.testing.expect(!funcs[1].is_public);
    try std.testing.expectEqualStrings("Method", funcs[2].name);
    try std.testing.expect(funcs[2].is_method);
}

test "c function extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\int add(int a, int b) {
        \\    return a + b;
        \\}
        \\static void helper(void) {
        \\}
        \\#define MACRO(x) ((x) + 1)
        \\int main(int argc, char **argv) {
        \\    return 0;
        \\}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "c");
    try std.testing.expectEqual(@as(usize, 3), funcs.len);
    try std.testing.expectEqualStrings("add", funcs[0].name);
    try std.testing.expect(funcs[0].is_public); // no static
    try std.testing.expectEqualStrings("helper", funcs[1].name);
    try std.testing.expect(!funcs[1].is_public); // static
    try std.testing.expectEqualStrings("main", funcs[2].name);
}

test "block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\/*
        \\fn hidden_in_comment() {}
        \\*/
        \\fn visible() void {}
    ;
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("visible", funcs[0].name);
}

test "language matrix ignores declarations inside literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const python =
        \\text = '''
        \\def hidden():
        \\    pass
        \\'''
        \\def visible():
        \\    pass
    ;
    const python_funcs = try FunctionExtractor.extract(arena.allocator(), python, "python");
    try std.testing.expectEqual(@as(usize, 1), python_funcs.len);
    try std.testing.expectEqualStrings("visible", python_funcs[0].name);

    const javascript =
        \\const text = `function hidden() {}`;
        \\function visible() {}
    ;
    const javascript_funcs = try FunctionExtractor.extract(arena.allocator(), javascript, "javascript");
    try std.testing.expectEqual(@as(usize, 1), javascript_funcs.len);
    try std.testing.expectEqualStrings("visible", javascript_funcs[0].name);

    const zig = "const text = \"fn hidden() {}\";\nfn visible() {}\n";
    const zig_funcs = try FunctionExtractor.extract(arena.allocator(), zig, "zig");
    try std.testing.expectEqual(@as(usize, 1), zig_funcs.len);
    try std.testing.expectEqualStrings("visible", zig_funcs[0].name);
}

test "unknown language yields nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const funcs = try FunctionExtractor.extract(arena.allocator(), "def whatever", "ruby");
    try std.testing.expectEqual(@as(usize, 0), funcs.len);
}

test "body end ignores braces inside multi-line strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "fn first() void {\n" ++
        "    const text = \\multiline\n" ++
        "        still text\\;\n" ++
        "}\n" ++
        "fn second() void {}\n";
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 2), funcs.len);
    try std.testing.expectEqualStrings("first", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 4), funcs[0].line_count);
    try std.testing.expectEqualStrings("second", funcs[1].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[1].line_count);
}

test "body end ignores braces inside closed multi-line string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Analyzed source uses a real Zig multiline string spanning lines 3-4 with a
    // brace inside it; the closing brace of the function is on line 6.
    const src = "fn first() void {\n" ++
        "    const text =\n" ++
        "        \\\\multi { line\n" ++
        "        \\\\another \\\\\n" ++
        "    ;\n" ++
        "}\n" ++
        "fn second() void {}\n";
    const funcs = try FunctionExtractor.extract(arena.allocator(), src, "zig");
    try std.testing.expectEqual(@as(usize, 2), funcs.len);
    try std.testing.expectEqualStrings("first", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 6), funcs[0].line_count);
    try std.testing.expectEqualStrings("second", funcs[1].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[1].line_count);
}
