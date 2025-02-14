pub const std = @import("std");
pub const vk = @import("vk");
pub const glfw = @import("glfw");

//

const Swapchain = @import("graphics/swapchain.zig").Swapchain;
const Vma = @import("graphics/vma.zig").Vma;
const Frame = @import("graphics/frame.zig").Frame;
const Queues = @import("graphics/queues.zig").Queues;
const QueueFamilies = @import("graphics/queues.zig").QueueFamilies;
const Dispatch = @import("graphics/dispatch.zig").Dispatch;
const Counter = @import("counter.zig").Counter;

//

const log = std.log.scoped(.graphics);

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

pub const apis: []const vk.ApiInfo = &[_]vk.ApiInfo{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
};

const api_version = vk.API_VERSION_1_3;

pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);
pub const CommandBuffer = vk.CommandBufferProxy(apis);
pub const Queue = vk.QueueProxy(apis);

pub const Allocator = std.mem.Allocator;

//

pub const Graphics = struct {
    allocator: Allocator,

    window: *glfw.Window,

    dispatch: *Dispatch,

    instance: Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    gpu: GpuCandidate,

    device: Device,
    queues: Queues,

    vma: Vma,
    swapchain: Swapchain,
    frame: Frame,

    fps_counter: Counter,

    start_time_ms: ?i64,

    const Self = @This();

    pub fn init(allocator: Allocator, window: *glfw.Window) !Self {
        var self: Self = undefined;

        self.allocator = allocator;
        self.window = window;

        self.dispatch = try allocator.create(Dispatch);
        errdefer allocator.destroy(self.dispatch);
        self.dispatch.* = .{};

        log.debug("loading vulkan ..", .{});
        try self.dispatch.loadBase();

        log.debug("creating instance ..", .{});
        try self.createInstance();
        errdefer self.deinitInstance();

        log.debug("creating debug messenger ..", .{});
        try self.createDebugMessenger();
        errdefer self.deinitDebugMessenger();

        log.debug("creating surface ..", .{});
        try self.createSurface();
        errdefer self.deinitSurface();

        log.debug("picking GPU ..", .{});
        try self.pickGpu();
        log.info("picked GPU: {s}", .{std.mem.sliceTo(&self.gpu.props.device_name, 0)});

        log.debug("creating device ..", .{});
        try self.createDevice();
        errdefer self.deinitDevice();

        log.debug("creating vma ..", .{});
        self.vma = try Vma.init(&self.dispatch.base, &self.dispatch.instance, self.instance, self.gpu.gpu, self.device);
        errdefer self.vma.deinit();

        log.debug("creating swapchain ..", .{});
        self.swapchain = try Swapchain.init(
            self.allocator,
            self.instance,
            self.gpu.gpu,
            self.gpu.queue_families.graphics,
            self.gpu.queue_families.present,
            self.device,
            self.surface,
            window,
        );
        errdefer self.swapchain.deinit(allocator, self.device);

        log.debug("creating frames in flight ..", .{});
        self.frame = try Frame.init(self.device, self.gpu.queue_families.graphics);
        errdefer self.frame.deinit(self.device);

        self.fps_counter = .{};
        self.start_time_ms = null;

        log.info("renderer initialization done", .{});

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self.device.deviceWaitIdle() catch {};

        self.frame.deinit(self.device);
        self.swapchain.deinit(self.allocator, self.device);
        self.vma.deinit();
        self.deinitDevice();
        self.deinitSurface();
        self.deinitDebugMessenger();
        self.deinitInstance();
        self.allocator.destroy(self.dispatch);
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

    pub fn draw(self: *Self) !void {
        const frame = self.frame.next();

        try frame.wait(self.device);

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

        if (self.fps_counter.next(null)) |count| {
            log.info("fps {}", .{count});
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

        try self.queues.graphics.submit2(1, @ptrCast(&submit_info), frame.render_fence);

        _ = try self.queues.present.presentKHR(&vk.PresentInfoKHR{
            .p_swapchains = @ptrCast(&self.swapchain),
            .swapchain_count = 1,
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.render_sema),
            .p_image_indices = @ptrCast(&image.index),
        });
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

    fn createInstance(self: *Self) !void {
        const version = try self.dispatch.base.enumerateInstanceVersion();
        log.info("Instance API version: {}.{}.{}", .{
            vk.apiVersionMajor(version),
            vk.apiVersionMinor(version),
            vk.apiVersionPatch(version),
        });

        var glfw_exts_count: u32 = 0;
        const glfw_exts = glfw.getRequiredInstanceExtensions(&glfw_exts_count) orelse &[0][*]const u8{};

        const layers = try self.dispatch.base.enumerateInstanceLayerPropertiesAlloc(self.allocator);
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

        const instance = try self.dispatch.base.createInstance(&vk.InstanceCreateInfo{
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

        try self.dispatch.loadInstance(instance);

        self.instance = Instance.init(instance, &self.dispatch.instance);
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
        const queue_create_infos = Queues.createInfos(self.gpu.queue_families);

        const device = try self.instance.createDevice(self.gpu.gpu, &vk.DeviceCreateInfo{
            .queue_create_info_count = @truncate(queue_create_infos.len),
            .p_queue_create_infos = @ptrCast(&queue_create_infos.items),
            .enabled_extension_count = @truncate(required_device_extensions.len),
            .pp_enabled_extension_names = &required_device_extensions,
        }, null);

        try self.dispatch.loadDevice(device);

        self.device = Device.init(device, &self.dispatch.device);
        errdefer self.device.destroyDevice(null);

        self.queues = Queues.init(self.device, self.gpu.queue_families);
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
        queue_families: QueueFamilies,
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

        return GpuCandidate{
            .gpu = gpu,
            .score = scoreOf(&props),
            .props = props,
            .mem_props = undefined,
            .queue_families = try QueueFamilies.getFromGpu(
                self.allocator,
                self.instance,
                self.surface,
                gpu,
            ) orelse return null,
        };
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
