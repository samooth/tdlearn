//! Out-of-memory propagation for the public analysis entry points.
//!
//! These APIs used to swallow allocation failures and return a plausible but
//! fabricated answer (an empty function list, an unresolved import, a Gini of
//! 0.0). A quality report built on a silent allocation failure is worse than a
//! crash, because the caller cannot tell "this project is clean" from "I could
//! not read the project". Each test pins the contract that `error.OutOfMemory`
//! reaches the caller instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const functions = @import("functions.zig");
const imports = @import("imports.zig");
const resolver = @import("resolver.zig");

const zig_source =
    \\const std = @import("std");
    \\pub fn main() void {
    \\    if (unknown()) {
    \\        std.debug.print("{}", .{1});
    \\    }
    \\}
    \\fn helper() u32 {
    \\    return 1;
    \\}
;

test "function extraction propagates out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        functions.FunctionExtractor.extract(failing.allocator(), zig_source, "zig"),
    );
}

test "import extraction propagates out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        imports.ImportExtractor.extract(failing.allocator(), "import \"std\";\n", "zig"),
    );
}

test "import resolution propagates out of memory instead of reporting unresolved" {
    const file_paths = [_][]const u8{ "src/main.zig", "src/core/types.zig" };
    // Let the index build succeed, then arm the failure for the scratch arena
    // that `resolve` allocates per call.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var r = try resolver.Resolver.init(failing.allocator(), &file_paths);
    defer r.deinit();
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(
        error.OutOfMemory,
        r.resolve("core/types", "src/main.zig"),
    );
}
