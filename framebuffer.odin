package engine

import "core:log"
import vk "vendor:vulkan"

Framebuffers_State :: struct {
	swapchain_triangle: []vk.Framebuffer,
	swapchain_default_mesh: []vk.Framebuffer,
}

build_framebuffers :: proc(core: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	assert(core != nil)
	if .Framebuffers in core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Framebuffers)

	success = build_framebuffers_swapchain(core, allocator, callbacks)
	success or_return

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Framebuffers)

	when CONFIG_VERBOSE_LOG do log.debug("All framebuffers built")
	return
}
cleanup_framebuffers :: proc(core: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	assert(core != nil)
	if .Framebuffers not_in core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Framebuffers)
		return
	}

	cleanup_framebuffers_swapchain(core, allocator, callbacks)

	unset_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Framebuffers)
	when CONFIG_VERBOSE_LOG do log.debug("All framebuffers cleaned up")
}

build_framebuffers_swapchain :: proc(core: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	assert(core != nil)
	create_info := vk.FramebufferCreateInfo{
		sType = .FRAMEBUFFER_CREATE_INFO,
		width = core.swapchain.image_extent.width,
		height = core.swapchain.image_extent.height,
		layers = 1,
		attachmentCount = 1,
	}

	core.framebuffers.swapchain_triangle = make([]vk.Framebuffer, len(core.swapchain.images), allocator)
	defer if !success do delete(core.framebuffers.swapchain_triangle, allocator)

	core.framebuffers.swapchain_default_mesh = make([]vk.Framebuffer, len(core.swapchain.images), allocator)
	defer if !success do delete(core.framebuffers.swapchain_default_mesh, allocator)

	for i in 0 ..< len(core.swapchain.images) {
		create_info.pAttachments = &core.swapchain.images[i].view
		create_info.renderPass = core.render_passes.handles[.Triangle]

		result := vk.CreateFramebuffer(core.device.handle, &create_info, callbacks, &core.framebuffers.swapchain_triangle[i])
		defer if !success do for j in 0 ..< i do vk.DestroyFramebuffer(core.device.handle, core.framebuffers.swapchain_triangle[j], callbacks)

		if result != .SUCCESS {
			log.errorf("Swapchain framebuffer creation failure: %v", result)
			return false
		} else do success = true
	}

	attachments: [2]vk.ImageView

	for i in 0 ..< len(core.swapchain.images) {
		attachments[0] = core.swapchain.images[i].view
		attachments[1] = core.images.depth_image.view

		create_info.attachmentCount = u32(len(attachments))
		create_info.pAttachments = raw_data(attachments[:])

		create_info.renderPass = core.render_passes.handles[.Default_Mesh]

		result := vk.CreateFramebuffer(core.device.handle, &create_info, callbacks, &core.framebuffers.swapchain_default_mesh[i])
		defer if !success do for j in 0 ..< i do vk.DestroyFramebuffer(core.device.handle, core.framebuffers.swapchain_default_mesh[j], callbacks)

		if result != .SUCCESS {
			log.errorf("Swapchain framebuffer creation failure: %v", result)
			return false
		} else do success = true
	}
	when CONFIG_VERBOSE_LOG do log.debug("Framebuffers for swapchain created")
	return true
}

cleanup_framebuffers_swapchain :: proc(core: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	for f in core.framebuffers.swapchain_triangle {
	 	vk.DestroyFramebuffer(core.device.handle, f, callbacks)
	}

	for f in core.framebuffers.swapchain_default_mesh {
		vk.DestroyFramebuffer(core.device.handle, f, callbacks)
	}


	delete(core.framebuffers.swapchain_triangle, allocator)
	delete(core.framebuffers.swapchain_default_mesh, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Framebuffers for swapchain cleaned up")
}
