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
        try runCheck(path);
    } else if (std.mem.eql(u8, command, "gate")) {
        try runGate(path);
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

fn runScan(io: std.Io, path: []const u8) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Scanning {s}...\n", .{path});

    // Walk filesystem (arena allocator handles all walker allocations)
    var walker = try analysis.walker.Walker.init(allocator, io, path);
    defer walker.deinit();

    const files = try walker.walk();

    const file_count = analysis.walker.Walker.countSourceFiles(files);
    const total_lines = analysis.walker.Walker.totalLines(files);

    std.debug.print("Found {d} files, {d} lines\n", .{ file_count, total_lines });

    // Compute health
    const report = try metrics.computeHealth(
        allocator,
        files,
        &.{},
        &.{},
    );

    // Print results
    std.debug.print("\n", .{});
    std.debug.print("Quality Signal: {d}/10000\n", .{report.quality_signal_int});
    std.debug.print("Bottleneck: {s}\n", .{report.bottleneck});
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

fn runCheck(path: []const u8) !void {
    std.debug.print("Checking rules in {s}...\n", .{path});
    // TODO: Implement rules checking
    std.debug.print("TODO: check not yet implemented\n", .{});
}

fn runGate(path: []const u8) !void {
    std.debug.print("Running quality gate on {s}...\n", .{path});
    // TODO: Implement quality gate
    std.debug.print("TODO: gate not yet implemented\n", .{});
}
