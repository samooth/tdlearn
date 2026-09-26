//! Behavioral tests for `dead_code.zig`.
//!
//! The tests live outside the production file so the analyzer ships without
//! them, and they reach it only through its public API (`analyze`,
//! `FileFuncs`, `DeadCodeResult`). A test that needs a private declaration is a
//! design signal about the analyzer's surface, not a reason to widen it, so
//! every fixture here is built from public types.
//!
//! Reached from `mod.zig` through a `test` import, which keeps the dependency
//! one-way: this file depends on `dead_code.zig`, never the reverse.

const std = @import("std");
const core = @import("core");
const dead_code = @import("dead_code.zig");

const Allocator = std.mem.Allocator;
const FileFuncs = dead_code.FileFuncs;
const analyze = dead_code.analyze;

// ── Fixtures ────────────────────────────────────────────────

fn makeFunc(name: []const u8, start: u32, end: u32, is_public: bool) core.types.FuncInfo {
    return .{
        .name = name,
        .start_line = start,
        .end_line = end,
        .line_count = end - start + 1,
        .is_public = is_public,
    };
}

/// Fixture runner for the allocator-failure sweep: there is nothing to free,
/// because the result owns no memory. The expectations pin the fixture so a
/// swallowed allocation failure cannot hide behind a different outcome.
fn analyzeAndDrop(
    allocator: Allocator,
    file_funcs: []const FileFuncs,
    call_edges: []const core.types.CallEdge,
) !void {
    const result = try analyze(allocator, file_funcs, call_edges);
    try std.testing.expectEqual(@as(u32, 4), result.total_functions);
    try std.testing.expectEqual(@as(u32, 4), result.production_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

// ── Tests ─────────────────────────────────────────────────────

test "no functions" {
    const result = try analyze(std.testing.allocator, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.production_functions);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 0.0), result.dead_code_ratio);
    try std.testing.expectEqual(@as(f64, 1.0), result.redundancy_ratio);
}

test "all public functions are alive" {
    const contents = "pub fn a() void {}\npub fn b() void {}";
    const funcs = [_]core.types.FuncInfo{
        makeFunc("a", 1, 1, true),
        makeFunc("b", 2, 2, true),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 2), result.total_functions);
    try std.testing.expectEqual(@as(u32, 2), result.production_functions);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 0.0), result.redundancy_ratio);
}

test "uncalled private function is dead" {
    // "orphan" is defined but never called; "used" is called by entry
    const contents =
        \\pub fn entry() void {
        \\    used();
        \\}
        \\fn used() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("entry", 1, 3, true),
        makeFunc("used", 4, 4, false),
        makeFunc("orphan", 5, 5, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 3), result.production_functions);
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 1.0 / 3.0), result.dead_code_ratio);
}

