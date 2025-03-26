use std::{ffi::c_void, ptr::NonNull, slice};

use ash::{Device, vk};
use eyre::Result;
use gpu_allocator::{
    MemoryLocation,
    vulkan::{AllocationCreateDesc, AllocationScheme, Allocator},
};

use super::delete_queue::DeleteQueue;

//

//

pub struct Buffer {
    pub buffer: vk::Buffer,
    pub size: u64,
    ptr: Option<SyncPtr>,
}

impl Buffer {
    pub fn as_slice(&self) -> Option<&[u8]> {
        self.ptr.map(|ptr| unsafe {
            slice::from_raw_parts(ptr.0.as_ptr().cast(), self.size as usize)
        })
    }

    pub fn as_slice_mut(&mut self) -> Option<&mut [u8]> {
        self.ptr.map(|ptr| unsafe {
            slice::from_raw_parts_mut(ptr.0.as_ptr().cast(), self.size as usize)
        })
    }

    pub const fn builder() -> BufferBuilder {
        BufferBuilder {
            capacity: 0,
            usage: vk::BufferUsageFlags::empty(),
            location: MemoryLocation::GpuOnly,
        }
    }
}

//

pub struct BufferBuilder {
    capacity: usize,
    usage: vk::BufferUsageFlags,
    location: MemoryLocation,
}

impl BufferBuilder {
    pub const fn capacity(&mut self, capacity: usize) -> &mut Self {
        self.capacity = capacity;
        self
    }

    pub const fn usage(&mut self, usage: vk::BufferUsageFlags) -> &mut Self {
        self.usage = usage;
        self
    }

    pub const fn location(&mut self, location: MemoryLocation) -> &mut Self {
        self.location = location;
        self
    }

    pub fn build(
        &self,
        device: &Device,
        allocator: &mut Allocator,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Buffer> {
        let create_info = vk::BufferCreateInfo::default()
            .size(self.capacity as u64)
            .usage(self.usage);

        let buffer = unsafe { device.create_buffer(&create_info, None)? };
        delete_queue.push(buffer);
        let requirements =
            unsafe { device.get_buffer_memory_requirements(buffer) };

        let alloc_desc = AllocationCreateDesc {
            name: "",
            requirements,
            location: self.location,
            linear: true,
            allocation_scheme: AllocationScheme::GpuAllocatorManaged,
        };

        let allocation = allocator.allocate(&alloc_desc)?;
        let size = self.capacity as u64;
        let offset = allocation.offset();
        let ptr = allocation.mapped_ptr().map(SyncPtr);
        let memory = unsafe { allocation.memory() };
        delete_queue.push(allocation);

        unsafe { device.bind_buffer_memory(buffer, memory, offset)? };

        Ok(Buffer { buffer, size, ptr })
    }
}

//

#[derive(Clone, Copy)]
struct SyncPtr(NonNull<c_void>);
unsafe impl Sync for SyncPtr {}
