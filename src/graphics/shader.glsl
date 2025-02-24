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

struct HitData {
    ivec3 voxel;
    vec3 position;
    vec3 normal;
    float distance;
    uint steps;
    bool hit;
};

void ray_cast(vec3 ray_origin, vec3 ray_dir, bool skip_first, out HitData hit_data) {
    
    vec3 ray_origin_grid = floor(ray_origin);
    ivec3 world_pos = ivec3(ray_origin_grid);

    vec3 ray_dist = 1.0 / abs(ray_dir);
    ivec3 ray_sign = ivec3(sign(ray_dir));
    
    vec3 next_dist = (ray_sign * (ray_origin_grid - ray_origin) + (ray_sign * 0.5) + 0.5) * ray_dist;

    bvec3 mask = bvec3(false);

    if (skip_first) {
        mask = lessThanEqual(next_dist.xyz, min(next_dist.yzx, next_dist.zxy));
        next_dist += vec3(mask) * ray_dist;
        world_pos += ivec3(vec3(mask) * ray_sign);
    }

    hit_data.hit = false;
    hit_data.steps = 0;
    for (; hit_data.steps < 100; hit_data.steps ++) {
        uint voxel_col = get_voxel(world_pos);
        if (voxel_col != 0) {
            hit_data.hit = true;
            break;
        }

        mask = lessThanEqual(next_dist.xyz, min(next_dist.yzx, next_dist.zxy));
        next_dist += vec3(mask) * ray_dist;
        world_pos += ivec3(vec3(mask) * ray_sign);
    }

    hit_data.voxel = world_pos;
    hit_data.normal = -vec3(ray_sign) * vec3(mask);
    hit_data.distance = length(vec3(mask) * (next_dist - ray_dist));
    hit_data.position = ray_origin + ray_dir * hit_data.distance;
}

vec4 palette[] = {
    vec4(0.000, 0.000, 0.000, 0.0),
    vec4(0.000, 0.453, 0.668, 1.0),
    vec4(0.000, 0.316, 0.469, 1.0),
    vec4(0.746, 0.914, 1.000, 1.0),
};

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

    // camera to world cast
    HitData hit_data;
    ray_cast(ray_origin.xyz, ray_dir, false, hit_data);

    if (!hit_data.hit) {
        imageStore(image, coord, vec4(0.0, 0.0, 0.0, 1.0));
        return;
    }

    // imageStore(image, coord, vec4(vec3(hit_data.distance / 50.0), 1.0));
    // return;

    // shadow cast
    vec3 sun_dir = vec3(0.5, 1.0, 0.75);
    HitData light_hit_data;
    ray_cast(hit_data.position + hit_data.normal * 0.001, sun_dir, true, light_hit_data);
    float brightness = float(light_hit_data.hit) * 0.1 + float(!light_hit_data.hit) * dot(sun_dir, hit_data.normal);

    uint voxel_col = get_voxel(hit_data.voxel);
    vec4 col = palette[voxel_col];
    col.xyz *= brightness;
    
    imageStore(image, coord, col);
}
