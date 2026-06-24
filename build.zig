const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "skill-importer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the skill-importer CLI");
    run_step.dependOn(&run_cmd.step);

    // Expose the built binary's path to the integration tests so they can exec
    // the real CLI against disposable temp roots (cli-clean-room-cli Phase 6:
    // "integration tests that exec the built binary must use disposable temp
    // roots only — never real user roots").
    const build_options = b.addOptions();
    build_options.addOptionPath("exe_path", exe.getEmittedBin());

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", build_options);
    // Some POSIX-only tests call libc `mkfifo` via `extern "c"`. macOS links
    // libSystem (libc) by default, but Linux requires it to be explicit, so
    // link libc into the test module to keep `zig build test` portable.
    test_module.link_libc = true;

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    // The CLI integration tests exec the built binary, so build it first.
    run_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);
}
