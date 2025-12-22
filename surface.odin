package render

import "core:log"
import "core:dynlib"

import "vendor:glfw"
import vk "vendor:vulkan"

Surface_State :: struct {
	handle: vk.SurfaceKHR,
}


glfw_create_surface :: proc(vulkan_state: ^Vulkan_Init_State, window_state: ^Desktop_Window_State, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	result := glfw.CreateWindowSurface(vulkan_state.instance.handle, window_state.handle, callbacks, &vulkan_state.surface.handle)
	if result != .SUCCESS {
		log.errorf("GLFW window surface creation error: %v", result)
		return
	}

	success = true
	return
} 
VkAndroidSurfaceCreateFlagKHR :: enum vk.Flags {}
VkAndroidSurfaceCreateFlagsKHR :: distinct bit_set[VkAndroidSurfaceCreateFlagKHR; vk.Flags]

ANativeWindow :: struct {}

VkAndroidSurfaceCreateInfoKHR :: struct {
	sType: vk.StructureType,
	pNext: rawptr,
	flags: VkAndroidSurfaceCreateFlagsKHR,
	window: ^ANativeWindow
}

Proc_vkCreateAndroidSurfaceKHR :: #type proc "system" (instance: vk.Instance, pCreateInfo: ^VkAndroidSurfaceCreateInfoKHR, pAllocator: ^vk.AllocationCallbacks, pSurface: ^vk.SurfaceKHR) -> vk.Result

android_create_surface :: proc() {
	
}
