//

use ash::{Device, vk};

/// deletes vulkan objects in FILO (stack) order
pub struct DeleteQueue {
    inner: Vec<DeletionEntry>,
}

impl DeleteQueue {
    pub fn new() -> Self {
        Self { inner: Vec::new() }
    }

    pub fn push(&mut self, object: impl Into<DeletionEntry>) {
        self.inner.push(object.into());
    }

    pub fn flush(&mut self, device: &Device) {
        for object in self.inner.drain(..).rev() {
            object.destroy(device);
        }
    }
}

//

#[must_use]
pub enum DeletionEntry {
    Semaphore(vk::Semaphore),
    Fence(vk::Fence),
    CommandPool(vk::CommandPool),
}

impl DeletionEntry {
    pub fn destroy(self, device: &Device) {
        match self {
            DeletionEntry::Semaphore(semaphore) => unsafe {
                device.destroy_semaphore(semaphore, None);
            },
            DeletionEntry::Fence(fence) => unsafe {
                device.destroy_fence(fence, None);
            },
            DeletionEntry::CommandPool(command_pool) => unsafe {
                device.destroy_command_pool(command_pool, None);
            },
        }
    }
}

macro_rules! impl_from {
    ($($ty:ident),* $(,)?) => {$(
        impl From<vk::$ty> for DeletionEntry {
            fn from(value: vk::$ty) -> Self {
                Self::$ty(value)
            }
        }
    )*};
}

impl_from! { Semaphore, Fence, CommandPool }
