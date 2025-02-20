#version 460

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D image;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(image);

    if (coord.x < size.x && coord.y < size.y) {
        vec4 col = vec4(
            float(gl_LocalInvocationID.x) / 16,
            float(gl_LocalInvocationID.y) / 16,
            float(coord.x) / size.x,
            1.0
        );
        imageStore(image, coord, col);
    }
}
