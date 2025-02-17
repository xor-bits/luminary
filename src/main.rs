use std::sync::Arc;

use eyre::Result;
use winit::{
    application::ApplicationHandler,
    event::{ElementState, KeyEvent, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::{KeyCode, PhysicalKey},
    window::{Window, WindowId},
};

use self::graphics::Graphics;

//

mod graphics;

//

#[derive(Default)]
struct App {
    inner: Option<AppInner>,
}

struct AppInner {
    window: Arc<Window>,
    graphics: Graphics,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        self.inner.get_or_insert_with(|| {
            let window: Arc<Window> = event_loop
                .create_window(Window::default_attributes().with_title("luminar"))
                .unwrap()
                .into();

            let graphics = Graphics::new(window.clone()).expect("failed to initialize graphics");

            AppInner { window, graphics }
        });
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _window_id: WindowId, event: WindowEvent) {
        let Some(inner) = self.inner.as_mut() else {
            return;
        };

        match event {
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::Escape),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            }
            | WindowEvent::CloseRequested => {
                println!("closing");
                el.exit();
            }
            WindowEvent::RedrawRequested => {
                inner.graphics.draw();
            }
            _ => {}
        }
    }
}

//

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    color_eyre::install()?;

    let el = EventLoop::new()?;
    el.set_control_flow(ControlFlow::Poll);
    el.run_app(&mut App::default())?;

    Ok(())
}

/// just a function to mark some branch as cold
#[cold]
fn cold() {}
