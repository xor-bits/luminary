use std::sync::Arc;

use ash::{Entry, Instance, ext, vk};
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
}

impl Graphics {
    pub fn new(window: Arc<Window>) -> Result<Self> {
        let window_handle = window.display_handle().unwrap().as_raw();

        let entry = ash::Entry::linked();

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

        let debug_utils = DebugUtils::new(&entry, &instance)?;

        let surface = Surface::new(window, &entry, &instance)?;

        let (gpu, queue_families) = pick_gpu(&entry, &instance, surface.inner)?;

        Ok(Self {
            entry,
            instance,
            debug_utils,
            surface,

            gpu,
            queue_families,
        })
    }

    pub fn draw(&mut self) {}
}

impl Drop for Graphics {
    fn drop(&mut self) {
        self.surface.destroy(&self.instance);
        self.debug_utils.destroy(&self.instance);
    }
}
