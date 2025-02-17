use core::slice;

use ash::{Device, vk};
use eyre::{Result, eyre};
use gpu_allocator::vulkan::Allocator;

use super::{delete_queue::DeleteQueue, queues::QueueFamilies};

//

pub struct FramesInFlight {
    frame: usize,
    frames: [FrameInFlight; 2],
}

impl FramesInFlight {
    pub fn new(
        device: &Device,
        queue_families: &QueueFamilies,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Self> {
        Ok({
            Self {
                frame: 0,
                frames: [
                    FrameInFlight::new(device, queue_families, delete_queue)?,
                    FrameInFlight::new(device, queue_families, delete_queue)?,
                ],
            }
        })
    }

    pub fn next(&mut self) -> (&mut FrameInFlight, usize) {
        let idx = self.frame;
        self.increment();
        (&mut self.frames[idx], idx)
    }

    pub fn current(&mut self) -> (&mut FrameInFlight, usize) {
        let idx = self.frame;
        (&mut self.frames[idx], idx)
    }

    pub fn previous(&mut self) -> (&mut FrameInFlight, usize) {
        let idx = self.frame.wrapping_sub(1).min(self.frames.len() - 1);
        (&mut self.frames[idx], idx)
    }

    pub fn increment(&mut self) {
        self.frame = (self.frame + 1) % self.frames.len();
    }

    pub fn get(&mut self, i: usize) -> &mut FrameInFlight {
        &mut self.frames[i]
    }
}

pub struct FrameInFlight {
    pub command_pool: vk::CommandPool,
    pub main_cbuf: vk::CommandBuffer,

    /// render cmds need to wait for the swapchain image
    pub swapchain_sema: vk::Semaphore,
    /// used to present the img once its rendered
    pub render_sema: vk::Semaphore,
    /// used to wait for this frame to be complete
    pub render_fence: vk::Fence,

    pub delete_queue: DeleteQueue,
}

impl FrameInFlight {
    pub fn new(
        device: &Device,
        queue_families: &QueueFamilies,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Self> {
        let create_info = vk::CommandPoolCreateInfo::default()
            .queue_family_index(queue_families.graphics)
            .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER);

        let command_pool = unsafe { device.create_command_pool(&create_info, None)? };
        delete_queue.push(command_pool);

        let alloc_info = vk::CommandBufferAllocateInfo::default()
            .command_pool(command_pool)
            .level(vk::CommandBufferLevel::PRIMARY)
            .command_buffer_count(1);

        let main_cbuf = unsafe {
            device
                .allocate_command_buffers(&alloc_info)?
                .into_iter()
                .next()
                .ok_or_else(|| eyre!("did not get any command buffers"))?
        };

        let create_info = vk::SemaphoreCreateInfo::default();
        let swapchain_sema = unsafe { device.create_semaphore(&create_info, None)? };
        delete_queue.push(swapchain_sema);
        let render_sema = unsafe { device.create_semaphore(&create_info, None)? };
        delete_queue.push(render_sema);

        let create_info = vk::FenceCreateInfo::default().flags(vk::FenceCreateFlags::SIGNALED);
        let render_fence = unsafe { device.create_fence(&create_info, None)? };
        delete_queue.push(render_fence);

        Ok(Self {
            command_pool,
            main_cbuf,
            swapchain_sema,
            render_sema,
            render_fence,
            delete_queue: DeleteQueue::new(),
        })
    }

    pub fn wait(&mut self, device: &Device, alloc: &mut Allocator) -> Result<()> {
        unsafe { device.wait_for_fences(&[self.render_fence], true, 1_000_000_000)? };
        unsafe { device.reset_fences(&[self.render_fence])? };

        self.delete_queue.flush(device, alloc);

        Ok(())
    }

    pub fn begin(&mut self, device: &Device) -> Result<()> {
        unsafe {
            device.reset_command_buffer(self.main_cbuf, vk::CommandBufferResetFlags::empty())?
        };

        let begin_info = vk::CommandBufferBeginInfo::default()
            .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT);
        unsafe { device.begin_command_buffer(self.main_cbuf, &begin_info)? };

        Ok(())
    }

    pub fn end(&mut self, device: &Device) -> Result<()> {
        unsafe { device.end_command_buffer(self.main_cbuf)? };
        Ok(())
    }

    pub fn submit(&mut self, device: &Device, queue: vk::Queue) -> Result<()> {
        let wait_info = vk::SemaphoreSubmitInfo::default()
            .semaphore(self.swapchain_sema)
            .stage_mask(vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT)
            .device_index(0)
            .value(1);

        let signal_info = vk::SemaphoreSubmitInfo::default()
            .semaphore(self.render_sema)
            .stage_mask(vk::PipelineStageFlags2::ALL_GRAPHICS)
            .device_index(0)
            .value(1);

        let cmd_info = vk::CommandBufferSubmitInfo::default()
            .command_buffer(self.main_cbuf)
            .device_mask(0);

        let submit_info = vk::SubmitInfo2::default()
            .wait_semaphore_infos(slice::from_ref(&wait_info))
            .signal_semaphore_infos(slice::from_ref(&signal_info))
            .command_buffer_infos(slice::from_ref(&cmd_info));

        unsafe { device.queue_submit2(queue, slice::from_ref(&submit_info), self.render_fence)? };

        Ok(())
    }
}
