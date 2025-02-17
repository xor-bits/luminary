use core::slice;
use std::ptr;

use ash::{
    Device, Entry, Instance, khr,
    vk::{self, Handle},
};
use eyre::{Result, bail};

use crate::cold;

use super::queues::QueueFamilies;

//

pub struct Swapchain {
    inner: vk::SwapchainKHR,
    surface: vk::SurfaceKHR,
    gpu: vk::PhysicalDevice,
    extent: vk::Extent2D,
    format: vk::Format,
    images: Box<[vk::Image]>,
    suboptimal: bool,

    surface_loader: khr::surface::Instance,
    swapchain_loader: khr::swapchain::Device,
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

        let res = Self::create(
            surface_loader,
            swapchain_loader,
            gpu,
            queue_families,
            surface,
            extent,
        )?;
        Ok(res)
    }

    pub fn recreate(&mut self, queue_families: &QueueFamilies, extent: vk::Extent2D) -> Result<()> {
        self.destroy();

        *self = Self::create(
            self.surface_loader.clone(),
            self.swapchain_loader.clone(),
            self.gpu,
            queue_families,
            self.surface,
            extent,
        )?;

        Ok(())
    }

    pub fn acquire(
        &mut self,
        on_acquire: vk::Semaphore,
        queue_families: &QueueFamilies,
    ) -> Result<SwapchainImage> {
        loop {
            if self.suboptimal {
                self.recreate(queue_families, self.extent)?;
            }

            let res = unsafe {
                self.swapchain_loader.acquire_next_image(
                    self.inner,
                    1_000_000_000, // 1 sec
                    on_acquire,
                    vk::Fence::null(),
                )
            };

            match res {
                Ok((index, suboptimal)) => {
                    self.suboptimal |= suboptimal;
                    return Ok(SwapchainImage {
                        image: self.images[index as usize],
                        index,
                    });
                }
                Err(vk::Result::NOT_READY) => continue,
                Err(vk::Result::TIMEOUT) => {
                    bail!("swapchain timeout")
                }
                Err(err) => {
                    eyre::bail!("failed to acquire next image: {err}")
                }
            }
        }
    }

    pub fn present(
        &mut self,
        image: SwapchainImage,
        queue: vk::Queue,
        wait_for: vk::Semaphore,
    ) -> Result<()> {
        let present_info = vk::PresentInfoKHR::default()
            .wait_semaphores(slice::from_ref(&wait_for))
            .swapchains(slice::from_ref(&self.inner))
            .image_indices(slice::from_ref(&image.index));
        self.suboptimal |= unsafe { self.swapchain_loader.queue_present(queue, &present_info)? };

        Ok(())
    }

    pub fn destroy(&mut self) {
        if self.inner.is_null() {
            cold();
            return;
        }

        unsafe { self.swapchain_loader.destroy_swapchain(self.inner, None) };
        self.inner = vk::SwapchainKHR::null();
    }

    fn create(
        surface_loader: khr::surface::Instance,
        swapchain_loader: khr::swapchain::Device,
        gpu: vk::PhysicalDevice,
        queue_families: &QueueFamilies,
        surface: vk::SurfaceKHR,
        extent: vk::Extent2D,
    ) -> Result<Self> {
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
            surface,
            gpu,
            extent,
            format: surface_format.format,
            images,
            suboptimal: false,

            surface_loader,
            swapchain_loader,
        })
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

//

#[must_use]
#[derive(Debug)]
pub struct SwapchainImage {
    image: vk::Image,
    index: u32,
}
