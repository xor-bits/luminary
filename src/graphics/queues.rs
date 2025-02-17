use ash::{
    Device,
    vk::{self, Queue},
};

//

pub struct Queues {
    pub present: Queue,
    pub graphics: Queue,
    pub transfer: Queue,
    pub compute: Queue,
}

impl Queues {
    pub fn new(device: &Device, queue_families: &QueueFamilies) -> Self {
        let present = unsafe { device.get_device_queue(queue_families.present, 0) };
        let graphics = unsafe { device.get_device_queue(queue_families.graphics, 0) };
        let transfer = unsafe { device.get_device_queue(queue_families.transfer, 0) };
        let compute = unsafe { device.get_device_queue(queue_families.compute, 0) };

        Self {
            present,
            graphics,
            transfer,
            compute,
        }
    }
}

//

#[derive(Debug)]
pub struct QueueFamilies {
    pub present: u32,
    pub graphics: u32,
    pub transfer: u32,
    pub compute: u32,

    pub families: Box<[vk::DeviceQueueCreateInfo<'static>]>,
}
