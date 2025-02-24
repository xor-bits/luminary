#version 460
#extension GL_EXT_shader_8bit_storage : enable
// #extension GL_EXT_shader_explicit_arithmetic_types : enable

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D image;

struct Voxel {
    uint8_t col;
};

layout(std430, set = 0, binding = 1) readonly buffer VoxelStorage {
    Voxel voxels[];
} voxel_storage;

layout(push_constant) uniform PushConstant {
    mat4x4 projection_view;
} push;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(image);

    if (coord.x < size.x && coord.y < size.y) {
        vec4 ray_target = push.projection_view * vec4(vec2(coord) / vec2(size), 0.0, 1.0);
        vec4 ray_origin = push.projection_view * vec4(vec2(coord) / vec2(size), 1.0, 1.0);

        imageStore(image, coord, ray_target);
        return;
        
        uvec2 grid_coord = gl_GlobalInvocationID.xy / 32;
        
        if (grid_coord.x >= 32 || grid_coord.y >= 32) {
            imageStore(image, coord, vec4(1.0, 0.0, 0.5, 1.0));
            return;
        }

        uint hit_depth = 0;
        for (; hit_depth < 32; hit_depth++) {
            uint index = (grid_coord.x) | (grid_coord.y << 5) | (hit_depth << 10);
            uint voxel_col = uint(voxel_storage.voxels[index].col);
            
            if (voxel_col != 0) {
                break;
            }
        }
        
        
        vec4 col = vec4(
            float(32 - hit_depth) / 32,
            float(32 - hit_depth) / 32,
            float(32 - hit_depth) / 32,
            1.0
        );
        // vec4 col = vec4(
        //     float(index) / 1024,
        //     float(index) / 1024,
        //     float(index) / 1024,
        //     1.0
        // );
        imageStore(image, coord, col);
    }
}
