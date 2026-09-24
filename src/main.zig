const std = @import("std");
const core = @import("core");
const metrics = @import("metrics");
const analysis = @import("analysis");

const json_schema_version: u32 = 2;
const tool_version = "0.1.0";

const CliOptions = struct {
    command: []const u8,
    path: []const u8 = ".",
    save: bool = false,
    json: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch {
        std.debug.print("tdlearn: unable to read arguments\n", .{});
        std.process.exit(2);
    };
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(init.gpa);
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        try args.append(init.gpa, arg);
    }

    if (args.items.len == 0) {
        try printUsage(init.io);
        std.process.exit(2);
    }

    const command = args.items[0];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        if (args.items.len != 1) {
            if (hasJsonFlag(args.items[1..])) {
                printJsonError(init.io, init.gpa, error.ExtraArgument) catch {};
            } else {
                std.debug.print("tdlearn: --help does not accept arguments\n", .{});
            }
            std.process.exit(2);
        }
        try printUsage(init.io);
        return;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        if (args.items.len != 1) {
            if (hasJsonFlag(args.items[1..])) {
                printJsonError(init.io, init.gpa, error.ExtraArgument) catch {};
            } else {
                std.debug.print("tdlearn: --version does not accept arguments\n", .{});
            }
            std.process.exit(2);
        }
        try printVersion(init.io);
        return;
    }

    const options = parseOptions(command, args.items[1..]) catch |err| {
        if (hasJsonFlag(args.items[1..])) {
            printJsonError(init.io, init.gpa, err) catch {};
        } else {
            std.debug.print("tdlearn: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };

    const result = if (std.mem.eql(u8, options.command, "scan"))
        runScan(init.io, options.path, options.json)
    else if (std.mem.eql(u8, options.command, "check"))
        runCheck(init.io, options.path, options.json)
    else
        runGate(init.io, options.path, options.save, options.json);
    result catch |err| exitForError(init.io, init.gpa, err, options.json);
}

fn hasJsonFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn parseOptions(command: []const u8, args: []const []const u8) !CliOptions {
    if (!std.mem.eql(u8, command, "scan") and
        !std.mem.eql(u8, command, "check") and
        !std.mem.eql(u8, command, "gate"))
    {
        return error.UnknownCommand;
    }

    var options = CliOptions{ .command = command };
    var path_seen = false;
    var save_seen = false;
    var json_seen = false;
    var options_done = false;

    for (args) |arg| {
        if (!options_done and std.mem.eql(u8, arg, "--")) {
            options_done = true;
            continue;
        }

        if (!options_done and std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--save")) {
                if (!std.mem.eql(u8, command, "gate")) return error.InvalidFlag;
                if (save_seen) return error.DuplicateFlag;
                save_seen = true;
                options.save = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                if (json_seen) return error.DuplicateFlag;
                json_seen = true;
                options.json = true;
            } else {
                return error.UnknownFlag;
            }
            continue;
        }

        if (path_seen) return error.ExtraArgument;
        if (arg.len == 0) return error.InvalidPath;
        path_seen = true;
        options.path = arg;
    }

    return options;
}

fn printUsage(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        \\tdlearn — Codebase structural quality sensor
        \\
        \\Usage:
        \\  tdlearn scan [path] [--json]       Scan a project
        \\  tdlearn check [path] [--json]      Check rules
        \\  tdlearn gate [path] [--save] [--json]  Quality gate for CI
        \\  tdlearn --help                      Show this help
        \\  tdlearn --version                   Show version
        \\
    );
    try writer.interface.flush();
}

fn printVersion(io: std.Io) !void {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll("tdlearn 0.1.0\n");
    try writer.interface.flush();
}

fn exitForError(io: std.Io, allocator: std.mem.Allocator, err: anyerror, json_flag: bool) noreturn {
    switch (err) {
        error.CheckFailed, error.GateFailed, error.NoRulesFile, error.NoBaseline => {},
        else => {
            if (json_flag) {
                printJsonError(io, allocator, err) catch {};
            } else {
                std.debug.print("tdlearn: {s}\n", .{@errorName(err)});
            }
        },
    }
    if (err == error.CheckFailed or err == error.GateFailed) std.process.exit(1);
    std.process.exit(2);
}

fn validateRoot(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    dir.close(io);
}

fn readFileOrNull(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0) return "";
    if (stat.size > 2 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const bytes_read = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..bytes_read];
}

// ── JSON output shapes (scores scaled ×10000) ────────────────────

const JsonRootCauses = struct {
    modularity: u32,
    acyclicity: u32,
    depth: u32,
    equality: u32,
    redundancy: u32,
};

