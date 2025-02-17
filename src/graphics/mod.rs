use core::slice;
use std::{mem::ManuallyDrop, sync::Arc};

use ash::{Device, Entry, Instance, ext, vk};
use eyre::Result;
use gpu_allocator::vulkan::{Allocator, AllocatorCreateDesc};
use winit::{dpi::PhysicalSize, raw_window_handle::HasDisplayHandle, window::Window};

use self::{
    debug::DebugUtils,
    delete_queue::DeleteQueue,
    frame::FramesInFlight,
    gpu::pick_gpu,
    image::Image,
    queues::{QueueFamilies, Queues},
    surface::Surface,
    swapchain::Swapchain,
};

//

mod debug;
mod delete_queue;
mod frame;
mod gpu;
mod image;
mod queues;
mod surface;
mod swapchain;

//

pub struct Graphics {
    entry: Entry,
    instance: Instance,
    debug_utils: DebugUtils,
    surface: Surface,

    gpu: vk::PhysicalDevice,
    queue_families: QueueFamilies,

    device: Device,
    queues: Queues,
    swapchain: Swapchain,

    allocator: ManuallyDrop<Allocator>,

    frames: FramesInFlight,

    render_target: Image,
    render_target_delete_queue: DeleteQueue,

    global_delete_queue: DeleteQueue,
}

impl Graphics {
    pub fn new(window: Arc<Window>) -> Result<Self> {
        let size = window.inner_size();
        let extent = vk::Extent2D {
            width: size.width,
            height: size.height,
        };
        let mut global_delete_queue = DeleteQueue::new();

        let entry = ash::Entry::linked();

        let instance = Self::create_instance(&window, &entry)?;

        let debug_utils = DebugUtils::new(&entry, &instance)?;

        let surface = Surface::new(window.clone(), &entry, &instance)?;

        let (gpu, queue_families) = pick_gpu(&entry, &instance, surface.inner)?;

        let device = Self::create_device(&instance, gpu, &queue_families)?;

        let queues = Queues::new(&device, &queue_families);

        let swapchain = Swapchain::new(
            &entry,
            &instance,
            &device,
            gpu,
            &queue_families,
            surface.inner,
            extent,
            window,
        )?;

        let mut allocator = ManuallyDrop::new(Self::create_allocator(&instance, gpu, &device)?);

        let frames = FramesInFlight::new(&device, &queue_families, &mut global_delete_queue)?;

        let mut render_target_delete_queue = DeleteQueue::new();
        let render_target = Self::create_render_image(
            &device,
            &mut allocator,
            &mut render_target_delete_queue,
            extent,
        )?;

        Ok(Self {
            entry,
            instance,
            debug_utils,
            surface,

            gpu,
            queue_families,

            device,
            queues,
            swapchain,

            allocator,

            frames,

            render_target,
            render_target_delete_queue,

            global_delete_queue,
        })
    }

    pub fn draw(&mut self) -> Result<()> {
        let (frame, frame_i) = self.frames.next();
        frame.wait(&self.device, &mut self.allocator)?;

        let swapchain_image =
            self.swapchain
                .acquire(&self.device, frame.swapchain_sema, &self.queue_families)?;

        frame.begin(&self.device)?;

        // make the main render target usable for rendering
        Self::transition_image(
            &self.device,
            frame.main_cbuf,
            self.render_target.image,
            vk::ImageLayout::UNDEFINED,
            vk::ImageLayout::GENERAL,
        );

        // render everything
        self.draw_scene();

        let frame = self.frames.get(frame_i);

        // blit the render target image to swapchain
        Self::transition_image(
            &self.device,
            frame.main_cbuf,
            self.render_target.image,
            vk::ImageLayout::GENERAL,
            vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
        );
        Self::transition_image(
            &self.device,
            frame.main_cbuf,
            swapchain_image.image,
            vk::ImageLayout::UNDEFINED,
            vk::ImageLayout::TRANSFER_DST_OPTIMAL,
        );
        Self::blit_image(
            &self.device,
            frame.main_cbuf,
            self.render_target.image,
            self.render_target.extent,
            swapchain_image.image,
            self.swapchain.extent,
        );

        // make the swapchain image usable for presenting
        Self::transition_image(
            &self.device,
            frame.main_cbuf,
            swapchain_image.image,
            vk::ImageLayout::TRANSFER_DST_OPTIMAL,
            vk::ImageLayout::PRESENT_SRC_KHR,
        );

        frame.end(&self.device)?;
        frame.submit(&self.device, self.queues.graphics)?;

        self.swapchain
            .present(swapchain_image, self.queues.present, frame.render_sema)?;

        Ok(())
    }

