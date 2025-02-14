const std = @import("std");
const vk = @import("vk");

const graphics = @import("../graphics.zig");
const Instance = graphics.Instance;
const Device = graphics.Device;
const Queue = graphics.Queue;

//

pub const Queues = struct {
    graphics: Queue,
    present: Queue,
    transfer: Queue,
    compute: Queue,

    pub const CreateInfos = struct {
        items: [4]vk.DeviceQueueCreateInfo,
        len: usize,
    };

    const Self = @This();

    pub fn init(device: Device, queue_families: QueueFamilies) Self {
        const graphics_queue = device.getDeviceQueue(queue_families.graphics, 0);
        const present_queue = device.getDeviceQueue(queue_families.present, 0);
        const transfer_queue = device.getDeviceQueue(queue_families.transfer, 0);
        const compute_queue = device.getDeviceQueue(queue_families.compute, 0);

        return Self{
            .graphics = Queue.init(graphics_queue, device.wrapper),
            .present = Queue.init(present_queue, device.wrapper),
            .transfer = Queue.init(transfer_queue, device.wrapper),
            .compute = Queue.init(compute_queue, device.wrapper),
        };
    }

    pub fn createInfos(queue_families: QueueFamilies) CreateInfos {
        const priority = [_]f32{1};
        var queue_create_infos_buf = [_]vk.DeviceQueueCreateInfo{
            vk.DeviceQueueCreateInfo{
                .queue_family_index = queue_families.graphics,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = queue_families.present,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = queue_families.transfer,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = queue_families.compute,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        std.sort.pdq(vk.DeviceQueueCreateInfo, queue_create_infos_buf[0..], {}, struct {
            fn inner(_: void, a: vk.DeviceQueueCreateInfo, b: vk.DeviceQueueCreateInfo) bool {
                return a.queue_family_index < b.queue_family_index;
            }
        }.inner);

        var queue_create_infos = std.ArrayListAlignedUnmanaged(vk.DeviceQueueCreateInfo, null){
            .items = queue_create_infos_buf[0..],
            .capacity = queue_create_infos_buf.len,
        };

        // remove duplicate queue families
        var i: usize = queue_create_infos.items.len;
        if (i > 0) {
            i -= 1;
        }
        while (i > 0) {
            i -= 1;

            if (queue_create_infos.items[i].queue_family_index == queue_create_infos.items[i + 1].queue_family_index) {
                _ = queue_create_infos.orderedRemove(i + 1);
            }
        }

        return CreateInfos{
            .items = queue_create_infos_buf,
            .len = queue_create_infos.items.len,
        };
    }
};

pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,
    transfer: u32,
    compute: u32,

    const Self = @This();

    pub fn getFromGpu(
        allocator: std.mem.Allocator,
        instance: Instance,
        surface: vk.SurfaceKHR,
        gpu: vk.PhysicalDevice,
    ) !?Self {
        const queue_family_props = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
            gpu,
            allocator,
        );
        defer allocator.free(queue_family_props);

        const graphics_family = try pickQueueFamily(
            instance,
            surface,
            gpu,
            queue_family_props,
            .{ .graphics_bit = true },
            false,
        ) orelse return null;
        const present_family = try pickQueueFamily(
            instance,
            surface,
            gpu,
            queue_family_props,
            .{},
            true,
        ) orelse return null;
        const transfer_family = try pickQueueFamily(
            instance,
            surface,
            gpu,
            queue_family_props,
            .{ .transfer_bit = true },
            false,
        ) orelse return null;
        const compute_family = try pickQueueFamily(
            instance,
            surface,
            gpu,
            queue_family_props,
            .{ .compute_bit = true },
            false,
        ) orelse return null;

        return Self{
            .graphics = graphics_family,
            .present = present_family,
            .transfer = transfer_family,
            .compute = compute_family,
        };
    }

    fn pickQueueFamily(
        instance: Instance,
        surface: vk.SurfaceKHR,
        gpu: vk.PhysicalDevice,
        queue_props: []const vk.QueueFamilyProperties,
        contains: vk.QueueFlags,
        check_present: bool,
    ) !?u32 {
        var queue_index: u32 = 0;
        var found = false;
        // find the most specific graphics queue
        // because the more generic the queue is, the slower it usually is
        // TODO: maybe try also picking queues so that each task has its own dedicated queue if possible
        var queue_generality: usize = std.math.maxInt(usize);
        for (queue_props, 0..) |queue_prop, i| {
            const index: u32 = @truncate(i);
            const has_present = try instance.getPhysicalDeviceSurfaceSupportKHR(gpu, index, surface) == vk.TRUE;
            const this_queue_generality = @popCount(queue_prop.queue_flags.intersect(.{
                .graphics_bit = true,
                .compute_bit = true,
                .transfer_bit = true,
            }).toInt()) + @intFromBool(has_present);

            // log.info("queue present={} graphics={} compute={} transfer={}", .{
            //     has_present,
            //     queue_prop.queue_flags.graphics_bit,
            //     queue_prop.queue_flags.compute_bit,
            //     queue_prop.queue_flags.transfer_bit,
            // });

            if (queue_prop.queue_flags.contains(contains) and
                this_queue_generality <= queue_generality)
            {
                if (check_present and !has_present) {
                    continue;
                }

                queue_index = index;
                queue_generality = this_queue_generality;
                found = true;
            }
        }

        if (!found) {
            return null;
        }

        return queue_index;
    }
};
