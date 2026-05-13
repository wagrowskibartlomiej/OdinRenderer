package engine

import "core:log"
import "core:mem"
import "core:sort"

import "base:runtime"

import vk "vendor:vulkan"

GPU_RESOURCE_HANDLE_BACKING_TYPE :: distinct u64
GPU_RESOURCE_HANDLE_INDEX_BITS :: 20
GPU_RESOURCE_HANDLE_ID_BITS :: 44
GPU_RESOURCE_HANDLE_INDEX_MAX :: (1 << GPU_RESOURCE_HANDLE_INDEX_BITS) - 1
GPU_RESOURCE_HANDLE_ID_MAX :: (1 << GPU_RESOURCE_HANDLE_ID_BITS) - 1

GPU_Resources_State :: struct {
	//resource_pool_allocator TODO: Implement pool allocating and exclusive linear allocator,
	//resource_linear_allocator,
	resource_static_allocator: GPU_Resource_Allocator,
	callbacks:                 ^vk.AllocationCallbacks,
	datas:                     [dynamic]GPU_Resource_Data,
	_internal_allocator:       runtime.Allocator, // for Odin side allocations
	_validation_id_counter:    u64,
	_free_list_idx:            int, // Used for tracking free list
}

GPU_Resource_Handle :: bit_field GPU_RESOURCE_HANDLE_BACKING_TYPE {
	index: u32 | GPU_RESOURCE_HANDLE_INDEX_BITS,
	id:    i64 | GPU_RESOURCE_HANDLE_ID_BITS, // used for validation
}
GPU_RESOURCE_HANDLE_NIL :: GPU_Resource_Handle(max(GPU_RESOURCE_HANDLE_BACKING_TYPE))

GPU_Resource_Data :: struct {
	resource:                        Vulkan_Resource,
	handle:                          GPU_Resource_Handle,
	type:                            GPU_Resource_Type,
	usage:                           GPU_Resource_Usage,
	data_size, backing_size, offset: vk.DeviceSize,
	parent_idx:                      int, // index of allocated block that is containing the resource
	pool_elems:                      [dynamic]GPU_Region,
}

Vulkan_Resource :: union {
	vk.Buffer,
	vk.Image,
}

GPU_Resource_Create_Info :: struct #raw_union {
	buffer: vk.BufferCreateInfo,
	image:  vk.ImageCreateInfo,
}

GPU_Memory_Resource_Category :: enum {
	Buffer,
	Image,
}

GPU_Resource_Usage :: enum {
	Static,
	Pool,
}

GPU_Resource_Type :: enum {
	Custom_Buffer,
	Custom_Image,
	Vertex_Buffer,
	Staging_Buffer,
	Index_Buffer,
	Depth_Image,
	Texture_2D_RGBA,
}

GPU_Data_Transfer_Action :: enum {
	Submit_Cmd_Buffer,
	Flush_Destination,
	Flush_Staging,
}
GPU_Data_Transfer_Action_Flags :: bit_set[GPU_Data_Transfer_Action]

GPU_Resource_Create_Info_Presets := #partial [GPU_Resource_Type]GPU_Resource_Create_Info {
	.Vertex_Buffer = {
		buffer = vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			sharingMode = .EXCLUSIVE,
			usage = {.TRANSFER_SRC, .TRANSFER_DST, .VERTEX_BUFFER},
		},
	},
	.Index_Buffer = {
		buffer = vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			sharingMode = .EXCLUSIVE,
			usage = {.TRANSFER_SRC, .TRANSFER_DST, .INDEX_BUFFER},
		},
	},
	.Staging_Buffer = {
		buffer = vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			sharingMode = .EXCLUSIVE,
			usage = {.TRANSFER_SRC, .TRANSFER_DST},
		},
	},
	.Depth_Image = {
		image = {
			sType = .IMAGE_CREATE_INFO,
			imageType = .D2,
			sharingMode = .EXCLUSIVE,
			usage = {.DEPTH_STENCIL_ATTACHMENT},
			format = .D32_SFLOAT,
			tiling = .OPTIMAL,
			initialLayout = .UNDEFINED,
			arrayLayers = 1,
			mipLevels = 1,
			samples = {._1},
		},
	},
	.Texture_2D_RGBA = {
		image = {
			sType = .IMAGE_CREATE_INFO,
			imageType = .D2,
			sharingMode = .EXCLUSIVE,
			usage = {.TRANSFER_DST, .TRANSFER_SRC, .SAMPLED},
			format = .R8G8B8A8_SRGB,
			tiling = .OPTIMAL,
			initialLayout = .UNDEFINED,
			arrayLayers = 1,
			mipLevels = 1,
			samples = {._1},
		},
	},
}

