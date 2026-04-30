package engine

import "core:c"
import "vendor:glfw"

main :: proc () {
	engine_state: Engine_Global_State

	context = engine_init(&engine_state)
	defer engine_cleanup(&engine_state)

	success := engine_renderer_init(&engine_state)
	defer engine_renderer_cleanup(&engine_state)
	if !success do return

	one_time_send := true
	tri:  [3]Triangle_Vertex

	tri[0].color = {1, 0, 1, 1}
	tri[0].position = {0, 0.5}

	tri[1].color = {0, 1, 0, 1}
	tri[1].position = {-0.5, -0.5}

	tri[2].color = {0, 0, 1, 1}
	tri[2].position = {0.5, -0.5}


	current_frame: int
	for engine_is_running(&engine_state) {
		engine_poll_events(&engine_state)

		engine_process_input()
		engine_update(&engine_state, &tri, size_of(tri), one_time_send)
		engine_draw_frame(&engine_state, current_frame)

		if one_time_send do one_time_send = false

		current_frame = (current_frame + 1) % get_engine_configuration().settings.Frames_In_Flight
	}

}

glfw_poll_events :: proc() {
	glfw.PollEvents()
}

glfw_is_running :: proc(state: ^Engine_Global_State) -> bool {
	return !glfw.WindowShouldClose(cast(glfw.WindowHandle)state.window.handle)
}


glfw_input_handler : glfw.KeyProc : proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	if action == glfw.PRESS do switch key {
		case glfw.KEY_ESCAPE: glfw.SetWindowShouldClose(window, glfw.TRUE)
	}
}
