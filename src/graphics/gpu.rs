use std::{
    alloc::Layout, ffi::CStr, intrinsics::const_allocate, mem::MaybeUninit,
    ptr, slice,
};

use ash::{Entry, Instance, khr, vk};

use eyre::{Result, eyre};

use super::queues::QueueFamilies;

//

pub fn pick_gpu(
    entry: &Entry,
    instance: &Instance,
    surface: vk::SurfaceKHR,
) -> Result<(vk::PhysicalDevice, QueueFamilies)> {
    let surface_loader = khr::surface::Instance::new(entry, instance);

    let gpus = unsafe { instance.enumerate_physical_devices()? };

    if tracing::enabled!(tracing::Level::INFO) {
        tracing::info!("gpus:");
        for gpu in gpus.iter().copied() {
            let props = unsafe { instance.get_physical_device_properties(gpu) };
            tracing::info!(
                " - {}",
                props
                    .device_name_as_c_str()
                    .ok()
                    .and_then(|s| s.to_str().ok())
                    .unwrap_or("<invalid name>")
            );
        }
    }

    let (gpu, queue_families, props) = gpus
        .into_iter()
        .filter_map(|gpu| is_suitable(instance, &surface_loader, gpu, surface))
        .max_by_key(|(_, _, props)| score(props))
        .ok_or_else(|| eyre!("no suitable GPUs"))?;

    let name = props
        .device_name_as_c_str()
        .ok()
        .and_then(|s| s.to_str().ok())
        .unwrap_or("<invalid name>");
    tracing::info!("picked {name}");
    tracing::debug!("{queue_families:?}");

    Ok((gpu, queue_families))
}

fn score(props: &vk::PhysicalDeviceProperties) -> usize {
    match props.device_type {
        vk::PhysicalDeviceType::DISCRETE_GPU => 5,
        vk::PhysicalDeviceType::INTEGRATED_GPU => 4,
        vk::PhysicalDeviceType::VIRTUAL_GPU => 3,
        vk::PhysicalDeviceType::CPU => 2,
        vk::PhysicalDeviceType::OTHER => 1,
        _ => 0,
    }
}

fn is_suitable(
    instance: &Instance,
    surface_loader: &khr::surface::Instance,
    gpu: vk::PhysicalDevice,
    surface: vk::SurfaceKHR,
) -> Option<(
    vk::PhysicalDevice,
    QueueFamilies,
    vk::PhysicalDeviceProperties,
)> {
    let props = unsafe { instance.get_physical_device_properties(gpu) };
    if props.api_version < vk::API_VERSION_1_3 {
        return None;
    }

    if !has_extensions(instance, gpu) {
        return None;
    }

    if !has_surface_support(surface_loader, gpu, surface) {
        return None;
    }

    let queue_families = find_queues(instance, surface_loader, gpu, surface)?;

    Some((gpu, queue_families, props))
}

fn has_extensions(instance: &Instance, gpu: vk::PhysicalDevice) -> bool {
    let res = unsafe { instance.enumerate_device_extension_properties(gpu) };
    let Ok(avail_exts) = res else {
        return false;
    };

    for required in REQUIRED_EXTS_CSTR {
        if !avail_exts
            .iter()
            .any(|avail| avail.extension_name_as_c_str() == Ok(required))
        {
            return false;
        }
    }

    true
}

fn has_surface_support(
    surface_loader: &khr::surface::Instance,
    gpu: vk::PhysicalDevice,
    surface: vk::SurfaceKHR,
) -> bool {
    let mut format_count: u32 = 0;
    let mut present_mode_count: u32 = 0;

    if unsafe {
        (surface_loader.fp().get_physical_device_surface_formats_khr)(
            gpu,
            surface,
            &mut format_count,
            ptr::null_mut(),
        )
    }
    .result()
    .is_err()
        || format_count == 0
    {
        return false;
    }

    if unsafe {
        (surface_loader
            .fp()
            .get_physical_device_surface_present_modes_khr)(
            gpu,
            surface,
            &mut present_mode_count,
            ptr::null_mut(),
        )
    }
    .result()
    .is_err()
        || present_mode_count == 0
    {
        return false;
    }

    true
}

