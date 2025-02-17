use std::{
    ffi::c_void,
    ptr::{self, NonNull},
};

use ash::{
    Entry, Instance,
    ext::debug_utils,
    vk::{self, Handle},
};

use eyre::Result;

use crate::cold;

//

#[must_use]
pub struct DebugUtils {
    debug_messenger: vk::DebugUtilsMessengerEXT,
    destroy_fp: vk::PFN_vkDestroyDebugUtilsMessengerEXT,
}

impl DebugUtils {
    pub fn new(entry: &Entry, instance: &Instance) -> Result<Self> {
        let debug_utils_loader = debug_utils::Instance::new(entry, instance);
        let destroy_fp = debug_utils_loader.fp().destroy_debug_utils_messenger_ext;

        let create_info = vk::DebugUtilsMessengerCreateInfoEXT::default()
            .message_severity(
                vk::DebugUtilsMessageSeverityFlagsEXT::ERROR
                    | vk::DebugUtilsMessageSeverityFlagsEXT::WARNING,
            )
            .message_type(
                vk::DebugUtilsMessageTypeFlagsEXT::GENERAL
                    | vk::DebugUtilsMessageTypeFlagsEXT::VALIDATION
                    | vk::DebugUtilsMessageTypeFlagsEXT::PERFORMANCE,
            )
            .pfn_user_callback(Some(callback));

        let debug_messenger =
            unsafe { debug_utils_loader.create_debug_utils_messenger(&create_info, None)? };

        Ok(Self {
            debug_messenger,
            destroy_fp,
        })
    }

    pub fn destroy(&mut self, instance: &Instance) {
        if self.debug_messenger.is_null() {
            cold();
            return;
        }

        unsafe { (self.destroy_fp)(instance.handle(), self.debug_messenger, ptr::null()) };
        self.debug_messenger = vk::DebugUtilsMessengerEXT::null();
    }
}

// impl Drop for DebugUtils {
//     fn drop(&mut self) {
//         tracing::error!("resource leak {}", std::any::type_name_of_val(self));
//     }
// }

unsafe extern "system" fn callback(
    message_severity: vk::DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk::DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: *const vk::DebugUtilsMessengerCallbackDataEXT<'_>,
    _p_user_data: *mut c_void,
) -> vk::Bool32 {
    let message = NonNull::new(p_callback_data as *mut vk::DebugUtilsMessengerCallbackDataEXT)
        .and_then(|ptr| unsafe { (*ptr.as_ptr()).message_as_c_str() })
        .unwrap_or(c"<no message>")
        .to_str()
        .unwrap_or("<invalid utf8>");

    if message_severity.contains(vk::DebugUtilsMessageSeverityFlagsEXT::ERROR) {
        tracing::error!("Vulkan validation error ({message_types:?})\n{message}");
    } else if message_severity.contains(vk::DebugUtilsMessageSeverityFlagsEXT::WARNING) {
        tracing::warn!("Vulkan validation warning ({message_types:?})\n{message}");
    } else if message_severity.contains(vk::DebugUtilsMessageSeverityFlagsEXT::INFO) {
        tracing::info!("Vulkan validation info ({message_types:?})\n{message}");
    } else if message_severity.contains(vk::DebugUtilsMessageSeverityFlagsEXT::VERBOSE) {
        tracing::debug!("Vulkan validation debug ({message_types:?})\n{message}");
    }

    vk::FALSE
}
