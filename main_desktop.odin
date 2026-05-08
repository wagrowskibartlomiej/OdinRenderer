package engine

import "core:c"
import "core:log"
import "core:slice"
import "vendor:glfw"

main :: proc () {
	engine_state := new(Engine_Global_State)
	defer free(engine_state)

	context = engine_init(engine_state)
	defer engine_cleanup(engine_state)

	success := engine_renderer_init(engine_state)
	defer engine_renderer_cleanup(engine_state)
	if !success do return

	tri:  [3]Triangle_Vertex

	tri[0].color = {1, 0, 1, 1}
	tri[0].position = {0, 0.5}

	tri[1].color = {0, 1, 0, 1}
	tri[1].position = {-0.5, -0.5}

	tri[2].color = {0, 0, 1, 1}
	tri[2].position = {0.5, -0.5}


	current_frame: int
	for engine_is_running(engine_state) {
		engine_calculate_delta(engine_state)
		engine_poll_events(engine_state)

		engine_process_input()
		engine_update_gpu(raw_data(tri[:]), slice.size(tri[:]), true)
		engine_draw_frame(engine_state, current_frame)

		engine_update_current_frame_idx(engine_state)
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
