const vk = @import("vk");

const Device = @import("../graphics.zig").Device;

//

pub const DescriptorPool = struct {
    pool: vk.DescriptorPool,

    pub fn init(device: Device, pools: []const vk.DescriptorPoolSize) !@This() {
        var max_size: u32 = 0;
        for (pools) |pool| {
            max_size = @max(max_size, pool.descriptor_count);
        }

        const pool = try device.createDescriptorPool(
            &vk.DescriptorPoolCreateInfo{
                .pool_size_count = @intCast(pools.len),
                .p_pool_sizes = pools.ptr,
                .max_sets = max_size,
            },
            null,
        );

        return .{
            .pool = pool,
        };
    }

    pub fn reset(self: @This(), device: Device) !void {
        try device.resetDescriptorPool(self.pool, .{});
    }

    pub fn deinit(self: @This(), device: Device) void {
        device.destroyDescriptorPool(self.pool, null);
    }

    pub fn alloc(self: @This(), device: Device, layout: vk.DescriptorSetLayout) !vk.DescriptorSet {
        var set: vk.DescriptorSet = undefined;
        try device.allocateDescriptorSets(
            &vk.DescriptorSetAllocateInfo{
                .descriptor_pool = self.pool,
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast(&layout),
            },
            @ptrCast(&set),
        );
        return set;
    }

    pub fn free(self: @This(), device: Device, set: vk.DescriptorSet) !void {
        try device.freeDescriptorSets(self.pool, 1, @ptrCast(&set));
    }
};

// pub const DescriptorSetLayoutBuilder = struct {
//     bindings: []const vk.DescriptorSetLayoutBinding,
//     pub fn build(self: @This(), device: Device) vk.DescriptorSetLayout {
//         device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
//             .flags = .
//         }, null);
//     }
// };

pub const Module = struct {
    module: vk.ShaderModule,

    pub fn loadFromMemory(device: Device, spirv: []const u8) !Module {
        const module = try device.createShaderModule(&vk.ShaderModuleCreateInfo{
            .code_size = spirv.len,
            .p_code = @alignCast(@ptrCast(spirv.ptr)),
        }, null);

        return Module{
            .module = module,
        };
    }

    pub fn deinit(self: @This(), device: Device) void {
        device.destroyShaderModule(self.module, null);
    }
};
