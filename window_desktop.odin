package engine

import "core:c"
import "core:log"
import "vendor:glfw"

// Creates window using GLFW. Prefer using `create_window`.
create_glfw_window :: proc(state: ^Window_State, app_name : cstring = APPLICATION_NAME, width : c.int = 800, height: c.int = 600) -> (success: bool) {
	if !glfw.Init() {
		log.errorf("GLFW not initialized")
		return 
	}

	when CONFIG_VERBOSE_LOG do log.debug("GLFW initialized")

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	state.handle = glfw.CreateWindow(width, height, app_name, nil, nil)

	state.created = true
	when CONFIG_VERBOSE_LOG do log.debugf("GLFW Window created")
	return true
}

// Cleanes up window created using GLFW. Prefer using `cleanup_window`.
cleanup_glfw_window :: proc(state: ^Window_State) {
	if !state.created do return

	glfw.DestroyWindow(glfw.WindowHandle(state.handle))
	when CONFIG_VERBOSE_LOG do log.debug("GLFW Window cleaned up")
}
