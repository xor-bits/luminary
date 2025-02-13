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
    vk.extensions.ext_debug_utils,
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
    debug_messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    gpu: GpuCandidate,
    device: Device,

    graphics_queue: Queue,
    present_queue: Queue,
    transfer_queue: Queue,
    compute_queue: Queue,

    vma: vma.VmaAllocator,

    swapchain: vk.SwapchainKHR,
    swapchain_format: vk.Format,
    swapchain_extent: vk.Extent2D,
    swapchain_images: []SwapchainImage,

    frame: usize,
    frame_data: [2]FrameData,

    const Self = @This();

    const SwapchainImage = struct {
        image: vk.Image,
        view: vk.ImageView,
    };

    const FrameData = struct {
        command_pool: vk.CommandPool,
        main_cbuf: vk.CommandBuffer,
    };

    pub fn init(allocator: Allocator, window: *glfw.Window) !*Self {
        const self = try allocator.create(Graphics);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.window = window;
        self.vkb = try BaseDispatch.load(getInstanceProcAddress);

        log.debug("creating instance ..", .{});
        try self.createInstance();
        errdefer self.deinitInstance();
        log.debug("instance created", .{});

        log.debug("creating debug messenger ..", .{});
        try self.createDebugMessenger();
        errdefer self.deinitDebugMessenger();
        log.debug("debug messenger created", .{});

        log.debug("creating surface ..", .{});
        try self.createSurface();
        errdefer self.deinitSurface();
        log.debug("surface created", .{});

        log.debug("picking GPU ..", .{});
        try self.pickGpu();
        log.info("GPU picked: {s}", .{std.mem.sliceTo(&self.gpu.props.device_name, 0)});

        log.debug("creating device ..", .{});
        try self.createDevice();
        errdefer self.deinitDevice();
        log.debug("device created", .{});

        log.debug("creating vma ..", .{});
        try self.createVma();
        errdefer self.deinitVma();
        log.debug("vma created", .{});

        log.debug("creating swapchain ..", .{});
        try self.createSwapchain(.null_handle);
        errdefer self.deinitSwapchain();
        log.debug("swapchain created", .{});

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.deinitSwapchain();
        self.deinitVma();
        self.deinitDevice();
        self.deinitSurface();
        self.deinitDebugMessenger();
        self.deinitInstance();

        self.allocator.destroy(self);
    }

    fn deinitSwapchain(self: *Self) void {
        for (self.swapchain_images) |*image| {
            self.device.destroyImageView(image.view, null);
        }
        self.allocator.free(self.swapchain_images);

        self.device.destroySwapchainKHR(self.swapchain, null);
    }

    fn deinitVma(self: *Self) void {
        vma.vmaDestroyAllocator(self.vma);
    }

    fn deinitDevice(self: *Self) void {
        self.device.destroyDevice(null);
    }

    fn deinitSurface(self: *Self) void {
        self.instance.destroySurfaceKHR(self.surface, null);
    }

    fn deinitDebugMessenger(self: *Self) void {
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    }

    fn deinitInstance(self: *Self) void {
        self.instance.destroyInstance(null);
    }

    fn currentFrame(self: *Self) *FrameData {
        return &self.frame_data[self.frame % self.frame_data.len];
    }

    fn createSwapchain(self: *Self, old_swapchain: vk.SwapchainKHR) !void {
        const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.gpu.gpu, self.surface, self.allocator);
        const surface_format = try preferred_format(surface_formats);

        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.gpu.gpu, self.surface, self.allocator);
        const present_mode = try preferred_present_mode(present_modes);

        var w: i32 = undefined;
        var h: i32 = undefined;
        glfw.getFramebufferSize(self.window, &w, &h);
        if (w <= 0 or h <= 0) {
            return error.InvalidWindowSize;
        }

        const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.gpu.gpu, self.surface);

        const extent = vk.Extent2D{
            .width = @max(@min(@as(u32, @intCast(w)), caps.max_image_extent.width), caps.min_image_extent.width),
            .height = @max(@min(@as(u32, @intCast(h)), caps.max_image_extent.height), caps.min_image_extent.height),
        };

        var create_info = vk.SwapchainCreateInfoKHR{
            .surface = self.surface,
            .image_sharing_mode = undefined,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .present_mode = present_mode,
            .image_extent = extent,
            .min_image_count = 0,
            .image_array_layers = 1,
            .image_usage = .{
                // .color_attachment_bit = true, // render to a custom image and copy it over
                .transfer_dst_bit = true,
            },
            .pre_transform = .{ .identity_bit_khr = true },
            .composite_alpha = .{ .opaque_bit_khr = true },
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain,
        };

        create_info.min_image_count = caps.min_image_count + 1;
        if (caps.max_image_count != 0 and create_info.min_image_count > caps.max_image_count) {
            // max image count 0 means there is no max
            create_info.min_image_count = caps.max_image_count;
        }

        const queue_family_indices = .{ self.gpu.graphics_family, self.gpu.present_family };
        if (self.gpu.graphics_family == self.gpu.present_family) {
            create_info.image_sharing_mode = .exclusive;
            create_info.queue_family_index_count = 0;
            create_info.p_queue_family_indices = null;
        } else {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = 2;
            create_info.p_queue_family_indices = @ptrCast(&queue_family_indices);
        }

        self.swapchain = try self.device.createSwapchainKHR(&create_info, null);
        errdefer self.device.destroySwapchainKHR(self.swapchain, null);
        self.swapchain_format = create_info.image_format;
        self.swapchain_extent = create_info.image_extent;

        const images = try self.device.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
        defer self.allocator.free(images);

        self.swapchain_images = try self.allocator.alloc(SwapchainImage, images.len);
        errdefer self.allocator.free(self.swapchain_images);

        for (images, self.swapchain_images, 0..) |image, *saved_image, i| {
            saved_image.image = image;

            const image_view = self.device.createImageView(&vk.ImageViewCreateInfo{
                .image = image,
                .view_type = .@"2d",
                .format = create_info.image_format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);

            saved_image.view = image_view catch |err| {
                for (self.swapchain_images, 0..i) |*deleting_view, _| {
                    self.device.destroyImageView(deleting_view.view, null);
                }
                return err;
            };
        }
    }

    fn preferred_format(avail: []vk.SurfaceFormatKHR) !vk.SurfaceFormatKHR {
        if (avail.len == 0) {
            return error.NoSurfaceFormats;
        }

        // use B8G8R8A8_UNORM SRGB_NONLINEAR if its there
        for (avail) |avl| {
            if (avl.format == .b8g8r8a8_unorm and avl.color_space == .srgb_nonlinear_khr) {
                return avl;
            }
        }

        return avail[0];
    }

    fn preferred_present_mode(avail: []vk.PresentModeKHR) !vk.PresentModeKHR {
        // use MAILBOX if its there
        for (avail) |avl| {
            if (avl == .mailbox_khr) {
                return avl;
            }
        }

        // // fallback to IMMEDIATE
        // for (avail) |avl| {
        //     if (avl == .immediate_khr) {
        //         return avl;
        //     }
        // }

        return vk.PresentModeKHR.fifo_khr;
    }

    fn createVma(self: *Self) !void {
        const vk_functions = vma.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(self.vkb.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(self.vki.dispatch.vkGetDeviceProcAddr),
        };

        const allocator_create_info = vma.VmaAllocatorCreateInfo{
            .flags = vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT,
            .vulkanApiVersion = vma.VK_API_VERSION_1_2,
            .physicalDevice = @ptrFromInt(@intFromEnum(self.gpu.gpu)),
            .device = @ptrFromInt(@intFromEnum(self.device.handle)),
            .instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
            .pVulkanFunctions = &vk_functions,
        };

        const res = vma.vmaCreateAllocator(&allocator_create_info, &self.vma);
        if (res != @intFromEnum(vk.Result.success)) {
            return error.VmaInitFailed;
        }
        errdefer vma.vmaDestroyAllocator(self.vma);
    }

    fn createInstance(self: *Self) !void {
        var glfw_exts_count: u32 = 0;
        const glfw_exts = glfw.getRequiredInstanceExtensions(&glfw_exts_count) orelse &[0][*]const u8{};

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

        var extensions = std.ArrayList([*]const u8).init(self.allocator);
        defer extensions.deinit();
        try extensions.appendSlice(glfw_exts[0..glfw_exts_count]);
        try extensions.append(vk.extensions.ext_debug_utils.name.ptr);

        const instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = "luminary",
                .application_version = vk.makeApiVersion(0, 0, 0, 0),
                .p_engine_name = "luminary",
                .engine_version = vk.makeApiVersion(0, 0, 0, 0),
                .api_version = vk.API_VERSION_1_2,
            },
            .enabled_extension_count = @truncate(extensions.items.len),
            .pp_enabled_extension_names = @ptrCast(extensions.items.ptr),
            .enabled_layer_count = @intFromBool(vk_layer_khronos_validation_found),
            .pp_enabled_layer_names = &.{vk_layer_khronos_validation},
        }, null);

        self.vki = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);

        self.instance = Instance.init(instance, &self.vki);
        errdefer self.instance.destroyInstance(null);
    }

    fn createDebugMessenger(self: *Self) !void {
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{
                .error_bit_ext = true,
                .warning_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
                .device_address_binding_bit_ext = true,
            },
            .pfn_user_callback = debugCallback,
        }, null);
    }

    fn createDevice(self: *Self) !void {
        const priority = [_]f32{1};
        var queue_create_infos_buf = [_]vk.DeviceQueueCreateInfo{
            vk.DeviceQueueCreateInfo{
                .queue_family_index = self.gpu.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = self.gpu.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = self.gpu.transfer_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = self.gpu.compute_family,
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
        var i: usize = queue_create_infos.items.len;
        if (i > 0) {
            i -= 1;
        }
        while (i > 0) {
            i -= 1;

            if (queue_create_infos.items[i].queue_family_index == queue_create_infos.items[i + 1].queue_family_index) {
                _ = queue_create_infos.orderedRemove(i + 1);
            }
        }

        const device = try self.instance.createDevice(self.gpu.gpu, &vk.DeviceCreateInfo{
            .queue_create_info_count = @truncate(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .enabled_extension_count = @truncate(required_device_extensions.len),
            .pp_enabled_extension_names = &required_device_extensions,
        }, null);

        self.vkd = try DeviceDispatch.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.device = Device.init(device, &self.vkd);
        errdefer self.device.destroyDevice(null);

        const graphics_queue = self.device.getDeviceQueue(self.gpu.graphics_family, 0);
        const present_queue = self.device.getDeviceQueue(self.gpu.present_family, 0);
        const transfer_queue = self.device.getDeviceQueue(self.gpu.transfer_family, 0);
        const compute_queue = self.device.getDeviceQueue(self.gpu.compute_family, 0);

        self.graphics_queue = Queue.init(graphics_queue, &self.vkd);
        self.present_queue = Queue.init(present_queue, &self.vkd);
        self.transfer_queue = Queue.init(transfer_queue, &self.vkd);
        self.compute_queue = Queue.init(compute_queue, &self.vkd);
    }

    fn pickGpu(self: *Self) !void {
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

        self.gpu = best_gpu orelse return error.NoSuitableGpus;
        self.gpu.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.gpu.gpu);
    }

    const GpuCandidate = struct {
        gpu: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
        mem_props: vk.PhysicalDeviceMemoryProperties,
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
            .mem_props = undefined,
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

fn debugCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = types;
    _ = user_data;
    const msg = b: {
        break :b (data orelse break :b "<no data>").p_message orelse "<no message>";
    };

    const l = std.log.scoped(.validation);
    if (severity.error_bit_ext) {
        l.err("{s}", .{msg});
    } else {
        l.warn("{s}", .{msg});
    }

    return vk.FALSE;
}
