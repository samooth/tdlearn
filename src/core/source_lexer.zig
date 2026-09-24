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
        if (state.block_comment) {
            if (std.mem.startsWith(u8, raw[index..], "*/")) {
                try appendCommentMarker(allocator, output, mode, 2);
                state.block_comment = false;
                index += 2;
            } else {
                try appendCommentMarker(allocator, output, mode, 1);
                index += 1;
            }
            continue;
        }
        if (state.triple_quote != 0) {
            if (hasTripleQuote(raw, index, state.triple_quote)) {
                try appendLiteral(allocator, output, raw[index .. index + 3], mode);
                state.triple_quote = 0;
                index += 3;
            } else {
                try appendLiteral(allocator, output, raw[index .. index + 1], mode);
                index += 1;
            }
            continue;
        }
        if (state.template) {
            if (raw[index] == '`') {
                try appendLiteral(allocator, output, raw[index .. index + 1], mode);
                state.template = false;
            } else {
                try appendLiteral(allocator, output, raw[index .. index + 1], mode);
            }
            index += 1;
            continue;
        }

        if (language == .python and raw[index] == '#') {
            try appendComment(allocator, output, raw.len - index, mode);
            break;
        }
        if (raw[index] == '/' and index + 1 < raw.len and raw[index + 1] == '/') {
            try appendComment(allocator, output, raw.len - index, mode);
            break;
        }
        if (raw[index] == '/' and index + 1 < raw.len and raw[index + 1] == '*') {
            try appendComment(allocator, output, 2, mode);
            state.block_comment = true;
            index += 2;
            continue;
        }
        if (language == .python and (raw[index] == '"' or raw[index] == '\'') and
            hasTripleQuote(raw, index, raw[index]))
        {
            try appendLiteral(allocator, output, raw[index .. index + 3], mode);
            state.triple_quote = raw[index];
            index += 3;
            continue;
        }
        if (language == .javascript and raw[index] == '`') {
            try appendLiteral(allocator, output, raw[index .. index + 1], mode);
            state.template = true;
            index += 1;
            continue;
        }
        if (raw[index] == '"' or raw[index] == '\'') {
            const quote = raw[index];
            try appendLiteral(allocator, output, raw[index .. index + 1], mode);
            index += 1;
            while (index < raw.len) {
                if (raw[index] == '\\' and index + 1 < raw.len) {
                    try appendLiteral(allocator, output, raw[index .. index + 2], mode);
                    index += 2;
                } else if (raw[index] == quote) {
                    try appendLiteral(allocator, output, raw[index .. index + 1], mode);
                    index += 1;
                    break;
                } else {
                    try appendLiteral(allocator, output, raw[index .. index + 1], mode);
                    index += 1;
                }
            }
            continue;
        }
        try appendCode(allocator, output, raw[index], mode);
        index += 1;
    }
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
