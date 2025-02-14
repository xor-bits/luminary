pub const std = @import("std");
pub const vma = @import("vma");
pub const vk = @import("vk");

const graphics = @import("../graphics.zig");
const dispatch = @import("dispatch.zig");
const BaseDispatch = dispatch.BaseDispatch;
const InstanceDispatch = dispatch.InstanceDispatch;
const Instance = graphics.Instance;
const Device = graphics.Device;

//

pub const Vma = struct {
    allocator: vma.VmaAllocator,

    const Self = @This();

    pub fn init(
        vkb: *BaseDispatch,
        vki: *InstanceDispatch,
        instance: Instance,
        gpu: vk.PhysicalDevice,
        device: Device,
    ) !Self {
        const vk_functions = vma.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(vkb.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(vki.dispatch.vkGetDeviceProcAddr),
        };

        const allocator_create_info = vma.VmaAllocatorCreateInfo{
            .flags = vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT,
            .vulkanApiVersion = vma.VK_API_VERSION_1_2,
            .physicalDevice = @ptrFromInt(@intFromEnum(gpu)),
            .device = @ptrFromInt(@intFromEnum(device.handle)),
            .instance = @ptrFromInt(@intFromEnum(instance.handle)),
            .pVulkanFunctions = &vk_functions,
        };

        var allocator: vma.VmaAllocator = undefined;
        const res = vma.vmaCreateAllocator(&allocator_create_info, &allocator);
        if (res != @intFromEnum(vk.Result.success)) {
            return error.VmaInitFailed;
        }
        errdefer vma.vmaDestroyAllocator(allocator);

        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        vma.vmaDestroyAllocator(self.allocator);
    }
};
