#+build linux

package render

import "core:log"
import "core:dynlib"

import vk "vendor:vulkan"

import android "androidglue/ndkbindings"

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
	when VERBOSE_LOG do log.debug("Android surface created")

	state.resource_flags |= {.Surface}
	when VERBOSE_LOG do log.debug("Surface resource flag set")

	success = true
	return
}