    pub fn draw_scene(&mut self) {}

    pub fn resize(&mut self) -> Result<()> {
        self.swapchain
            .recreate(&self.device, &self.queue_families)?;

        let target_ext = self.render_target.extent;
        let surface_ext = self.swapchain.extent;

        // resize the render target if it cant fit the swapchain image at full res
        // or when the render target is way bigger than the swapchain image
        const RENDER_TARGET_MULTIPLES: u32 = 256;
        if target_ext.width >= surface_ext.width
            && target_ext.height >= surface_ext.height
            && target_ext.width.abs_diff(surface_ext.width) <= RENDER_TARGET_MULTIPLES
            && target_ext.width.abs_diff(surface_ext.width) <= RENDER_TARGET_MULTIPLES
        {
            return Ok(());
        }

        self.frames
            .previous()
            .0
            .delete_queue
            .append(&mut self.render_target_delete_queue);
        self.render_target = Self::create_render_image(
            &self.device,
            &mut self.allocator,
            &mut self.render_target_delete_queue,
            vk::Extent2D {
                width: surface_ext.width.next_multiple_of(RENDER_TARGET_MULTIPLES),
                height: surface_ext.height.next_multiple_of(RENDER_TARGET_MULTIPLES),
            },
        )?;

        Ok(())
    }

    fn create_instance(window: &Window, entry: &Entry) -> Result<Instance> {
        let window_handle = window.display_handle().unwrap().as_raw();

        let layers = unsafe { entry.enumerate_instance_layer_properties()? };
        if tracing::enabled!(tracing::Level::DEBUG) {
            tracing::info!("layers:");
            for layer in layers.iter() {
                let name = layer
                    .layer_name_as_c_str()
                    .ok()
                    .and_then(|s| s.to_str().ok())
                    .unwrap_or("<invalid name>");
                tracing::info!(" - {name}");
            }
        }
        let validation_layer = c"VK_LAYER_KHRONOS_validation";
        let validation_layer_found = layers
            .iter()
            .any(|layer| layer.layer_name_as_c_str() == Ok(validation_layer));
        let layers = if validation_layer_found {
            &[validation_layer.as_ptr()][..]
        } else {
            &[][..]
        };
        tracing::debug!("enabled layers: {validation_layer_found} {layers:?}");

        let mut extensions = ash_window::enumerate_required_extensions(window_handle)
            .unwrap()
            .to_vec();
        extensions.push(ext::debug_utils::NAME.as_ptr());

        let app_info = vk::ApplicationInfo::default()
            .application_name(c"luminary")
            .application_version(0)
            .engine_name(c"luminary")
            .engine_version(0)
            .api_version(vk::make_api_version(0, 1, 3, 0));

        let instance_info = vk::InstanceCreateInfo::default()
            .application_info(&app_info)
            .enabled_layer_names(layers)
            .enabled_extension_names(&extensions);

        let instance = unsafe { entry.create_instance(&instance_info, None) }?;
        Ok(instance)
    }

    fn create_device(
        instance: &Instance,
        gpu: vk::PhysicalDevice,
        queue_families: &QueueFamilies,
    ) -> Result<Device> {
        let mut features13 = vk::PhysicalDeviceVulkan13Features::default()
            .synchronization2(true)
            .dynamic_rendering(true);

        let mut features12 = vk::PhysicalDeviceVulkan12Features::default()
            .buffer_device_address(true)
            .buffer_device_address_capture_replay(true)
            .descriptor_indexing(true);

        let create_info = vk::DeviceCreateInfo::default()
            .push_next(&mut features13)
            .push_next(&mut features12)
            .enabled_extension_names(&gpu::REQUIRED_EXTS_PTRPTR)
            .queue_create_infos(&queue_families.families);

        let device = unsafe { instance.create_device(gpu, &create_info, None)? };
        Ok(device)
    }

    fn create_allocator(
        instance: &Instance,
        gpu: vk::PhysicalDevice,
        device: &Device,
    ) -> Result<Allocator> {
        Ok(Allocator::new(&AllocatorCreateDesc {
            instance: instance.clone(),
            device: device.clone(),
            physical_device: gpu,
            debug_settings: <_>::default(),
            buffer_device_address: true,
            allocation_sizes: <_>::default(),
        })?)
    }

