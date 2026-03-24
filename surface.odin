#+private file
package engine

import "core:log"
import "core:dynlib"

import "vendor:glfw"
import vk "vendor:vulkan"

import android "androidglue/ndkbindings"

@(private="package")
Surface_State :: struct {
	handle: vk.SurfaceKHR,
}

@(private="package")
create_surface :: proc(state: ^Vulkan_Init_State, window_state: ^Window_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	if .Surface in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Init_Resource_Flag.Surface)

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

@(private="package")
cleanup_surface :: proc(state: ^Vulkan_Init_State, callbacks: ^vk.AllocationCallbacks = nil) {
	if .Surface not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Init_Resource_Flag.Surface)
		return
	}

	vk.DestroySurfaceKHR(state.instance.handle, state.surface.handle, callbacks)
	when CONFIG_VERBOSE_LOG  {
		when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do log.debug("GLFW surface destroyed")
		else do log.debug("Android surface destroyed")
	}

	unset_resource_flag(&state.resource_flags, Vulkan_Init_Resource_Flag.Surface)
}

glfw_create_surface :: proc(state: ^Vulkan_Init_State, window_state: ^Window_State, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	result := glfw.CreateWindowSurface(state.instance.handle, cast(glfw.WindowHandle)window_state.handle, callbacks, &state.surface.handle)
	if result != .SUCCESS {
		log.errorf("GLFW window surface creation error: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG  do log.debug("GLFW Surface created")
	
	set_resource_flag(&state.resource_flags, Vulkan_Init_Resource_Flag.Surface)

	success = true
	return
} 


when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET == .Android {

VkAndroidSurfaceCreateFlagKHR :: enum vk.Flags {}
VkAndroidSurfaceCreateFlagsKHR :: distinct bit_set[VkAndroidSurfaceCreateFlagKHR; vk.Flags]

VkAndroidSurfaceCreateInfoKHR :: struct {
	sType: vk.StructureType,
	pNext: rawptr,
	flags: VkAndroidSurfaceCreateFlagsKHR,
	window: ^android.ANativeWindow
}

Proc_vkCreateAndroidSurfaceKHR :: #type proc "system" (instance: vk.Instance, pCreateInfo: ^VkAndroidSurfaceCreateInfoKHR, pAllocator: ^vk.AllocationCallbacks, pSurface: ^vk.SurfaceKHR) -> vk.Result

android_create_surface :: proc(state: ^Vulkan_Init_State, window_state: ^Window_State, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	symbol, found := dynlib.symbol_address(state.vklib, "vkCreateAndroidSurfaceKHR")
	if !found {
		log.fatal("Cannot found address of 'vkCreateAndroidSurfaceKHR', the application cannot continue.")
		return
	}
	vkCreateAndroidSurface := cast(Proc_vkCreateAndroidSurfaceKHR)symbol

	create_info := VkAndroidSurfaceCreateInfoKHR{
		sType = .ANDROID_SURFACE_CREATE_INFO_KHR,
		window = cast(^android.ANativeWindow)window_state.handle,
	}
	result := vkCreateAndroidSurface(state.instance.handle, &create_info, callbacks, &state.surface.handle)
	if result != .SUCCESS {
		log.errorf("Android surface creation failed: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Android surface created")

	set_resource_flag(&state.resource_flags, Vulkan_Init_Resource_Flag.Surface)

	success = true
	return
}

}
