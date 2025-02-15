#version 460

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D image;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(image);

    if (coord.x < size.x && coord.y < size.y) {
        imageStore(image, coord, vec4(float(coord.x) / size.x, float(coord.y) / size.y, 0.0, 1.0));
        // return;
    }
}
