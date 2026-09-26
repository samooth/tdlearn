//! Tests for the architectural rules engine.
//!
//! They live here rather than in `rules.zig` for two reasons: the module keeps
//! only its implementation (which is what `max_file_lines` is meant to bound),
//! and exercising the module from outside proves the public surface is enough
//! to configure and check a project — no test reaches into a private helper.
//! `core/mod.zig` imports this file from its test block, so these tests only
//! exist in test builds.

const std = @import("std");
const rules = @import("rules.zig");

// ── Tests ─────────────────────────────────────────────────────

test "glob match basics" {
    try std.testing.expect(rules.globMatch("src/core/types.zig", "src/core/types.zig"));
    try std.testing.expect(!rules.globMatch("src/core", "src/metrics/mod.zig"));
    try std.testing.expect(rules.globMatch("src/core", "src/core/types.zig"));
    try std.testing.expect(rules.globMatch("src/core/**", "src/core/deep/nested/file.zig"));
    try std.testing.expect(rules.globMatch("src/core/**", "src/core/types.zig"));
    try std.testing.expect(rules.globMatch("src/**/*", "src/anything/deep.zig"));
    try std.testing.expect(rules.globMatch("src/*", "src/top.zig"));
    try std.testing.expect(!rules.globMatch("src/*", "src/sub/deep.zig"));
    try std.testing.expect(rules.globMatch("*.zig", "any/file.zig"));
    try std.testing.expect(!rules.globMatch("*.zig", "file.rs"));
    try std.testing.expect(rules.globMatch("src/foo*.zig", "src/foobar.zig"));
    try std.testing.expect(!rules.globMatch("src/foo*.zig", "src/bar.zig"));
}

test "glob escapes and unicode wildcards" {
    try std.testing.expect(rules.globMatch("src/\\*.zig", "src/*.zig"));
    try std.testing.expect(!rules.globMatch("src/\\*.zig", "src/file.zig"));
    try std.testing.expect(rules.globMatch("src/?.zig", "src/é.zig"));
    try std.testing.expect(!rules.globMatch("src/?.zig", "src/éé.zig"));
    try std.testing.expect(rules.globMatch("src/Ж*.zig", "src/Журнал.zig"));
    try std.testing.expect(rules.globMatch("src\\core\\*.zig", "src/core/file.zig"));
}

test "glob segment boundaries" {
    try std.testing.expect(rules.globMatch("src/**/test.zig", "src/a/b/test.zig"));
    try std.testing.expect(!rules.globMatch("src/*/test.zig", "src/a/b/test.zig"));
    try std.testing.expect(rules.globMatch("**/*.zig", "a/b.zig"));
    try std.testing.expect(!rules.globMatch("src/*.zig", "src/a/b.zig"));
    try std.testing.expect(rules.globMatch("src/core", "src/core/types.zig"));
}

test "parse rules constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.7
        \\max_cycles = 0
        \\max_file_lines = 500
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), config.constraints.min_quality.?, 0.001);
    try std.testing.expectEqual(@as(u32, 0), config.constraints.max_cycles.?);
    try std.testing.expectEqual(@as(u32, 500), config.constraints.max_file_lines.?);
    try std.testing.expect(config.constraints.min_modularity == null);
}

test "parse layers and boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/core/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/app/**", "src/main.zig"]
        \\order = 1
        \\
        \\[[boundaries]]
        \\from = "src/app/**"
        \\to = "src/renderer/**"
        \\reason = "app must not draw"
    );
    try std.testing.expectEqual(@as(usize, 2), config.layers.len);
    try std.testing.expectEqualStrings("core", config.layers[0].name);
    try std.testing.expectEqual(@as(u32, 0), config.layers[0].order);
    try std.testing.expectEqual(@as(u32, 1), config.layers[1].order);
    try std.testing.expectEqual(@as(usize, 1), config.boundaries.len);
    try std.testing.expectEqualStrings("app must not draw", config.boundaries[0].reason);
}

test "parse rules rejects invalid values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 1.5
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cycles = -1
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\unknown = 1
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality 0.7
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = "0.7
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.7
        \\min_quality = 0.8
    ));
}

test "parse rules rejects incomplete layers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
    ));
}

