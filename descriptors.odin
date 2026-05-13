package engine

import "core:log"

import vk "vendor:vulkan"

Descriptors_State :: struct {
	pool: vk.DescriptorPool,
	layout: vk.DescriptorSetLayout,
	set: vk.DescriptorSet,
}

initialize_descriptors :: proc(core: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Descriptors in core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Descriptors)

	device := core.device.handle
	core.descriptors.pool = create_descriptor_pool(device, callbacks) or_return
	core.descriptors.layout = create_descriptor_layout(device, &core.images.default_sampler, callbacks) or_return
	core.descriptors.set = allocate_descriptor_set(device, core.descriptors.pool, &core.descriptors.layout) or_return

	img_info := vk.DescriptorImageInfo{
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView = core.images.example_texture.view,
		sampler = core.images.default_sampler,
	}

	write_info := vk.WriteDescriptorSet{
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = core.descriptors.set,
		dstBinding = 0,
		descriptorCount = 1,
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		pImageInfo = &img_info,
	}

	vk.UpdateDescriptorSets(device, 1, &write_info, 0, nil)

	when CONFIG_VERBOSE_LOG do log.debug("Descriptors state initalized")

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Descriptors)

	return true
}

cleanup_descriptors :: proc(core: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Descriptors not_in core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Descriptors)
		return
	}

	vk.DestroyDescriptorSetLayout(core.device.handle, core.descriptors.layout, callbacks)
	vk.DestroyDescriptorPool(core.device.handle, core.descriptors.pool, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Descriptors state cleaned up")

	unset_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Descriptors)
}

create_descriptor_pool :: proc(device: vk.Device, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (pool: vk.DescriptorPool, success: bool) {
	pool_size := vk.DescriptorPoolSize{
		descriptorCount = 1,
		type = .COMBINED_IMAGE_SAMPLER,
	}

	info := vk.DescriptorPoolCreateInfo{
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		pPoolSizes = &pool_size,
		poolSizeCount = 1,
		maxSets = 1, // We can have only one now since we're using only sampler
	}
	result := vk.CreateDescriptorPool(device, &info, callbacks, &pool)
	if result != .SUCCESS {
		log.errorf("Descriptor pool creation failure: %v", result)
		return
	}

	return pool, true
}

create_descriptor_layout :: proc(device: vk.Device, sampler: ^vk.Sampler, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (layout: vk.DescriptorSetLayout, success: bool) {
	bind := vk.DescriptorSetLayoutBinding{
		binding = 0,
		descriptorCount = 1,
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		stageFlags = {.FRAGMENT},
		pImmutableSamplers = sampler,
	}

	lay_info := vk.DescriptorSetLayoutCreateInfo{
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings = &bind,
	}

	result := vk.CreateDescriptorSetLayout(device, &lay_info, callbacks, &layout)
	if result != .SUCCESS {
		log.errorf("Descriptor layout creation failure: %v", result)
		return
	}

	return layout, true
}

allocate_descriptor_set :: proc(device: vk.Device, pool: vk.DescriptorPool, layout: ^vk.DescriptorSetLayout) -> (set: vk.DescriptorSet, success: bool) {
	info := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = pool,
		descriptorSetCount = 1,
		pSetLayouts = layout,
	}

	result := vk.AllocateDescriptorSets(device, &info, &set)
	if result != .SUCCESS {
		log.errorf("Descriptor set allocation failure: %v", result)
		return
	}

	return set, true
}