gpu_initalize_resources :: proc(
	res_state: ^GPU_Resources_State,
	res_static_alloc: GPU_Resource_Allocator = {gpu_default_static_resource_allocator, nil},
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> mem.Allocator_Error {
	res_state.datas = make([dynamic]GPU_Resource_Data) or_return
	res_state.resource_static_allocator = res_static_alloc
	res_state.callbacks = callbacks
	res_state._free_list_idx = GPU_FREE_LIST_ABSENT_VALUE
	res_state._internal_allocator = allocator

	return nil
}

gpu_cleanup_resources :: proc(res_state: ^GPU_Resources_State) {
	for data in res_state.datas {
		if !_is_handle(data.handle) do continue
		gpu_destroy(data.handle)
	}

	delete(res_state.datas)
}

gpu_create :: proc(
	type: GPU_Resource_Type,
	usage: GPU_Resource_Usage,
	size: vk.DeviceSize,
	flags: vk.MemoryPropertyFlags,
	mappable: bool,
	alignment: vk.DeviceSize = 0,
	info: GPU_Resource_Create_Info = {},
	extent := vk.Extent3D{},
) -> (
	handle: GPU_Resource_Handle,
	err: GPU_Error,
) {
	r := &get_global_state().renderer
	static := r.resources.resource_static_allocator
	request := GPU_Resource_Allocator_Request {
		info      = info,
		mappable  = mappable,
		type      = type,
		alignment = alignment,
		allocator = r.resources._internal_allocator,
		flags     = flags,
		size      = size,
		extent    = extent,
	}

	#partial switch usage {
	case .Static:
		res, err, idx, padding := static.procedure(
			.Create,
			request,
			{},
			r.resources.callbacks,
			static.data,
		)
		if err != nil {
			return {}, err
		}
		handle := _gpu_update_resources_addition(res, &r.resources) or_return
		new_region := GPU_Taken_Region{{res.offset, res.backing_size}, padding, 0, handle}
		_gpu_update_block_res_created(&new_region, idx, &r.memory.blocks[res.parent_idx])
		return handle, nil
	case:
		return {}, .Not_Implemented
	}
}

gpu_destroy :: proc(handle: GPU_Resource_Handle) -> GPU_Error {
	r := get_global_state().renderer.resources

	res := gpu_get_resource_from_handle(handle)
	if res == nil {
		return .Unknown
	}

	data := r.datas[handle.index]
	if !_validate_handles(handle, data.handle) {
		return .Unknown
	}

	static_allocator := r.resource_static_allocator

	switch data.usage {
	case .Static:
		static_allocator.procedure(.Destroy, {}, handle, r.callbacks, static_allocator.data)
		_gpu_update_block_res_destroyed(data)
		_gpu_update_resources_deletion(handle, &r)
	case .Pool:
		return .Not_Implemented
	}

	return nil
}

/*
	I do not think it's a good idea to unify these copy procs cause of different behaviour that is expected from a caller,
	but idk really, short version seems really handy at some times
*/


// TODO: When pool allocator will be available we need to update copy procedures to account for reosurce pool regions
// WARN: Before usage read what exactly each of the procedure does, use only for shorthand purposes.
gpu_copy :: proc {
	gpu_copy_buffers,
	gpu_copy_to_mappable,
	gpu_copy_images,
	gpu_copy_buffer_to_image,
	gpu_copy_image_to_buffer,
}

// Procedure expects that caller will manage submition, synchrozniation of barriers/semaphores and a call to `vk.BeginCommandBuffer`.
gpu_copy_buffers :: proc(
	cmd: vk.CommandBuffer,
	dst, src: GPU_Resource_Handle,
	regions: []vk.BufferCopy,
) -> (
	success: bool,
) {
	dst_buffer := gpu_get_resource_from_handle(dst).(vk.Buffer) or_return
	src_buffer := gpu_get_resource_from_handle(src).(vk.Buffer) or_return

	vk.CmdCopyBuffer(cmd, src_buffer, dst_buffer, u32(len(regions)), raw_data(regions))
	return true
}

