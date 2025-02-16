use ash::{
    ext,
    vk::{self},
};
use winit::{
    application::ApplicationHandler,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    raw_window_handle::HasDisplayHandle,
    window::{Window, WindowId},
};

//

#[derive(Default)]
struct App {
    inner: Option<AppInner>,
}

struct AppInner {
    window: Window,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        self.inner.get_or_insert_with(|| {
            let window = event_loop
                .create_window(Window::default_attributes().with_title("luminar"))
                .unwrap();

            let entry = ash::Entry::linked();

            let validation_layer = c"VK_LAYER_KHRONOS_validation";
            let validation_layer_found = unsafe { entry.enumerate_instance_layer_properties() }
                .unwrap()
                .iter()
                .any(|layer| layer.layer_name_as_c_str() == Ok(validation_layer));

            let layers = if validation_layer_found {
                &[validation_layer.as_ptr()][..]
            } else {
                &[][..]
            };

            let mut extensions = ash_window::enumerate_required_extensions(
                window.display_handle().unwrap().as_raw(),
            )
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

            let instance = unsafe { entry.create_instance(&instance_info, None) }.unwrap();
            _ = instance;

            AppInner { window }
        });
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _window_id: WindowId, event: WindowEvent) {
        let Some(inner) = self.inner.as_mut() else {
            return;
        };

        match event {
            WindowEvent::CloseRequested => {
                println!("closing");
                el.exit();
            }
            WindowEvent::RedrawRequested => {
                _ = inner;
            }
            _ => {}
        }
    }
}

//

fn main() {
    let el = EventLoop::new().unwrap();
    el.set_control_flow(ControlFlow::Poll);
    el.run_app(&mut App::default()).unwrap();
}
