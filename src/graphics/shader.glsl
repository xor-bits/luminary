#version 460
// #extension GL_EXT_shader_8bit_storage : enable
// #extension GL_EXT_shader_16bit_storage : enable
// #extension GL_EXT_shader_8bit_storage : enable
#extension GL_EXT_shader_explicit_arithmetic_types : enable

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D image;

struct Voxel {
    uint32_t col;
    // 15 bit pointer (relative to this block) to 8 children within the current block,
    // the last 1 bit tells if it is actually a pointer to a far pointer
    uint16_t child_pointer;
    // which children are non-leaf voxels
    uint8_t valid_mask;
    // which children are leaf voxels
    uint8_t leaf_mask;
};

layout(std430, set = 0, binding = 1) readonly buffer VoxelStorage {
    Voxel voxels[];
} voxel_storage;

layout(push_constant) uniform PushConstant {
    mat4x4 projection_view;
    uint mode_flags;
} push;

//

uint get_voxel_linear(ivec3 world_pos) {
    if (0 <= world_pos.x && world_pos.x < 32 &&
        0 <= world_pos.y && world_pos.y < 32 &&
        0 <= world_pos.z && world_pos.z < 32) {
        uint index = (world_pos.x) | (world_pos.y << 5) | (world_pos.z << 10);
        uint voxel_col = uint(voxel_storage.voxels[index].col);

        return voxel_col;
    }

    return 0;
}

uint get_voxel(ivec3 world_pos) {
    vec3 center = vec3(16.0);
    float half_span = 8.0;

    uint current = 0;

    for (uint i = 0; i < 5; i++) {
        bvec3 cmpge = greaterThanEqual(world_pos, center);
        uint child_idx = uint(cmpge.x) | (uint(cmpge.y) << 1) | (uint(cmpge.z) << 2);
        center -= vec3(half_span);
        center += vec3(half_span * 2.0) * ivec3(cmpge);
        half_span /= 2.0;

        if ((uint(voxel_storage.voxels[current].valid_mask) & (1 << child_idx)) == 0) {
            return 0;
        }

        current = uint(voxel_storage.voxels[current].child_pointer) + child_idx;
    }

    return voxel_storage.voxels[current].col;
}

/* {
    world_pos = 0,0,0
    ivec3 center = 8,8,8;
    uint half_span = 4;

    uint current = 0;

    for (uint i = 1; i < 4; i++) {
        bvec3 cmpge = greaterThanEqual(world_pos, center);
        uint child_idx = uint(cmpge.x) | (uint(cmpge.y) << 1) | (uint(cmpge.z) << 2);
        center -= ivec3(half_span);
        center += ivec3(half_span * 2) * ivec3(cmpge);
        half_span /= 2;

        if ((uint(voxel_storage.voxels[current].valid_mask) & child_idx) == 0) {
            return 0;
        }

        current = uint(voxel_storage.voxels[current].child_pointer) + child_idx;
    }

    return voxel_storage.voxels[current].col;
} */

struct HitData {
    ivec3 voxel;
    vec3 position;
    vec3 normal;
    float distance;
    uint steps;
    bool hit;
};

bool ray_aabb(
    vec3 ray_origin,
    vec3 ray_dir,
    vec3 low,
    vec3 high,
    out float t_close_f,
    out float t_far_f
) {
    vec3 t_low = (low - ray_origin) / ray_dir;
    vec3 t_high = (high - ray_origin) / ray_dir;
    vec3 t_close = min(t_low, t_high);
    vec3 t_far = max(t_low, t_high);
    t_close_f = max(t_close.x, max(t_close.y, t_close.z));
    t_far_f = min(t_far.x, min(t_far.y, t_far.z));

    return sign(t_far_f) > 0.0 && t_close_f <= t_far_f;
    // return (sign(t_close_f) > 0.0 && t_close_f <= t_far_f) || (all(lessThanEqual(low, ray_origin)) && all(lessThanEqual(ray_origin, high)));
}

