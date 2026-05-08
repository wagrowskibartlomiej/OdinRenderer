package engine

import "core:log"
import "vendor:glfw"

// Creates Vulkan surface for desktop targets. Prefer using `create_surface`.
glfw_create_surface :: proc(state: ^Core_Vk_State, window_state: ^Window_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	result := glfw.CreateWindowSurface(state.instance.handle, cast(glfw.WindowHandle)window_state.handle, callbacks, &state.surface.handle)
	if result != .SUCCESS {
		log.errorf("GLFW window surface creation error: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG  do log.debug("GLFW Surface created")

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Surface)

	success = true
	return
}