const JsonUnits = struct {
    quality_signal: []const u8,
    line_counts: []const u8,
    edge_counts: []const u8,
};

const JsonGateMetrics = struct {
    quality_signal: u32,
    cycle_count: u32,
    max_depth: u32,
    total_functions: u32,
    dead_functions: u32,
    duplicate_functions: u32,
};

const JsonErrorDetails = struct {
    code: []const u8,
    category: []const u8,
    message: []const u8,
};

const JsonError = struct {
    schema_version: u32,
    tool_version: []const u8,
    ok: bool,
    error_info: JsonErrorDetails,
};

const JsonHotspot = struct {
    file: []const u8,
    name: []const u8,
    lines: u32,
    cyclomatic: u32,
    cognitive: u32,
    score: u64,
};

const JsonScan = struct {
    schema_version: u32,
    tool_version: []const u8,
    ok: bool,
    root: []const u8,
    units: JsonUnits,
    quality_signal: u32,
    bottleneck: []const u8,
    files: u32,
    lines: u32,
    import_edges: u32,
    call_edges: u32,
    inherit_edges: u32,
    functions: u32,
    dead_functions: u32,
    duplicate_functions: u32,
    root_causes: JsonRootCauses,
    depth_path: []const []const u8,
    hotspots: []const JsonHotspot,
};

const JsonCheck = struct {
    schema_version: u32,
    tool_version: []const u8,
    ok: bool,
    root: []const u8,
    units: JsonUnits,
    pass: bool,
    rules_checked: u32,
    quality_signal: u32,
    violations: []const JsonViolation,
};

const JsonViolation = struct {
    rule: []const u8,
    severity: []const u8,
    message: []const u8,
    from: ?[]const u8,
    to: ?[]const u8,
};

const JsonGate = struct {
    schema_version: u32,
    tool_version: []const u8,
    ok: bool,
    root: []const u8,
    units: JsonUnits,
    pass: bool,
    quality_signal: u32,
    baseline: JsonGateMetrics,
    current: JsonGateMetrics,
    violations: []const []const u8,
};

const JsonGateSave = struct {
    schema_version: u32,
    tool_version: []const u8,
    ok: bool,
    root: []const u8,
    units: JsonUnits,
    saved: bool,
    quality_signal: u32,
    metrics: JsonGateMetrics,
};

fn scoreInt(score: f64) u32 {
    return @intFromFloat(@max(0.0, @min(1.0, score)) * 10000.0);
}

/// Write JSON payload to stdout (for tooling consumption).
fn printJsonStdout(io: std.Io, allocator: std.mem.Allocator, payload: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(json);
    try stdout_writer.interface.writeAll("\n");
    try stdout_writer.interface.flush();
}

fn jsonUnits() JsonUnits {
    return .{
        .quality_signal = "0-10000",
        .line_counts = "lines",
        .edge_counts = "edges",
    };
}

fn gateMetricsFromReport(report: metrics.HealthReport) JsonGateMetrics {
    return .{
        .quality_signal = report.quality_signal_int,
        .cycle_count = report.root_cause_raw.cycle_count,
        .max_depth = report.root_cause_raw.max_depth,
        .total_functions = report.total_functions,
        .dead_functions = report.dead_functions,
        .duplicate_functions = report.duplicate_functions,
    };
}

fn gateMetricsFromBaseline(baseline: core.baseline.Baseline) JsonGateMetrics {
    return .{
        .quality_signal = @intFromFloat(@max(0.0, @min(1.0, baseline.quality_signal)) * 10000.0),
        .cycle_count = baseline.cycle_count,
        .max_depth = baseline.max_depth,
        .total_functions = baseline.total_functions,
        .dead_functions = baseline.dead_functions,
        .duplicate_functions = baseline.duplicate_functions,
    };
}

fn printJsonError(io: std.Io, allocator: std.mem.Allocator, err: anyerror) !void {
    const code = @errorName(err);
    const payload = JsonError{
        .schema_version = json_schema_version,
        .tool_version = tool_version,
        .ok = false,
        .error_info = .{
            .code = code,
            .category = errorCategory(code),
            .message = code,
        },
    };
    try printJsonStdout(io, allocator, payload);
}

fn errorCategory(code: []const u8) []const u8 {
    const usage_errors = [_][]const u8{ "UnknownCommand", "UnknownFlag", "InvalidFlag", "DuplicateFlag", "ExtraArgument", "InvalidPath" };
    for (usage_errors) |candidate| {
        if (std.mem.eql(u8, code, candidate)) return "usage";
    }
    const config_errors = [_][]const u8{ "InvalidRules", "UnsupportedBaselineSchema", "InvalidBaseline", "NoRulesFile" };
    for (config_errors) |candidate| {
        if (std.mem.eql(u8, code, candidate)) return "configuration";
    }
    if (std.mem.eql(u8, code, "NoBaseline")) return "baseline";
    return "analysis";
}

