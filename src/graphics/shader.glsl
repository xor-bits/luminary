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

//

uint get_voxel(ivec3 world_pos) {
    if (0 <= world_pos.x && world_pos.x < 32 &&
        0 <= world_pos.y && world_pos.y < 32 &&
        0 <= world_pos.z && world_pos.z < 32) {
        uint index = (world_pos.x) | (world_pos.y << 5) | (world_pos.z << 10);
        uint voxel_col = uint(voxel_storage.voxels[index].col);

        return voxel_col;
    }

    return 0;
}

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

    vec3 ray_origin_grid = floor(ray_origin.xyz);
    ivec3 world_pos = ivec3(ray_origin_grid);

    vec3 ray_dir = normalize(ray_target.xyz - ray_origin.xyz);
    vec3 ray_dir_inv = 1.0 / ray_dir;
    ivec3 ray_sign = ivec3(sign(ray_dir));
    
    vec3 ray_dist = abs(ray_dir_inv);
    vec3 next_dist = (ray_sign * (ray_origin_grid - ray_origin.xyz) + (ray_sign * 0.5) + 0.5) * ray_dist;

    bvec3 mask = bvec3(false);
    uint hit_depth = 0;
    for (; hit_depth < 100; hit_depth ++) {
        uint voxel_col = get_voxel(world_pos);
        if (voxel_col != 0) {
            break;
        }

        mask = lessThanEqual(next_dist.xyz, min(next_dist.yzx, next_dist.zxy));
        next_dist += vec3(mask) * ray_dist;
        world_pos += ivec3(vec3(mask) * ray_sign);
    }

    // vec3 col = vec3(hit_depth) / vec3(100.0);
    vec3 col = vec3(0.0);
    if (mask.x)
        col = vec3(1.0);
    if (mask.y)
        col = vec3(0.5);
    if (mask.z)
        col = vec3(0.75);
    if (hit_depth == 100)
        col = vec3(0.0);

    imageStore(image, coord, vec4(col, 1.0));
}
