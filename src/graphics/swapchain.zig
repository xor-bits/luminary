pub const std = @import("std");
pub const vk = @import("vk");
pub const glfw = @import("glfw");

const graphics = @import("../graphics.zig");
const Instance = graphics.Instance;
const Device = graphics.Device;
const Gpu = graphics.Gpu;

//

pub const Swapchain = struct {
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,
    images: []Image,
    suboptimal: bool,

    pub const Image = struct {
        image: vk.Image,
        view: vk.ImageView,
        index: u32,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        instance: Instance,
        gpu: *const Gpu,
        device: Device,
        surface: vk.SurfaceKHR,
        extent: vk.Extent2D,
    ) !Self {
        return try create(allocator, instance, gpu, device, surface, extent, .null_handle);
    }

    pub fn deinit(
        self: *const Self,
        allocator: std.mem.Allocator,
        device: Device,
    ) void {
        for (self.images) |*image| {
            device.destroyImageView(image.view, null);
        }
        allocator.free(self.images);

        device.destroySwapchainKHR(self.swapchain, null);
    }

    pub fn acquireImage(self: *Self, device: Device, on_acquire: vk.Semaphore) !*Image {
        while (true) {
            if (self.suboptimal) {
                // TODO: recreate swapchain
                // const old_swapchain = self.swapchain;
                // self.createSwapchain(old_swapchain);
                // self.
            }

            const result = try device.acquireNextImageKHR(self.swapchain, 1_000_000_000, on_acquire, .null_handle);
            if (result.result == .suboptimal_khr) {
                self.suboptimal = true;
            } else if (result.result == .timeout) {
                return error.SwapchainTimeout;
            } else if (result.result == .not_ready) {
                return error.SwapchainNotReady;
            }

            return &self.images[result.image_index];
        }
    }

    fn create(
        allocator: std.mem.Allocator,
        instance: Instance,
        gpu: *const Gpu,
        device: Device,
        surface: vk.SurfaceKHR,
        extent: vk.Extent2D,
        old_swapchain: vk.SwapchainKHR,
    ) !Self {
        const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gpu.device, surface, allocator);
        const surface_format = try preferred_format(surface_formats);

        const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gpu.device, surface, allocator);
        const present_mode = try preferred_present_mode(present_modes);

        const caps = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gpu.device, surface);

        var create_info = vk.SwapchainCreateInfoKHR{
            .surface = surface,
            .image_sharing_mode = undefined,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .present_mode = present_mode,
            .image_extent = vk.Extent2D{
                .width = @max(@min(extent.width, caps.max_image_extent.width), caps.min_image_extent.width),
                .height = @max(@min(extent.height, caps.max_image_extent.height), caps.min_image_extent.height),
            },
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

        const queue_family_indices = .{ gpu.queue_families.graphics, gpu.queue_families.present };
        if (queue_family_indices[0] == queue_family_indices[1]) {
            create_info.image_sharing_mode = .exclusive;
            create_info.queue_family_index_count = 0;
            create_info.p_queue_family_indices = null;
        } else {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = 2;
            create_info.p_queue_family_indices = @ptrCast(&queue_family_indices);
        }

        const swapchain = try device.createSwapchainKHR(&create_info, null);
        errdefer device.destroySwapchainKHR(swapchain, null);
        // self.swapchain_format = create_info.image_format;
        // self.swapchain_extent = create_info.image_extent;
        // self.swapchain_suboptimal = false;

        const tmp_images = try device.getSwapchainImagesAllocKHR(swapchain, allocator);
        defer allocator.free(tmp_images);

        const images = try allocator.alloc(Image, tmp_images.len);
        errdefer allocator.free(images);

        for (tmp_images, images, 0..) |image, *saved_image, i| {
            saved_image.image = image;
            saved_image.index = @truncate(i);

            const image_view = device.createImageView(&vk.ImageViewCreateInfo{
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
                for (images, 0..i) |*deleting_view, _| {
                    device.destroyImageView(deleting_view.view, null);
                }
                return err;
            };
        }

        return Self{
            .swapchain = swapchain,
            .format = surface_format.format,
            .extent = extent,
            .images = images,
            .suboptimal = false,
        };
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
};
