const vk = @import("vk");
const vma = @import("vma.zig");

const Device = @import("../graphics.zig").Device;

//

pub const Image = struct {
    image: vk.Image,
    view: vk.ImageView,
    alloc: vma.Allocation,
    extent: vk.Extent3D,
    format: vk.Format,

    const Self = @This();

    pub fn createInfo(
        format: vk.Format,
        usage: vk.ImageUsageFlags,
        extent: vk.Extent3D,
    ) vk.ImageCreateInfo {
        return vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = usage,
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };
    }

    pub fn viewCreateInfo(
        format: vk.Format,
        image: vk.Image,
        aspect_flags: vk.ImageAspectFlags,
    ) vk.ImageViewCreateInfo {
        return vk.ImageViewCreateInfo{
            .view_type = .@"2d",
            .image = image,
            .format = format,
            .subresource_range = vk.ImageSubresourceRange{
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
                .aspect_mask = aspect_flags,
            },
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
        };
    }

    pub const ImageInfo = struct {
        format: vk.Format,
        usage: vk.ImageUsageFlags,
        extent: vk.Extent3D,
        aspect_flags: vk.ImageAspectFlags,
    };

    pub fn createImage(device: Device, alloc: vma.Vma, info: ImageInfo) !Self {
        const vma_image = try alloc.createImage(
            &createInfo(info.format, info.usage, info.extent),
            .{ .device_local_bit = true },
            .gpu_only,
        );

        const view = try device.createImageView(
            &viewCreateInfo(info.format, vma_image.image, info.aspect_flags),
            null,
        );

        return Self{
            .image = vma_image.image,
            .view = view,
            .alloc = vma_image.allocation,
            .extent = info.extent,
            .format = info.format,
        };
    }

    pub fn deinit(self: Self, device: Device, alloc: vma.Vma) void {
        device.destroyImageView(self.view, null);
        alloc.destroyImage(.{
            .image = self.image,
            .allocation = self.alloc,
        });
    }
};
