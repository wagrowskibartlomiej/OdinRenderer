package engine

import "core:log"

import vk "vendor:vulkan"

Surface_State :: struct {
	handle: vk.SurfaceKHR,
}

// Creates platform surface for Vulkan.
create_surface :: proc(state: ^Core_Vk_State, window_state: ^Window_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Surface in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Surface)

	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do success = glfw_create_surface(state, window_state, callbacks)
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] {
		when ODIN_PLATFORM_SUBTARGET == .Android do success = android_create_surface(state, window_state, callbacks)
		else do #panic("Platform subtraget '" + ODIN_PLATFORM_SUBTARGET + "' does not have implemented Vulkan's surface creation")
	}
	else do #panic("Build target '" + CONFIG_BUILD_TARGET + "' does not have implemented Vulkan's surface creation")

	success or_return

	success = true
	return
}

// Cleanes up platform surface for Vulkan.
cleanup_surface :: proc(state: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Surface not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Surface)
		return
	}

	vk.DestroySurfaceKHR(state.instance.handle, state.surface.handle, callbacks)
	when CONFIG_VERBOSE_LOG  {
		when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do log.debug("GLFW surface destroyed")
		else do log.debug("Android surface destroyed")
	}

	unset_resource_flag(&state.resource_flags, Vulkan_Core_State_Resource_Flag.Surface)
}
