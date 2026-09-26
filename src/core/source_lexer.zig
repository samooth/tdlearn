const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList(u8);

pub const Language = enum {
    zig,
    rust,
    python,
    javascript,
    go,
    c,
    other,
};

pub const Mode = enum {
    discard_literals,
    preserve_literals,
};

pub const State = struct {
    block_comment: bool = false,
    triple_quote: u8 = 0,
    template: bool = false,
};

/// Mask (or preserve) one source line.
///
/// The loop handles plain code bytes; everything that is not code — comments,
/// string and template literals, and the line-continuation forms that need
/// language knowledge — is handled by `consumeNonCode`, which consumes at least
/// one byte when it returns true. Splitting it that way keeps this function a
/// plain driver and lets the per-language rules be read in one place.
pub fn sanitizeLine(
    allocator: Allocator,
    output: *ArrayList,
    raw: []const u8,
    language: Language,
    mode: Mode,
    state: *State,
) !void {
    var index: usize = 0;
    while (index < raw.len) {
        if (try consumeLiteralState(allocator, output, raw, &index, mode, state)) continue;
        if (try consumeNonCode(allocator, output, raw, &index, language, mode, state)) continue;
        try appendCode(allocator, output, raw[index], mode);
        index += 1;
    }
}

/// Handle a non-code construct that starts at `index`. Returns true when it
/// consumed the construct, false when this byte is ordinary code and the
/// caller should emit it.
fn consumeNonCode(
    allocator: Allocator,
    output: *ArrayList,
    raw: []const u8,
    index: *usize,
    language: Language,
    mode: Mode,
    state: *State,
) !bool {
    if (index.* == 0 and language == .zig and isZigMultilineStringLine(raw)) {
        // A Zig multiline string line begins with `\` after indentation and is
        // literal content until the newline; the whole line is masked so braces
        // and quotes inside it never affect the caller.
        try appendLiteral(allocator, output, raw, mode);
        index.* = raw.len;
        return true;
    }

    const c = raw[index.*];
    if (c == '#' and language == .python) {
        try appendComment(allocator, output, raw.len - index.*, mode);
        index.* = raw.len;
        return true;
    }
    if (c == '/' and index.* + 1 < raw.len) {
        const next = raw[index.* + 1];
        if (next == '/') {
            try appendComment(allocator, output, raw.len - index.*, mode);
            index.* = raw.len;
            return true;
        }
        if (next == '*') {
            try appendComment(allocator, output, 2, mode);
            state.block_comment = true;
            index.* += 2;
            return true;
        }
    }
    if (language == .python and (c == '"' or c == '\'') and hasTripleQuote(raw, index.*, c)) {
        try appendLiteral(allocator, output, raw[index.* .. index.* + 3], mode);
        state.triple_quote = c;
        index.* += 3;
        return true;
    }
    if (language == .javascript and c == '`') {
        try appendLiteral(allocator, output, raw[index.* .. index.* + 1], mode);
        state.template = true;
        index.* += 1;
        return true;
    }
    if (c == '"' or c == '\'') {
        try consumeQuoted(allocator, output, raw, index, c, mode);
        return true;
    }
    return false;
}

/// Consume a single-line quoted literal, honouring backslash escapes, up to and
/// including the closing quote. An unterminated literal runs to the end of the
/// line, which is the only information a line-based scanner has.
fn consumeQuoted(
    allocator: Allocator,
    output: *ArrayList,
    raw: []const u8,
    index: *usize,
    quote: u8,
    mode: Mode,
) !void {
    try appendLiteral(allocator, output, raw[index.* .. index.* + 1], mode);
    index.* += 1;
    while (index.* < raw.len) {
        if (raw[index.*] == '\\' and index.* + 1 < raw.len) {
            try appendLiteral(allocator, output, raw[index.* .. index.* + 2], mode);
            index.* += 2;
            continue;
        }
        const closes = raw[index.*] == quote;
        try appendLiteral(allocator, output, raw[index.* .. index.* + 1], mode);
        index.* += 1;
        if (closes) return;
    }
}

