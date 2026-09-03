const std = @import("std");
const core = @import("core");
const metrics = @import("metrics");
const analysis = @import("analysis");

pub fn main(init: std.process.Init) !void {
    _ = init.gpa;

    // Parse args using iterator
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();
    // Skip the program name (first arg)
    _ = args_iter.next();

    // Get the command (second arg)
    const command_opt = args_iter.next();
    if (command_opt == null) {
        printUsage();
        return;
    }
    const command = command_opt.?;

    // Get optional path argument (third arg)
    const path_opt = args_iter.next();
    const path: []const u8 = if (path_opt) |p| p else ".";

    if (std.mem.eql(u8, command, "scan")) {
        try runScan(init.io, path);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(init.io, path);
    } else if (std.mem.eql(u8, command, "gate")) {
        try runGate(init.io, path);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("tdlearn 0.1.0\n", .{});
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
        return error.InvalidCommand;
    }
}

fn printUsage() void {
    std.debug.print(
        \\tdlearn — Codebase structural quality sensor
        \\
        \\Usage:
        \\  tdlearn scan [path]     Scan a project and print quality signal
        \\  tdlearn check [path]    Check rules (exits 0 or 1)
        \\  tdlearn gate [path]     Quality gate for CI
        \\  tdlearn --help          Show this help
        \\  tdlearn --version       Show version
        \\
    , .{});
}

fn readFileOrNull(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 2 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const bytes_read = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..bytes_read];
}

/// Full analysis result shared by scan/check/gate commands.
const Analysis = struct {
    report: metrics.HealthReport,
    import_edges: []const core.types.ImportEdge,
    file_paths: []const []const u8,
    max_file_lines: u32,
    max_fn_lines: u32,
};

/// Run walker + graph builder + function extraction + health metrics.
/// All allocations come from `arena` (caller-owned).
fn runAnalysis(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Analysis {
    var walker = try analysis.walker.Walker.init(arena, io, path);
    defer walker.deinit();

    const files = try walker.walk();

    const file_paths = try analysis.walker.Walker.flattenFiles(files, arena);
    const import_edges = try analysis.graph_builder.GraphBuilder.buildImportEdges(arena, io, file_paths);

    // Extract functions per file; track size extremes
    var file_funcs = std.ArrayList(metrics.dead_code.FileFuncs).empty;
    var max_file_lines: u32 = 0;
    var max_fn_lines: u32 = 0;
    for (file_paths) |fpath| {
        const lang = analysis.graph_builder.GraphBuilder.detectLangForFile(fpath);
        if (std.mem.eql(u8, lang, "unknown")) continue;
        const contents = (readFileOrNull(arena, io, fpath)) orelse continue;
        const funcs = try analysis.functions.FunctionExtractor.extract(arena, contents, lang);
        try file_funcs.append(arena, .{ .file = fpath, .contents = contents, .funcs = funcs });

        if (findFileNode(files, fpath)) |node| {
            if (node.lines > max_file_lines) max_file_lines = node.lines;
        }
        for (funcs) |f| {
            if (f.line_count > max_fn_lines) max_fn_lines = f.line_count;
        }
    }

    const report = try metrics.computeHealth(
        arena,
        files,
        import_edges,
        &.{},
        file_funcs.items,
    );

    return .{
        .report = report,
        .import_edges = import_edges,
        .file_paths = file_paths,
        .max_file_lines = max_file_lines,
        .max_fn_lines = max_fn_lines,
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

fn runScan(io: std.Io, path: []const u8) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("Scanning {s}...\n", .{path});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const result = try runAnalysis(arena.allocator(), io, path);
    const report = result.report;

    std.debug.print("Found {d} files, {d} lines\n", .{ report.file_count, report.line_count });
    std.debug.print("\n", .{});
    std.debug.print("Quality Signal: {d}/10000\n", .{report.quality_signal_int});
    std.debug.print("Bottleneck: {s}\n", .{report.bottleneck});
    std.debug.print("Import edges: {d}\n", .{result.import_edges.len});
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
}

fn runCheck(io: std.Io, path: []const u8) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const aa = arena.allocator();

    // Load rules from <path>/.tdlearn/rules.toml
    const rules_path = try std.fmt.allocPrint(aa, "{s}/.tdlearn/rules.toml", .{path});
    const rules_contents = readFileOrNull(aa, io, rules_path) orelse {
        std.debug.print("No rules file at {s} — nothing to check.\n", .{rules_path});
        std.debug.print("Create .tdlearn/rules.toml to define constraints.\n", .{});
        return error.NoRulesFile;
    };

    const config = try core.rules.parseRules(aa, rules_contents);

    // Run analysis
    const result = try runAnalysis(aa, io, path);
    const report = result.report;

    // Build check input
    const edges = try aa.alloc(core.rules.CheckInput.Edge, result.import_edges.len);
    for (result.import_edges, 0..) |e, i| {
        edges[i] = .{ .from = e.from_file, .to = e.to_file };
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

    const check = try core.rules.checkRules(aa, &config, &input);

    // Print results
    std.debug.print("tdlearn check — {d} rules checked\n", .{check.rules_checked});
    std.debug.print("Quality: {d}/10000\n", .{report.quality_signal_int});

    if (check.violations.len == 0) {
        std.debug.print("All rules passed\n", .{});
        return;
    }

    for (check.violations) |v| {
        std.debug.print("x [{s}] {s}: {s}\n", .{ v.severity.label(), v.rule, v.message });
        if (v.files.len >= 2) {
            std.debug.print("    {s} -> {s}\n", .{ v.files[0], v.files[1] });
        }
    }

    std.debug.print("\n{d} violation(s)\n", .{check.violations.len});
    return error.CheckFailed;
}

fn runGate(io: std.Io, path: []const u8) !void {
    std.debug.print("Running quality gate on {s}...\n", .{path});
    _ = io;
    // TODO: Implement quality gate
    std.debug.print("TODO: gate not yet implemented\n", .{});
}