/// Full analysis result shared by scan/check/gate commands.
const Analysis = struct {
    report: metrics.HealthReport,
    import_edges: []const core.types.ImportEdge,
    call_edges: []const core.types.CallEdge,
    inherit_edges: []const core.types.InheritEdge,
    file_paths: []const []const u8,
    max_file_lines: u32,
    max_fn_lines: u32,
    depth_path: []const []const u8,
    hotspots: []const JsonHotspot,
};

fn filterSourcePaths(allocator: std.mem.Allocator, all_paths: []const []const u8) ![]const []const u8 {
    var source_paths = std.ArrayList([]const u8).empty;
    errdefer source_paths.deinit(allocator);
    for (all_paths) |file_path| {
        if (!std.mem.eql(u8, analysis.graph_builder.GraphBuilder.detectLangForFile(file_path), "unknown")) {
            try source_paths.append(allocator, file_path);
        }
    }
    return try source_paths.toOwnedSlice(allocator);
}

/// Run walker + graph builder + function extraction + health metrics.
/// All allocations come from `arena` (caller-owned).
fn runAnalysis(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Analysis {
    try validateRoot(io, path);
    var settings = core.settings.Settings{};
    settings.sanitize();
    var walker = try analysis.walker.Walker.initWithSettings(arena, io, path, settings);
    defer walker.deinit();

    const files = try walker.walk();

    const all_file_paths = try analysis.walker.Walker.flattenFiles(files, arena);
    const file_paths = try filterSourcePaths(arena, all_file_paths);

    var source_contents = std.ArrayList([]const u8).empty;
    defer source_contents.deinit(arena);
    var contents_by_path = std.StringHashMap([]const u8).init(arena);
    defer contents_by_path.deinit();
    for (file_paths) |fpath| {
        const source_path = if (path.len == 0) fpath else try std.mem.join(arena, "/", &.{ path, fpath });
        const contents = readFileOrNull(arena, io, source_path) orelse return error.FileNotFound;
        if (@as(u64, settings.max_parse_size_kb) * 1024 < contents.len) return error.FileTooLarge;
        try source_contents.append(arena, contents);
        try contents_by_path.put(fpath, contents);
    }
    const import_edges = try analysis.graph_builder.GraphBuilder.buildImportEdgesAtRootWithContents(
        arena,
        io,
        path,
        all_file_paths,
        contents_by_path,
    );

    var source_files = std.ArrayList(core.types.FileNode).empty;
    defer source_files.deinit(arena);
    for (file_paths) |fpath| {
        const node = findFileNode(files, fpath) orelse return error.FileNotFound;
        try source_files.append(arena, node.*);
    }

    // Extract functions per file; track size extremes
    var file_funcs = std.ArrayList(metrics.dead_code.FileFuncs).empty;
    var file_classes = std.ArrayList(analysis.inherit_graph.InheritGraphBuilder.FileClasses).empty;
    var max_file_lines: u32 = 0;
    var max_fn_lines: u32 = 0;
    for (file_paths, source_contents.items) |fpath, contents| {
        const lang = analysis.graph_builder.GraphBuilder.detectLangForFile(fpath);
        const funcs = try analysis.functions.FunctionExtractor.extract(arena, contents, lang);
        try file_funcs.append(arena, .{ .file = fpath, .contents = contents, .funcs = funcs });

        const classes = try analysis.classes.ClassExtractor.extract(arena, contents, lang);
        if (classes.len > 0) {
            try file_classes.append(arena, .{ .file = fpath, .classes = classes });
        }

        if (findFileNode(files, fpath)) |node| {
            if (node.lines > max_file_lines) max_file_lines = node.lines;
        }
        for (funcs) |f| {
            if (f.line_count > max_fn_lines) max_fn_lines = f.line_count;
        }
    }

    // Build call graph from extracted functions + import edges
    const call_edges = try analysis.call_graph.CallGraphBuilder.buildCallEdgesWithLimit(
        arena,
        file_funcs.items,
        import_edges,
        settings.max_call_targets,
    );

    // Build inheritance graph from extracted classes + import edges
    const inherit_edges = try analysis.inherit_graph.InheritGraphBuilder.buildInheritEdges(
        arena,
        file_classes.items,
        import_edges,
    );

    const report = try metrics.computeHealth(
        arena,
        source_files.items,
        import_edges,
        call_edges,
        inherit_edges,
        file_funcs.items,
    );
    const depth_path = try buildDepthPath(arena, file_paths, import_edges);
    const hotspots = try collectHotspots(arena, file_funcs.items);

    return .{
        .report = report,
        .import_edges = import_edges,
        .call_edges = call_edges,
        .inherit_edges = inherit_edges,
        .file_paths = file_paths,
        .max_file_lines = max_file_lines,
        .max_fn_lines = max_fn_lines,
        .depth_path = depth_path,
        .hotspots = hotspots,
    };
}

fn findFileNode(files: []const core.types.FileNode, path: []const u8) ?*const core.types.FileNode {
    for (files) |*f| {
        if (!f.is_dir and std.mem.eql(u8, f.path, path)) return f;
        if (f.children) |children| {
            if (findFileNode(children, path)) |found| return found;
        }
    }
    return null;
}

const max_hotspots = 10;

fn hotspotScore(func: core.types.FuncInfo) u64 {
    const cyclomatic = func.cyclomatic_complexity orelse 0;
    const cognitive = func.cognitive_complexity orelse 0;
    return @as(u64, cyclomatic) * 1_000_000 + @as(u64, cognitive) * 1_000 + func.line_count;
}

fn collectHotspots(
    allocator: std.mem.Allocator,
    file_funcs: []const metrics.dead_code.FileFuncs,
) ![]const JsonHotspot {
    var hotspots = std.ArrayList(JsonHotspot).empty;
    errdefer hotspots.deinit(allocator);
    for (file_funcs) |file| {
        for (file.funcs) |func| {
            const hotspot = JsonHotspot{
                .file = file.file,
                .name = func.name,
                .lines = func.line_count,
                .cyclomatic = func.cyclomatic_complexity orelse 0,
                .cognitive = func.cognitive_complexity orelse 0,
                .score = hotspotScore(func),
            };
            if (hotspots.items.len < max_hotspots) {
                try hotspots.append(allocator, hotspot);
            } else if (hotspot.score > hotspots.items[hotspots.items.len - 1].score) {
                hotspots.items[hotspots.items.len - 1] = hotspot;
            } else {
                continue;
            }
            var index = hotspots.items.len - 1;
            while (index > 0 and hotspots.items[index - 1].score < hotspots.items[index].score) : (index -= 1) {
                const temporary = hotspots.items[index - 1];
                hotspots.items[index - 1] = hotspots.items[index];
                hotspots.items[index] = temporary;
            }
        }
    }
    return try hotspots.toOwnedSlice(allocator);
}

fn collectDepthEntries(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    import_edges: []const core.types.ImportEdge,
    entries: *std.ArrayList(usize),
) !void {
    for (file_paths, 0..) |path, index| {
        if (core.path_utils.isEntryPointPath(path)) try entries.append(allocator, index);
    }
    if (entries.items.len != 0) return;
    if (import_edges.len == 0) {
        if (file_paths.len != 0) try entries.append(allocator, 0);
        return;
    }

    var node_index = std.StringHashMap(usize).init(allocator);
    defer node_index.deinit();
    for (file_paths, 0..) |path, index| try node_index.put(path, index);
    var incoming = try allocator.alloc(bool, file_paths.len);
    defer allocator.free(incoming);
    @memset(incoming, false);
    for (import_edges) |edge| {
        const target = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;
        incoming[target] = true;
    }
    for (incoming, 0..) |has_incoming, index| {
        if (!has_incoming) try entries.append(allocator, index);
    }
    if (entries.items.len == 0 and file_paths.len != 0) try entries.append(allocator, 0);
}

fn buildDepthPath(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    import_edges: []const core.types.ImportEdge,
) ![]const []const u8 {
    var entries = std.ArrayList(usize).empty;
    defer entries.deinit(allocator);
    try collectDepthEntries(allocator, file_paths, import_edges, &entries);

    var node_index = std.StringHashMap(usize).init(allocator);
    defer node_index.deinit();
    for (file_paths, 0..) |path, index| try node_index.put(path, index);
    var graph_edges = std.ArrayList(core.types.GraphEdge).empty;
    defer graph_edges.deinit(allocator);
    for (import_edges) |edge| {
        const from = node_index.get(edge.from_file) orelse return error.InvalidGraphEdge;
        const to = node_index.get(edge.to_file) orelse return error.InvalidGraphEdge;
        try graph_edges.append(allocator, .{ .from = from, .to = to });
    }
    const longest = try metrics.depth.computeLongestPath(allocator, file_paths.len, entries.items, graph_edges.items);
    defer if (longest.nodes.len != 0) allocator.free(longest.nodes);

    var path = std.ArrayList([]const u8).empty;
    errdefer path.deinit(allocator);
    for (longest.nodes) |node| {
        if (node >= file_paths.len) return error.InvalidGraphEdge;
        try path.append(allocator, file_paths[node]);
    }
    return try path.toOwnedSlice(allocator);
}

fn runScan(io: std.Io, path: []const u8, json_flag: bool) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    if (!json_flag) std.debug.print("Scanning {s}...\n", .{path});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const result = try runAnalysis(arena.allocator(), io, path);
    const report = result.report;

    if (json_flag) {
        const payload = JsonScan{
            .schema_version = json_schema_version,
            .tool_version = tool_version,
            .ok = true,
            .root = path,
            .units = jsonUnits(),
            .quality_signal = report.quality_signal_int,
            .bottleneck = report.bottleneck,
            .files = report.file_count,
            .lines = report.line_count,
            .import_edges = @intCast(result.import_edges.len),
            .call_edges = @intCast(result.call_edges.len),
            .inherit_edges = @intCast(result.inherit_edges.len),
            .functions = report.total_functions,
            .dead_functions = report.dead_functions,
            .duplicate_functions = report.duplicate_functions,
            .root_causes = .{
                .modularity = scoreInt(report.root_cause_scores.modularity),
                .acyclicity = scoreInt(report.root_cause_scores.acyclicity),
                .depth = scoreInt(report.root_cause_scores.depth),
                .equality = scoreInt(report.root_cause_scores.equality),
                .redundancy = scoreInt(report.root_cause_scores.redundancy),
            },
            .depth_path = result.depth_path,
            .hotspots = result.hotspots,
        };
        try printJsonStdout(io, arena.allocator(), payload);
        return;
    }

    std.debug.print("Found {d} files, {d} lines\n", .{ report.file_count, report.line_count });
    std.debug.print("\n", .{});
    std.debug.print("Quality Signal: {d}/10000\n", .{report.quality_signal_int});
    std.debug.print("Bottleneck: {s}\n", .{report.bottleneck});
    std.debug.print("Import edges: {d}, call edges: {d}, inherit edges: {d}\n", .{
        result.import_edges.len,
        result.call_edges.len,
        result.inherit_edges.len,
    });
    std.debug.print("Functions: {d} (dead: {d}, duplicated: {d})\n", .{
        report.total_functions,
        report.dead_functions,
        report.duplicate_functions,
    });
    std.debug.print("\n", .{});
    std.debug.print("Root Causes:\n", .{});
    std.debug.print("  Modularity:  {d:.3} (raw Q={d:.3})\n", .{
        report.root_cause_scores.modularity,
        report.root_cause_raw.modularity_q,
    });
    std.debug.print("  Acyclicity:  {d:.3} (cycles={d})\n", .{
        report.root_cause_scores.acyclicity,
        report.root_cause_raw.cycle_count,
    });
    std.debug.print("  Depth:       {d:.3} (max={d})\n", .{
        report.root_cause_scores.depth,
        report.root_cause_raw.max_depth,
    });
    std.debug.print("  Equality:    {d:.3} (gini={d:.3})\n", .{
        report.root_cause_scores.equality,
        report.root_cause_raw.complexity_gini,
    });
    std.debug.print("  Redundancy:  {d:.3} (ratio={d:.3})\n", .{
        report.root_cause_scores.redundancy,
        report.root_cause_raw.redundancy_ratio,
    });
    if (result.depth_path.len != 0) {
        std.debug.print("Longest path: ", .{});
        for (result.depth_path, 0..) |node_path, index| {
            if (index != 0) std.debug.print(" -> ", .{});
            std.debug.print("{s}", .{node_path});
        }
        std.debug.print("\n", .{});
    }
    if (result.hotspots.len != 0) {
        std.debug.print("Function hotspots:\n", .{});
        for (result.hotspots) |hotspot| {
            std.debug.print("  {s}:{s} lines={d} cyclomatic={d} cognitive={d}\n", .{
                hotspot.file,
                hotspot.name,
                hotspot.lines,
                hotspot.cyclomatic,
                hotspot.cognitive,
            });
        }
    }
}

