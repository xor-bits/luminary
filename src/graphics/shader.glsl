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

    if (coord.x >= size.x || coord.y >= size.y) {
        return;
    }

    vec2 plane_pos = vec2(coord.xy) / vec2(size.xy) * 2.0 - 1.0;
    vec4 ray_origin = push.projection_view * vec4(plane_pos, 0.0, 1.0);
    vec4 ray_target = push.projection_view * vec4(plane_pos, 1.0, 1.0);

    ray_origin.xyz /= ray_origin.w;
    ray_target.xyz /= ray_target.w;

    vec3 ray_dir = normalize(ray_target.xyz - ray_origin.xyz);

    ivec3 ray_step = ivec3(sign(ray_dir));

    uint hit_depth = 0;
    for (; hit_depth < 1024; hit_depth ++) {
        ivec3 world_pos = ivec3(ray_origin.xyz);
        if (0 <= world_pos.x && world_pos.x < 32 &&
            0 <= world_pos.y && world_pos.y < 32 &&
            0 <= world_pos.z && world_pos.z < 32) {
            uint index = (world_pos.x) | (world_pos.y << 5) | (world_pos.z << 10);
            uint voxel_col = uint(voxel_storage.voxels[index].col);

            if (voxel_col != 0) {
                break;
            }
        }
   
        ray_origin.xyz += ray_dir * 0.1;
    }

    imageStore(image, coord, vec4(vec3(hit_depth) / vec3(1024.0), 1.0));
}