fn find_queues(
    instance: &Instance,
    surface_loader: &khr::surface::Instance,
    gpu: vk::PhysicalDevice,
    surface: vk::SurfaceKHR,
) -> Option<QueueFamilies> {
    let mut queue_families =
        unsafe { instance.get_physical_device_queue_family_properties(gpu) };
    // use the timestamp_valid_bits field to count the times this queue is used
    for queue_family in queue_families.iter_mut() {
        queue_family.timestamp_valid_bits = 0;
    }
    tracing::debug!("queue family count: {}", queue_families.len());

    let present = find_queue(
        surface_loader,
        gpu,
        surface,
        &queue_families,
        |_, has_present| has_present,
    )?;
    queue_families[present as usize].timestamp_valid_bits += 1;
    let graphics = find_queue(
        surface_loader,
        gpu,
        surface,
        &queue_families,
        |props, _| props.queue_flags.contains(vk::QueueFlags::GRAPHICS),
    )?;
    queue_families[graphics as usize].timestamp_valid_bits += 1;
    let transfer = find_queue(
        surface_loader,
        gpu,
        surface,
        &queue_families,
        |props, _| props.queue_flags.contains(vk::QueueFlags::TRANSFER),
    )?;
    queue_families[transfer as usize].timestamp_valid_bits += 1;
    let compute = find_queue(
        surface_loader,
        gpu,
        surface,
        &queue_families,
        |props, _| props.queue_flags.contains(vk::QueueFlags::COMPUTE),
    )?;
    queue_families[compute as usize].timestamp_valid_bits += 1;

    let mut families: Vec<vk::DeviceQueueCreateInfo<'static>> =
        [present, graphics, transfer, compute]
            .into_iter()
            .map(|i| {
                vk::DeviceQueueCreateInfo::default()
                    .queue_family_index(i)
                    .queue_priorities(&[1.0])
            })
            .collect();

    families.sort_by_key(|i| i.queue_family_index);
    families.dedup_by_key(|i| i.queue_family_index);

    Some(QueueFamilies {
        present,
        graphics,
        transfer,
        compute,
        families: families.into_boxed_slice(),
    })
}

fn find_queue(
    surface_loader: &khr::surface::Instance,
    gpu: vk::PhysicalDevice,
    surface: vk::SurfaceKHR,
    queue_families: &[vk::QueueFamilyProperties],
    mut is_valid: impl FnMut(&vk::QueueFamilyProperties, bool) -> bool,
) -> Option<u32> {
    tracing::debug!("finding next queue");
    queue_families
        .iter()
        .enumerate()
        .take(u32::MAX as _)
        .map(|(i, p)| (i as u32, p))
        .map(|(i, p)| {
            tracing::debug!("i={i}");
            let has_present =
                unsafe { surface_loader.get_physical_device_surface_support(gpu, i, surface) }
                    .unwrap_or(false);
            (i, p, has_present)
        })
        .filter(|(i, props, has_present)| {
            let functions = props.queue_flags.as_raw().count_ones();
            let is_valid = is_valid(props, *has_present);
            tracing::debug!(
                "queue_family={i} functions={functions} has_present={has_present} already_picked={} is_valid={is_valid} {:?}",
                props.timestamp_valid_bits,props.queue_flags
            );
            is_valid
        })
        .min_by_key(|(_, props, has_present)| {
            let functions = props.queue_flags.as_raw().count_ones();

            // find the most specific graphics queue
            // because the more generic the queue is, the slower it usually is
            functions
                + *has_present as u32
                // use the timestamp_valid_bits field to count the times this queue is used
                + props.timestamp_valid_bits * 100
        })
        .map(|(i, _, _)| i as _)
}

//

pub const REQUIRED_EXTS_CSTR: &[&CStr] = &[
    khr::swapchain::NAME,
    khr::acceleration_structure::NAME,
    khr::ray_tracing_pipeline::NAME,
    khr::deferred_host_operations::NAME,
];
pub const REQUIRED_EXTS_PTRPTR: &[*const i8] = map(REQUIRED_EXTS_CSTR);

const fn map(a: &[&CStr]) -> &'static [*const i8] {
    let Ok((layout, _)) = Layout::new::<*const i8>().repeat(a.len()) else {
        panic!("invalid layout for some reason");
    };
    let ptr = unsafe { const_allocate(layout.size(), layout.align()) };

    if ptr.is_null() {
        panic!("cannot run this in non-const context");
    }

    let slice = ptr::slice_from_raw_parts_mut(ptr.cast(), a.len());
    let slice = unsafe { slice.as_uninit_slice_mut().unwrap() };

    let mut i = 0;
    while i < a.len() {
        slice[i].write(a[i].as_ptr());
        i += 1;
    }

    unsafe { MaybeUninit::slice_assume_init_ref(slice) }
}
