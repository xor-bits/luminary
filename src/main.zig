const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");

const graphics = @import("graphics.zig");

//

const log = std.log.scoped(.main);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

//

pub fn main() !void {
    var major: i32 = 0;
    var minor: i32 = 0;
    var rev: i32 = 0;
    glfw.getVersion(&major, &minor, &rev);
    log.debug("GLFW {}.{}.{}", .{ major, minor, rev });

    try glfw.init();
    defer glfw.terminate();
    log.info("GLFW init successful", .{});

    if (!glfw.vulkanSupported()) {
        log.err("GLFW could not find libvulkan", .{});
        return error.NoVulkan;
    }

    const extent = vk.Extent2D{
        .width = 800,
        .height = 600,
    };

    glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
    const window: *glfw.Window = try glfw.createWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        "luminary",
        null,
        null,
    );
    defer glfw.destroyWindow(window);

    _ = try graphics.Graphics.init(allocator, window);

    log.info("running main loop", .{});

    while (!glfw.windowShouldClose(window)) {
        if (glfw.getKey(window, glfw.KeyEscape) == glfw.Press) {
            glfw.setWindowShouldClose(window, true);
        }

        glfw.pollEvents();
    }
}
