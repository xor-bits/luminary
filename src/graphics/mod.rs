use std::sync::Arc;

use ash::{Device, Entry, Instance, ext, vk};
use eyre::Result;
use winit::{raw_window_handle::HasDisplayHandle, window::Window};

use self::{
    debug::DebugUtils,
    gpu::{QueueFamilies, pick_gpu},
    surface::Surface,
};

//

mod debug;
mod gpu;
mod surface;

//

pub struct Graphics {
    entry: Entry,
    instance: Instance,
    debug_utils: DebugUtils,
    surface: Surface,

    gpu: vk::PhysicalDevice,
    queue_families: QueueFamilies,

    device: Device,
}

impl Graphics {
    pub fn new(window: Arc<Window>) -> Result<Self> {
        let entry = ash::Entry::linked();

        let instance = Self::create_instance(&window, &entry)?;

        let debug_utils = DebugUtils::new(&entry, &instance)?;

        let surface = Surface::new(window, &entry, &instance)?;

        let (gpu, queue_families) = pick_gpu(&entry, &instance, surface.inner)?;

        let device = Self::create_device(&instance, gpu, &queue_families)?;

        Ok(Self {
            entry,
            instance,
            debug_utils,
            surface,

            gpu,
            queue_families,

            device,
        })
    }

    pub fn draw(&mut self) {}

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
}

impl Drop for Graphics {
    fn drop(&mut self) {
        unsafe { self.device.destroy_device(None) };
        self.surface.destroy(&self.instance);
        self.debug_utils.destroy(&self.instance);
    }
}
