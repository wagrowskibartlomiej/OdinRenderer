#+private file
package render

import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"


@(private="package")
Surface_State :: struct {
	handle: vk.SurfaceKHR,
}

@(private="package")
create_surface :: proc(state: ^Vulkan_Init_State, window_state: ^Window_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {

	when DESKTOP_BUILD do success = glfw_create_surface(state, window_state, callbacks)
	else do success = android_create_surface(state, window_state, callbacks)
	success or_return

	success = true
	return
}

@(private="package")
cleanup_surface :: proc(state: ^Vulkan_Init_State, callbacks: ^vk.AllocationCallbacks = nil) {
	vk.DestroySurfaceKHR(state.instance.handle, state.surface.handle, callbacks)
	when VERBOSE_LOG {
		when DESKTOP_BUILD do log.debug("GLFW surface destroyed")
		else do log.debug("Android surface destroyed")
	}

	state.resource_flags &~= {.Surface}
	when VERBOSE_LOG do log.debug("Surface resource flag unset")
}

glfw_create_surface :: proc(state: ^Vulkan_Init_State, window_state: ^Window_State, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	result := glfw.CreateWindowSurface(state.instance.handle, cast(glfw.WindowHandle)window_state.handle, callbacks, &state.surface.handle)
	if result != .SUCCESS {
		log.errorf("GLFW window surface creation error: %v", result)
		return
	}
	when VERBOSE_LOG do log.debug("GLFW Surface created")
	
	state.resource_flags |= {.Surface}
	when VERBOSE_LOG do log.debug("Surface resource flag set")

	success = true
	return
} 


