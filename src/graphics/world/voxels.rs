use std::{mem, slice};

use ash::{Device, vk};
use bytemuck::{Pod, Zeroable};
use eyre::Result;
use gpu_allocator::{MemoryLocation, vulkan::Allocator};

use crate::graphics::{
    buffer::Buffer, delete_queue::DeleteQueue, immediate::Immediate,
};

//

pub struct VoxelStructure {
    pub buffer: Buffer,
}

impl VoxelStructure {
    pub fn new(
        device: &Device,
        imm: &Immediate,
        allocator: &mut Allocator,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Self> {
        let mut basic_grid: Vec<Voxel> = Vec::with_capacity(32 * 32 * 32);
        for i in 0..basic_grid.capacity() {
            let x = i & 31;
            let y = (i >> 5) & 31;
            let z = (i >> 10) & 31;

            let is_corner = (x == 0 || x == 31)
                && (y == 0 || y == 31)
                && (z == 0 || z == 31);

            let is_ball = (x.abs_diff(16).pow(2)
                + y.abs_diff(16).pow(2)
                + z.abs_diff(16).pow(2))
                <= 99;

            let is_solid = is_corner || is_ball;

            assert_eq!(basic_grid.len(), i);
            basic_grid.push(Voxel {
                col: is_solid as u8,
            });

            if is_solid {
                tracing::info!("i={i:05} x={x:02} y={y:02} z={z:02}");
            }
        }

        let voxel_buffer = Buffer::builder()
            .capacity(basic_grid.len() * mem::size_of::<Voxel>())
            .usage(
                vk::BufferUsageFlags::STORAGE_BUFFER
                    | vk::BufferUsageFlags::TRANSFER_DST,
            )
            .location(MemoryLocation::GpuOnly)
            .build(device, allocator, delete_queue)?;

        let mut tmp_delete_queue = DeleteQueue::new();

        let mut stage_buffer = Buffer::builder()
            .capacity(basic_grid.len() * mem::size_of::<Voxel>())
            .usage(vk::BufferUsageFlags::TRANSFER_SRC)
            .location(MemoryLocation::CpuToGpu)
            .build(device, allocator, &mut tmp_delete_queue)?;

        let stage_buffer_memory = stage_buffer
            .as_slice_mut()
            .expect("stage buffer should be CPU mappable");

        stage_buffer_memory.copy_from_slice(bytemuck::cast_slice(&basic_grid));

        imm.submit(device, |cbuf| {
            let copy = vk::BufferCopy::default()
                .src_offset(0)
                .dst_offset(0)
                .size(stage_buffer.size);

            unsafe {
                device.cmd_copy_buffer(
                    cbuf,
                    stage_buffer.buffer,
                    voxel_buffer.buffer,
                    slice::from_ref(&copy),
                );
            }

            Ok(())
        })?;

        tmp_delete_queue.flush(device, allocator);

        Ok(Self {
            buffer: voxel_buffer,
        })

        // device.map_memory(memory, offset, size, flags)

        // allocator.allocate(desc)

        // Ok(Self {})
    }
}

#[derive(Debug, Clone, Copy, Pod, Zeroable)]
#[repr(C)]
pub struct Node {
    /// relative offset in the buffer to the next 8 nodes or voxels
    children: i16,
    /// which next children are final voxels and which are nodes
    child_mask: u8,
    /// average of the next levels, lower LOD
    average: u8,
}

#[derive(Debug, Clone, Copy, Pod, Zeroable)]
#[repr(C)]
pub struct Voxel {
    col: u8,
}
