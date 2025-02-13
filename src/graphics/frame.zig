const std = @import("std");
const vk = @import("vk");

const graphics = @import("../graphics.zig");
const Device = graphics.Device;

//

pub const Frame = struct {
    frame: usize = 0,
    frames: [2]FrameData,

    const FrameData = struct {
        command_pool: vk.CommandPool,
        main_cbuf: vk.CommandBuffer,
        index: u32,

        /// render cmds need to wait for the swapchain image
        swapchain_sema: vk.Semaphore,
        /// used to present the img once its rendered
        render_sema: vk.Semaphore,
        /// used to wait for this frame to be complete
        render_fence: vk.Fence,

        pub fn wait(self: *@This(), device: Device) !void {
            if (try device.waitForFences(
                1,
                @ptrCast(&self.render_fence),
                vk.TRUE,
                1_000_000_000,
            ) != .success) {
                return error.DrawTimeout;
            }
            try device.resetFences(1, @ptrCast(&self.render_fence));
        }
    };

    const Self = @This();

    pub fn init(device: Device, graphics_queue_family: u32) !Self {
        var frames: [2]FrameData = undefined;

        for (&frames, 0..) |*frame, i| {
            // FIXME: leak on err

            frame.index = @truncate(i);

            frame.command_pool = try device.createCommandPool(&vk.CommandPoolCreateInfo{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = graphics_queue_family,
            }, null);

            try device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
                .command_pool = frame.command_pool,
                .command_buffer_count = 1,
                .level = .primary,
            }, @ptrCast(&frame.main_cbuf));

            frame.render_fence = try device.createFence(&vk.FenceCreateInfo{
                // they are already ready for rendering
                .flags = .{ .signaled_bit = true },
            }, null);

            frame.swapchain_sema = try device.createSemaphore(&.{}, null);
            frame.render_sema = try device.createSemaphore(&.{}, null);
        }

        return Self{
            .frames = frames,
        };
    }

    pub fn deinit(self: *Self, device: Device) void {
        for (&self.frames) |*frame| {
            device.destroySemaphore(frame.render_sema, null);
            device.destroySemaphore(frame.swapchain_sema, null);
            device.destroyFence(frame.render_fence, null);

            device.destroyCommandPool(frame.command_pool, null);
        }
    }

    pub fn next(self: *Self) *FrameData {
        const idx = self.frame;
        self.frame = (idx + 1) % self.frames.len;
        return &self.frames[idx];
    }
};
