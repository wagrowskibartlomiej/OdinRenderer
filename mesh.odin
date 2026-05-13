package engine

import "obj"
import "core:math/linalg/glsl"

// Vertex used in simple triangle rendering
Triangle_Vertex :: struct {
	position: [2]f32,
	_padding: [2]f32,
	color: [4]f32,
}

Model_World_Data :: struct {
	position,
	rotation,
	scale: vec3,
}

UP_VEC :: vec3{0, 1, 0}
vec3 :: #type [3]f32

Base_Vertex :: obj.Vertex
MVP_Matrix :: glsl.mat4

Radians :: distinct f32
Degrees :: distinct f32

get_mvp :: proc(m: Model_World_Data) -> glsl.mat4 {
	camera_pos := vec3{3, 2, 2}
	camera_target := vec3{-2, -1, -1}

	model := get_model_matrix(m)
	view  := get_view_matrix(camera_pos, camera_target)
	proj  := get_projection_matrix()

	return proj * view * model
}

get_model_matrix :: proc(m: Model_World_Data) -> glsl.mat4 {
	// Identity at the start
	model := glsl.mat4(1.0)

	model = glsl.mat4Translate(m.position)

	model *= glsl.mat4Rotate({0, 1, 0}, f32(degrees_to_radians(Degrees(m.rotation.y))))

	radians := degrees_to_radians(-90)
	model *= glsl.mat4Rotate({1, 0, 0}, f32(radians))

	model *= glsl.mat4Scale(m.scale)
	return model
}

get_view_matrix :: proc(position, looking: vec3, up := UP_VEC) -> glsl.mat4 {
	return glsl.mat4LookAt(position, looking, up)
}

get_projection_matrix :: proc(fov: Degrees = 65, aspect: f32 = -1, near: f32 = 0.1, far: f32 = 100) -> glsl.mat4 {
	aspect := aspect
	if aspect < 0 do aspect = get_aspect_ratio_from_swapchain()

	fov_rad := degrees_to_radians(fov)
	current_transform := get_global_state().renderer.core.physical_devices.active.capabilites.currentTransform

	proj := glsl.mat4Perspective(f32(fov_rad), aspect, near, far)
	proj[1][1] *= -1

	if .ROTATE_90 in current_transform {
		proj *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(f32(-90)))
	} else if .ROTATE_270 in current_transform {
		proj *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(f32(-270)))
	} else if .ROTATE_180 in current_transform {
		proj *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(f32(-180)))
	}

	return proj
}

get_aspect_ratio_from_swapchain :: proc() -> f32 {
	ext := get_global_state().renderer.core.swapchain.image_extent
	current_transform := get_global_state().renderer.core.physical_devices.active.capabilites.currentTransform

	if .ROTATE_90 in current_transform || .ROTATE_270 in current_transform {
		return f32(ext.height) / f32(ext.width)
	}

	return f32(ext.width) / f32(ext.height)
}

degrees_to_radians :: proc(degrees: Degrees) -> Radians {
	return Radians(glsl.radians(f32(degrees)))
}
