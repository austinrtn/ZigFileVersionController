const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});


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
}
