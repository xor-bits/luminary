const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const comp_compile = b.addSystemCommand(&.{ "glslc", "-DCOMP=1", "-fshader-stage=comp" });
    comp_compile.addFileArg(b.path("src/graphics/shader.glsl"));
    comp_compile.addArg("-o");
    const shader_comp_spirv = comp_compile.addOutputFileArg("shader.comp.spirv");

    const vk_dep = b.dependency("vulkan_headers", .{});
    const vk_zig_dep = b.dependency("vulkan_zig", .{});
    const glfw_dep = b.dependency("glfw", .{});
    const vma_dep = b.dependency("vma", .{});

    const vk_xml = vk_dep.path("registry/vk.xml");
    const vk_gen = vk_zig_dep.artifact("vulkan-zig-generator");
    const vk_gen_cmd = b.addRunArtifact(vk_gen);
    vk_gen_cmd.addFileArg(vk_xml);
    const vk = b.addModule("vulkan-zig", .{
        .root_source_file = vk_gen_cmd.addOutputFileArg("vk.zig"),
    });

    const glfw = glfw_dep.module("glfw");

    const wf = b.addNamedWriteFiles("vma-impl-src");
    const vma_impl_src = wf.add("vk_mem_alloc.cpp",
        \\#define VMA_IMPLEMENTATION
        \\#define VMA_VULKAN_VERSION 1002000
        \\#include "vk_mem_alloc.h"
    );

    const vma_impl = b.addStaticLibrary(.{
        .name = "vma-impl",
        .target = target,
        .optimize = optimize,
    });
    vma_impl.linkLibCpp();
    vma_impl.addCSourceFile(.{
        .file = vma_impl_src,
        .flags = &.{
            "--std=c++17",
            "-DVMA_STATIC_VULKAN_FUNCTIONS=0",
            "-DVMA_DYNAMIC_VULKAN_FUNCTIONS=1",
        },
    });
    vma_impl.addIncludePath(vk_dep.path("include"));
    vma_impl.addIncludePath(vma_dep.path("include"));
    vma_impl.installHeadersDirectory(vma_dep.path("include"), "", .{});
    // b.installArtifact(vma_impl);

    const vma_h = b.addTranslateC(.{
        .root_source_file = vma_dep.path("include/vk_mem_alloc.h"),
        .target = target,
        .optimize = optimize,
    });
    // HACK: addIncludeDir and getPath instead of addIncludePath until zig 0.14
    vma_h.addIncludeDir(vk_dep.path("include").getPath(b));
    vma_h.addIncludeDir(vma_dep.path("include").getPath(b));
    const i = b.getInstallStep();
    const s = b.addInstallFile(vma_h.getOutput(), "vma.zig");
    i.dependOn(&s.step);

    const vma = vma_h.createModule();
    vma.linkLibrary(vma_impl);

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
    exe.root_module.addImport("vma", vma);
    exe.root_module.addAnonymousImport("shader-comp", .{ .root_source_file = shader_comp_spirv });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