// Procedure expects that caller will manage synchronization.
gpu_copy_to_mappable :: proc(
	dst: GPU_Resource_Handle,
	ptr: rawptr,
	size: int,
) -> (
	flush_required: bool,
	success: bool,
) {
	r := get_global_state().renderer

	data := r.resources.datas[dst.index]

	assert(data.parent_idx < len(r.memory.blocks) && data.parent_idx >= 0)
	block := r.memory.blocks[data.parent_idx]

	if block.mapped_ptr == nil || data.data_size < vk.DeviceSize(size) {
		when CONFIG_VERBOSE_LOG do log.warnf(
			"Called '%v', but dst (%v, %v) doesn't meet requirements (mapped: %v, size (got vs requested): %v %v vs %v %v) - parent block %v",
			#procedure,
			dst,
			gpu_get_data(dst),
			block.mapped_ptr,
			logs_simplify_bytes(u64(data.data_size)),
			logs_simplify_bytes(u64(size)),
			block,
		)
		return
	}

	target := cast(rawptr)(uintptr(block.mapped_ptr) + uintptr(data.offset))

	// I think non overlapping will be good
	mem.copy_non_overlapping(target, ptr, size)
	if .HOST_COHERENT in block.flags {
		return false, true
	}

	return true, true
}

gpu_copy_images :: proc(
	cmd_buff: vk.CommandBuffer,
	dst, src: GPU_Resource_Handle,
	src_layout, dst_layout: vk.ImageLayout,
	regions: []vk.ImageCopy,
) -> (
	success: bool,
) {
	src_img := gpu_get_resource_from_handle(src).(vk.Image) or_return
	dst_img := gpu_get_resource_from_handle(dst).(vk.Image) or_return

	vk.CmdCopyImage(
		cmd_buff,
		src_img,
		src_layout,
		dst_img,
		dst_layout,
		u32(len(regions)),
		raw_data(regions),
	)
	return true
}

gpu_copy_buffer_to_image :: proc(
	cmd_buff: vk.CommandBuffer,
	dst: GPU_Resource_Handle,
	dst_layout: vk.ImageLayout,
	src: GPU_Resource_Handle,
	regions: []vk.BufferImageCopy,
) -> (
	success: bool,
) {
	src_buff := gpu_get_resource_from_handle(src).(vk.Buffer) or_return
	dst_img := gpu_get_resource_from_handle(dst).(vk.Image) or_return

	vk.CmdCopyBufferToImage(
		cmd_buff,
		src_buff,
		dst_img,
		dst_layout,
		u32(len(regions)),
		raw_data(regions),
	)
	return true
}

gpu_copy_image_to_buffer :: proc(
	cmd_buff: vk.CommandBuffer,
	dst, src: GPU_Resource_Handle,
	src_layout: vk.ImageLayout,
	regions: []vk.BufferImageCopy,
) -> (
	success: bool,
) {
	src_img := gpu_get_resource_from_handle(src).(vk.Image) or_return
	dst_buff := gpu_get_resource_from_handle(src).(vk.Buffer) or_return

	vk.CmdCopyImageToBuffer(
		cmd_buff,
		src_img,
		src_layout,
		dst_buff,
		u32(len(regions)),
		raw_data(regions),
	)
	return true
}

//WARN: Do not use without reading soruce code
gpu_move :: proc {
	gpu_move_data_to_buffer,
	gpu_move_data_to_image,
}

/*
	- Moves data to gpu buffer passed in `dst` param. If possible, copies directly to mapped, if not tries to use staging buffer.
	- If procedure needs to use stagin buffer, the command buffer passed in `staging` is used for recording and procedure calls `begin_command_buffer` and `end_command_buffer` on it.
	- It's up to the caller to submit staging command buffer and to synchronize `vkCmdCopyBuffer`.
	- Returned `actions` param idicates which actions are required to properly synchronize memory access.
	- WARN: In current state **DOES NOT** support queue ownership transfer or any other queue other than graphics.
*/
gpu_move_data_to_buffer :: proc(
	data: rawptr,
	size: int,
	dst: GPU_Resource_Handle,
	staging: ^Staging_Buffer,
) -> (
	actions: GPU_Data_Transfer_Action_Flags,
	success: bool,
) {
	r := get_global_state().renderer
	parent_idx := r.resources.datas[dst.index].parent_idx

	//TODO: Now we're only using graphics queue for transfers and only exclusive resources, but this needs to change
	if r.memory.blocks[parent_idx].mapped_ptr != nil {
		flush_required := gpu_copy_to_mappable(dst, data, size) or_return
		if flush_required {
			actions += {.Flush_Destination}
		}
		return actions, true
	}

	if staging == nil do return

	// Wait till we can use staging cmd buffer and actually copy into it
	if .Dont_Wait_Fence not_in staging.flags {
		vk.WaitForFences(r.core.device.handle, 1, &staging.fence, true, VK_TIMEOUT_MAX)
		vk.ResetFences(r.core.device.handle, 1, &staging.fence)
	}
	defer if success {
		staging^.flags -= {.Dont_Wait_Fence}
	}

	result := vk.ResetCommandPool(r.core.device.handle, staging.pool, nil)
	if result != .SUCCESS {
		log.panicf("Staging buffer command pool resetting failure: %v", result)
	}

	flush_required := gpu_copy_to_mappable(staging.handle, data, size) or_return

	if flush_required {
		actions += {.Flush_Staging}
	}

	region := []vk.BufferCopy{{0, 0, vk.DeviceSize(size)}}

	begin_command_buffer(staging.cmd_buff) or_return
	gpu_copy_buffers(staging.cmd_buff, dst, staging.handle, region) or_return
	end_command_buffer(staging.cmd_buff) or_return
	actions += {.Submit_Cmd_Buffer}

	return actions, true
}


