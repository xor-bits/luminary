use std::slice;

use ash::{Device, vk};
use eyre::Result;

use super::{delete_queue::DeleteQueue, descriptor::DescriptorSetLayout, shader::Shader};

//

pub struct PipelineLayout {
    pub layout: vk::PipelineLayout,
}

impl PipelineLayout {
    pub fn new(
        device: &Device,
        delete_queue: &mut DeleteQueue,
        set_layout: &DescriptorSetLayout,
    ) -> Result<Self> {
        let create_info = vk::PipelineLayoutCreateInfo::default()
            .set_layouts(slice::from_ref(&set_layout.layout));
        let layout = unsafe { device.create_pipeline_layout(&create_info, None)? };
        delete_queue.push(layout);
        Ok(Self { layout })
    }
}

//

pub struct ComputePipeline {
    pub pipeline: vk::Pipeline,
}

impl ComputePipeline {
    pub fn new(
        device: &Device,
        delete_queue: &mut DeleteQueue,
        layout: &PipelineLayout,
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

        Ok(Self { pipeline })
    }
}
