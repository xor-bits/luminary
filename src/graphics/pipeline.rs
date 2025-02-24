use std::{marker::PhantomData, mem, slice};

use ash::{Device, vk};
use bytemuck::{Pod, Zeroable};
use eyre::Result;
use glam::UVec3;

use super::{
    delete_queue::DeleteQueue, descriptor::DescriptorSetLayout, shader::Shader,
};

//

#[derive(Clone, Copy)]
pub struct PipelineLayout<C = ()> {
    pub layout: vk::PipelineLayout,
    _p: PhantomData<C>,
}

impl<C: Sized> PipelineLayout<C> {
    pub fn new(
        device: &Device,
        delete_queue: &mut DeleteQueue,
        set_layout: &DescriptorSetLayout,
    ) -> Result<Self> {
        let push_constant_size: u32 = size_of::<C>().try_into()?;

        let push_constant_range = vk::PushConstantRange::default()
            .offset(0)
            .size(push_constant_size)
            .stage_flags(vk::ShaderStageFlags::COMPUTE); // TODO: specify the stage or something idk

        let mut create_info = vk::PipelineLayoutCreateInfo::default()
            .set_layouts(slice::from_ref(&set_layout.layout));

        if push_constant_size != 0 {
            create_info = create_info
                .push_constant_ranges(slice::from_ref(&push_constant_range));
        }

        let layout =
            unsafe { device.create_pipeline_layout(&create_info, None)? };
        delete_queue.push(layout);
        Ok(Self {
            layout,
            _p: PhantomData,
        })
    }
}

//

pub struct ComputePipeline<C = ()> {
    pub pipeline: vk::Pipeline,
    pub layout: PipelineLayout<C>,
}

impl<C: Sized> ComputePipeline<C> {
    const PUSH_CONSTANT_SIZE: u32 = mem::size_of::<C>() as _;

    pub fn new(
        device: &Device,
        delete_queue: &mut DeleteQueue,
        layout: PipelineLayout<C>,
        compute_shader: &Shader,
    ) -> Result<Self> {
        let stage_info = vk::PipelineShaderStageCreateInfo::default()
            .stage(vk::ShaderStageFlags::COMPUTE)
            .module(compute_shader.module)
            .name(c"main");

        let create_info = vk::ComputePipelineCreateInfo::default()
            .stage(stage_info)
            .layout(layout.layout);

        let pipelines = unsafe {
            device.create_compute_pipelines(
                vk::PipelineCache::null(),
                slice::from_ref(&create_info),
                None,
            )
        }
        .map_err(|(_, err)| err)?;
        let pipeline = pipelines.into_iter().next().unwrap();
        delete_queue.push(pipeline);

        Ok(Self { pipeline, layout })
    }

    pub fn bind(&self, device: &Device, cbuf: vk::CommandBuffer) {
        unsafe {
            device.cmd_bind_pipeline(
                cbuf,
                vk::PipelineBindPoint::COMPUTE,
                self.pipeline,
            );
        }
    }

    pub fn write_push_constant(
        &self,
        device: &Device,
        cbuf: vk::CommandBuffer,
        data: &C,
    ) where
        C: Pod + Zeroable,
    {
        if Self::PUSH_CONSTANT_SIZE == 0 {
            return;
        }

        unsafe {
            device.cmd_push_constants(
                cbuf,
                self.layout.layout,
                vk::ShaderStageFlags::COMPUTE,
                0,
                bytemuck::cast_slice(slice::from_ref(data)),
            );
        }
    }

    pub fn bind_sets(
        &self,
        device: &Device,
        cbuf: vk::CommandBuffer,
        sets: &[vk::DescriptorSet],
        offsets: &[u32],
    ) {
        unsafe {
            device.cmd_bind_descriptor_sets(
                cbuf,
                vk::PipelineBindPoint::COMPUTE,
                self.layout.layout,
                0,
                sets,
                offsets,
            );
        }
    }

    pub fn dispatch(
        &self,
        device: &Device,
        cbuf: vk::CommandBuffer,
        group_count: UVec3,
    ) {
        unsafe {
            device.cmd_dispatch(
                cbuf,
                group_count.x,
                group_count.y,
                group_count.z,
            );
        }
    }
}