// Moves data to image by copying it to stating buffer and then copies staging into destination image.
// WARN: Used only with aspect mask COLOR
gpu_move_data_to_image :: proc(
	cmd_buff: vk.CommandBuffer,
	ptr: rawptr,
	size: int,
	dst: GPU_Resource_Handle,
	dst_layout: vk.ImageLayout,
	region: vk.BufferImageCopy,
	staging: ^Staging_Buffer,
) -> (
	actions: GPU_Data_Transfer_Action_Flags,
	success: bool,
) {
	assert(size >= 0 && staging != nil)

	r := get_global_state().renderer

	dst_img := gpu_get_resource_from_handle(dst).(vk.Image) or_return
	if .Dont_Wait_Fence not_in staging.flags {
		vk.WaitForFences(r.core.device.handle, 1, &staging.fence, true, VK_TIMEOUT_MAX)
		vk.ResetFences(r.core.device.handle, 1, &staging.fence)
	}

	result := vk.ResetCommandPool(r.core.device.handle, staging.pool, nil)
	if result != .SUCCESS {
		log.panicf("Staging buffer command pool resetting failure: %v", result)
	}

	defer if success {
		staging^.flags -= {.Dont_Wait_Fence}
	}

	flush_required := gpu_copy_to_mappable(staging.handle, ptr, size) or_return
	if flush_required {
		actions += {.Flush_Staging}
	}

	regions := []vk.BufferImageCopy{region}

	img_barrier1 := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcAccessMask = nil,
		dstAccessMask = {.TRANSFER_WRITE},
		image = dst_img,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			baseMipLevel = 0,
			layerCount = 1,
			levelCount = 1,
		},
	}

	img_barrier2 := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = dst_layout,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_READ},
		image = dst_img,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			baseMipLevel = 0,
			layerCount = 1,
			levelCount = 1,
		},
	}

	begin_command_buffer(cmd_buff) or_return
	vk.CmdPipelineBarrier(
		cmd_buff,
		{.TOP_OF_PIPE},
		{.TRANSFER},
		nil,
		0,
		nil,
		0,
		nil,
		1,
		&img_barrier1,
	)
	gpu_copy_buffer_to_image(
		cmd_buff,
		dst,
		.TRANSFER_DST_OPTIMAL,
		staging.handle,
		regions,
	) or_return
	vk.CmdPipelineBarrier(
		cmd_buff,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		nil,
		0,
		nil,
		0,
		nil,
		1,
		&img_barrier2,
	)
	end_command_buffer(cmd_buff) or_return

	actions += {.Submit_Cmd_Buffer}
	return actions, true
}


_gpu_create_buffer :: proc(
	device: vk.Device,
	info: ^vk.BufferCreateInfo,
	callbacks: ^vk.AllocationCallbacks,
) -> (
	buff: vk.Buffer,
	success: bool,
) {
	result := vk.CreateBuffer(device, info, callbacks, &buff)
	if result != .SUCCESS {
		when CONFIG_VERBOSE_LOG do log.errorf("Buffer creation failure: %v", result)
	}
	return buff, result == .SUCCESS
}

_gpu_get_buffer_requirements :: proc(
	device: vk.Device,
	buffer: vk.Buffer,
) -> vk.MemoryRequirements {
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &req)

	return req
}

_gpu_get_storage_buffer_requirements :: proc(
	device: vk.Device,
	buffer: vk.Buffer,
	limits: vk.PhysicalDeviceLimits,
) -> vk.MemoryRequirements {
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &req)

	req.alignment = max(req.alignment, limits.minStorageBufferOffsetAlignment)
	return req
}

