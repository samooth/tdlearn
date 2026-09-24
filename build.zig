const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core library ──────────────────────────────────────────────
    const core_mod = b.addModule("tdlearn-core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_lib = b.addLibrary(.{
        .name = "tdlearn-core",
        .root_module = core_mod,
    });
    b.installArtifact(core_lib);

    // ── Metrics module ────────────────────────────────────────────
    const metrics_mod = b.createModule(.{
        .root_source_file = b.path("src/metrics/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_mod.addImport("core", core_mod);

    // ── Analysis module ───────────────────────────────────────────
    const analysis_mod = b.createModule(.{
        .root_source_file = b.path("src/analysis/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    analysis_mod.addImport("core", core_mod);

    // ── Binary ────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("core", core_mod);
    exe_mod.addImport("metrics", metrics_mod);
    exe_mod.addImport("analysis", analysis_mod);

    const exe = b.addExecutable(.{
        .name = "tdlearn",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    addRunCommand(b, exe);
    addTestStep(b, core_mod, metrics_mod, analysis_mod, exe_mod);
}

fn addRunCommand(b: *std.Build, exe: anytype) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tdlearn");
    run_step.dependOn(&run_cmd.step);
}

fn addTestStep(b: *std.Build, core_mod: anytype, metrics_mod: anytype, analysis_mod: anytype, exe_mod: anytype) void {
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const metrics_tests = b.addTest(.{ .root_module = metrics_mod });
    const analysis_tests = b.addTest(.{ .root_module = analysis_mod });
    const main_tests = b.addTest(.{ .root_module = exe_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(metrics_tests).step);
    test_step.dependOn(&b.addRunArtifact(analysis_tests).step);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
