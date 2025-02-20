use std::{intrinsics::const_allocate, slice};

use ash::{Device, vk};
use eyre::Result;

use super::delete_queue::DeleteQueue;

//

pub struct Shader {
    pub module: vk::ShaderModule,
}

impl Shader {
    pub const DEFAULT_COMP: &[u32] = read_shader(include_bytes!(concat!(
        env!("OUT_DIR"),
        "/shader.comp.spirv"
    )));

    pub fn new(device: &Device, delete_queue: &mut DeleteQueue, code: &[u32]) -> Result<Self> {
        tracing::debug!("shader module size {}", code.len());

        let create_info = vk::ShaderModuleCreateInfo::default().code(code);
        let module = unsafe { device.create_shader_module(&create_info, None)? };
        delete_queue.push(module);

        Ok(Self { module })
    }
}

//

const fn read_shader(bytes: &[u8]) -> &[u32] {
    if bytes.is_empty() {
        return &[];
    }

    assert!(bytes.len().is_multiple_of(4));

    let size = bytes.len() / 4;
    let align = align_of::<u32>();

    // if bytes.as_ptr() as usize % 4 == 0 {
    //     return unsafe { slice::from_raw_parts(bytes.as_ptr().cast(), size) };
    // }

    let ptr = unsafe { const_allocate(bytes.len(), align) as *mut u32 };
    assert!(!ptr.is_null());

    unsafe { bytes.as_ptr().copy_to_nonoverlapping(ptr as _, bytes.len()) };

    unsafe { slice::from_raw_parts(ptr, size) }
}