/*
        Returned param `free_region_index` should be ignored if `search_free` is set to `false`.
        If `search_free` is set to true, `free_region_index` is the region in which the offset has been found.
        WARN: caller is responsible for updating the region list
*/
_gpu_find_offset_for_resource :: proc(
	memory: GPU_Memory_Block,
	alignment, size: vk.DeviceSize,
	search_free: bool,
) -> (
	offset: i64 = -1,
	padding: vk.DeviceSize,
	free_region_index := -1,
) {
	off, pad := _gpu_find_offset_alloc_linear(memory, alignment, size)
	if off != -1 || !search_free do return off, pad, -1

	return _gpu_find_offset_free_regions(memory.free_regions[:], alignment, size)
}

_gpu_find_offset_alloc_linear :: proc(
	memory: GPU_Memory_Block,
	alignment, size: vk.DeviceSize,
) -> (
	offset: i64,
	padding: vk.DeviceSize,
) {
	if memory.allocated + size > memory.size || memory.linear_write_offset + size > memory.size {
		return -1, 0
	}

	off := find_aligned_offset_align_up(u64(memory.linear_write_offset), u64(alignment))

	if vk.DeviceSize(off) + size > memory.size {
		return -1, 0
	}

	padding = vk.DeviceSize(off) - memory.linear_write_offset

	return off, padding
}

_gpu_find_offset_free_regions :: proc(
	regions: []GPU_Region,
	alignment, size: vk.DeviceSize,
) -> (
	offset: i64,
	region_padding: vk.DeviceSize,
	region_index: int,
) {
	for r, i in regions {
		if r.size < size do continue

		off := find_aligned_offset_align_up(u64(r.offset), u64(alignment))
		if off == -1 || vk.DeviceSize(off) + size > r.size + r.offset do continue

		return off, vk.DeviceSize(off) - r.offset, i
	}

	return -1, 0, -1
}

_gpu_readjust_requirements_for_mapping :: proc(
	requirements: vk.MemoryRequirements,
	limits: vk.PhysicalDeviceLimits,
) -> (
	alignment, size: vk.DeviceSize,
) {
	final_align := max(requirements.alignment, limits.nonCoherentAtomSize)
	final_size := align_up_pow_2(u64(requirements.size), u64(final_align))

	return final_align, vk.DeviceSize(final_size)
}

_gpu_update_block_res_created :: proc(
	new_reg: ^GPU_Taken_Region,
	free_reg_index: int,
	block: ^GPU_Memory_Block,
) -> (
	taken_region_idx: int,
) {
	assert(block != nil)
	// If we've used free region index, we need to check if we used it all,
	// if so remove it ordered to not sort anymore
	// then add region to taken and sort the taken ones
	if free_reg_index >= 0 {
		free_reg := block.free_regions[free_reg_index]

		_gpu_update_free_region_based_on_new_addition(block, new_reg, free_reg_index)

		append(&block.taken_regions, new_reg^)
		sort.quick_sort_proc(block.taken_regions[:], _gpu_region_resource_sort_by_offset)

		// Find index after sorting
		for taken, i in block.taken_regions {
			if taken == new_reg^ {
				taken_region_idx = i
				break
			}
		}
	} else {
		// In this branch we've used linear write so we need to update write offset
		// and just append taken region, they we'll be sorted naturally
		block.linear_write_offset = new_reg.offset + new_reg.size
		append(&block.taken_regions, new_reg^)
		taken_region_idx = len(block.taken_regions) - 1
	}

	block.allocated += new_reg.size

	return taken_region_idx
}

_gpu_update_block_res_destroyed :: proc(data: GPU_Resource_Data) {
	r := get_global_state().renderer
	block := &r.memory.blocks[data.parent_idx]

	reg_idx := _gpu_search_for_region_index(data.handle, block)
	if reg_idx == -1 {
		return
	}

	reg := block.taken_regions[reg_idx]

	block.allocated -= reg.size
	ordered_remove(&block.taken_regions, reg_idx)

	append(
		&block.free_regions,
		GPU_Region{reg.offset - reg.padding, reg.size + reg.padding + reg.back_padding},
	)

	sort.quick_sort_proc(block.free_regions[:], _gpu_region_sort_by_offset)
	_gpu_merge_free_regions(block)

	// Unwind now that we've sorted
	if len(block.free_regions) > 0 {
		last_free := &block.free_regions[len(block.free_regions) - 1]

		if last_free.offset + last_free.size == vk.DeviceSize(block.linear_write_offset) {
			block.linear_write_offset = vk.DeviceSize(last_free.offset)
			pop(&block.free_regions)
		}
	}
}

_gpu_search_for_region_index :: proc(res: GPU_Resource_Handle, block: ^GPU_Memory_Block) -> int {
	for t, i in block.taken_regions {
		if t.handle == res {
			return i
		}
	}

	return -1
}