const CheckExecution = struct {
    report: metrics.HealthReport,
    check: core.rules.CheckResult,
};

const GateSaveExecution = struct {
    report: metrics.HealthReport,
};

const GateCompareExecution = struct {
    baseline: core.baseline.Baseline,
    current: core.baseline.Baseline,
    report: metrics.HealthReport,
    violations: []const []const u8,
};

fn evaluateCheck(arena: std.mem.Allocator, io: std.Io, path: []const u8) !CheckExecution {
    try validateRoot(io, path);
    const rules_path = try std.fmt.allocPrint(arena, "{s}/.tdlearn/rules.toml", .{path});
    const rules_contents = readFileOrNull(arena, io, rules_path) orelse return error.NoRulesFile;
    const config = try core.rules.parseRules(arena, rules_contents);
    const result = try runAnalysis(arena, io, path);
    const report = result.report;
    const edges = try arena.alloc(core.rules.CheckInput.Edge, result.import_edges.len);
    for (result.import_edges, 0..) |edge, index| {
        edges[index] = .{ .from = edge.from_file, .to = edge.to_file };
    }
    const input = core.rules.CheckInput{
        .quality_signal = report.quality_signal,
        .modularity = report.root_cause_scores.modularity,
        .acyclicity = report.root_cause_scores.acyclicity,
        .depth = report.root_cause_scores.depth,
        .equality = report.root_cause_scores.equality,
        .redundancy = report.root_cause_scores.redundancy,
        .cycle_count = report.root_cause_raw.cycle_count,
        .max_file_lines = result.max_file_lines,
        .max_fn_lines = result.max_fn_lines,
        .import_edges = edges,
        .file_paths = result.file_paths,
    };
    return .{
        .report = report,
        .check = try core.rules.checkRules(arena, &config, &input),
    };
}

