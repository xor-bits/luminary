const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");

const apis = @import("../graphics.zig").apis;

pub const BaseDispatch = vk.BaseWrapper(apis);
pub const InstanceDispatch = vk.InstanceWrapper(apis);
pub const DeviceDispatch = vk.DeviceWrapper(apis);

//

pub const Dispatch = struct {
    base: BaseDispatch = undefined,
    instance: InstanceDispatch = undefined,
    device: DeviceDispatch = undefined,

    base_loaded: bool = false,
    instance_loaded: bool = false,
    device_loaded: bool = false,

    const Self = @This();

    pub fn loadBase(self: *Self) !void {
        self.base = try BaseDispatch.load(getInstanceProcAddress);
        self.base_loaded = true;
    }

    pub fn loadInstance(self: *Self, instance_handle: vk.Instance) !void {
        std.debug.assert(self.base_loaded);
        self.instance = try InstanceDispatch.load(
            instance_handle,
            self.base.dispatch.vkGetInstanceProcAddr,
        );
        self.instance_loaded = true;
    }

    pub fn loadDevice(self: *Self, device_handle: vk.Device) !void {
        std.debug.assert(self.base_loaded);
        std.debug.assert(self.instance_loaded);
        self.device = try DeviceDispatch.load(
            device_handle,
            self.instance.dispatch.vkGetDeviceProcAddr,
        );
        self.device_loaded = true;
    }
};

fn getInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) ?glfw.VKproc {
    return glfw.getInstanceProcAddress(@intFromEnum(instance), procname);
}