_gpu_update_resources_addition :: proc(
	data: GPU_Resource_Data,
	res_state: ^GPU_Resources_State,
) -> (
	h: GPU_Resource_Handle,
	err: GPU_Error,
) {
	assert(res_state != nil)

	if res_state._free_list_idx == GPU_FREE_LIST_ABSENT_VALUE {
		append(&res_state.datas, data)
		last := len(res_state.datas) - 1
		handle := _gpu_generate_resource_handle(last, &res_state._validation_id_counter)
		res_state.datas[last].handle = handle
		return handle, nil
	}

	idx := res_state._free_list_idx
	d := res_state.datas[idx]
	switch d.handle.id {
	case GPU_HANDLE_LIST_END_ID_VALUE:
		res_state._free_list_idx = GPU_FREE_LIST_ABSENT_VALUE
	case GPU_HANDLE_LIST_NEXT_ID_VALUE:
		res_state._free_list_idx = int(d.handle.index)
	case:
		log.warnf("Unexpected ID value encountered in handle: %v", d.handle)
		return {}, .Unknown
	}

	res_state.datas[idx] = data
	handle := _gpu_generate_resource_handle(idx, &res_state._validation_id_counter)
	res_state.datas[idx].handle = handle

	return handle, nil
}

_gpu_update_resources_deletion :: proc(h: GPU_Resource_Handle, res_state: ^GPU_Resources_State) {
	assert(_is_handle(h))
	if len(res_state.datas) <= 0 {
		return
	}

	// If last element just remove
	last_idx := u32(len(res_state.datas) - 1)
	if h.index == last_idx && res_state._free_list_idx != GPU_FREE_LIST_ABSENT_VALUE {
		res_state.datas[last_idx].handle = GPU_RESOURCE_HANDLE_NIL
		pop(&res_state.datas)
		return
	}

	// Add to free list if not the last element
	assert(h.index >= 0 && h.index < u32(len(res_state.datas)))
	if res_state._free_list_idx == GPU_FREE_LIST_ABSENT_VALUE {
		res_state._free_list_idx = int(h.index)
		res_state.datas[h.index].handle.id = GPU_HANDLE_LIST_END_ID_VALUE
		return
	}

	idx := res_state._free_list_idx
	res_state._free_list_idx = int(h.index)
	res_state.datas[h.index].handle = {
		id    = GPU_HANDLE_LIST_NEXT_ID_VALUE,
		index = u32(idx),
	}
	return
}


_gpu_region_sort_by_offset :: proc(first, second: GPU_Region) -> int {
	if first.offset < second.offset do return -1
	else if first.offset > second.offset do return 1
	else do return 0
}

_gpu_region_resource_sort_by_offset :: proc(first, second: GPU_Taken_Region) -> int {
	if first.offset < second.offset do return -1
	else if first.offset > second.offset do return 1
	else do return 0
}

// Procedure can change `padding` of passed `new_region` if it's suitable to create new free region based on it.
_gpu_update_free_region_based_on_new_addition :: proc(
	block: ^GPU_Memory_Block,
	new_region: ^GPU_Taken_Region,
	free_region_idx: int,
) {
	assert(block != nil)

	if free_region_idx < 0 {
		return
	}

	free_region := block.free_regions[free_region_idx]

	// Best path
	if new_region.offset == free_region.offset {
		new_size := free_region.size - new_region.size

		// We cover all space, best case scenario
		if new_size == 0 {
			ordered_remove(&block.free_regions, free_region_idx)
			return
		} else // Left space is not enough so we add it as back padding
		if new_size < GPU_MIN_BYTES_FREE_REGION_THRESHOLD {
			new_region.back_padding = new_size
			ordered_remove(&block.free_regions, free_region_idx)
			return
		}

		// Left space is big enough to be a new standalone free region
		new_offset := free_region.offset + new_region.size

		block.free_regions[free_region_idx] = {new_offset, new_size}
		return
	}

	// when they end at the same offset, we either leave it as a padding or shrink region if the size is enough
	if new_region.offset + new_region.size == free_region.offset + free_region.size {
		if new_region.padding < GPU_MIN_BYTES_FREE_REGION_THRESHOLD {
			// leave it as is and just remove region
			ordered_remove(&block.free_regions, free_region_idx)
			return
		}

		// We shrink the region cause it still is big enough to be not included in padding
		// So we use the region that would be padding as new free and remove padding from new region
		block.free_regions[free_region_idx] = {free_region.offset, new_region.padding}
		new_region.padding = 0

		return
	}

	// REMEMBER TO MAKE THEM ORDERED!!
	// Worst case, we need to split into to or manage paddings

	// First handle te "back"
	back_region_offset := new_region.offset + new_region.size
	back_region_size := (free_region.offset + free_region.size) - (back_region_offset)

	// either we add it as back_padding
	if back_region_size < GPU_MIN_BYTES_FREE_REGION_THRESHOLD {
		new_region.back_padding = back_region_size
	} else {
		// or inject back region after the old one
		inject_at(
			&block.free_regions,
			free_region_idx + 1, // we inject after the old one, if the old one will be removed TODO: Optimize this, we could avoid injecting if we now that only one will be left
			GPU_Region{back_region_offset, back_region_size},
		)
	}

	// after "back" we need to handle front
	front_region_offset := free_region.offset
	front_region_size := new_region.padding

	// either remove it and leave padding
	if front_region_size < GPU_MIN_BYTES_FREE_REGION_THRESHOLD {
		ordered_remove(&block.free_regions, free_region_idx)
	} else {
		// or shrink it down and zero the padding on new taken region
		block.free_regions[free_region_idx] = {front_region_offset, front_region_size}
		new_region.padding = 0
	}

	return
}

