package engine

import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"

Swapchain_State :: struct {
	handle: vk.SwapchainKHR,
	image_format: vk.SurfaceFormatKHR,
	image_extent: vk.Extent2D,
	present_mode: vk.PresentModeKHR,
	images: []Swapchain_Image,
}
Swapchain_Image :: struct {
	handle: vk.Image,
	view: vk.ImageView,
}

choose_swapchain_image_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	log.assert(len(formats) >= 1, "Passed formats length is zero")

	for f in formats do if f.colorSpace == .SRGB_NONLINEAR && f.format == .B8G8R8A8_SRGB do return f

	// Any will do as a fallback
	return formats[0]
}

choose_swapchain_image_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, window_handle: rawptr) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) do return capabilities.currentExtent
	else {
		when CONFIG_BUILD_TARGET != Build_Targets[.Pc] do log.panicf("Value of current extent set to max(u32) is supported only for desktop builds")
		else {
			width, height := glfw.GetFramebufferSize(glfw.WindowHandle(window_handle))

			extent := vk.Extent2D{
				u32(width),
				u32(height)
			}

			extent.width = clamp(extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
			extent.height = clamp(extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)

			return extent
		}
	}
}

choose_swapchain_presentation_mode :: proc(present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	log.assert(len(present_modes) >= 1, "Passed presentation modes length is zero")

	for p in present_modes do if p == .FIFO do return p

	return present_modes[0]
}

create_swapchain :: proc(state: ^Vulkan_Init_State, window_handle: rawptr, old_swapchain: vk.SwapchainKHR, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	ensure(.Surface in state.resource_flags, "Surface must be created before swapchain creation")
	if .Swapchain in state.resource_flags do log.warn("Called swapchain creation when resource flag is set, possible error")

	NON_STEREOSCOPIC :: 1
	DEFAULT_USAGE : vk.ImageUsageFlags : {.TRANSFER_DST, .COLOR_ATTACHMENT}
	DEFAULT_COMPOSITE_ALPHA : vk.CompositeAlphaFlagsKHR : {.OPAQUE}

	state.swapchain.image_format = choose_swapchain_image_format(state.physical_devices.active.formats)
	when CONFIG_VERBOSE_LOG do log.debugf("Chosen swapchain image format and color: %v | %v", state.swapchain.image_format.format, state.swapchain.image_format.colorSpace)
	state.swapchain.image_extent = choose_swapchain_image_extent(state.physical_devices.active.capabilites, window_handle)
	when CONFIG_VERBOSE_LOG do log.debugf("Chosen swapchain image extent (W x H): %v x %v", state.swapchain.image_extent.width, state.swapchain.image_extent.height)
	state.swapchain.present_mode = choose_swapchain_presentation_mode(state.physical_devices.active.present_modes)
	when CONFIG_VERBOSE_LOG do log.debugf("Chosen swapchain presentation mode: %v", state.swapchain.present_mode)



	swapchain_create_info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = state.surface.handle,
		minImageCount = state.physical_devices.active.capabilites.minImageCount,
		preTransform = state.physical_devices.active.capabilites.currentTransform,
		imageFormat = state.swapchain.image_format.format,
		imageColorSpace = state.swapchain.image_format.colorSpace,
		imageExtent = state.swapchain.image_extent,
		presentMode = state.swapchain.present_mode,
		clipped = true,
		imageArrayLayers = 1,
		imageUsage = DEFAULT_USAGE,
		compositeAlpha = DEFAULT_COMPOSITE_ALPHA,
		imageSharingMode = .EXCLUSIVE,
		// Exclusive mode so its basically ignored
		pQueueFamilyIndices = nil,
		queueFamilyIndexCount = 0,
		oldSwapchain = old_swapchain,
		
	}

	result := vk.CreateSwapchainKHR(state.device.handle, &swapchain_create_info, callbacks, &state.swapchain.handle)
	if result != .SUCCESS {
		log.errorf("Swapchain creation failed: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain created")

	image_count: u32
	result = vk.GetSwapchainImagesKHR(state.device.handle, state.swapchain.handle, &image_count, nil)
 	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Retrieving swapchain images successful")
	case .INCOMPLETE:
		log.warn("(1) Not all swapchain images were retrieved")
	case:
		log.errorf("(1) Swapchain images retrieval failed: %v", result)
		return
	}

	images := make([]vk.Image, image_count, allocator)
	defer delete(images, allocator)

	result = vk.GetSwapchainImagesKHR(state.device.handle, state.swapchain.handle, &image_count, raw_data(images))
 	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Retrieving swapchain images successful")
	case .INCOMPLETE:
		log.warn("(2) Not all swapchain images were retrieved")
	case:
		log.errorf("(2) Swapchain images retrieval failed: %v", result)
		return
	}

	state.swapchain.images = make([]Swapchain_Image, len(images), allocator)
	defer if !success do delete(state.swapchain.images, allocator)

	image_view_create_info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = .D2,
		format = state.swapchain.image_format.format,
		subresourceRange = {
			layerCount = 1,
			levelCount = 1,
			baseArrayLayer = 0,
			baseMipLevel = 0,
			aspectMask = {.COLOR}
		}

	}

	for &img, i in state.swapchain.images {
		state.swapchain.images[i].handle = images[i]

		image_view_create_info.image = img.handle


		result = vk.CreateImageView(state.device.handle, &image_view_create_info, callbacks, &img.view)
		if result != .SUCCESS {
			log.errorf("Swapchain image view creation failed: %v", result)
			return
		}
	}
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain image views created")
	
	state.resource_flags |= {.Swapchain}
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain resource flag set")

	success = true
	return 
}

cleanup_swapchain :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Swapchain not_in state.resource_flags {
		log.warn("Called swapchain cleanup when swapchain resource flag is unset")
		return
	}

	for i in state.swapchain.images do vk.DestroyImageView(state.device.handle, i.view, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain image views destroyed")

	delete(state.swapchain.images, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain images cleaned up")
	
	vk.DestroySwapchainKHR(state.device.handle, state.swapchain.handle, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain destroyed")

	state.resource_flags &~= {.Swapchain}
	when CONFIG_VERBOSE_LOG do log.debug("Swapchain resource flag unset")
}
