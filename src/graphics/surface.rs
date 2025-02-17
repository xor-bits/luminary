use std::{ptr, sync::Arc};

use ash::{
    Entry, Instance,
    khr::surface,
    vk::{self, Handle},
};
use eyre::Result;
use winit::{
    raw_window_handle::{HasDisplayHandle, HasWindowHandle},
    window::Window,
};

use crate::cold;

//

pub struct Surface {
    pub inner: vk::SurfaceKHR,
    destroy_fp: vk::PFN_vkDestroySurfaceKHR,

    /// keeps the surface alive
    #[allow(dead_code)]
    window: Arc<Window>,
}

impl Surface {
    pub fn new(window: Arc<Window>, entry: &Entry, instance: &Instance) -> Result<Self> {
        let display_handle = window.display_handle().unwrap().as_raw();
        let window_handle = window.window_handle().unwrap().as_raw();

        let surface = unsafe {
            ash_window::create_surface(entry, instance, display_handle, window_handle, None)?
        };

        let destroy_fp = surface::Instance::new(entry, instance)
            .fp()
            .destroy_surface_khr;

        Ok(Self {
            inner: surface,
            window,
            destroy_fp,
        })
    }

    pub fn destroy(&mut self, instance: &Instance) {
        if self.inner.is_null() {
            cold();
            return;
        }

        unsafe {
            (self.destroy_fp)(instance.handle(), self.inner, ptr::null());
        }
        self.inner = vk::SurfaceKHR::null();
    }
}
