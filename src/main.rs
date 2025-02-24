#![allow(internal_features)]
#![feature(
    core_intrinsics,
    unsigned_is_multiple_of,
    const_heap,
    alloc_layout_extra,
    ptr_as_uninit,
    maybe_uninit_slice
)]

use std::sync::Arc;

use eyre::Result;
use glam::{Vec2, Vec3};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::{DeviceEvent, DeviceId, ElementState, KeyEvent, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::{KeyCode, PhysicalKey},
    window::{CursorGrabMode, Window, WindowId},
};

use self::graphics::Graphics;

//

mod counter;
mod flycam;
mod graphics;
mod renderer;

//

#[derive(Default)]
struct App {
    inner: Option<AppInner>,
}

struct AppInner {
    window: Arc<Window>,
    graphics: Graphics,
    eye: flycam::Flycam,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        self.inner.get_or_insert_with(|| {
            let window: Arc<Window> = event_loop
                .create_window(
                    Window::default_attributes()
                        .with_title("luminar")
                        .with_inner_size(PhysicalSize::<u32>::from((
                            64u32, 64u32,
                        ))),
                )
                .unwrap()
                .into();

            window.set_cursor_grab(CursorGrabMode::Confined).unwrap();

            let graphics = Graphics::new(window.clone())
                .expect("failed to initialize graphics");

            let eye = flycam::Flycam::new();

            AppInner {
                window,
                graphics,
                eye,
            }
        });
    }

    fn window_event(
        &mut self,
        el: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
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
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::KeyA),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.movement(Vec3::new(-1.0, 0.0, 0.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::KeyD),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.movement(Vec3::new(1.0, 0.0, 0.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::KeyW),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.movement(Vec3::new(0.0, 0.0, 1.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::KeyS),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.movement(Vec3::new(0.0, 0.0, -1.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::ArrowLeft),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.mouse_delta(Vec2::new(-20.0, 0.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::ArrowRight),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.mouse_delta(Vec2::new(20.0, 0.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::ArrowUp),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.mouse_delta(Vec2::new(0.0, 20.0));
            }
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::ArrowDown),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.eye.mouse_delta(Vec2::new(0.0, -20.0));
            }
            WindowEvent::RedrawRequested => {
                inner
                    .graphics
                    .draw(inner.eye.view_matrix())
                    .expect("failed to draw");
            }
            WindowEvent::Resized(size) => {
                inner.graphics.resize().expect("failed to resize");
                tracing::debug!("resized to {}x{}", size.width, size.height);
            }
            _ => {}
        }
    }

    fn device_event(
        &mut self,
        _: &ActiveEventLoop,
        _: DeviceId,
        event: DeviceEvent,
    ) {
        let Some(inner) = self.inner.as_mut() else {
            return;
        };

        if let DeviceEvent::MouseMotion { delta } = event {
            inner
                .eye
                .mouse_delta(Vec2::new(-delta.0 as _, -delta.1 as _));
        }
    }

    fn about_to_wait(&mut self, _: &ActiveEventLoop) {
        let Some(inner) = self.inner.as_mut() else {
            return;
        };
        inner
            .graphics
            .draw(inner.eye.view_matrix())
            .expect("failed to draw");
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
