pub const std = @import("std");
pub const vk = @import("vk");
pub const glfw = @import("glfw");

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

    instance: Instance,
    surface: vk.SurfaceKHR,
    gpu: vk.PhysicalDevice,

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
        try self.createDevice();
        log.debug("device created", .{});

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

    fn createDevice(self: *Self) !void {
        _ = self;
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

            if (best_gpu == null) {
                if (is_suitable) |new_gpu| {
                    best_gpu = new_gpu;
                }
            }
        }

        const gpu = best_gpu orelse return error.NoSuitableGpus;
        self.gpu = gpu.gpu;

        return gpu;
    }

    const GpuCandidate = struct {
        gpu: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
        graphics_family: u32,
        present_family: u32,
        transfer_family: u32,
        compute_family: u32,
    };

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
