package render

import "core:log"

import "vendor:glfw"

when DESKTOP_BUILD {
	create_glfw_window :: proc() -> (window: Desktop_Window_State) {
		if !glfw.Init() do log.panic("Glfw not initialized")
		when VERBOSE_LOG do log.debug("Glfw initialized")

		return
	}
	cleanup_glfw_window :: proc(state: ^Desktop_Window_State) {
		when VERBOSE_LOG do log.debug("Glfw cleaned up")
	}
}

Desktop_Window_State :: struct {
	handle: glfw.WindowHandle,
}
