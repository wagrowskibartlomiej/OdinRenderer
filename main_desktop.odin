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

	for engine_is_running(&engine_state) {
		engine_poll_events(&engine_state)

		engine_process_input()
		engine_update_logic()
		engine_draw_frame()
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
