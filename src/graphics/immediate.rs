use std::slice;

use ash::{Device, vk};
use eyre::Result;

//

pub struct Immediate {
    pool: vk::CommandPool,
    cbuf: vk::CommandBuffer,
    fence: vk::Fence,

    // not owned
    queue: vk::Queue,
}

impl Immediate {
    pub fn new(
        device: &Device,
        queue: vk::Queue,
        queue_family: u32,
    ) -> Result<Self> {
        let create_info = vk::CommandPoolCreateInfo::default()
            .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER)
            .queue_family_index(queue_family);

        let pool = unsafe { device.create_command_pool(&create_info, None)? };

        let allocate_info = vk::CommandBufferAllocateInfo::default()
            .command_pool(pool)
            .level(vk::CommandBufferLevel::PRIMARY)
            .command_buffer_count(1);

        let cbufs = unsafe { device.allocate_command_buffers(&allocate_info)? };
        let cbuf = cbufs.into_iter().next().unwrap();

        let fence = unsafe {
            device.create_fence(&vk::FenceCreateInfo::default(), None)?
        };

        Ok(Self {
            pool,
            cbuf,
            fence,
            queue,
        })
    }

    pub fn destroy(&self, device: &Device) {
        unsafe { device.destroy_fence(self.fence, None) };
        unsafe { device.destroy_command_pool(self.pool, None) };
    }

    pub fn submit<T>(
        &self,
        device: &Device,
        f: impl FnOnce(vk::CommandBuffer) -> Result<T>,
    ) -> Result<T> {
        unsafe {
            device.reset_fences(&[self.fence])?;
        }

        unsafe {
            device.reset_command_buffer(
                self.cbuf,
                vk::CommandBufferResetFlags::empty(),
            )?;
        }

        let begin_info = vk::CommandBufferBeginInfo::default()
            .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT);

        unsafe {
            device.begin_command_buffer(self.cbuf, &begin_info)?;
        }

        let val = f(self.cbuf)?;

        unsafe {
            device.end_command_buffer(self.cbuf)?;
        }

        let cbuf_submit_info = vk::CommandBufferSubmitInfo::default()
            .command_buffer(self.cbuf)
            .device_mask(0);
        let submit_info = vk::SubmitInfo2::default()
            .command_buffer_infos(slice::from_ref(&cbuf_submit_info));

        unsafe {
            device.queue_submit2(
                self.queue,
                slice::from_ref(&submit_info),
                self.fence,
            )?;
        }

        unsafe {
            device.wait_for_fences(
                slice::from_ref(&self.fence),
                true,
                1_000_000_000,
            )?;
        }

        Ok(val)
    }
}
