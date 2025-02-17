use std::ptr;

use ash::{
    Device, Entry, Instance, khr,
    vk::{self, Handle},
};
use eyre::Result;

use crate::cold;

use super::queues::QueueFamilies;

//

pub struct Swapchain {
    inner: vk::SwapchainKHR,
    extent: vk::Extent2D,
    format: vk::Format,
    images: Box<[vk::Image]>,
    suboptimal: bool,

    destroy_fp: vk::PFN_vkDestroySwapchainKHR,
}

impl Swapchain {
    pub fn new(
        entry: &Entry,
        instance: &Instance,
        device: &Device,
        gpu: vk::PhysicalDevice,
        queue_families: &QueueFamilies,
        surface: vk::SurfaceKHR,
        extent: vk::Extent2D,
    ) -> Result<Self> {
        let surface_loader = khr::surface::Instance::new(entry, instance);
        let swapchain_loader = khr::swapchain::Device::new(instance, device);

        let surface_formats =
            unsafe { surface_loader.get_physical_device_surface_formats(gpu, surface)? };
        let surface_present_modes =
            unsafe { surface_loader.get_physical_device_surface_present_modes(gpu, surface)? };

        let surface_format = Self::preferred_format(&surface_formats);
        let present_mode = Self::preferred_present_mode(&surface_present_modes);

        let caps =
            unsafe { surface_loader.get_physical_device_surface_capabilities(gpu, surface)? };

        let mut image_count = caps.min_image_count + 1;
        if caps.max_image_count != 0 && image_count > caps.max_image_count {
            // max image count 0 means there is no max
            image_count = caps.max_image_count;
        }

        let queue_family_indices = [queue_families.present, queue_families.graphics];
        let (sharing_mode, queue_family_indices) =
            if queue_family_indices[0] == queue_family_indices[1] {
                (vk::SharingMode::EXCLUSIVE, &queue_family_indices[..])
            } else {
                (vk::SharingMode::CONCURRENT, &[][..])
            };

        let extent = vk::Extent2D {
            width: extent
                .width
                .max(caps.min_image_extent.width)
                .min(caps.max_image_extent.width),
            height: extent
                .height
                .max(caps.min_image_extent.height)
                .min(caps.max_image_extent.height),
        };

        let create_info = vk::SwapchainCreateInfoKHR::default()
            .surface(surface)
            .image_sharing_mode(sharing_mode)
            .queue_family_indices(queue_family_indices)
            .image_format(surface_format.format)
            .image_color_space(surface_format.color_space)
            .present_mode(present_mode)
            .image_extent(extent)
            .min_image_count(image_count)
            .image_array_layers(1)
            .image_usage(vk::ImageUsageFlags::TRANSFER_DST)
            .pre_transform(vk::SurfaceTransformFlagsKHR::IDENTITY)
            .composite_alpha(vk::CompositeAlphaFlagsKHR::OPAQUE)
            .clipped(true);

        let inner = unsafe { swapchain_loader.create_swapchain(&create_info, None)? };

        let images = unsafe { swapchain_loader.get_swapchain_images(inner)? }.into_boxed_slice();

        Ok(Self {
            inner,
            extent,
            format: surface_format.format,
            images,
            suboptimal: false,

            destroy_fp: swapchain_loader.fp().destroy_swapchain_khr,
        })
    }

    pub fn destroy(&mut self, device: &Device) {
        if self.inner.is_null() {
            cold();
            return;
        }

        unsafe {
            (self.destroy_fp)(device.handle(), self.inner, ptr::null());
        }
        self.inner = vk::SwapchainKHR::null();
    }

    fn preferred_format(formats: &[vk::SurfaceFormatKHR]) -> vk::SurfaceFormatKHR {
        formats
            .iter()
            .copied()
            .find(|f| {
                f.format == vk::Format::B8G8R8A8_UNORM
                    && f.color_space == vk::ColorSpaceKHR::SRGB_NONLINEAR
            })
            .unwrap_or(formats[0])
    }

    fn preferred_present_mode(present_modes: &[vk::PresentModeKHR]) -> vk::PresentModeKHR {
        present_modes
            .iter()
            .copied()
            .find(|mode| *mode == vk::PresentModeKHR::MAILBOX)
            .unwrap_or(vk::PresentModeKHR::FIFO)
    }
}
