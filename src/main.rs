#![allow(internal_features)]
#![feature(
    core_intrinsics,
    unsigned_is_multiple_of,
    const_heap,
    alloc_layout_extra,
    ptr_as_uninit,
    maybe_uninit_slice
)]

use std::{default, sync::Arc, time::Instant};

use eyre::Result;
use glam::{Vec2, Vec3};
use rustc_hash::{FxHashMap, FxHashSet};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::{
        DeviceEvent, DeviceId, ElementState, KeyEvent, MouseScrollDelta,
        WindowEvent,
    },
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
    dt: Instant,
    speed: f32,

    cursor_visible: bool,

    just_pressed: FxHashSet<KeyCode>,
    just_released: FxHashSet<KeyCode>,
    pressed: FxHashSet<KeyCode>,
}

impl AppInner {
    pub fn render(&mut self) {
        self.update();

        self.graphics
            .draw(self.eye.view_matrix())
            .expect("failed to draw");
    }

    pub fn update(&mut self) {
        let delta_seconds = self.dt.elapsed().as_secs_f32();
        self.dt = Instant::now();

        let mut delta = Vec3::ZERO;
        if self.pressed.contains(&KeyCode::KeyA) {
            delta.x -= 1.0;
        }
        if self.pressed.contains(&KeyCode::KeyD) {
            delta.x += 1.0;
        }
        if self.pressed.contains(&KeyCode::KeyS) {
            delta.z -= 1.0;
        }
        if self.pressed.contains(&KeyCode::KeyW) {
            delta.z += 1.0;
        }
        if self.pressed.contains(&KeyCode::ShiftLeft) {
            delta.y -= 1.0;
        }
        if self.pressed.contains(&KeyCode::Space) {
            delta.y += 1.0;
        }
        if self.pressed.contains(&KeyCode::ControlLeft) {
            delta *= 0.2;
        }
        self.eye.movement(delta * delta_seconds * 10.0 * self.speed);

        self.just_pressed.clear();
        self.just_released.clear();
    }

    pub fn ev(&mut self, ev: &WindowEvent) {
        let WindowEvent::KeyboardInput {
            event:
                KeyEvent {
                    physical_key: PhysicalKey::Code(code),
                    state,
                    ..
                },
            ..
        } = ev
        else {
            return;
        };

        match state {
            ElementState::Pressed => {
                self.just_pressed.insert(*code);
                self.pressed.insert(*code);
            }
            ElementState::Released => {
                self.just_released.insert(*code);
                self.pressed.remove(code);
            }
        }
    }
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

            let graphics = Graphics::new(window.clone())
                .expect("failed to initialize graphics");

            let eye = flycam::Flycam::new();

            AppInner {
                window,
                graphics,
                eye,
                dt: Instant::now(),
                speed: 1.0,

                cursor_visible: true,

                just_pressed: <_>::default(),
                just_released: <_>::default(),
                pressed: <_>::default(),
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

        inner.ev(&event);

        // tracing::debug!("event: {event:?}");

        match event {
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::Escape),
                        state: ElementState::Pressed,
                        ..
                    },
                ..
            } => {
                inner.cursor_visible ^= true;
                inner
                    .window
                    .set_cursor_grab(if inner.cursor_visible {
                        CursorGrabMode::None
                    } else {
                        CursorGrabMode::Confined
                    })
                    .unwrap();
                inner.window.set_cursor_visible(inner.cursor_visible);
            }
            WindowEvent::CloseRequested => {
                println!("closing");
                el.exit();
            }
            WindowEvent::RedrawRequested => {
                inner.render();
            }
            WindowEvent::MouseWheel {
                delta: MouseScrollDelta::LineDelta(x, y),
                ..
            } => {
                inner.speed = 2.0f32.powf(inner.speed.log2() + y * 0.25);
                // tracing::info!("speed={} delta={y}", inner.speed);
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

        if inner.cursor_visible {
            return;
        }

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
        inner.render();
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