fn runCheck(io: std.Io, path: []const u8, json_flag: bool) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const aa = arena.allocator();
    const execution = evaluateCheck(aa, io, path) catch |err| {
        if (err == error.NoRulesFile) {
            const rules_path = try std.fmt.allocPrint(aa, "{s}/.tdlearn/rules.toml", .{path});
            if (json_flag) {
                try printJsonError(io, aa, error.NoRulesFile);
            } else {
                std.debug.print("No rules file at {s} — nothing to check.\n", .{rules_path});
                std.debug.print("Create .tdlearn/rules.toml to define constraints.\n", .{});
            }
        }
        return err;
    };
    const report = execution.report;
    const check = execution.check;

    if (json_flag) {
        var json_violations = try aa.alloc(JsonViolation, check.violations.len);
        for (check.violations, 0..) |violation, index| {
            json_violations[index] = .{
                .rule = violation.rule,
                .severity = violation.severity.label(),
                .message = violation.message,
                .from = if (violation.files.len >= 2) violation.files[0] else null,
                .to = if (violation.files.len >= 2) violation.files[1] else null,
            };
        }
        const payload = JsonCheck{
            .schema_version = json_schema_version,
            .tool_version = tool_version,
            .ok = check.pass(),
            .root = path,
            .units = jsonUnits(),
            .pass = check.pass(),
            .rules_checked = check.rules_checked,
            .quality_signal = report.quality_signal_int,
            .violations = json_violations,
        };
        try printJsonStdout(io, aa, payload);
        if (!check.pass()) return error.CheckFailed;
        return;
    }

    std.debug.print("tdlearn check — {d} rules checked\n", .{check.rules_checked});
    std.debug.print("Quality: {d}/10000\n", .{report.quality_signal_int});
    if (check.violations.len == 0) {
        std.debug.print("All rules passed\n", .{});
        return;
    }
    for (check.violations) |violation| {
        std.debug.print("x [{s}] {s}: {s}\n", .{ violation.severity.label(), violation.rule, violation.message });
        if (violation.files.len >= 2) {
            std.debug.print("    {s} -> {s}\n", .{ violation.files[0], violation.files[1] });
        }
    }
    std.debug.print("\n{d} violation(s)\n", .{check.violations.len});
    return error.CheckFailed;
}

