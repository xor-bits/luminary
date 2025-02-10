pub const std = @import("std");
pub const vk = @import("vk");
pub const glfw = @import("glfw");
pub const vma = @import("vma");

//

const log = std.log.scoped(.graphics);

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);
const CommandBuffer = vk.CommandBufferProxy(apis);
const Queue = vk.QueueProxy(apis);

pub const Allocator = std.mem.Allocator;

//

pub const Graphics = struct {
    allocator: Allocator,

    window: *glfw.Window,

    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: Instance,
    surface: vk.SurfaceKHR,
    gpu: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    device: Device,

    graphics_queue: Queue,
    present_queue: Queue,
    transfer_queue: Queue,
    compute_queue: Queue,

    vma: vma.VmaAllocator,

    const Self = @This();

    pub fn init(allocator: Allocator, window: *glfw.Window) !*Self {
        const self = try allocator.create(Graphics);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.window = window;
        self.vkb = try BaseDispatch.load(getInstanceProcAddress);

        log.debug("creating instance ..", .{});
        try self.createInstance();
        errdefer self.instance.destroyInstance(null);
        log.debug("instance created", .{});

        log.debug("creating surface ..", .{});
        try self.createSurface();
        errdefer self.instance.destroySurfaceKHR(self.surface, null);
        log.debug("surface created", .{});

        log.debug("picking GPU ..", .{});
        const gpu = try self.pickGpu();
        log.info("GPU picked: {s}", .{std.mem.sliceTo(&gpu.props.device_name, 0)});

        log.debug("creating device ..", .{});
        try self.createDevice(gpu);
        errdefer self.device.destroyDevice(null);
        log.debug("device created", .{});

        const vk_functions = vma.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(self.vkb.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(self.vki.dispatch.vkGetDeviceProcAddr),
        };

        const allocator_create_info = vma.VmaAllocatorCreateInfo{
            .flags = vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT,
            .vulkanApiVersion = vma.VK_API_VERSION_1_2,
            .physicalDevice = @ptrFromInt(@intFromEnum(self.gpu)),
            .device = @ptrFromInt(@intFromEnum(self.device.handle)),
            .instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
            .pVulkanFunctions = &vk_functions,
        };

        const res = vma.vmaCreateAllocator(&allocator_create_info, &self.vma);
        if (res != @intFromEnum(vk.Result.success)) {
            return error.VmaInitFailed;
        }
        errdefer vma.vmaDestroyAllocator(self.vma);

        return self;
    }

    fn createInstance(self: *Self) !void {
        var glfw_exts_count: u32 = 0;
        const glfw_exts = glfw.getRequiredInstanceExtensions(&glfw_exts_count);

        const layers = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.allocator);
        defer self.allocator.free(layers);

        const vk_layer_khronos_validation = "VK_LAYER_KHRONOS_validation";
        var vk_layer_khronos_validation_found = false;
        for (layers) |layer| {
            const name = std.mem.sliceTo(&layer.layer_name, 0);
            log.debug("layer: {s}", .{name});

            if (std.mem.eql(u8, name, vk_layer_khronos_validation)) {
                vk_layer_khronos_validation_found = true;
                break;
            }
        }

        const instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = "luminary",
                .application_version = vk.makeApiVersion(0, 0, 0, 0),
                .p_engine_name = "luminary",
                .engine_version = vk.makeApiVersion(0, 0, 0, 0),
                .api_version = vk.API_VERSION_1_2,
            },
            .enabled_extension_count = glfw_exts_count,
            .pp_enabled_extension_names = @ptrCast(glfw_exts),
            .enabled_layer_count = @intFromBool(vk_layer_khronos_validation_found),
            .pp_enabled_layer_names = &.{vk_layer_khronos_validation},
        }, null);

        self.vki = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);

        self.instance = Instance.init(instance, &self.vki);
        errdefer self.instance.destroyInstance(null);
    }

    fn createDevice(self: *Self, gpu: GpuCandidate) !void {
        log.debug("gpu={any}", .{gpu});

        const priority = [_]f32{1};
        var queue_create_infos_buf = [_]vk.DeviceQueueCreateInfo{
            vk.DeviceQueueCreateInfo{
                .queue_family_index = gpu.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = gpu.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = gpu.transfer_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = gpu.compute_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        std.sort.pdq(vk.DeviceQueueCreateInfo, queue_create_infos_buf[0..], {}, struct {
            fn inner(_: void, a: vk.DeviceQueueCreateInfo, b: vk.DeviceQueueCreateInfo) bool {
                return a.queue_family_index < b.queue_family_index;
            }
        }.inner);

        var queue_create_infos = std.ArrayListAlignedUnmanaged(vk.DeviceQueueCreateInfo, null){
            .items = queue_create_infos_buf[0..],
            .capacity = queue_create_infos_buf.len,
        };

        // remove duplicate queue families
        for (1..queue_create_infos.items.len) |i| {
            const j = queue_create_infos.items.len - i;
            if (queue_create_infos.items[j].queue_family_index == queue_create_infos.items[j - 1].queue_family_index) {
                _ = queue_create_infos.orderedRemove(j);
            }
        }

        for (queue_create_infos.items) |queue_create_info| {
            log.debug("queue: {}", .{
                queue_create_info.queue_family_index,
            });
        }

        const device = try self.instance.createDevice(self.gpu, &vk.DeviceCreateInfo{
            .queue_create_info_count = @truncate(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .enabled_extension_count = @truncate(required_device_extensions.len),
            .pp_enabled_extension_names = &required_device_extensions,
        }, null);

        self.vkd = try DeviceDispatch.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.device = Device.init(device, &self.vkd);
        errdefer self.device.destroyDevice(null);

        const graphics_queue = self.device.getDeviceQueue(gpu.graphics_family, 0);
        const present_queue = self.device.getDeviceQueue(gpu.present_family, 0);
        const transfer_queue = self.device.getDeviceQueue(gpu.transfer_family, 0);
        const compute_queue = self.device.getDeviceQueue(gpu.compute_family, 0);

        self.graphics_queue = Queue.init(graphics_queue, &self.vkd);
        self.present_queue = Queue.init(present_queue, &self.vkd);
        self.transfer_queue = Queue.init(transfer_queue, &self.vkd);
        self.compute_queue = Queue.init(compute_queue, &self.vkd);
    }

    fn pickGpu(self: *Self) !GpuCandidate {
        const gpus = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(gpus);

        // TODO: maybe pick the gpu based on the largest dedicated memory
        var best_gpu: ?GpuCandidate = null;

        for (gpus) |gpu| {
            const props = self.instance.getPhysicalDeviceProperties(gpu);
            const is_suitable = try self.isSuitable(gpu, props);
            log.debug("gpu ({s}): {s}", .{ if (is_suitable != null) "suitable" else "not suitable", std.mem.sliceTo(&props.device_name, 0) });

            const new_gpu = is_suitable orelse continue;

            if (best_gpu) |*current| {
                if (current.score < new_gpu.score) {
                    best_gpu = new_gpu;
                }
            } else {
                best_gpu = new_gpu;
            }
        }

        const gpu = best_gpu orelse return error.NoSuitableGpus;
        self.gpu = gpu.gpu;
        self.props = gpu.props;
        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(gpu.gpu);

        return gpu;
    }

    const GpuCandidate = struct {
        gpu: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
        score: usize,
        graphics_family: u32,
        present_family: u32,
        transfer_family: u32,
        compute_family: u32,
    };

    fn scoreOf(props: *const vk.PhysicalDeviceProperties) usize {
        return switch (props.device_type) {
            .discrete_gpu => 5,
            .virtual_gpu => 4,
            .integrated_gpu => 3,
            .cpu => 2,
            .other => 1,
            else => 0,
        };
    }

    fn isSuitable(
        self: *Self,
        gpu: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
    ) !?GpuCandidate {
        const exts = try self.instance.enumerateDeviceExtensionPropertiesAlloc(gpu, null, self.allocator);
        defer self.allocator.free(exts);

        if (!hasExtensions(&required_device_extensions, exts)) {
            return null;
        }

        var format_count: u32 = undefined;
        var present_mode_count: u32 = undefined;

        _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(gpu, self.surface, &format_count, null);
        _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(gpu, self.surface, &present_mode_count, null);

        if (format_count == 0 or present_mode_count == 0) {
            return null;
        }

        const queue_family_props = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(gpu, self.allocator);
        defer self.allocator.free(queue_family_props);

        const graphics_family = try self.pickQueueFamily(
            gpu,
            queue_family_props,
            .{ .graphics_bit = true },
            false,
        ) orelse return null;
        const present_family = try self.pickQueueFamily(
            gpu,
            queue_family_props,
            .{},
            true,
        ) orelse return null;
        const transfer_family = try self.pickQueueFamily(
            gpu,
            queue_family_props,
            .{ .transfer_bit = true },
            false,
        ) orelse return null;
        const compute_family = try self.pickQueueFamily(
            gpu,
            queue_family_props,
            .{ .compute_bit = true },
            false,
        ) orelse return null;

        return GpuCandidate{
            .gpu = gpu,
            .score = scoreOf(&props),
            .props = props,
            .graphics_family = graphics_family,
            .present_family = present_family,
            .transfer_family = transfer_family,
            .compute_family = compute_family,
        };
    }

    fn pickQueueFamily(
        self: *Self,
        gpu: vk.PhysicalDevice,
        queue_props: []const vk.QueueFamilyProperties,
        contains: vk.QueueFlags,
        check_present: bool,
    ) !?u32 {
        var queue_index: u32 = 0;
        var found = false;
        // find the most specific graphics queue
        // because the more generic the queue is, the slower it usually is
        // TODO: maybe try also picking queues so that each task has its own dedicated queue if possible
        var queue_generality: usize = std.math.maxInt(usize);
        for (queue_props, 0..) |queue_prop, i| {
            const index: u32 = @truncate(i);
            const has_present = try self.instance.getPhysicalDeviceSurfaceSupportKHR(gpu, index, self.surface) == vk.TRUE;
            const this_queue_generality = @popCount(queue_prop.queue_flags.intersect(.{
                .graphics_bit = true,
                .compute_bit = true,
                .transfer_bit = true,
            }).toInt()) + @intFromBool(has_present);

            // log.info("queue present={} graphics={} compute={} transfer={}", .{
            //     has_present,
            //     queue_prop.queue_flags.graphics_bit,
            //     queue_prop.queue_flags.compute_bit,
            //     queue_prop.queue_flags.transfer_bit,
            // });

            if (queue_prop.queue_flags.contains(contains) and
                this_queue_generality <= queue_generality)
            {
                if (check_present and !has_present) {
                    continue;
                }

                queue_index = index;
                queue_generality = this_queue_generality;
                found = true;
            }
        }

        if (!found) {
            return null;
        }

        return queue_index;
    }

    fn hasExtensions(required: []const [*:0]const u8, got: []vk.ExtensionProperties) bool {
        for (required) |required_ext| {
            const required_name = std.mem.span(required_ext);
            for (got) |got_ext| {
                if (std.mem.eql(u8, required_name, std.mem.sliceTo(&got_ext.extension_name, 0))) {
                    break;
                }
            } else {
                return false;
            }
        }

        return true;
    }

    fn createSurface(self: *Self) !void {
        if (.success != glfw.createWindowSurface(@intFromEnum(self.instance.handle), self.window, null, @ptrCast(&self.surface))) {
            return error.SurfaceInitFailed;
        }
    }

    fn getInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) ?glfw.VKproc {
        return glfw.getInstanceProcAddress(@intFromEnum(instance), procname);
    }
};
