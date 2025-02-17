use std::{mem::ManuallyDrop, sync::Arc};

use ash::{Device, Entry, Instance, ext, vk};
use eyre::Result;
use gpu_allocator::vulkan::{Allocator, AllocatorCreateDesc};
use winit::{dpi::PhysicalSize, raw_window_handle::HasDisplayHandle, window::Window};

use self::{
    debug::DebugUtils,
    frame::FramesInFlight,
    gpu::pick_gpu,
    queues::{QueueFamilies, Queues},
    surface::Surface,
    swapchain::Swapchain,
};

//

mod debug;
mod frame;
mod gpu;
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
}

impl Graphics {
    pub fn new(window: Arc<Window>) -> Result<Self> {
        let size = window.inner_size();
        let extent = vk::Extent2D {
            width: size.width,
            height: size.height,
        };

        let entry = ash::Entry::linked();

        let instance = Self::create_instance(&window, &entry)?;

        let debug_utils = DebugUtils::new(&entry, &instance)?;

        let surface = Surface::new(window, &entry, &instance)?;

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
        )?;

        let allocator = ManuallyDrop::new(Self::create_allocator(&instance, gpu, &device)?);

        let frames = FramesInFlight::new(&device, &queue_families)?;

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
        })
    }

    pub fn draw(&mut self) -> Result<()> {
        let (frame, _) = self.frames.next();
        frame.wait(&self.device)?;

        let swapchain_image = self
            .swapchain
            .acquire(frame.swapchain_sema, &self.queue_families)?;

        frame.begin(&self.device)?;

        // self.device.cmd_clear_attachments(frame.main_cbuf, &[vk::ClearAttachment::], rects);

        frame.end(&self.device)?;
        frame.submit(&self.device, self.queues.graphics)?;

        self.swapchain
            .present(swapchain_image, self.queues.present, frame.render_sema)?;

        Ok(())
    }

    pub fn resize(&mut self, size: PhysicalSize<u32>) -> Result<()> {
        self.swapchain.recreate(
            &self.queue_families,
            vk::Extent2D {
                width: size.width,
                height: size.height,
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
}

impl Drop for Graphics {
    fn drop(&mut self) {
        self.frames.destroy(&self.device);
        self.swapchain.destroy();
        unsafe { ManuallyDrop::drop(&mut self.allocator) };
        unsafe { self.device.destroy_device(None) };
        self.surface.destroy(&self.instance);
        self.debug_utils.destroy(&self.instance);
    }
}
