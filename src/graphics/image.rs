use ash::{Device, vk};
use eyre::Result;
use gpu_allocator::{
    MemoryLocation,
    vulkan::{AllocationCreateDesc, AllocationScheme, Allocator},
};

use super::delete_queue::DeleteQueue;

//

pub struct Image {
    pub image: vk::Image,
    pub view: vk::ImageView,
    pub extent: vk::Extent2D,
    pub format: vk::Format,
}

impl Image {
    pub fn builder() -> ImageBuilder {
        ImageBuilder::default()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ImageBuilder {
    format: vk::Format,
    usage: vk::ImageUsageFlags,
    extent: vk::Extent2D,
    aspect_flags: vk::ImageAspectFlags,
}

impl ImageBuilder {
    pub fn build(
        self,
        device: &Device,
        alloc: &mut Allocator,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Image> {
        let create_info = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(self.format)
            .extent(vk::Extent3D {
                width: self.extent.width,
                height: self.extent.height,
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::OPTIMAL)
            .usage(self.usage)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED);

        let image = unsafe { device.create_image(&create_info, None)? };
        delete_queue.push(image);

        let requirements = unsafe { device.get_image_memory_requirements(image) };

        let alloc_desc = AllocationCreateDesc {
            name: "",
            requirements,
            location: MemoryLocation::GpuOnly,
            linear: false,
            allocation_scheme: AllocationScheme::GpuAllocatorManaged,
        };

        let allocation = alloc.allocate(&alloc_desc)?;
        let memory = unsafe { allocation.memory() };
        let offset = allocation.offset();
        delete_queue.push(allocation);

        unsafe { device.bind_image_memory(image, memory, offset)? };

        let create_info = vk::ImageViewCreateInfo::default()
            .view_type(vk::ImageViewType::TYPE_2D)
            .image(image)
            .format(self.format)
            .subresource_range(
                vk::ImageSubresourceRange::default()
                    .base_mip_level(0)
                    .level_count(1)
                    .base_array_layer(0)
                    .layer_count(1)
                    .aspect_mask(self.aspect_flags),
            );

        let view = unsafe { device.create_image_view(&create_info, None)? };
        delete_queue.push(view);

        Ok(Image {
            image,
            view,
            extent: self.extent,
            format: self.format,
        })
    }

    pub fn format(mut self, format: vk::Format) -> Self {
        self.format = format;
        self
    }

    pub fn usage(mut self, usage: vk::ImageUsageFlags) -> Self {
        self.usage = usage;
        self
    }

    pub fn extent(mut self, extent: vk::Extent2D) -> Self {
        self.extent = extent;
        self
    }

    pub fn aspect_flags(mut self, aspect_flags: vk::ImageAspectFlags) -> Self {
        self.aspect_flags = aspect_flags;
        self
    }
}

impl Default for ImageBuilder {
    fn default() -> Self {
        Self {
            format: vk::Format::R16G16B16A16_SFLOAT,
            usage: vk::ImageUsageFlags::TRANSFER_SRC
                | vk::ImageUsageFlags::TRANSFER_DST
                | vk::ImageUsageFlags::STORAGE
                | vk::ImageUsageFlags::SAMPLED
                | vk::ImageUsageFlags::COLOR_ATTACHMENT,
            extent: vk::Extent2D {
                width: 64,
                height: 64,
            },
            aspect_flags: vk::ImageAspectFlags::COLOR,
        }
    }
}