    fn create_render_image(
        device: &Device,
        allocator: &mut Allocator,
        delete_queue: &mut DeleteQueue,
        extent: vk::Extent2D,
    ) -> Result<Image> {
        let render_target = Image::builder()
            .format(vk::Format::R16G16B16A16_SFLOAT)
            .extent(extent)
            .usage(
                vk::ImageUsageFlags::TRANSFER_SRC
                    | vk::ImageUsageFlags::TRANSFER_DST
                    | vk::ImageUsageFlags::STORAGE
                    | vk::ImageUsageFlags::COLOR_ATTACHMENT,
            )
            .aspect_flags(vk::ImageAspectFlags::COLOR)
            .build(device, allocator, delete_queue)?;
        Ok(render_target)
    }

    fn transition_image(
        device: &Device,
        cbuf: vk::CommandBuffer,
        image: vk::Image,
        from: vk::ImageLayout,
        to: vk::ImageLayout,
    ) {
        let aspect = if to == vk::ImageLayout::DEPTH_STENCIL_ATTACHMENT_OPTIMAL {
            vk::ImageAspectFlags::DEPTH
        } else {
            vk::ImageAspectFlags::COLOR
        };

        let image_barrier = vk::ImageMemoryBarrier2::default()
            // the swapchain image is a copy destination
            .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
            .src_access_mask(vk::AccessFlags2::MEMORY_WRITE)
            // the new layout is read+write render target
            .dst_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
            .dst_access_mask(vk::AccessFlags2::MEMORY_WRITE | vk::AccessFlags2::MEMORY_READ)
            .old_layout(from)
            .new_layout(to)
            .src_queue_family_index(0)
            .dst_queue_family_index(0)
            .subresource_range(Self::subresource_range(aspect))
            .image(image);

        let dependency_info =
            vk::DependencyInfo::default().image_memory_barriers(slice::from_ref(&image_barrier));

        unsafe { device.cmd_pipeline_barrier2(cbuf, &dependency_info) };
    }

    fn blit_image(
        device: &Device,
        cbuf: vk::CommandBuffer,
        src: vk::Image,
        src_size: vk::Extent2D,
        dst: vk::Image,
        dst_size: vk::Extent2D,
    ) {
        let blit_region = vk::ImageBlit2::default()
            .src_offsets([
                vk::Offset3D::default().x(0).y(0).z(0),
                vk::Offset3D::default()
                    .x(src_size.width as _)
                    .y(src_size.height as _)
                    .z(1),
            ])
            .src_subresource(
                vk::ImageSubresourceLayers::default()
                    .aspect_mask(vk::ImageAspectFlags::COLOR)
                    .mip_level(0)
                    .layer_count(1)
                    .base_array_layer(0),
            )
            .dst_offsets([
                vk::Offset3D::default().x(0).y(0).z(0),
                vk::Offset3D::default()
                    .x(dst_size.width as _)
                    .y(dst_size.height as _)
                    .z(1),
            ])
            .dst_subresource(
                vk::ImageSubresourceLayers::default()
                    .aspect_mask(vk::ImageAspectFlags::COLOR)
                    .mip_level(0)
                    .layer_count(1)
                    .base_array_layer(0),
            );

        let blit_info = vk::BlitImageInfo2::default()
            .src_image(src)
            .src_image_layout(vk::ImageLayout::TRANSFER_SRC_OPTIMAL)
            .dst_image(dst)
            .dst_image_layout(vk::ImageLayout::TRANSFER_DST_OPTIMAL)
            .filter(vk::Filter::LINEAR)
            .regions(slice::from_ref(&blit_region));

        unsafe { device.cmd_blit_image2(cbuf, &blit_info) };
    }

    fn subresource_range(aspect: vk::ImageAspectFlags) -> vk::ImageSubresourceRange {
        vk::ImageSubresourceRange::default()
            .aspect_mask(aspect)
            .base_mip_level(0)
            .level_count(vk::REMAINING_MIP_LEVELS)
            .base_array_layer(0)
            .layer_count(vk::REMAINING_ARRAY_LAYERS)
    }
}

impl Drop for Graphics {
    fn drop(&mut self) {
        _ = unsafe { self.device.device_wait_idle() };

        self.render_target_delete_queue
            .flush(&self.device, &mut self.allocator);
        self.global_delete_queue
            .flush(&self.device, &mut self.allocator);

        unsafe { ManuallyDrop::drop(&mut self.allocator) };
        self.swapchain.destroy();
        unsafe { self.device.destroy_device(None) };
        self.surface.destroy(&self.instance);
        self.debug_utils.destroy(&self.instance);
    }
}