test "parse rules normalizes Windows separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src\core\types.zig", "src\core\*.zig", "src/\*.zig"]
        \\order = 0
    );
    try std.testing.expectEqualStrings("src/core/types.zig", config.layers[0].paths[0]);
    try std.testing.expectEqualStrings("src/core/*.zig", config.layers[0].paths[1]);
    try std.testing.expectEqualStrings("src/\\*.zig", config.layers[0].paths[2]);
}

test "parse rules rejects invalid layer names and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "bad name"
        \\paths = ["src/**"]
        \\order = 0
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["/absolute/**"]
        \\order = 0
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/../outside/**"]
        \\order = 0
    ));
}

test "parse rules rejects duplicate layer names and patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "core"
        \\paths = ["lib/**"]
        \\order = 1
    ));
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/**"]
        \\order = 1
    ));
}

test "check constraints pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.5
        \\max_cycles = 2
    );
    const input = rules.CheckInput{
        .quality_signal = 0.8,
        .modularity = 0.6,
        .acyclicity = 1.0,
        .depth = 0.9,
        .equality = 0.7,
        .redundancy = 0.95,
        .cycle_count = 1,
        .max_file_lines = 100,
        .max_fn_lines = 50,
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(result.pass());
    try std.testing.expectEqual(@as(u32, 2), result.rules_checked);
}

test "check constraints fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.9
        \\max_cycles = 0
    );
    const input = rules.CheckInput{
        .quality_signal = 0.5,
        .modularity = 0.5,
        .acyclicity = 0.5,
        .depth = 0.5,
        .equality = 0.5,
        .redundancy = 0.5,
        .cycle_count = 3,
        .max_file_lines = 100,
        .max_fn_lines = 50,
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    // Both min_quality and max_cycles violated
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
}

test "layer order violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/core/**"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/app/**"]
        \\order = 1
    );
    // app (order 1) imports core (order 0) — violation: 1 > 0
    // core (order 0) imports app (order 1) — OK: 0 < 1
    const edges = [_]rules.CheckInput.Edge{
        .{ .from = "src/app/main.zig", .to = "src/core/types.zig" },
        .{ .from = "src/core/types.zig", .to = "src/app/main.zig" },
    };
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqualStrings("layer_order", result.violations[0].rule);
}

test "ambiguous layers are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[layers]]
        \\name = "core"
        \\paths = ["src/*"]
        \\order = 0
        \\
        \\[[layers]]
        \\name = "app"
        \\paths = ["src/**"]
        \\order = 1
    );
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &.{},
        .file_paths = &[_][]const u8{"src/file.zig"},
    };
    try std.testing.expectError(error.AmbiguousLayer, rules.checkRules(arena.allocator(), &config, &input));
}

test "violations are deduplicated and deterministically ordered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[boundaries]]
        \\from = "src/**"
        \\to = "lib/**"
        \\
        \\[[boundaries]]
        \\from = "src/*"
        \\to = "lib/*"
    );
    const edges = [_]rules.CheckInput.Edge{
        .{ .from = "src/z.zig", .to = "lib/b.zig" },
        .{ .from = "src/a.zig", .to = "lib/a.zig" },
        .{ .from = "src/z.zig", .to = "lib/b.zig" },
    };
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
    try std.testing.expectEqualStrings("src/a.zig", result.violations[0].files[0]);
    try std.testing.expectEqualStrings("src/z.zig", result.violations[1].files[0]);
}

test "check rules rejects absolute input paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(), "[constraints]\nmin_quality = 0.5");
    const edges = [_]rules.CheckInput.Edge{.{ .from = "/tmp/a.zig", .to = "src/b.zig" }};
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    try std.testing.expectError(error.InvalidPath, rules.checkRules(arena.allocator(), &config, &input));
}

test "boundary violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[[boundaries]]
        \\from = "src/renderer/**"
        \\to = "src/analysis/**"
    );
    const edges = [_]rules.CheckInput.Edge{
        .{ .from = "src/renderer/panel.zig", .to = "src/analysis/walker.zig" },
        .{ .from = "src/renderer/panel.zig", .to = "src/core/types.zig" },
    };
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .import_edges = &edges,
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqualStrings("boundary", result.violations[0].rule);
}

// ── Per-function complexity ceilings ──────────────────────────────

test "parse rules accepts the complexity ceilings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 12
        \\max_cognitive = 30
    );
    try std.testing.expectEqual(@as(u32, 12), config.constraints.max_cyclomatic.?);
    try std.testing.expectEqual(@as(u32, 30), config.constraints.max_cognitive.?);
}

test "complexity ceilings default to absent so they are not checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\min_quality = 0.5
    );
    try std.testing.expect(config.constraints.max_cyclomatic == null);
    try std.testing.expect(config.constraints.max_cognitive == null);

    // An absurdly complex function must not be reported when no ceiling is set.
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .functions = &.{.{ .file = "src/a.zig", .name = "huge", .line = 1, .cyclomatic = 900, .cognitive = 900 }},
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(result.pass());
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "parse rules rejects malformed complexity ceilings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Not an integer.
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 1.5
    ));
    // Negative.
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = -1
    ));
    // Out of u32 range.
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cognitive = 4294967296
    ));
    // Not a number at all.
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cognitive = "20"
    ));
    // Unknown key next to a valid one is still rejected.
    try std.testing.expectError(error.InvalidRules, rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 20
        \\max_complexity = 20
    ));
}

test "complexity ceilings report every offending function with identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 10
    );
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .functions = &.{
            .{ .file = "src/a.zig", .name = "ok", .line = 1, .cyclomatic = 10, .cognitive = 3 },
            .{ .file = "src/a.zig", .name = "tooBig", .line = 9, .cyclomatic = 11, .cognitive = 3 },
            .{ .file = "src/a.zig", .name = "wayTooBig", .line = 20, .cyclomatic = 40, .cognitive = 3 },
        },
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
    // The boundary value is allowed; only strictly greater values are reported.
    try std.testing.expectEqualStrings("max_cyclomatic", result.violations[0].rule);
    try std.testing.expectEqualStrings("tooBig", result.violations[0].subject.?);
    try std.testing.expectEqual(@as(u32, 9), result.violations[0].line.?);
    try std.testing.expectEqual(@as(usize, 1), result.violations[0].files.len);
    try std.testing.expectEqualStrings("src/a.zig", result.violations[0].files[0]);
    // Same file, different function: deduplication must keep both, and they
    // must come out in source order rather than string order.
    try std.testing.expectEqualStrings("wayTooBig", result.violations[1].subject.?);
    try std.testing.expectEqual(@as(u32, 20), result.violations[1].line.?);
}

test "cognitive ceiling reports the function and not the cyclomatic number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cognitive = 15
    );
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .functions = &.{
            // Cyclomatic 5 is under any sane ceiling; cognitive 18 is not.
            .{ .file = "src/b.zig", .name = "deepButSimple", .line = 3, .cyclomatic = 5, .cognitive = 18 },
        },
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqualStrings("max_cognitive", result.violations[0].rule);
    try std.testing.expectEqualStrings("deepButSimple", result.violations[0].subject.?);
}

test "both ceilings are counted once each and can fire together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 10
        \\max_cognitive = 10
    );
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .functions = &.{.{ .file = "src/c.zig", .name = "both", .line = 7, .cyclomatic = 20, .cognitive = 20 }},
        .import_edges = &.{},
        .file_paths = &.{},
    };
    const result = try rules.checkRules(arena.allocator(), &config, &input);
    try std.testing.expect(!result.pass());
    // Two rules checked, two violations: rules are counted, not findings.
    try std.testing.expectEqual(@as(u32, 2), result.rules_checked);
    try std.testing.expectEqual(@as(usize, 2), result.violations.len);
    // Sorted by rule name, so the cognitive finding comes first.
    try std.testing.expectEqualStrings("max_cognitive", result.violations[0].rule);
    try std.testing.expectEqualStrings("max_cyclomatic", result.violations[1].rule);
}

test "complexity violations carry a canonical relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try rules.parseRules(arena.allocator(),
        \\[constraints]
        \\max_cyclomatic = 1
    );
    const input = rules.CheckInput{
        .quality_signal = 1.0,
        .modularity = 1.0,
        .acyclicity = 1.0,
        .depth = 1.0,
        .equality = 1.0,
        .redundancy = 1.0,
        .cycle_count = 0,
        .max_file_lines = 10,
        .max_fn_lines = 10,
        .functions = &.{.{ .file = "./src/d.zig", .name = "weird", .line = 2, .cyclomatic = 2, .cognitive = 0 }},
        .import_edges = &.{},
        .file_paths = &.{},
    };
    // rules.checkRules validates every input path, exactly as it does for edges and
    // scanned files, so a non-canonical path is a hard error and not a silent
    // pass.
    try std.testing.expectError(
        error.InvalidPath,
        rules.checkRules(arena.allocator(), &config, &input),
    );
}
