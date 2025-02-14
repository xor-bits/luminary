const std = @import("std");
const vk = @import("vk");
const vma = @import("vma");

const graphics = @import("../graphics.zig");
const dispatch = @import("dispatch.zig");
const BaseDispatch = dispatch.BaseDispatch;
const InstanceDispatch = dispatch.InstanceDispatch;
const Instance = graphics.Instance;
const Device = graphics.Device;
const Gpu = graphics.Gpu;

const log = std.log.scoped(.vma);

//

pub const Vma = struct {
    allocator: vma.VmaAllocator,

    const Self = @This();

    pub fn init(
        vkb: *BaseDispatch,
        vki: *InstanceDispatch,
        instance: Instance,
        gpu: *const Gpu,
        device: Device,
    ) !Self {
        const vk_functions = vma.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(vkb.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(vki.dispatch.vkGetDeviceProcAddr),
        };

        const allocator_create_info = vma.VmaAllocatorCreateInfo{
            .flags = vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT,
            .vulkanApiVersion = vma.VK_API_VERSION_1_2,
            .physicalDevice = @ptrFromInt(@intFromEnum(gpu.device)),
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

    pub fn deinit(self: Self) void {
        vma.vmaDestroyAllocator(self.allocator);
    }

    pub fn createImage(
        self: Self,
        image_create_info: *const vk.ImageCreateInfo,
        mem_flags: vk.MemoryPropertyFlags,
        mem_usage: MemoryUsage,
    ) !ImageAllocation {
        var image: vk.Image = undefined;
        var allocation: vma.VmaAllocation = undefined;

        const allocation_info = vma.VmaAllocationCreateInfo{
            .usage = @intFromEnum(mem_usage),
            .requiredFlags = mem_flags.toInt(),
        };

        const res = vma.vmaCreateImage(
            self.allocator,
            @ptrCast(image_create_info),
            @ptrCast(&allocation_info),
            @ptrCast(&image),
            &allocation,
            null,
        );
        switch (@as(vk.Result, @enumFromInt(res))) {
            vk.Result.success => {},
            else => |err| {
                log.err("vmaCreateImage returned {}", .{err});
                return error.AllocationError;
            },
        }

        return ImageAllocation{
            .allocation = .{ .inner = allocation },
            .image = image,
        };
    }

    pub fn destroyImage(self: Self, image: ImageAllocation) void {
        vma.vmaDestroyImage(self.allocator, @ptrFromInt(@intFromEnum(image.image)), image.allocation.inner);
    }
};

pub const MemoryUsage = enum(u32) {
    unknown = vma.VMA_MEMORY_USAGE_UNKNOWN,
    gpu_only = vma.VMA_MEMORY_USAGE_GPU_ONLY,
    cpu_only = vma.VMA_MEMORY_USAGE_CPU_ONLY,
    cpu_to_gpu = vma.VMA_MEMORY_USAGE_CPU_TO_GPU,
    gpu_to_cpu = vma.VMA_MEMORY_USAGE_GPU_TO_CPU,
    cpu_copy = vma.VMA_MEMORY_USAGE_CPU_COPY,
    gpu_lazily_allocated = vma.VMA_MEMORY_USAGE_GPU_LAZILY_ALLOCATED,
    auto = vma.VMA_MEMORY_USAGE_AUTO,
    auto_prefer_device = vma.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
    auto_prefer_host = vma.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
    max_enum = vma.VMA_MEMORY_USAGE_MAX_ENUM,
};

pub const ImageAllocation = struct {
    allocation: Allocation,
    image: vk.Image,
};

pub const Allocation = struct {
    inner: vma.VmaAllocation,
};