fn consumeLiteralState(
    allocator: Allocator,
    output: *ArrayList,
    raw: []const u8,
    index: *usize,
    mode: Mode,
    state: *State,
) !bool {
    if (state.block_comment) {
        if (std.mem.startsWith(u8, raw[index.*..], "*/")) {
            try appendCommentMarker(allocator, output, mode, 2);
            state.block_comment = false;
            index.* += 2;
        } else {
            try appendCommentMarker(allocator, output, mode, 1);
            index.* += 1;
        }
        return true;
    }
    if (state.triple_quote != 0) {
        if (hasTripleQuote(raw, index.*, state.triple_quote)) {
            try appendLiteral(allocator, output, raw[index.* .. index.* + 3], mode);
            state.triple_quote = 0;
            index.* += 3;
        } else {
            try appendLiteral(allocator, output, raw[index.* .. index.* + 1], mode);
            index.* += 1;
        }
        return true;
    }
    if (state.template) {
        try appendLiteral(allocator, output, raw[index.* .. index.* + 1], mode);
        if (raw[index.*] == '`') state.template = false;
        index.* += 1;
        return true;
    }
    return false;
}

fn isZigMultilineStringLine(raw: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, raw, " \t");
    return trimmed.len >= 2 and trimmed[0] == '\\' and trimmed[1] == '\\';
}

fn hasTripleQuote(raw: []const u8, index: usize, quote: u8) bool {
    return index + 2 < raw.len and raw[index] == quote and raw[index + 1] == quote and raw[index + 2] == quote;
}

fn appendCode(allocator: Allocator, output: *ArrayList, character: u8, mode: Mode) !void {
    if (mode == .preserve_literals and std.ascii.isWhitespace(character)) {
        try appendSeparator(allocator, output);
    } else {
        try output.append(allocator, character);
    }
}

fn appendLiteral(allocator: Allocator, output: *ArrayList, text: []const u8, mode: Mode) !void {
    if (mode == .preserve_literals) {
        try output.appendSlice(allocator, text);
    } else {
        try output.appendNTimes(allocator, ' ', text.len);
    }
}

fn appendCommentMarker(allocator: Allocator, output: *ArrayList, mode: Mode, count: usize) !void {
    if (mode == .discard_literals) {
        try output.appendNTimes(allocator, ' ', count);
    }
}

fn appendComment(allocator: Allocator, output: *ArrayList, count: usize, mode: Mode) !void {
    if (mode == .preserve_literals) {
        try appendSeparator(allocator, output);
    } else {
        try output.appendNTimes(allocator, ' ', count);
    }
}

fn appendSeparator(allocator: Allocator, output: *ArrayList) !void {
    if (output.items.len != 0 and output.items[output.items.len - 1] != ' ') {
        try output.append(allocator, ' ');
    }
}

test "lexer discards and preserves literals" {
    const allocator = std.testing.allocator;
    var discarded = std.ArrayList(u8).empty;
    defer discarded.deinit(allocator);
    var state = State{};
    try sanitizeLine(allocator, &discarded, "fn f(x: []const u8) { const s = \"secret\"; }", .zig, .discard_literals, &state);
    try std.testing.expectEqualStrings("fn f(x: []const u8) { const s =         ; }", discarded.items);

    var preserved = std.ArrayList(u8).empty;
    defer preserved.deinit(allocator);
    state = .{};
    try sanitizeLine(allocator, &preserved, "fn f() { const s = \"secret value\"; }", .zig, .preserve_literals, &state);
    try std.testing.expectEqualStrings("fn f() { const s = \"secret value\"; }", preserved.items);
}

test "lexer carries multiline literal state" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var state = State{};
    try sanitizeLine(allocator, &output, "text = \"\"\"start", .python, .discard_literals, &state);
    try sanitizeLine(allocator, &output, "end\"\"\"", .python, .discard_literals, &state);
    try std.testing.expectEqualStrings("text =               ", output.items);
}

test "lexer masks zig multiline string lines entirely" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var state = State{};
    try sanitizeLine(allocator, &output, "    \\\\has { brace and \\\"quote", .zig, .discard_literals, &state);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.items, '{') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.items, '"') == null);
}

test "discard mode preserves length for every language" {
    const allocator = std.testing.allocator;
    // Callers rely on this: the import scanner and the call scanner slice
    // identifiers out of the *original* line using offsets found in the mask,
    // so a mask of a different length would silently misalign every offset.
    const lines = [_][]const u8{
        "const s = \"text\"; // trailing",
        "    fn f() void { _ = 1; }",
        "    /* block */ _ = 2;",
        "    const raw = \\multi\n",
        "text = '''triple",
        "const t = `template ${x}`;",
    };
    const languages = [_]Language{ .zig, .rust, .python, .javascript, .go, .c, .other };
    for (lines) |line| {
        for (languages) |language| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);
            var state = State{};
            try sanitizeLine(allocator, &out, line, language, .discard_literals, &state);
            try std.testing.expectEqual(line.len, out.items.len);
        }
    }
}
