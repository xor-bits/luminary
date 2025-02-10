const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_xml = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_gen_cmd = b.addRunArtifact(vk_gen);
    vk_gen_cmd.addFileArg(vk_xml);
    const vk = b.addModule("vulkan-zig", .{
        .root_source_file = vk_gen_cmd.addOutputFileArg("vk.zig"),
    });

    const glfw = b.dependency("glfw", .{}).module("glfw");

    const exe = b.addExecutable(.{
        .name = "luminary",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("glfw");
    exe.root_module.addImport("vk", vk);
    exe.root_module.addImport("glfw", glfw);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
