use std::{mem, slice};

use ash::{Device, vk};
use eyre::Result;

use super::{delete_queue::DeleteQueue, image::Image};

//

pub struct DescriptorSet {
    pub set: vk::DescriptorSet,
}

impl DescriptorSet {
    pub fn update<'a>(&'a mut self, device: &'a Device) -> DescriptorSetUpdate<'a> {
        DescriptorSetUpdate {
            device,
            entries: Vec::new(),
            set: self,
        }
    }
}

// impl Drop for DescriptorSet {
//     fn drop(&mut self) {
//         tracing::error!("descriptor set leak");
//     }
// }

//

pub struct DescriptorSetUpdate<'a> {
    device: &'a Device,
    entries: Vec<(u32, DescriptorSetUpdateEntry)>,
    set: &'a DescriptorSet,
}

impl DescriptorSetUpdate<'_> {
    pub fn write(&mut self, binding: u32, entry: DescriptorSetUpdateEntry) -> &mut Self {
        self.entries.push((binding, entry));
        self
    }
}

impl Drop for DescriptorSetUpdate<'_> {
    fn drop(&mut self) {
        let writes: Box<[vk::WriteDescriptorSet]> = self
            .entries
            .iter()
            .map(|(binding, entry)| {
                let base = vk::WriteDescriptorSet::default()
                    .dst_binding(*binding)
                    .dst_set(self.set.set)
                    .dst_array_element(0)
                    .descriptor_count(1);

                entry.fill(base)
            })
            .collect();

        unsafe { self.device.update_descriptor_sets(&writes, &[]) };
    }
}

//

pub enum DescriptorSetUpdateEntry {
    StorageImage(vk::DescriptorImageInfo),
}

impl DescriptorSetUpdateEntry {
    pub fn storage_image(image: &Image) -> Self {
        Self::StorageImage(vk::DescriptorImageInfo {
            sampler: vk::Sampler::null(),
            image_view: image.view,
            image_layout: vk::ImageLayout::GENERAL,
        })
    }

    fn fill<'a>(&'a self, info: vk::WriteDescriptorSet<'a>) -> vk::WriteDescriptorSet<'a> {
        match self {
            DescriptorSetUpdateEntry::StorageImage(image_info) => info
                .descriptor_type(vk::DescriptorType::STORAGE_IMAGE)
                .image_info(slice::from_ref(image_info)),
        }
    }
}

//

pub struct DescriptorSetLayout {
    pub layout: vk::DescriptorSetLayout,
}

impl DescriptorSetLayout {
    pub const fn builder<'a>() -> DescriptorSetLayoutBuilder<'a> {
        DescriptorSetLayoutBuilder {
            bindings: Vec::new(),
        }
    }
}

//

pub struct DescriptorSetLayoutBuilder<'a> {
    bindings: Vec<vk::DescriptorSetLayoutBinding<'a>>,
}

impl DescriptorSetLayoutBuilder<'_> {
    pub fn add_binding(
        mut self,
        binding: u32,
        ty: vk::DescriptorType,
        stages: vk::ShaderStageFlags,
    ) -> Self {
        self.bindings.push(
            vk::DescriptorSetLayoutBinding::default()
                .binding(binding)
                .descriptor_type(ty)
                .descriptor_count(1)
                .stage_flags(stages),
        );
        self
    }

    pub fn build(
        &self,
        device: &Device,
        delete_queue: &mut DeleteQueue,
    ) -> Result<DescriptorSetLayout> {
        let create_info = vk::DescriptorSetLayoutCreateInfo::default().bindings(&self.bindings);
        let layout = unsafe { device.create_descriptor_set_layout(&create_info, None)? };
        delete_queue.push(layout);
        Ok(DescriptorSetLayout { layout })
    }
}

//

pub struct DescriptorPool {
    pool: vk::DescriptorPool,
}

impl DescriptorPool {
    pub const fn builder() -> DescriptorPoolBuilder {
        DescriptorPoolBuilder {
            sizes: Vec::new(),
            max_sets: 10,
        }
    }

    pub fn reset(&self, device: &Device) -> Result<()> {
        unsafe { device.reset_descriptor_pool(self.pool, vk::DescriptorPoolResetFlags::empty())? };
        Ok(())
    }

    pub fn alloc(&self, device: &Device, layout: &DescriptorSetLayout) -> Result<DescriptorSet> {
        let allocate_info = vk::DescriptorSetAllocateInfo::default()
            .descriptor_pool(self.pool)
            .set_layouts(slice::from_ref(&layout.layout));
        let sets = unsafe { device.allocate_descriptor_sets(&allocate_info)? };
        Ok(DescriptorSet {
            set: sets.into_iter().next().unwrap(),
        })
    }

    pub fn free(&self, device: &Device, set: DescriptorSet) -> Result<()> {
        let vk_set = set.set;
        mem::forget(set);
        unsafe { device.free_descriptor_sets(self.pool, &[vk_set])? };
        Ok(())
    }
}

//

pub struct DescriptorPoolBuilder {
    sizes: Vec<vk::DescriptorPoolSize>,
    max_sets: u32,
}

impl DescriptorPoolBuilder {
    pub fn add_type_allocation(mut self, ty: vk::DescriptorType, max_count: u32) -> Self {
        self.sizes.push(vk::DescriptorPoolSize {
            ty,
            descriptor_count: max_count,
        });
        self
    }

    pub fn max_sets(mut self, max_sets: u32) -> Self {
        self.max_sets = max_sets;
        self
    }

    pub fn build(&self, device: &Device, delete_queue: &mut DeleteQueue) -> Result<DescriptorPool> {
        let create_info = vk::DescriptorPoolCreateInfo::default()
            .pool_sizes(&self.sizes)
            .max_sets(self.max_sets)
            .flags(vk::DescriptorPoolCreateFlags::FREE_DESCRIPTOR_SET);
        let pool = unsafe { device.create_descriptor_pool(&create_info, None)? };
        delete_queue.push(pool);
        Ok(DescriptorPool { pool })
    }
}
