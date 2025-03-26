use std::{mem, slice};

use ash::{Device, Instance, vk};
use bytemuck::{Pod, Zeroable};
use eyre::Result;
use glam::{U64Vec3, UVec3};
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
        instance: &Instance,
        device: &Device,
        imm: &Immediate,
        allocator: &mut Allocator,
        delete_queue: &mut DeleteQueue,
    ) -> Result<Self> {
        let mut octree_data: Vec<Voxel> = vec![Voxel {
            col: 0,
            child_pointer: 0,
            valid_mask: 0,
            leaf_mask: 0,
        }];

        for i in 0..(32 * 32 * 32) as usize {
            let x = i & 31;
            let y = (i >> 5) & 31;
            let z = (i >> 10) & 31;

            let is_corner = (x == 0 || x == 31)
                && (y == 0 || y == 31)
                && (z == 0 || z == 31);

            let is_ball = (x.abs_diff(16).pow(2)
                + y.abs_diff(16).pow(2)
                + z.abs_diff(16).pow(2))
                <= 120;

            let is_cross = (x.abs_diff(16) <= 1 && y.abs_diff(16) <= 1)
                || (x.abs_diff(16) <= 1 && z.abs_diff(16) <= 1)
                || (y.abs_diff(16) <= 1 && z.abs_diff(16) <= 1);

            let is_solid = (is_corner || is_ball) && !is_cross;
            // let is_solid = is_corner;

            if !is_solid {
                continue;
            }

            let col = 1 + (i % 3) as u8;

            Self::insert_voxel(
                &mut octree_data,
                U64Vec3::new(x as _, y as _, z as _),
                col as u32,
            );

            // if is_solid {
            //     tracing::info!("i={i:05} x={x:02} y={y:02} z={z:02}");
            // }
        }

        // tracing::info!("octree: {octree_data:#?}");

        tracing::info!(
            "voxel data = {}B",
            octree_data.len() * mem::size_of::<Voxel>()
        );

        let voxel_buffer = Buffer::builder()
            .capacity(octree_data.len() * mem::size_of::<Voxel>())
            .usage(
                vk::BufferUsageFlags::STORAGE_BUFFER
                    | vk::BufferUsageFlags::TRANSFER_DST,
            )
            .location(MemoryLocation::GpuOnly)
            .build(device, allocator, delete_queue)?;

        let mut tmp_delete_queue = DeleteQueue::new();

        let mut stage_buffer = Buffer::builder()
            .capacity(octree_data.len() * mem::size_of::<Voxel>())
            .usage(vk::BufferUsageFlags::TRANSFER_SRC)
            .location(MemoryLocation::CpuToGpu)
            .build(device, allocator, &mut tmp_delete_queue)?;

        let stage_buffer_memory = stage_buffer
            .as_slice_mut()
            .expect("stage buffer should be CPU mappable");

        stage_buffer_memory[..octree_data.len() * mem::size_of::<Voxel>()]
            .copy_from_slice(bytemuck::cast_slice(&octree_data));

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

        // TODO: make one AABB per voxel octree,
        // then use the intersection shader to run DDA algorithm
        // to raycast the voxels (hardware raytracing is shit for
        // voxel data, because the octree voxel data is already in
        // an optimal format for traversal)
        //
        // hardware ray tracing acceleration could later be used
        // for having other ray traced objects in the scene, like
        // the player, particles, vehicles, ..

        Ok(Self {
            buffer: voxel_buffer,
        })
    }

    fn insert_voxel(octree: &mut Vec<Voxel>, at: U64Vec3, col: u32) {
        let mut current = 0usize;
        let mut center = U64Vec3::splat(16);
        let mut span = 16usize;

        for i in 0..5 {
            if octree[current].valid_mask == 0 {
                octree[current].child_pointer = octree
                    .len()
                    .try_into()
                    .expect("todo: blocks & far pointers");
                octree.extend(
                    [Voxel {
                        col: 0,
                        child_pointer: 0,
                        valid_mask: 0,
                        leaf_mask: 0,
                    }]
                    .iter()
                    .cycle()
                    .take(8),
                );
            }

            tracing::info!("center = {center} point = {at}");
            let cmpge = at.cmpge(center);
            let child_idx = cmpge.bitmask();
            tracing::info!("child_idx = {child_idx}");
            span /= 2;
            center -= U64Vec3::splat(span as _);
            center += U64Vec3::splat(span as u64 * 2)
                * U64Vec3::new(cmpge.x as _, cmpge.y as _, cmpge.z as _);

            octree[current].valid_mask |= 1 << child_idx;
            current =
                octree[current].child_pointer as usize + child_idx as usize;
        }

        octree[current].col = col;
    }
}

#[derive(Debug, Clone, Copy, Pod, Zeroable)]
#[repr(C)]
pub struct Voxel {
    col: u32,
    /// 15 bit pointer (relative to this block) to 8 children within the current block,
    /// the last 1 bit tells if it is actually a pointer to a far pointer
    child_pointer: u16,
    /// which children are non-leaf voxels
    valid_mask: u8,
    /// which children are leaf voxels
    leaf_mask: u8,
}
