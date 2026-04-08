package engine

import "core:log"
import vk "vendor:vulkan"

Framebuffers_State :: struct {
	swapchain: []vk.Framebuffer
}

build_framebuffers :: proc(init_state: ^Vulkan_Init_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Framebuffers in init_state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Init_Resource_Flag.Framebuffers)

	success = build_framebuffers_swapchain(init_state, allocator, callbacks)
	success or_return

	set_resource_flag(&init_state.resource_flags, Vulkan_Init_Resource_Flag.Framebuffers)

	when CONFIG_VERBOSE_LOG do log.debug("All framebuffers built")
	return
}
cleanup_framebuffers :: proc(init_state: ^Vulkan_Init_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Framebuffers not_in init_state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Init_Resource_Flag.Framebuffers)
		return
	}

	cleanup_framebuffers_swapchain(init_state, allocator, callbacks)

	unset_resource_flag(&init_state.resource_flags, Vulkan_Init_Resource_Flag.Framebuffers)
	when CONFIG_VERBOSE_LOG do log.debug("All framebuffers cleaned up")
}

build_framebuffers_swapchain :: proc(init_state: ^Vulkan_Init_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	create_info := vk.FramebufferCreateInfo{
		sType = .FRAMEBUFFER_CREATE_INFO,
		width = init_state.swapchain.image_extent.width,
		height = init_state.swapchain.image_extent.height,
		layers = 1,
		renderPass = init_state.render_passes.main_render_pass,
		attachmentCount = 1,
	}
	
	init_state.framebuffers.swapchain = make([]vk.Framebuffer, len(init_state.swapchain.images), allocator)
	defer if !success do delete(init_state.framebuffers.swapchain, allocator)

	for i in 0 ..< len(init_state.swapchain.images) {
		create_info.pAttachments = &init_state.swapchain.images[i].view

		result := vk.CreateFramebuffer(init_state.device.handle, &create_info, callbacks, &init_state.framebuffers.swapchain[i])
		defer if !success do for j in 0 ..< i do vk.DestroyFramebuffer(init_state.device.handle, init_state.framebuffers.swapchain[j], callbacks)

		if result != .SUCCESS {
			log.errorf("Swapchain framebuffer creation failure: %v", result)
			return false
		}
	}

	when CONFIG_VERBOSE_LOG do log.debug("Framebuffers for swapchain created")
	return true
}

cleanup_framebuffers_swapchain :: proc(init_state: ^Vulkan_Init_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	for f in init_state.framebuffers.swapchain do vk.DestroyFramebuffer(init_state.device.handle, f, callbacks)
	delete(init_state.framebuffers.swapchain, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Framebuffers for swapchain cleaned up")
}
