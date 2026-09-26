const std = @import("std");

pub const types = @import("types.zig");
pub const path_utils = @import("path_utils.zig");
pub const settings = @import("settings.zig");
pub const toml = @import("toml.zig");
pub const rules = @import("rules.zig");
pub const baseline = @import("baseline.zig");
pub const source_lexer = @import("source_lexer.zig");

// Force test discovery in imported files (imports are lazy otherwise).
test {
    // Test-only: the rules tests exercise the module from outside, so they need
    // their own file (see rules_test.zig). Invisible to non-test builds.
    _ = @import("rules_test.zig");
    std.testing.refAllDecls(@This());
}
