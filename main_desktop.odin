package engine

import "core:c"
import "core:time"
import "vendor:glfw"

main :: proc () {
	engine_state := new(Engine_Global_State)
	defer free(engine_state)

	context = engine_init(engine_state)
	defer engine_cleanup(engine_state)

	success := engine_renderer_init(engine_state)
	defer engine_renderer_cleanup(engine_state)
	if !success do return

	current_frame: int
	one_time_upload := true
	engine_state.time.last_frame_start = time.now()
	for engine_is_running(engine_state) {
		engine_calculate_delta(engine_state)
		engine_poll_events(engine_state)

		engine_process_input()
		engine_update_logic()
		engine_upload_gpu(one_time_upload)
		engine_draw_frame(engine_state, current_frame)

		engine_update_current_frame_idx(engine_state)
		one_time_upload = false
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