fn saveGate(arena: std.mem.Allocator, io: std.Io, path: []const u8) !GateSaveExecution {
    try validateRoot(io, path);
    const baseline_path = try std.fmt.allocPrint(arena, "{s}/.tdlearn/baseline.json", .{path});
    const result = try runAnalysis(arena, io, path);
    const baseline = core.baseline.Baseline{
        .quality_signal = result.report.quality_signal,
        .cycle_count = result.report.root_cause_raw.cycle_count,
        .max_depth = result.report.root_cause_raw.max_depth,
        .total_functions = result.report.total_functions,
        .dead_functions = result.report.dead_functions,
        .duplicate_functions = result.report.duplicate_functions,
    };
    const json = try core.baseline.writeBaseline(arena, baseline);
    const dir_path = try std.fmt.allocPrint(arena, "{s}/.tdlearn", .{path});
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const temp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{baseline_path});
    const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), baseline_path, io);
    return .{ .report = result.report };
}

fn compareGate(arena: std.mem.Allocator, io: std.Io, path: []const u8) !GateCompareExecution {
    try validateRoot(io, path);
    const baseline_path = try std.fmt.allocPrint(arena, "{s}/.tdlearn/baseline.json", .{path});
    const baseline_contents = readFileOrNull(arena, io, baseline_path) orelse return error.NoBaseline;
    const baseline = try core.baseline.readBaseline(arena, baseline_contents);
    const result = try runAnalysis(arena, io, path);
    const current = core.baseline.Baseline{
        .quality_signal = result.report.quality_signal,
        .cycle_count = result.report.root_cause_raw.cycle_count,
        .max_depth = result.report.root_cause_raw.max_depth,
        .total_functions = result.report.total_functions,
        .dead_functions = result.report.dead_functions,
        .duplicate_functions = result.report.duplicate_functions,
    };
    return .{
        .baseline = baseline,
        .current = current,
        .report = result.report,
        .violations = try baseline.diff(current, arena),
    };
}

