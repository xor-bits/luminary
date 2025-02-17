//

use ash::{Device, vk};
use eyre::Result;
use gpu_allocator::vulkan::{Allocation, Allocator};

/// deletes vulkan objects in FILO (stack) order
pub struct DeleteQueue {
    inner: Vec<DeletionEntry>,
}

impl DeleteQueue {
    pub fn new() -> Self {
        Self { inner: Vec::new() }
    }

    #[track_caller]
    pub fn push(&mut self, object: impl Into<DeletionEntry>) {
        tracing::debug!(
            "added object to be deleted {} (len={})",
            std::panic::Location::caller(),
            self.inner.len()
        );
        self.inner.push(object.into());
    }

    /// move deletion entries from another queue to this one,
    /// keeps the ordering but places everything after the last one in `self`
    pub fn append(&mut self, from: &mut DeleteQueue) {
        self.inner.append(&mut from.inner);
    }

    pub fn flush(&mut self, device: &Device, alloc: &mut Allocator) {
        if self.inner.is_empty() {
            return;
        }

        tracing::debug!("deleting {} objects", self.inner.len());
        for object in self.inner.drain(..).rev() {
            if let Err(err) = object.destroy(device, alloc) {
                tracing::error!("failed to destroy object: {err}");
            }
        }
    }
}

impl Drop for DeleteQueue {
    fn drop(&mut self) {
        if self.inner.is_empty() {
            return;
        }

        tracing::error!("delete queue dropped without flushing");
    }
}

//

#[must_use]
pub enum DeletionEntry {
    Semaphore(vk::Semaphore),
    Fence(vk::Fence),
    CommandPool(vk::CommandPool),
    Image(vk::Image),
    ImageView(vk::ImageView),
    Allocation(Allocation),
}

impl DeletionEntry {
    pub fn destroy(self, device: &Device, alloc: &mut Allocator) -> Result<()> {
        match self {
            DeletionEntry::Semaphore(semaphore) => unsafe {
                tracing::debug!("deleting semaphore");
                device.destroy_semaphore(semaphore, None);
            },
            DeletionEntry::Fence(fence) => unsafe {
                tracing::debug!("deleting fence");
                device.destroy_fence(fence, None);
            },
            DeletionEntry::CommandPool(command_pool) => unsafe {
                tracing::debug!("deleting command pool");
                device.destroy_command_pool(command_pool, None);
            },
            DeletionEntry::Image(image) => unsafe {
                tracing::debug!("deleting image");
                device.destroy_image(image, None);
            },
            DeletionEntry::ImageView(image_view) => unsafe {
                tracing::debug!("deleting imageview");
                device.destroy_image_view(image_view, None);
            },
            DeletionEntry::Allocation(allocation) => {
                tracing::debug!("deleting allocation");
                alloc.free(allocation)?;
            }
        }

        Ok(())
    }
}

impl From<Allocation> for DeletionEntry {
    fn from(value: Allocation) -> Self {
        Self::Allocation(value)
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

impl_from! {
    Semaphore, Fence, CommandPool, Image, ImageView,
}