gpu_get_resource_from_handle :: proc(handle: GPU_Resource_Handle) -> Vulkan_Resource {
	res := get_global_state().renderer.resources

	if !validate_handle(handle) {
		return nil
	}

	data := res.datas[handle.index]
	if handle.id != data.handle.id {
		return nil
	}

	return data.resource
}

validate_handle :: proc {
	validate_memory_handle,
	validate_resource_handle,
}

validate_memory_handle :: proc(handle: GPU_Memory_Handle) -> (ok: bool) {
	_is_handle(handle) or_return

	m := get_global_state().renderer.memory
	return m.blocks[handle.index].handle.id == handle.id
}

validate_resource_handle :: proc(handle: GPU_Resource_Handle) -> (ok: bool) {
	_is_handle(handle) or_return

	r := get_global_state().renderer.resources
	return r.datas[handle.index].handle.id == handle.id
}

// Checks if handle ID is not special or invalid value.
_is_handle :: proc {
	_is_memory_handle,
	_is_resource_handle,
}

// Checks if memory handle ID is not special or invalid value. Prefer using `is_handle`.
_is_memory_handle :: proc(handle: GPU_Memory_Handle) -> (ok: bool) {
	_is_handle_in_range(handle) or_return
	if handle.id == GPU_HANDLE_LIST_END_ID_VALUE ||
	   handle.id == GPU_HANDLE_LIST_NEXT_ID_VALUE ||
	   handle == GPU_MEMORY_HANDLE_NIL ||
	   handle.id < 0 {
		return false
	}
	return true
}

// Checks if resource handle ID is not special or invalid value. Prefer using `is_handle`.
_is_resource_handle :: proc(handle: GPU_Resource_Handle) -> (ok: bool) {
	_is_handle_in_range(handle) or_return
	if handle.id == GPU_HANDLE_LIST_END_ID_VALUE ||
	   handle.id == GPU_HANDLE_LIST_NEXT_ID_VALUE ||
	   handle == GPU_RESOURCE_HANDLE_NIL ||
	   handle.id < 0 {
		return false
	}
	return true
}

// Validates passed user handle to internal one, internal being the source of 'truth'.
_validate_handles :: proc {
	_validate_memory_handles,
	_validate_resources_handles,
}

// Validates passed user memory handle to internal one, internal being the source of 'truth'. Prefer using `validate_handle`.
_validate_memory_handles :: proc(user, internal: GPU_Memory_Handle) -> (ok: bool) {
	_is_handle(user) or_return

	return user.id == internal.id
}

// Validates passed user resource handle to internal one, internal being the source of 'truth'. Prefer using `validate_handle`.
_validate_resources_handles :: proc(user, internal: GPU_Resource_Handle) -> (ok: bool) {
	_is_handle(user) or_return

	return user.id == internal.id
}

_is_handle_in_range :: proc {
	_is_memory_handle_in_range,
	_is_resource_handle_in_range,
}

_is_memory_handle_in_range :: proc(handle: GPU_Memory_Handle) -> (is: bool) {
	r := get_global_state().renderer
	when CONFIG_BUILD_VARIANT != Build_Variants[.Editor] {
		// this shouldn't happen
		if handle.index > GPU_MEMORY_HANDLE_INDEX_MAX {
			log.warnf(
				"Detected memory handle outside valid range; handle '%v' - max allowed index: %v",
				handle,
				GPU_RESOURCE_HANDLE_INDEX_MAX,
			)
			return false
		}
	}
	if handle.index < 0 || int(handle.index) >= len(r.memory.blocks) {
		return false
	}

	return true
}

