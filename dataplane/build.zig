const std = @import("std");

/// The one place the version is written (with `control/mix.exs` for the
/// control plane); the code gets it through the `build_options` module.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release artifacts are built with -Dstrip=true: the debug information is
    // most of the binary's size, and a panic still names itself in one line.
    const strip = b.option(bool, "strip", "Omit debug information from the binary") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "omnigate-dp",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the data plane");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
