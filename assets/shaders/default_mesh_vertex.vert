#version 450

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNorm;
layout(location = 2) in vec2 inUv;

layout(location = 0) out vec3 outNorm;
layout(location = 1) out vec2 outUv;

layout(push_constant) uniform Constants {
        mat4 mvp;
} pc;

void main() {
	gl_Position = pc.mvp * vec4(inPos, 1.0);
	outNorm = inNorm;
	outUv = inUv;
}
