pub const std = @import("std");
pub const vk = @import("vk");
pub const glfw = @import("glfw");

//

const Swapchain = @import("graphics/swapchain.zig").Swapchain;
const Vma = @import("graphics/vma.zig").Vma;

//

const log = std.log.scoped(.graphics);

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

const apis: []const vk.ApiInfo = &[_]vk.ApiInfo{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
};

const api_version = vk.API_VERSION_1_3;

pub const BaseDispatch = vk.BaseWrapper(apis);
pub const InstanceDispatch = vk.InstanceWrapper(apis);
pub const DeviceDispatch = vk.DeviceWrapper(apis);

pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);
pub const CommandBuffer = vk.CommandBufferProxy(apis);
pub const Queue = vk.QueueProxy(apis);

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

    vma: Vma,
    swapchain: Swapchain,

    second: usize,
    frame_counter: usize,
    frame: usize,
    frame_data: [2]FrameData,

    start_time_ms: ?i64,

    const Self = @This();

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
        self.vma = try Vma.init(&self.vkb, &self.vki, self.instance, self.gpu.gpu, self.device);
        errdefer self.vma.deinit();
        log.debug("vma created", .{});

        log.debug("creating swapchain ..", .{});
        self.swapchain = try Swapchain.init(
            self.allocator,
            self.instance,
            self.gpu.gpu,
            self.gpu.graphics_family,
            self.gpu.present_family,
            self.device,
            self.surface,
            window,
        );
        errdefer self.swapchain.deinit(allocator, self.device);
        log.debug("swapchain created", .{});

        log.debug("creating command buffers ..", .{});
        try self.createCommandBuffers();
        errdefer self.deinitCommandBuffers();
        log.debug("command buffers created", .{});

        log.debug("creating frame sync structures ..", .{});
        try self.createSyncStructs();
        errdefer self.deinitSyncStructs();
        log.debug("frame sync structures created", .{});

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self.device.deviceWaitIdle() catch {};

        self.deinitSyncStructs();
        self.deinitCommandBuffers();
        self.swapchain.deinit(self.allocator, self.device);
        self.vma.deinit();
        self.deinitDevice();
        self.deinitSurface();
        self.deinitDebugMessenger();
        self.deinitInstance();

        self.allocator.destroy(self);
    }

    fn deinitSyncStructs(self: *Self) void {
        for (&self.frame_data) |*frame| {
            self.device.destroySemaphore(frame.render_sema, null);
            self.device.destroySemaphore(frame.swapchain_sema, null);
            self.device.destroyFence(frame.render_fence, null);
        }
    }

    fn deinitCommandBuffers(self: *Self) void {
        for (&self.frame_data) |*frame| {
            self.device.destroyCommandPool(frame.command_pool, null);
        }
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

    pub fn draw(self: *Self) !void {
        const frame = self.currentFrame();

        if (try self.device.waitForFences(1, @ptrCast(&frame.render_fence), vk.TRUE, 1_000_000_000) != .success) {
            return error.DrawTimeout;
        }
        try self.device.resetFences(1, @ptrCast(&frame.render_fence));

        const image = try self.swapchain.acquireImage(self.device, frame.swapchain_sema);
        // log.info("draw frame={} image={}", .{ frame.index, image.index });

        try self.device.resetCommandBuffer(frame.main_cbuf, .{});
        try self.device.beginCommandBuffer(frame.main_cbuf, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.transitionImage(frame.main_cbuf, image.image, .undefined, .general);

        const now_ms: i64 = std.time.milliTimestamp();
        const start_time_ms: i64 = self.start_time_ms orelse blk: {
            self.start_time_ms = now_ms;
            break :blk now_ms;
        };
        const time_ms = now_ms - start_time_ms;
        const time_sec = @as(f64, @floatFromInt(time_ms)) / 1000.0;
        const time_sec_int = @as(usize, @intCast(@divFloor(time_ms, 1000)));

        self.frame_counter += 1;
        if (time_sec_int > self.second) {
            self.second = time_sec_int;
            log.info("fps (approx) {}", .{self.frame_counter});
            self.frame_counter = 0;
        }

        const clear_ranges = subresource_range(.{ .color_bit = true });
        self.device.cmdClearColorImage(
            frame.main_cbuf,
            image.image,
            .general,
            &vk.ClearColorValue{
                .float_32 = .{ @as(f32, @floatCast(std.math.sin(time_sec))) * 0.5 + 0.5, 0.0, 0.0, 1.0 },
            },
            1,
            @ptrCast(&clear_ranges),
        );

        self.transitionImage(frame.main_cbuf, image.image, .general, .present_src_khr);

        try self.device.endCommandBuffer(frame.main_cbuf);

        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = frame.swapchain_sema,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
            .value = 1,
        };

        const signal_info = vk.SemaphoreSubmitInfo{
            .semaphore = frame.render_sema,
            .stage_mask = .{ .all_graphics_bit = true },
            .device_index = 0,
            .value = 1,
        };

        const cmd_info = vk.CommandBufferSubmitInfo{
            .command_buffer = frame.main_cbuf,
            .device_mask = 0,
        };

        const submit_info = vk.SubmitInfo2{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&wait_info),
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = @ptrCast(&signal_info),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&cmd_info),
        };

        try self.graphics_queue.submit2(1, @ptrCast(&submit_info), frame.render_fence);

        _ = try self.present_queue.presentKHR(&vk.PresentInfoKHR{
            .p_swapchains = @ptrCast(&self.swapchain),
            .swapchain_count = 1,
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.render_sema),
            .p_image_indices = @ptrCast(&image.index),
        });

        self.frame = (self.frame + 1) % self.frame_data.len;
    }

    fn transitionImage(self: *Self, cbuf: vk.CommandBuffer, image: vk.Image, from: vk.ImageLayout, to: vk.ImageLayout) void {
        const image_barrier = vk.ImageMemoryBarrier2{
            // the swapchain image is a copy destination
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            // the new layout is read+write render target
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },

            .old_layout = from,
            .new_layout = to,

            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,

            .subresource_range = subresource_range(vk.ImageAspectFlags{
                .color_bit = to != .depth_stencil_attachment_optimal,
                .depth_bit = to == .depth_stencil_attachment_optimal,
            }),
            .image = image,
        };

        self.device.cmdPipelineBarrier2(cbuf, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&image_barrier),
        });
    }

    fn subresource_range(aspect: vk.ImageAspectFlags) vk.ImageSubresourceRange {
        return .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        };
    }

    fn createSyncStructs(self: *Self) !void {
        for (&self.frame_data) |*frame| {
            // FIXME: leak on err

            frame.render_fence = try self.device.createFence(&vk.FenceCreateInfo{
                // they are already ready for rendering
                .flags = .{ .signaled_bit = true },
            }, null);

            frame.swapchain_sema = try self.device.createSemaphore(&.{}, null);
            frame.render_sema = try self.device.createSemaphore(&.{}, null);
        }
    }

    fn createCommandBuffers(self: *Self) !void {
        self.frame = 0;
        self.frame_counter = 0;
        self.second = 0;
        self.start_time_ms = null;
        for (&self.frame_data, 0..) |*frame, i| {
            // FIXME: leak on err

            frame.index = @truncate(i);

            frame.command_pool = try self.device.createCommandPool(&vk.CommandPoolCreateInfo{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = self.gpu.graphics_family,
            }, null);

            try self.device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
                .command_pool = frame.command_pool,
                .command_buffer_count = 1,
                .level = .primary,
            }, @ptrCast(&frame.main_cbuf));
        }
    }

    fn createInstance(self: *Self) !void {
        const version = try self.vkb.enumerateInstanceVersion();
        log.info("Instance API version: {}.{}.{}", .{
            vk.apiVersionMajor(version),
            vk.apiVersionMinor(version),
            vk.apiVersionPatch(version),
        });

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
                .api_version = api_version,
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

        const features_13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = vk.TRUE,
            .maintenance_4 = vk.TRUE,
        };

        const device = try self.instance.createDevice(self.gpu.gpu, &vk.DeviceCreateInfo{
            .p_next = &features_13,
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

        log.info("GPU API version: {}.{}.{}", .{
            vk.apiVersionMajor(self.gpu.props.api_version),
            vk.apiVersionMinor(self.gpu.props.api_version),
            vk.apiVersionPatch(self.gpu.props.api_version),
        });
        log.info("GPU Driver version: {}.{}.{}", .{
            vk.apiVersionMajor(self.gpu.props.driver_version),
            vk.apiVersionMinor(self.gpu.props.driver_version),
            vk.apiVersionPatch(self.gpu.props.driver_version),
        });
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