fn runGate(io: std.Io, path: []const u8, save_mode: bool, json_flag: bool) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const aa = arena.allocator();
    const baseline_path = try std.fmt.allocPrint(aa, "{s}/.tdlearn/baseline.json", .{path});

    if (save_mode) {
        const execution = try saveGate(aa, io, path);
        if (json_flag) {
            const payload = JsonGateSave{
                .schema_version = json_schema_version,
                .tool_version = tool_version,
                .ok = true,
                .root = path,
                .units = jsonUnits(),
                .saved = true,
                .quality_signal = execution.report.quality_signal_int,
                .metrics = gateMetricsFromReport(execution.report),
            };
            try printJsonStdout(io, aa, payload);
            return;
        }
        std.debug.print("tdlearn gate — baseline saved\n", .{});
        std.debug.print("Quality: {d}/10000\n", .{execution.report.quality_signal_int});
        std.debug.print("Baseline written to {s}\n", .{baseline_path});
        return;
    }

    const execution = compareGate(aa, io, path) catch |err| {
        if (err == error.NoBaseline) {
            if (json_flag) {
                try printJsonError(io, aa, error.NoBaseline);
            } else {
                std.debug.print("No baseline at {s}\n", .{baseline_path});
                std.debug.print("Run 'tdlearn gate --save' first to create one.\n", .{});
            }
        }
        return err;
    };
    const violations = execution.violations;
    if (json_flag) {
        const payload = JsonGate{
            .schema_version = json_schema_version,
            .tool_version = tool_version,
            .ok = violations.len == 0,
            .root = path,
            .units = jsonUnits(),
            .pass = violations.len == 0,
            .quality_signal = execution.report.quality_signal_int,
            .baseline = gateMetricsFromBaseline(execution.baseline),
            .current = gateMetricsFromReport(execution.report),
            .violations = violations,
        };
        try printJsonStdout(io, aa, payload);
        if (violations.len > 0) return error.GateFailed;
        return;
    }

    std.debug.print("tdlearn gate — structural regression check\n", .{});
    std.debug.print("Quality:  {d} -> {d} (per 10000)\n", .{
        @as(u32, @intFromFloat(execution.baseline.quality_signal * 10000)),
        execution.report.quality_signal_int,
    });
    std.debug.print("Cycles:  {d} -> {d}\n", .{ execution.baseline.cycle_count, execution.current.cycle_count });
    std.debug.print("Depth:   {d} -> {d}\n", .{ execution.baseline.max_depth, execution.current.max_depth });
    if (violations.len == 0) {
        std.debug.print("No degradation detected\n", .{});
        return;
    }
    for (violations) |violation| {
        std.debug.print("x {s}\n", .{violation});
    }
    std.debug.print("\nDEGRADED — {d} regression(s)\n", .{violations.len});
    return error.GateFailed;
}

test "analysis pipeline runs against a temporary project" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\const helper = @import("helper.zig");
        \\pub fn main() void {
        \\    helper();
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/helper.zig",
        .data =
        \\pub fn helper() void {}
        ,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const result = try runAnalysis(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(u32, 2), result.report.file_count);
    try std.testing.expectEqual(@as(usize, 1), result.import_edges.len);
    try std.testing.expectEqual(@as(u32, 2), result.report.total_functions);
    try std.testing.expectEqual(@as(u32, 0), result.report.dead_functions);
}

test "temporary project supports check and gate evaluation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 0.0\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const check = try evaluateCheck(arena.allocator(), io, project_path);
    try std.testing.expect(check.check.pass());
    const saved = try saveGate(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(u32, 1), saved.report.file_count);
    const compared = try compareGate(arena.allocator(), io, project_path);
    try std.testing.expectEqual(@as(usize, 0), compared.violations.len);
}

