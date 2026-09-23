const std = @import("std");

pub const call_graph = @import("call_graph.zig");
pub const classes = @import("classes.zig");
pub const functions = @import("functions.zig");
pub const graph_builder = @import("graph_builder.zig");
pub const imports = @import("imports.zig");
pub const inherit_graph = @import("inherit_graph.zig");
pub const manifests = @import("manifests.zig");
pub const lang_registry = @import("lang_registry.zig");
pub const resolver = @import("resolver.zig");
pub const walker = @import("walker.zig");

// Force test discovery in imported files (imports are lazy otherwise).
test {
    std.testing.refAllDecls(@This());
}
