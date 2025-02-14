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
    gpu: Gpu,

    device: Device,
    queues: Queues,

    vma: Vma,
    swapchain: Swapchain,
    frame: Frame,

    fps_counter: Counter = .{},
    start_time_ms: ?i64 = null,

    const Self = @This();

    pub fn init(allocator: Allocator, window: *glfw.Window) !Self {
        const dispatch = try allocator.create(Dispatch);
        errdefer allocator.destroy(dispatch);
        dispatch.* = .{};

        log.debug("loading vulkan ..", .{});
        try dispatch.loadBase();

        log.debug("creating instance ..", .{});
        const instance = try createInstance(allocator, dispatch);
        errdefer deinitInstance(instance);

        log.debug("creating debug messenger ..", .{});
        const debug_messenger = try createDebugMessenger(instance);
        errdefer deinitDebugMessenger(instance, debug_messenger);

        log.debug("creating surface ..", .{});
        const surface = try createSurface(instance, window);
        errdefer deinitSurface(instance, surface);

        log.debug("picking GPU ..", .{});
        const gpu = try pickGpu(allocator, instance, surface);

        log.debug("creating device ..", .{});
        const device = try createDevice(dispatch, instance, &gpu);
        errdefer deinitDevice(device);

        log.debug("fetching queues ..", .{});
        const queues = Queues.init(device, gpu.queue_families);

        log.debug("creating vma ..", .{});
        const vma = try Vma.init(
            &dispatch.base,
            &dispatch.instance,
            instance,
            &gpu,
            device,
        );
        errdefer vma.deinit();

        log.debug("creating swapchain ..", .{});
        const swapchain = try Swapchain.init(
            allocator,
            instance,
            &gpu,
            device,
            surface,
            window,
        );
        errdefer swapchain.deinit(allocator, device);

        log.debug("creating frames in flight ..", .{});
        const frame = try Frame.init(
            device,
            gpu.queue_families.graphics,
        );
        errdefer frame.deinit(device);

        log.info("renderer initialization done", .{});
        return Self{
            .allocator = allocator,

            .window = window,

            .dispatch = dispatch,

            .instance = instance,
            .debug_messenger = debug_messenger,
            .surface = surface,
            .gpu = gpu,

            .device = device,
            .queues = queues,

            .vma = vma,
            .swapchain = swapchain,
            .frame = frame,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self.device.deviceWaitIdle() catch {};

        self.frame.deinit(self.device);
        self.swapchain.deinit(self.allocator, self.device);
        self.vma.deinit();
        deinitDevice(self.device);
        deinitSurface(self.instance, self.surface);
        deinitDebugMessenger(self.instance, self.debug_messenger);
        deinitInstance(self.instance);
        self.allocator.destroy(self.dispatch);
    }

    // instance

    fn createInstance(allocator: std.mem.Allocator, dispatch: *Dispatch) !Instance {
        const version = try dispatch.base.enumerateInstanceVersion();
        log.info("Instance API version: {}.{}.{}", .{
            vk.apiVersionMajor(version),
            vk.apiVersionMinor(version),
            vk.apiVersionPatch(version),
        });

        var glfw_exts_count: u32 = 0;
        const glfw_exts = glfw.getRequiredInstanceExtensions(&glfw_exts_count) orelse &[0][*]const u8{};

        const layers = try dispatch.base.enumerateInstanceLayerPropertiesAlloc(allocator);
        defer allocator.free(layers);

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

        var extensions = std.ArrayList([*]const u8).init(allocator);
        defer extensions.deinit();
        try extensions.appendSlice(glfw_exts[0..glfw_exts_count]);
        try extensions.append(vk.extensions.ext_debug_utils.name.ptr);

        const instance = try dispatch.base.createInstance(&vk.InstanceCreateInfo{
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

        try dispatch.loadInstance(instance);

        return Instance.init(instance, &dispatch.instance);
    }

    fn deinitInstance(instance: Instance) void {
        instance.destroyInstance(null);
    }

    // debug utils

    fn createDebugMessenger(instance: Instance) !vk.DebugUtilsMessengerEXT {
        return try instance.createDebugUtilsMessengerEXT(&vk.DebugUtilsMessengerCreateInfoEXT{
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

    fn deinitDebugMessenger(instance: Instance, debug_messenger: vk.DebugUtilsMessengerEXT) void {
        instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);
    }

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

    // surface

    fn createSurface(instance: Instance, window: *glfw.Window) !vk.SurfaceKHR {
        var surface: vk.SurfaceKHR = undefined;
        if (.success != glfw.createWindowSurface(@intFromEnum(instance.handle), window, null, @ptrCast(&surface))) {
            return error.SurfaceInitFailed;
        }
        return surface;
    }

    fn deinitSurface(instance: Instance, surface: vk.SurfaceKHR) void {
        instance.destroySurfaceKHR(surface, null);
    }

    // physical device

    fn pickGpu(
        allocator: Allocator,
        instance: Instance,
        surface: vk.SurfaceKHR,
    ) !Gpu {
        const gpus = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(gpus);

        // TODO: maybe pick the gpu based on the largest dedicated memory
        var best_gpu: ?Gpu = null;

        for (gpus) |gpu| {
            const props = instance.getPhysicalDeviceProperties(gpu);
            const is_suitable = try isSuitable(allocator, instance, surface, gpu, props);
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

        var gpu = best_gpu orelse return error.NoSuitableGpus;
        gpu.mem_props = instance.getPhysicalDeviceMemoryProperties(gpu.device);

        log.info("picked GPU: {s}", .{
            std.mem.sliceTo(&gpu.props.device_name, 0),
        });
        log.info(" - API version: {}.{}.{}", .{
            vk.apiVersionMajor(gpu.props.api_version),
            vk.apiVersionMinor(gpu.props.api_version),
            vk.apiVersionPatch(gpu.props.api_version),
        });
        log.info(" - Driver version: {}.{}.{}", .{
            vk.apiVersionMajor(gpu.props.driver_version),
            vk.apiVersionMinor(gpu.props.driver_version),
            vk.apiVersionPatch(gpu.props.driver_version),
        });

        return gpu;
    }

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
        allocator: Allocator,
        instance: Instance,
        surface: vk.SurfaceKHR,
        gpu: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
    ) !?Gpu {
        const exts = try instance.enumerateDeviceExtensionPropertiesAlloc(gpu, null, allocator);
        defer allocator.free(exts);

        if (!hasExtensions(&required_device_extensions, exts)) {
            return null;
        }

        var format_count: u32 = undefined;
        var present_mode_count: u32 = undefined;

        _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(gpu, surface, &format_count, null);
        _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(gpu, surface, &present_mode_count, null);

        if (format_count == 0 or present_mode_count == 0) {
            return null;
        }

        return Gpu{
            .device = gpu,
            .score = scoreOf(&props),
            .props = props,
            .mem_props = undefined,
            .queue_families = try QueueFamilies.getFromGpu(
                allocator,
                instance,
                surface,
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

    // logical device

    fn createDevice(dispatch: *Dispatch, instance: Instance, gpu: *const Gpu) !Device {
        const queue_create_infos = Queues.createInfos(gpu.queue_families);

        const device = try instance.createDevice(gpu.device, &vk.DeviceCreateInfo{
            .queue_create_info_count = @truncate(queue_create_infos.len),
            .p_queue_create_infos = @ptrCast(&queue_create_infos.items),
            .enabled_extension_count = @truncate(required_device_extensions.len),
            .pp_enabled_extension_names = &required_device_extensions,
        }, null);

        try dispatch.loadDevice(device);

        return Device.init(device, &dispatch.device);
    }

    fn deinitDevice(device: Device) void {
        device.destroyDevice(null);
    }

    // other

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
};

pub const Gpu = struct {
    device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    score: usize,
    queue_families: QueueFamilies,
};