test "temporary invalid rules are rejected before output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rules_dir = try tmp.dir.createDirPathOpen(io, ".tdlearn", .{});
    rules_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".tdlearn/rules.toml",
        .data = "[constraints]\nmin_quality = 2.0\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectError(error.InvalidRules, evaluateCheck(arena.allocator(), io, project_path));
}

test "temporary command helpers return typed setup errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var src_dir = try tmp.dir.createDirPathOpen(io, "src", .{});
    src_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const project_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectError(error.NoRulesFile, evaluateCheck(arena.allocator(), io, project_path));
    try std.testing.expectError(error.NoBaseline, compareGate(arena.allocator(), io, project_path));
}

test "filter source paths excludes non-source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all_paths = [_][]const u8{
        "src/main.zig",
        "README.md",
        "src/app.py",
        "package.json",
        "src/types.ts",
    };
    const source_paths = try filterSourcePaths(arena.allocator(), &all_paths);
    try std.testing.expectEqual(@as(usize, 3), source_paths.len);
    try std.testing.expectEqualStrings("src/main.zig", source_paths[0]);
    try std.testing.expectEqualStrings("src/app.py", source_paths[1]);
    try std.testing.expectEqualStrings("src/types.ts", source_paths[2]);
}

test "json error envelope has stable fields" {
    const payload = JsonError{
        .schema_version = json_schema_version,
        .tool_version = tool_version,
        .ok = false,
        .error_info = .{
            .code = "InvalidRules",
            .category = "configuration",
            .message = "InvalidRules",
        },
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"category\":\"configuration\"") != null);
}

test "hotspots are sorted by complexity score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const funcs = [_]core.types.FuncInfo{
        .{
            .name = "low",
            .start_line = 1,
            .end_line = 2,
            .line_count = 2,
            .cyclomatic_complexity = 2,
            .cognitive_complexity = 2,
        },
        .{
            .name = "high",
            .start_line = 1,
            .end_line = 20,
            .line_count = 20,
            .cyclomatic_complexity = 20,
            .cognitive_complexity = 30,
        },
    };
    const files = [_]metrics.dead_code.FileFuncs{
        .{ .file = "src/lib.zig", .contents = "", .funcs = &funcs },
    };
    const hotspots = try collectHotspots(arena.allocator(), &files);
    try std.testing.expectEqual(@as(usize, 2), hotspots.len);
    try std.testing.expectEqualStrings("high", hotspots[0].name);
    try std.testing.expectEqualStrings("low", hotspots[1].name);
}

test "depth path maps solver nodes to source paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/util.zig" };
    const edges = [_]core.types.ImportEdge{
        .{ .from_file = "src/main.zig", .to_file = "src/lib.zig" },
        .{ .from_file = "src/lib.zig", .to_file = "src/util.zig" },
    };
    const path = try buildDepthPath(arena.allocator(), &paths, &edges);
    try std.testing.expectEqualSlices([]const u8, &paths, path);
}

test "json payloads expose root and units" {
    try std.testing.expectEqualStrings("0-10000", jsonUnits().quality_signal);
    try std.testing.expectEqualStrings("lines", jsonUnits().line_counts);
    try std.testing.expectEqualStrings("edges", jsonUnits().edge_counts);
    try std.testing.expect(hasJsonFlag(&[_][]const u8{ "path", "--json" }));
    try std.testing.expect(!hasJsonFlag(&[_][]const u8{ "--", "--json" }));
    try std.testing.expectEqualStrings("usage", errorCategory("UnknownFlag"));
    try std.testing.expectEqualStrings("baseline", errorCategory("NoBaseline"));
}

test "parse options accepts flags and path" {
    const args = [_][]const u8{ "--json", "project" };
    const options = try parseOptions("scan", &args);
    try std.testing.expectEqualStrings("project", options.path);
    try std.testing.expect(options.json);
    try std.testing.expect(!options.save);
}

test "parse options supports escaped path" {
    const args = [_][]const u8{ "--", "-project" };
    const options = try parseOptions("scan", &args);
    try std.testing.expectEqualStrings("-project", options.path);
}

test "parse options rejects invalid combinations" {
    const unknown = [_][]const u8{"--bogus"};
    try std.testing.expectError(error.UnknownFlag, parseOptions("scan", &unknown));

    const extra = [_][]const u8{ "one", "two" };
    try std.testing.expectError(error.ExtraArgument, parseOptions("scan", &extra));

    const duplicate = [_][]const u8{ "--json", "--json" };
    try std.testing.expectError(error.DuplicateFlag, parseOptions("scan", &duplicate));

    const invalid_save = [_][]const u8{"--save"};
    try std.testing.expectError(error.InvalidFlag, parseOptions("scan", &invalid_save));
}
