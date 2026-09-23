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

    // ── Run command ───────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run tdlearn");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests ────────────────────────────────────────────────
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const metrics_tests = b.addTest(.{
        .root_module = metrics_mod,
    });
    const run_metrics_tests = b.addRunArtifact(metrics_tests);

    const analysis_tests = b.addTest(.{
        .root_module = analysis_mod,
    });
    const run_analysis_tests = b.addRunArtifact(analysis_tests);

    const main_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_metrics_tests.step);
    test_step.dependOn(&run_analysis_tests.step);
    test_step.dependOn(&run_main_tests.step);
}
