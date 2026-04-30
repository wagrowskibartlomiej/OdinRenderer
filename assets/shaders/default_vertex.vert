#version 450

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

void main() {
	gl_Position = vec4(inPos, 0.0, 1.0);
	outColor = inColor;
	/*
	const vec2 positions[3] = vec2[](
		vec2(0.0, -0.5),
		vec2(0.5, 0.5),
		vec2(-0.5, 0.5)
	);
	const vec4 colors[3] = vec4[](
		vec4(1.0, 0.0, 0.0, 1.0),
		vec4(0.0, 1.0, 0.0, 1.0),
		vec4(0.0, 0.0, 1.0, 1.0)
	);	
	gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
	outColor = colors[gl_VertexIndex];
	*/
}