void ray_cast_linear(vec3 ray_origin, vec3 ray_dir, bool skip_first, out HitData hit_data) {
    float t_close_f, t_far_f;
    if (!ray_aabb(ray_origin, ray_dir, vec3(0.0), vec3(32.0), t_close_f, t_far_f)) {
        hit_data.position = ray_origin;
        hit_data.hit = false;
        hit_data.steps = 0;
        return;
    }

    // start DDA from the voxel AABB edge, if it starts outside
    ray_origin += ray_dir * max(t_close_f, 0.0);
        
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

        if (!(all(lessThanEqual(ivec3(0), world_pos)) && all(lessThanEqual(world_pos, ivec3(32))))) {
            break;
        }
    }

    hit_data.voxel = world_pos;
    hit_data.normal = -vec3(ray_sign) * vec3(mask);
    hit_data.distance = length(vec3(mask) * (next_dist - ray_dist));
    hit_data.position = ray_origin + ray_dir * hit_data.distance;
    hit_data.distance += max(t_close_f, 0.0);
}

uint select_child(vec3 t_coeff, vec3 t_bias, vec3 center, vec3 point) {
    vec3 planes = t_coeff * center + t_bias;
    bvec3 bitmask = greaterThanEqual(point, planes);
    return uint(bitmask.x) | (uint(bitmask.y) << 1) | (uint(bitmask.z) << 2);
}

void ray_cast(vec3 ray_origin, vec3 ray_dir, bool skip_first, out HitData hit_data) {
    // float t_close_f, t_far_f;
    // if (!ray_aabb(ray_origin, ray_dir, vec3(0.0), vec3(32.0), t_close_f, t_far_f)) {
    //     hit_data.position = ray_origin;
    //     hit_data.hit = false;
    //     hit_data.steps = 0;
    //     return;
    // }

    // t(a) = (1/ray_dir)a + (-ray_origin/ray_dir)
    //      = (a - ray_origin)/ray_dir
    vec3 t_coeff = 1.0 / ray_dir;
    vec3 t_bias  = - t_coeff * ray_origin;

    vec3 t_low = t_bias;
    vec3 t_high = t_coeff * 32.0 + t_bias;
    vec3 t_close = min(t_low, t_high);
    vec3 t_far = max(t_low, t_high);
    float t_min = max(t_close.x, max(t_close.y, t_close.z));
    float t_max = min(t_far.x, min(t_far.y, t_far.z));

    hit_data.hit = t_min <= t_max;
    hit_data.distance = t_min;

    float stop = t_max;
    uint parent = 0; // root node
    uint idx = select_child(t_coeff, t_bias, vec3(16), vec3(t_min));

    hit_data.distance = float(idx) * 5.0;
}

vec4 palette[] = {
    vec4(0.000, 0.000, 0.000, 0.0),
    vec4(0.000, 0.453, 0.668, 1.0),
    vec4(0.000, 0.316, 0.469, 1.0),
    vec4(0.746, 0.914, 1.000, 1.0),
};

void main() {
    vec3 sun_dir = normalize(vec3(0.5, 1.0, 0.75));
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

    if ((push.mode_flags & 8) != 0) {
        imageStore(image, coord, vec4(vec3(float(hit_data.steps) / 50), 1.0));
        return;
    }

    if (!hit_data.hit) {
        float sky = smoothstep(0.998, 1.0, dot(sun_dir, ray_dir));
        imageStore(image, coord, vec4(vec3(sky), 1.0));
        return;
    }

    // shadow cast
    HitData light_hit_data;
    ray_cast(hit_data.position + hit_data.normal * 0.005, sun_dir, true, light_hit_data);
    float brightness = float(light_hit_data.hit) * 0.05 + float(!light_hit_data.hit) * dot(sun_dir, hit_data.normal);

    uint voxel_col = get_voxel(hit_data.voxel);
    vec4 col = palette[voxel_col];
    col.xyz *= brightness;

    if ((push.mode_flags & 1) != 0) {
        col = vec4(vec3(brightness), 1.0);
    } else if ((push.mode_flags & 2) != 0) {
        col = vec4(vec3(hit_data.distance / 100.0), 1.0);
    } else if ((push.mode_flags & 4) != 0) {
        col = vec4(vec3(hit_data.normal), 1.0);
    }  
    
    imageStore(image, coord, col);
}
