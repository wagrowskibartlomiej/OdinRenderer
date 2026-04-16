package engine

import "vendor:glfw"

main :: proc () {
	engine_state: Engine_Global_State

	context = engine_init(&engine_state)
	defer engine_cleanup(&engine_state)

	success := engine_renderer_init(&engine_state)
	defer engine_renderer_cleanup(&engine_state)
	if !success do return

	for i in 0 ..< 1 {
		running := engine_poll_events(&engine_state)
		running or_break

		engine_process_input()
		engine_update_logic()
		engine_draw_frame()
	}

}

glfw_poll_events :: proc(window: ^Window_State) -> (running: bool) {
	glfw.PollEvents()

	if glfw.WindowShouldClose(cast(glfw.WindowHandle)window.handle) do return false
	else do return true
}
