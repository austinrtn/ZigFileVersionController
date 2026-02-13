const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("FileCacheTest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "FileCacheTest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "FileCacheTest", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArg(b.pathFromRoot("."));

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const update_cache_exe= b.addExecutable(.{
        .name = "Update_Cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/vc_cacher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(update_cache_exe);
    const update_cache_step = b.step("vc-cache", "Update File Version Control Cache");
    const update_cache_cmd= b.addRunArtifact(update_cache_exe);
    update_cache_step.dependOn(&update_cache_cmd.step);
    update_cache_cmd.addArg(b.pathFromRoot("."));
    if(b.args) |args| update_cache_cmd.addArgs(args);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const version_ctrl_exe = b.addExecutable(.{
        .name = "Version Control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/vc_updater.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const version_ctrl_step = b.step("vc-update", "Download and overwrite out-of-date files");
    const version_ctrl_cmd = b.addRunArtifact(version_ctrl_exe);
    version_ctrl_step.dependOn(&version_ctrl_cmd.step);
    version_ctrl_cmd.addArg(b.pathFromRoot("."));

    if (b.args) |args| {
        version_ctrl_cmd.addArgs(args);
    }
    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