test "function references used as callbacks are alive" {
    const contents =
        \\pub fn api() void {
        \\    register(callback);
        \\}
        \\fn callback() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("callback", 4, 4, false),
        makeFunc("orphan", 5, 5, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "cross-file reference keeps a uniquely defined function alive" {
    // A bare mention resolves across files only when one file defines the
    // name; here that is the callback in callbacks.zig.
    const api_contents = "pub fn api() void {\n    register(callback);\n}";
    const callback_contents = "fn callback() void {\n    const value = 1 + 2;\n}";
    const api_funcs = [_]core.types.FuncInfo{makeFunc("api", 1, 3, true)};
    const callback_funcs = [_]core.types.FuncInfo{makeFunc("callback", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/api.zig", .contents = api_contents, .funcs = &api_funcs },
        .{ .file = "src/callbacks.zig", .contents = callback_contents, .funcs = &callback_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "ambiguous cross-file mention keeps no same-named function alive" {
    // Two files define `handler`, so the mention in api.zig is ambiguous and
    // neither definition is resurrected by it.
    const api_contents = "pub fn api() void {\n    register(handler);\n}";
    const first_contents = "fn handler() void {\n    const value = 1 + 2;\n}";
    const second_contents = "fn handler() void {\n    const other = 3 + 4;\n}";
    const api_funcs = [_]core.types.FuncInfo{makeFunc("api", 1, 3, true)};
    const first_funcs = [_]core.types.FuncInfo{makeFunc("handler", 1, 3, false)};
    const second_funcs = [_]core.types.FuncInfo{makeFunc("handler", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/api.zig", .contents = api_contents, .funcs = &api_funcs },
        .{ .file = "src/first.zig", .contents = first_contents, .funcs = &first_funcs },
        .{ .file = "src/second.zig", .contents = second_contents, .funcs = &second_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "runtime entry names are roots in any file" {
    // `main`, the Python protocol hooks and the Go package initializer are
    // invoked by their runtime; `render` and `cleanup` are ordinary helpers
    // reached only by an explicit call, and `init` in a .zig file is too.
    const zig_contents = "fn main() void {}\nfn render() void {}\nfn init() void {}";
    const zig_funcs = [_]core.types.FuncInfo{
        makeFunc("main", 1, 1, false),
        makeFunc("render", 2, 2, false),
        makeFunc("init", 3, 3, false),
    };
    const python_contents =
        \\def __del__(self):
        \\    pass
        \\def helper(self):
        \\    pass
    ;
    const python_funcs = [_]core.types.FuncInfo{
        makeFunc("__del__", 1, 2, false),
        makeFunc("helper", 3, 4, false),
    };
    const go_contents = "func init() {}\nfunc cleanup() {}";
    const go_funcs = [_]core.types.FuncInfo{
        makeFunc("init", 1, 1, false),
        makeFunc("cleanup", 2, 2, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/main.zig", .contents = zig_contents, .funcs = &zig_funcs },
        .{ .file = "src/service.py", .contents = python_contents, .funcs = &python_funcs },
        .{ .file = "src/boot.go", .contents = go_contents, .funcs = &go_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    // Alive: main, __del__, Go init. Dead: render, Zig init, helper, cleanup.
    try std.testing.expectEqual(@as(u32, 7), result.production_functions);
    try std.testing.expectEqual(@as(u32, 4), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 4.0 / 7.0), result.dead_code_ratio);
}

test "entry names are roots only inside conventional entry paths" {
    const index_contents = "function index() {\n    const value = 1 + 2;\n}";
    const lib_contents = "function index() {\n    const value = 3 + 4;\n}";
    const app_contents = "def app():\n    return 1\n";
    const build_contents = "pub fn build() void {\n    const value = 1 + 2;\n}";
    const nested_contents = "pub fn build() void {\n    const other = 3 + 4;\n}";
    const index_funcs = [_]core.types.FuncInfo{makeFunc("index", 1, 3, false)};
    const lib_funcs = [_]core.types.FuncInfo{makeFunc("index", 1, 3, false)};
    const app_funcs = [_]core.types.FuncInfo{makeFunc("app", 1, 2, false)};
    const build_funcs = [_]core.types.FuncInfo{makeFunc("build", 1, 3, false)};
    const nested_funcs = [_]core.types.FuncInfo{makeFunc("build", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/index.js", .contents = index_contents, .funcs = &index_funcs },
        .{ .file = "src/lib.js", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/app.py", .contents = app_contents, .funcs = &app_funcs },
        .{ .file = "build.zig", .contents = build_contents, .funcs = &build_funcs },
        .{ .file = "src/nested/build.zig", .contents = nested_contents, .funcs = &nested_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    // Alive: src/index.js:index, src/app.py:app, build.zig:build.
    try std.testing.expectEqual(@as(u32, 5), result.production_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "methods never dead" {
    const contents = "impl Foo { fn method(&self) {} }";
    var funcs = [_]core.types.FuncInfo{makeFunc("method", 1, 1, false)};
    funcs[0].is_method = true;
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.rs", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "test files excluded from dead analysis" {
    const contents = "fn helper() void {}";
    const funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib_test.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.production_functions);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "duplicate bodies detected" {
    // Two identical private functions in different files — both uncalled too
    const contents_a =
        \\fn dup() void {
        \\    const x = 1 + 2 + 3;
        \\    const y = x * 2;
        \\    _ = y;
        \\}
    ;
    const contents_b =
        \\fn dup2() void {
        \\    const x = 1 + 2 + 3;
        \\    const y = x * 2;
        \\    _ = y;
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("dup", 1, 4, false),
        makeFunc("dup2", 1, 4, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/a.zig", .contents = contents_a, .funcs = funcs[0..1] },
        .{ .file = "src/b.zig", .contents = contents_b, .funcs = funcs[1..2] },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    // Both are dead AND duplicated: redundancy includes both signals
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "call target across files keeps function alive" {
    const lib_contents = "fn helper() void {}";
    const app_contents = "pub fn main() void {\n    helper();\n}";
    const lib_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const app_funcs = [_]core.types.FuncInfo{makeFunc("main", 1, 3, true)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/app.zig", .contents = app_contents, .funcs = &app_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "call edges mark liveness without textual call sites" {
    // helper is never textually called from main's body, but a call edge
    // (from external analysis) declares it alive
    const lib_contents = "fn helper() void {}";
    const lib_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const app_contents = "pub fn main() void {\n    other_stuff();\n}";
    const app_funcs = [_]core.types.FuncInfo{makeFunc("main", 1, 3, true)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/app.zig", .contents = app_contents, .funcs = &app_funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/app.zig", .from_func = "main", .to_file = "src/lib.zig", .to_func = "helper" },
    };
    const result = try analyze(std.testing.allocator, &ff, &edges);
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "body too small skipped from duplicates" {
    const contents = "fn a() void {}\nfn b() void {}";
    const funcs = [_]core.types.FuncInfo{
        makeFunc("a", 1, 1, false),
        makeFunc("b", 2, 2, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "test path matching does not use arbitrary substrings" {
    const latest_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const test_funcs = [_]core.types.FuncInfo{makeFunc("test_helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/latest.zig", .contents = "fn helper() void {}", .funcs = &latest_funcs },
        .{ .file = "src/test.zig", .contents = "fn test_helper() void {}", .funcs = &test_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "liveness follows reachable callers" {
    const contents =
        \\pub fn api() void {}
        \\fn orphan_caller() void {}
        \\fn leaf() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 1, true),
        makeFunc("orphan_caller", 2, 2, false),
        makeFunc("leaf", 3, 3, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/lib.zig", .from_func = "orphan_caller", .to_file = "src/lib.zig", .to_func = "leaf" },
    };
    const result = try analyze(std.testing.allocator, &ff, &edges);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "public API roots keep transitive local calls alive" {
    const contents =
        \\pub fn api() void {
        \\    private_a();
        \\}
        \\fn private_a() void {
        \\    private_b();
        \\}
        \\fn private_b() void {}
        \\fn orphan() void {}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("private_a", 4, 6, false),
        makeFunc("private_b", 7, 7, false),
        makeFunc("orphan", 8, 8, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "resolved symbols keep only the selected target alive" {
    const caller_contents = "pub fn api() void {\n    helper();\n}";
    const target_contents = "fn helper() void {\n    const value = 1 + 2 + 3;\n    _ = value;\n}";
    const other_contents = "fn helper() void {\n    const value = 4 + 5 + 6;\n    _ = value;\n}";
    const caller_funcs = [_]core.types.FuncInfo{makeFunc("api", 1, 3, true)};
    const target_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const other_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/caller.zig", .contents = caller_contents, .funcs = &caller_funcs },
        .{ .file = "src/target.zig", .contents = target_contents, .funcs = &target_funcs },
        .{ .file = "src/other.zig", .contents = other_contents, .funcs = &other_funcs },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/caller.zig", .from_func = "api", .to_file = "src/target.zig", .to_func = "helper" },
    };
    const result = try analyze(std.testing.allocator, &ff, &edges);
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "declaration scanning is not capped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var contents = std.ArrayList(u8).empty;
    var funcs = std.ArrayList(core.types.FuncInfo).empty;
    for (0..65) |index| {
        const line = try std.fmt.allocPrint(arena.allocator(), "fn helper{d}() void {{}}\n", .{index});
        try contents.appendSlice(arena.allocator(), line);
        try funcs.append(arena.allocator(), makeFunc("helper", @intCast(index + 1), @intCast(index + 1), false));
    }
    const ff = [_]FileFuncs{
        .{ .file = "src/generated.zig", .contents = contents.items, .funcs = funcs.items },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 65), result.total_functions);
    try std.testing.expectEqual(@as(u32, 65), result.dead_functions);
}

test "test-only helpers are excluded from duplicate candidates" {
    const contents =
        \\fn helper() void {
        \\    const value = 1 + 2;
        \\}
        \\fn other() void {
        \\    const value = 1 + 2;
        \\}
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("helper", 1, 3, false),
        makeFunc("other", 4, 6, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_functions);
    // `other` shares a body with `helper` but nothing references it at all.
    try std.testing.expectEqual(@as(u32, 1), result.dead_functions);
}

test "test probe in another file does not keep same-named helper alive" {
    // probes.zig only exercises `helper` from a test block. That reference is
    // file-scoped, so the uncalled helper in lib.zig stays dead, whichever
    // order the files arrive in.
    const probe_contents =
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const lib_contents = "fn helper() void {}";

    const probe_first = [_]FileFuncs{
        .{ .file = "src/probes.zig", .contents = probe_contents, .funcs = &.{} },
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &[_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)} },
    };
    const lib_first = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &[_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)} },
        .{ .file = "src/probes.zig", .contents = probe_contents, .funcs = &.{} },
    };
    const before = try analyze(std.testing.allocator, &probe_first, &.{});
    try std.testing.expectEqual(@as(u32, 1), before.dead_functions);
    const after = try analyze(std.testing.allocator, &lib_first, &.{});
    try std.testing.expectEqual(@as(u32, 1), after.dead_functions);
}

test "test probe in the same file keeps the helper alive" {
    const contents =
        \\fn helper() void {}
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.dead_functions);
}

test "test probe in another file does not suppress duplicate detection" {
    // The probe only reaches the `helper` of probes.zig, so the identical
    // bodies in first.zig and second.zig are still duplication candidates.
    const probe_contents =
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const first_contents = "fn helper() void {\n    const value = 1 + 2 + 3;\n    _ = value;\n}";
    const second_contents = "fn helper() void {\n    const value = 1 + 2 + 3;\n    _ = value;\n}";
    const first_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const second_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/probes.zig", .contents = probe_contents, .funcs = &.{} },
        .{ .file = "src/first.zig", .contents = first_contents, .funcs = &first_funcs },
        .{ .file = "src/second.zig", .contents = second_contents, .funcs = &second_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
}

test "production reference in another file keeps a test helper out of the duplicate set" {
    // probes.zig: helper is only reached from a test block, but api.zig calls
    // a same-named function, so the name is production-referenced and the
    // helper stays a duplication candidate.
    const probe_contents =
        \\fn helper() void {
        \\    const value = 1 + 2;
        \\}
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const api_contents = "pub fn api() void {\n    helper();\n}";
    const other_contents = "fn helper() void {\n    const value = 1 + 2;\n}";
    const probe_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const api_funcs = [_]core.types.FuncInfo{makeFunc("api", 1, 3, true)};
    const other_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 3, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/probes.zig", .contents = probe_contents, .funcs = &probe_funcs },
        .{ .file = "src/api.zig", .contents = api_contents, .funcs = &api_funcs },
        .{ .file = "src/other.zig", .contents = other_contents, .funcs = &other_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "normalized bodies ignore comments but preserve string values" {
    const contents_a =
        \\fn first() void {
        \\    // comment A
        \\    const text = "same";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const contents_b =
        \\fn second() void {
        \\    /* comment B */
        \\    const text = "same";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const contents_c =
        \\fn third() void {
        \\    // comment C
        \\    const text = "different";
        \\    const value = 1 + 2 + 3;
        \\    _ = value;
        \\}
    ;
    const funcs_a = [_]core.types.FuncInfo{makeFunc("first", 1, 5, false)};
    const funcs_b = [_]core.types.FuncInfo{makeFunc("second", 1, 5, false)};
    const funcs_c = [_]core.types.FuncInfo{makeFunc("third", 1, 5, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/a.zig", .contents = contents_a, .funcs = &funcs_a },
        .{ .file = "src/b.zig", .contents = contents_b, .funcs = &funcs_b },
        .{ .file = "src/c.zig", .contents = contents_c, .funcs = &funcs_c },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "large normalized bodies are compared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first = std.ArrayList(u8).empty;
    var second = std.ArrayList(u8).empty;
    try first.appendSlice(arena.allocator(), "fn first() void {\n");
    try second.appendSlice(arena.allocator(), "fn second() void {\n");
    for (0..200) |index| {
        const line = try std.fmt.allocPrint(arena.allocator(), "    const value{d} = 1 + 2;\n", .{index});
        try first.appendSlice(arena.allocator(), line);
        try second.appendSlice(arena.allocator(), line);
    }
    try first.appendSlice(arena.allocator(), "}\n");
    try second.appendSlice(arena.allocator(), "}\n");
    const first_funcs = [_]core.types.FuncInfo{makeFunc("first", 1, 202, false)};
    const second_funcs = [_]core.types.FuncInfo{makeFunc("second", 1, 202, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/first.zig", .contents = first.items, .funcs = &first_funcs },
        .{ .file = "src/second.zig", .contents = second.items, .funcs = &second_funcs },
    };
    const result = try analyze(arena.allocator(), &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.duplicate_functions);
}

test "overlapping function bodies are excluded from duplicate matching" {
    const contents =
        \\fn outer() void {
        \\    fn inner() void {
        \\        const value = 1 + 2 + 3;
        \\        _ = value;
        \\    }
        \\    _ = inner;
        \\}
    ;
    const funcs = [_]core.types.FuncInfo{
        makeFunc("outer", 1, 6, false),
        makeFunc("inner", 2, 4, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/nested.zig", .contents = contents, .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_functions);
}

test "ratios divide by production functions" {
    // Two production functions, one dead, plus two test-file functions that
    // are counted in total_functions but are not part of the denominator.
    const lib_contents = "fn private_a() void {}\nfn private_b() void {}";
    const lib_funcs = [_]core.types.FuncInfo{
        makeFunc("private_a", 1, 1, false),
        makeFunc("private_b", 2, 2, false),
    };
    const test_contents = "fn helper() void {}\nfn other() void {}";
    const test_funcs = [_]core.types.FuncInfo{
        makeFunc("helper", 1, 1, false),
        makeFunc("other", 2, 2, false),
    };
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/lib_test.zig", .contents = test_contents, .funcs = &test_funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 4), result.total_functions);
    try std.testing.expectEqual(@as(u32, 2), result.production_functions);
    try std.testing.expectEqual(@as(u32, 2), result.dead_functions);
    try std.testing.expectEqual(@as(f64, 1.0), result.dead_code_ratio);
    try std.testing.expectEqual(@as(f64, 1.0), result.redundancy_ratio);
}

test "a test-only project reports unknown redundancy" {
    // Nothing to measure: dead and duplicate counts are necessarily zero and
    // redundancy is unknown rather than clean.
    const funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 1, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib_test.zig", .contents = "fn helper() void {}", .funcs = &funcs },
    };
    const result = try analyze(std.testing.allocator, &ff, &.{});
    try std.testing.expectEqual(@as(u32, 1), result.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.production_functions);
    try std.testing.expectEqual(@as(f64, 0.0), result.dead_code_ratio);
    try std.testing.expectEqual(@as(f64, 0.0), result.duplication_ratio);
    try std.testing.expectEqual(@as(f64, 1.0), result.redundancy_ratio);
}

test "result owns no memory" {
    // A leak or a forgotten free fails the test: `analyze` takes a plain
    // allocator, returns a value that owns nothing, and can be called again
    // without any teardown in between.
    const lib_contents = "pub fn api() void {\n    helper();\n}\nfn helper() void {}\nfn orphan() void {}";
    const lib_funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("helper", 4, 4, false),
        makeFunc("orphan", 5, 5, false),
    };
    const test_contents = "test \"helper works\" {\n    helper();\n}";
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/probes.zig", .contents = test_contents, .funcs = &.{} },
    };
    const edges = [_]core.types.CallEdge{
        .{ .from_file = "src/lib.zig", .from_func = "api", .to_file = "src/lib.zig", .to_func = "orphan" },
    };
    const first = try analyze(std.testing.allocator, &ff, &edges);
    try std.testing.expectEqual(@as(u32, 3), first.total_functions);
    try std.testing.expectEqual(@as(u32, 0), first.dead_functions);
    const second = try analyze(std.testing.allocator, &ff, &edges);
    try std.testing.expectEqual(first.dead_functions, second.dead_functions);
    try std.testing.expectEqual(first.duplicate_functions, second.duplicate_functions);
}

test "analyze releases every allocation when an allocation fails" {
    const lib_contents =
        \\pub fn api() void {
        \\    helper();
        \\}
        \\fn helper() void {
        \\    const value = 1 + 2;
        \\    _ = value;
        \\}
        \\fn orphan() void {
        \\    const other = 3 + 4;
        \\    _ = other;
        \\}
        \\test "helper works" {
        \\    helper();
        \\}
    ;
    const lib_funcs = [_]core.types.FuncInfo{
        makeFunc("api", 1, 3, true),
        makeFunc("helper", 4, 7, false),
        makeFunc("orphan", 8, 11, false),
    };
    const other_contents = "fn helper() void {\n    const value = 1 + 2;\n    _ = value;\n}";
    const other_funcs = [_]core.types.FuncInfo{makeFunc("helper", 1, 4, false)};
    const ff = [_]FileFuncs{
        .{ .file = "src/lib.zig", .contents = lib_contents, .funcs = &lib_funcs },
        .{ .file = "src/other.zig", .contents = other_contents, .funcs = &other_funcs },
    };
    // The sweep fails the Nth allocation for every N: each attempt must
    // propagate OutOfMemory and leave nothing allocated behind.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, analyzeAndDrop, .{ &ff, &[_]core.types.CallEdge{} });
}
