const std = @import("std");

/// Tunable limits for a single tdlearn analysis run.
///
/// Every field here is read by the scan pipeline (`analysis.walker.Walker` and
/// the CLI in `main.zig`). The walker takes a copy at construction, so a run
/// observes a consistent set of limits for its whole duration.
pub const Settings = struct {
    // ── Scanner limits ──
    /// Maximum file size to include in the scan (kilobytes)
    max_file_size_kb: u64 = 512,
    /// Maximum file size to attempt line-based parsing (kilobytes)
    max_parse_size_kb: u32 = 100,
    /// Directory names to exclude while walking (exact match, per component)
    exclude_dirs: []const []const u8 = &.{ ".git", "node_modules", "target", "__pycache__", ".zig-cache" },
    /// Maximum call targets kept per function (limits ambiguous resolution)
    max_call_targets: u32 = 20,

    /// Check that every limit is usable (non-zero). `sanitize` guarantees this.
    pub fn validate(self: *const Settings) !void {
        if (self.max_file_size_kb == 0 or
            self.max_parse_size_kb == 0 or
            self.max_call_targets == 0) return error.InvalidSettings;
    }

    /// Clamp unusable limits into the smallest workable configuration, so that
    /// `validate` succeeds afterwards. Safe to call more than once.
    pub fn sanitize(self: *Settings) void {
        if (self.max_file_size_kb == 0) self.max_file_size_kb = 1;
        if (self.max_parse_size_kb == 0) self.max_parse_size_kb = 1;
        if (self.max_call_targets == 0) self.max_call_targets = 1;
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "Settings default values" {
    const s = Settings{};
    try std.testing.expectEqual(@as(u64, 512), s.max_file_size_kb);
    try std.testing.expectEqual(@as(u32, 100), s.max_parse_size_kb);
    try std.testing.expectEqual(@as(u32, 20), s.max_call_targets);
    try std.testing.expectEqual(@as(usize, 5), s.exclude_dirs.len);
    try std.testing.expectEqualStrings(".zig-cache", s.exclude_dirs[4]);
}

test "Settings defaults validate" {
    const s = Settings{};
    try s.validate();
}

test "Settings sanitize prevents zero values" {
    var s = Settings{
        .max_file_size_kb = 0,
        .max_parse_size_kb = 0,
        .max_call_targets = 0,
    };
    s.sanitize();
    try std.testing.expect(s.max_file_size_kb >= 1);
    try std.testing.expect(s.max_parse_size_kb >= 1);
    try std.testing.expect(s.max_call_targets >= 1);
    try s.validate();
}

test "Settings sanitize is idempotent" {
    var s = Settings{
        .max_file_size_kb = 0,
        .max_parse_size_kb = 0,
        .max_call_targets = 0,
    };
    s.sanitize();
    const after_first = s;
    s.sanitize();
    try std.testing.expectEqual(after_first.max_file_size_kb, s.max_file_size_kb);
    try std.testing.expectEqual(after_first.max_parse_size_kb, s.max_parse_size_kb);
    try std.testing.expectEqual(after_first.max_call_targets, s.max_call_targets);
}

test "Settings validate rejects zero limits" {
    var s = Settings{};
    s.max_file_size_kb = 0;
    try std.testing.expectError(error.InvalidSettings, s.validate());
    s = Settings{};
    s.max_parse_size_kb = 0;
    try std.testing.expectError(error.InvalidSettings, s.validate());
    s = Settings{};
    s.max_call_targets = 0;
    try std.testing.expectError(error.InvalidSettings, s.validate());
}
