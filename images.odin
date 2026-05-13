package engine

import "core:log"

import vk "vendor:vulkan"

Images_State :: struct {
	default_sampler:              vk.Sampler,
	depth_image, example_texture: Image,
}

Image :: struct {
	handle: GPU_Resource_Handle,
	view:   vk.ImageView,
}

initalize_images_state :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	if .Images in core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Images)

	create_depth_image(core, callbacks) or_return

	texture, exists := get_asset(
		"example_texture.png",
		DEFAULT_ASSETS_DIR_NAME,
		.PNG,
		&get_global_state().assets,
	)
	if !exists {
		log.panic("Cannot continute without texture, extent is needed")
	}

	text_img, texture_err := gpu_create(
		.Texture_2D_RGBA,
		.Static,
		0,
		VRAM_FLAGS,
		false,
		extent = get_vulkan_extent_from_texture_data(texture.data.texture),
	)
	if texture_err != nil {
		log.fatalf("Cannot create texture image resource: %v", texture_err)
		return
	}
	core.images.example_texture.handle = text_img

	text_img_res := gpu_get_resource_from_handle(text_img).(vk.Image)
	core.images.example_texture.view = create_example_texture_image_view(
		core.device.handle,
		text_img_res,
		callbacks,
	) or_return

	core.images.default_sampler = create_sampler(core.device.handle, callbacks) or_return
	when CONFIG_VERBOSE_LOG do log.debug("Images state initalized")

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Images)
	return true
}

create_depth_image :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	depth_img, err := gpu_create(.Depth_Image, .Static, 0, VRAM_FLAGS, false)
	if err != nil {
		log.fatalf("Cannot create depth image resource: %v", err)
		return
	}
	core.images.depth_image.handle = depth_img

	depth_img_res := gpu_get_resource_from_handle(depth_img).(vk.Image)
	core.images.depth_image.view = create_depth_image_view(
		core.device.handle,
		depth_img_res,
		callbacks,
	) or_return

	return true
}

cleanup_depth_image :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	vk.DestroyImageView(core.device.handle, core.images.depth_image.view, callbacks)
	err := gpu_destroy(core.images.depth_image.handle)
	if err != nil {
		log.errorf("Failure destroying depth image, possible leaks: %v", err)
	}
}

cleanup_images_state :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	if .Images not_in core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Images)
		return
	}

	cleanup_depth_image(core, callbacks)

	vk.DestroyImageView(core.device.handle, core.images.example_texture.view, callbacks)
	text_err := gpu_destroy(core.images.example_texture.handle)
	if text_err != nil {
		log.errorf("Failure destroying texture image, possible leaks: %v", text_err)
	}

	vk.DestroySampler(core.device.handle, core.images.default_sampler, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Images state cleaned up")

	unset_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Images)
}

create_sampler :: proc(
	device: vk.Device,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	sampler: vk.Sampler,
	success: bool,
) {
	info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		addressModeU = .REPEAT,
		addressModeV = .REPEAT,
		addressModeW = .REPEAT,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
	}
	result := vk.CreateSampler(device, &info, callbacks, &sampler)
	if result != .SUCCESS {
		log.errorf("Sampler creation failure: %v", result)
		return
	}

	return sampler, true
}

create_depth_image_view :: proc(
	device: vk.Device,
	image: vk.Image,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	view: vk.ImageView,
	success: bool,
) {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		format = .D32_SFLOAT,
		image = image,
		subresourceRange = {aspectMask = {.DEPTH}, layerCount = 1, levelCount = 1},
		viewType = .D2,
	}
	result := vk.CreateImageView(device, &info, callbacks, &view)
	if result != .SUCCESS {
		log.errorf("Depth image view creation failure: %v", result)
		return
	}

	return view, true
}

create_example_texture_image_view :: proc(
	device: vk.Device,
	image: vk.Image,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	view: vk.ImageView,
	success: bool,
) {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		format = .R8G8B8A8_SRGB,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, layerCount = 1, levelCount = 1},
		viewType = .D2,
	}

	result := vk.CreateImageView(device, &info, callbacks, &view)
	if result != .SUCCESS {
		log.errorf("Texture image view creation failure: %v", result)
		return
	}

	return view, true
}