_is_resource_handle_in_range :: proc(handle: GPU_Resource_Handle) -> (is: bool) {
	r := get_global_state().renderer
	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		// this shouldn't happen
		if handle.index > GPU_RESOURCE_HANDLE_INDEX_MAX {
			log.warnf(
				"Detected resource handle outside valid range; handle '%v' - max allowed index: %v",
				handle,
				GPU_RESOURCE_HANDLE_INDEX_MAX,
			)
			return false
		}
	}

	if handle.index < 0 || int(handle.index) >= len(r.resources.datas) {
		return false
	}

	return true
}

gpu_get_data :: proc {
	gpu_get_resource_data,
	gpu_get_memory_block_data,
}

gpu_get_memory_block_data :: proc(handle: GPU_Memory_Handle) -> ^GPU_Memory_Block {
	g := get_global_state()
	return &g.renderer.memory.blocks[handle.index]
}

gpu_get_resource_data :: proc(handle: GPU_Resource_Handle) -> ^GPU_Resource_Data {
	g := get_global_state()
	return &g.renderer.resources.datas[handle.index]
}

gpu_get_parent_data :: proc(handle: GPU_Resource_Handle) -> ^GPU_Memory_Block {
	r := get_global_state().renderer
	return &r.memory.blocks[r.resources.datas[handle.index].parent_idx]
}

gpu_flush_resource :: proc(handle: GPU_Resource_Handle) -> (success: bool) {
	range := _gpu_get_range_from_resource(handle)
	result := vk.FlushMappedMemoryRanges(get_global_state().renderer.core.device.handle, 1, &range)
	if result != .SUCCESS {
		when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
			log.errorf(
				"Flushing memory range '%v' from handle '%v' failure: %v",
				range,
				handle,
				result,
			)
		} else do log.errorf("Flushin memory range failure: %v", result)

		return false
	}

	return true
}

//gpu_flush_buffers :: proc(handles: []GPU_Resource_Handles) -> (success: bool) {}

_gpu_get_range_from_resource :: proc(
	handle: GPU_Resource_Handle,
) -> (
	range: vk.MappedMemoryRange,
) {
	mem := gpu_get_parent_data(handle)
	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		if mem.mapped_ptr == nil {
			log.errorf(
				"Called '%v' but memory from passed handle does not have mapped pointer",
				#procedure,
			)
			return
		}
		if .HOST_VISIBLE not_in mem.flags {
			log.errorf("Called '%v' but flag HOST_VISIBLE is absent in memory", #procedure)
			return
		}
		if .HOST_COHERENT in mem.flags {
			log.errorf("Called '%v' but flag HOST_COHERENT is present in memory", #procedure)
			return
		}
	}
	data := gpu_get_data(handle)
	range.sType = .MAPPED_MEMORY_RANGE
	range.memory = mem.memory
	range.offset = data.offset
	range.size = data.backing_size

	return range
}

_gpu_create_image :: proc(
	device: vk.Device,
	info: ^vk.ImageCreateInfo,
	callbacks: ^vk.AllocationCallbacks,
) -> (
	image: vk.Image,
	ok: bool,
) {
	result := vk.CreateImage(device, info, callbacks, &image)

	if result != .SUCCESS {
		when CONFIG_VERBOSE_LOG do log.errorf("Image creation failure: %v", result)
	}

	return image, result == .SUCCESS
}

_gpu_get_image_extent_from_swapchain :: proc() -> vk.Extent3D {
	ext := get_global_state().renderer.core.swapchain.image_extent
	return {ext.width, ext.height, 1}
}

_gpu_get_image_requirements :: proc(img: vk.Image) -> (req: vk.MemoryRequirements) {
	g := get_global_state()
	vk.GetImageMemoryRequirements(g.renderer.core.device.handle, img, &req)

	return
}

_gpu_bind_image_memory :: proc(
	device: vk.Device,
	img: vk.Image,
	mem: vk.DeviceMemory,
	offset: vk.DeviceSize,
) -> (
	success: bool,
) {
	result := vk.BindImageMemory(device, img, mem, offset)
	if result != .SUCCESS {
		when CONFIG_VERBOSE_LOG do log.errorf("Image memory binding failure: %v", result)
	}
	return result == .SUCCESS
}

_gpu_merge_free_regions :: proc(block: ^GPU_Memory_Block) {
	if len(block.free_regions) < 2 do return

	for i := 0; i < len(block.free_regions) - 1; {
		current := &block.free_regions[i]
		next := &block.free_regions[i + 1]

		if current.offset + current.size == next.offset {
			current.size += next.size
			ordered_remove(&block.free_regions, i + 1)
		} else {
			i += 1
		}
	}
}
