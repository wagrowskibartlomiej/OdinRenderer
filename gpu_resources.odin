package engine

import "core:mem"
import "core:sort"

import "base:runtime"

import vk "vendor:vulkan"

GPU_Resources_State :: struct {
	//resource_pool_allocator,
	//resource_linear_allocator,
	resource_static_allocator: GPU_Resource_Allocator,
	handles: [dynamic]GPU_Internal_Handle,
	resources_map: map[GPU_Resource_Handle]GPU_Resource_Data,
	internal_allocator: runtime.Allocator, // for Odin side allocations
	callbacks: ^vk.AllocationCallbacks,
	_validation_id_counter: i64,
	_handles_append: bool, // Used to prevent fragmentation of handles array with avoiding handles index changing
}

GPU_User_Handle :: struct {
	index: int,
	validation_id: i64, // incremental id generation for usage validation (index may be valid range, but the handle undearneath is different)
}
GPU_USER_HANDLE_NIL :: GPU_User_Handle{-1, -1}

GPU_Internal_Handle :: struct {
	handle: GPU_Resource_Handle,
	validation_id: i64,
}
GPU_INTERNAL_HANDLE_NIL :: GPU_Internal_Handle{nil, -1}

GPU_Resource_Data :: struct {
    type: GPU_Resource_Type,
    usage: GPU_Resource_Usage,
    data_size, backing_size, offset: vk.DeviceSize,
    parent_idx: int, // index of allocated block that is containing the resource
    taken_region_idx: int,
    pool_elems: [dynamic]GPU_Region
}

GPU_Resource_Handle :: union {
    vk.Buffer,
    vk.Image,
}

GPU_Resource_Create_Info :: struct #raw_union {
    buffer: vk.BufferCreateInfo,
    image: vk.ImageCreateInfo,
}

GPU_Memory_Resource_Category:: enum {
    Buffer,
    Image,
}

GPU_Resource_Usage :: enum {
    Static,
    Pool
}

GPU_Resource_Type :: enum {
    Custom_Buffer,
    Custom_Image,
    Vertex_Buffer,
    //Texture_2D,
}

GPU_Resource_Error :: enum {
    None = 0,
    Mode_Unsupported,
    Memory_Unsupported,
    Not_Implemented,
    Creation_Failure,
}

GPU_Resource_Create_Info_Presets := #partial [GPU_Resource_Type]GPU_Resource_Create_Info{
    .Vertex_Buffer = {
        buffer = vk.BufferCreateInfo{
            sType = .BUFFER_CREATE_INFO,
            sharingMode = .EXCLUSIVE,
            usage = {.TRANSFER_SRC, .TRANSFER_DST, .VERTEX_BUFFER},
        },
    },
}

gpu_initalize_resources :: proc(res_state: ^GPU_Resources_State, static_res_alloc: GPU_Resource_Allocator = {gpu_default_static_resource_allocator, nil}, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	res_state.handles = make([dynamic]GPU_Internal_Handle)
	res_state.resources_map = make(map[GPU_Resource_Handle]GPU_Resource_Data)
	res_state.resource_static_allocator = static_res_alloc
	res_state._handles_append = true
	res_state.internal_allocator = allocator
	res_state.callbacks = callbacks
}

gpu_cleanup_resources :: proc(res_state: GPU_Resources_State) {
	for h, _ in res_state.resources_map {
		gpu_destroy(h, res_state)
	}
}

gpu_create :: proc(type: GPU_Resource_Type, usage: GPU_Resource_Usage, size: vk.DeviceSize, flags: vk.MemoryPropertyFlags, mapable: bool, alignment: vk.DeviceSize = 0, info: GPU_Resource_Create_Info = {}) -> (handle: GPU_User_Handle, err: GPU_Allocator_Error)  {
	assert(context.user_ptr != nil)
	state := (^Engine_Global_State)(context.user_ptr)

	static_allocator := state.renderer.resources.resource_static_allocator
	switch usage {
	case .Static:
		res, handle := static_allocator.procedure(.Create, type, info, size, alignment, flags, mapable, resources_state.internal_allocator, resources_state.callbacks, static_allocator.data) or_return
		h := gpu_update_resources_addition(res, handle, resources_state)
		return h, nil
	case .Pool: return GPU_USER_HANDLE_NIL, .Not_Implemented
	}

}

gpu_destroy :: proc{
	gpu_destroy_by_res_handle,
	gpu_destroy_by_user_handle,
}

gpu_destroy_by_user_handle :: proc(handle: GPU_User_Handle) -> GPU_Allocator_Error {
	if handle == GPU_USER_HANDLE_NIL do return

	assert(context.user_ptr != nil)
	g := (^Engine_Global_State)(context.user_ptr)
	state := g.renderer

	h := get_resource_handle_from_user_handle(handle, state.resources.handles[:])
	if h == nil {
		return .Unknown
	}

	return gpu_destroy_by_res_handle(h, &state.resources)
}

gpu_destroy_by_res_handle :: proc(h: GPU_Resource_Handle, resources: ^GPU_Resources_State) -> GPU_Allocator_Error {
	assert(resources != nil)

	res, exists := resources.resources_map[h]
	if !exists {
		return .Unknown
	}

	static_allocator := resources.resource_static_allocator

	switch res.usage {
	case .Static:
		// we do handle copy earlier so ignore the one returned
		_, ok := gpu_update_resources_deletion(h, &resources)
		// Log that error happened, but perform destroy call still, It probably will work
		if !ok {
			log.error("GPU Resource deletion failure")
		}
		static_allocator.procedure(.Destroy, res.type, {}, res.backing_size, 0, nil, false, resources.internal_allocator, handle, res, resources.callbacks, static_allocator.data)
	case .Pool: return .Not_Implemented
	}

	return nil
}

gpu_copy :: proc{
	gpu_copy_buffers,
	gpu_copy_to_mapable_buffer,
}

// Procedure expects that caller will manage submition and call to `vk.BeginCommandBuffer`.
gpu_copy_buffers :: proc(cmd: vk.CommandBuffer, dst, src: GPU_User_Handle, regions: []vk.BufferCopy) -> (success: bool) {
	assert(context.user_ptr != nil)
	g := (^Engine_Global_State)(context.user_ptr)

	dst_buffer := get_resource_handle_from_user_handle(dst, g.renderer.resources.handles[:])
	src_buffer := get_resource_handle_from_user_handle(src, g.renderer.resources.handles[:])

	dst := dst_buffer.(vk.Buffer) or_return
	src := src_buffer.(vk.Buffer) or_return

	vk.CmdCopyBuffer(cmd, src, dst, u32(len(regions)), raw_data(regions))
	return true
}

gpu_copy_to_mapable_buffer :: proc(dst: GPU_User_Handle, data: rawptr, size: int) -> (success, flush_required: bool) {
	assert(context.user_ptr != nil && size > 0)
	g := (^Engine_Global_State)(context.user_ptr)

	handle := get_resource_handle_from_user_handle(dst, g.renderer.resources.handles[:])
	res := g.renderer.resources.resources_map[handle] or_return

	assert(res.parent_idx < len(g.renderer.memory.allocated_blocks))
	block := g.renderer.memory.allocated_blocks[res.parent_idx]

	if block.mapped_ptr == nil || res.data_size < vk.DeviceSize(size) {
		return
	}

	target := cast(rawptr) (uintptr(block.mapped_ptr) + res.offset)

	mem.copy(target, data, size) // Maybe using mem.copy_non_overlapping would be better? Most of the time It shouldn't overlap
	if .HOST_COHERENT in block.flags {
		return true, false
	}

	return true, true
}

gpu_create_buffer :: proc(device: vk.Device, info: vk.BufferCreateInfo, callbacks: ^vk.AllocationCallbacks) -> (buff: vk.Buffer, success: bool) {
    buff: vk.Buffer
    result := vk.CreateBuffer(device, &info, callbacks, &buff)
    if result != .SUCCESS {
        when CONFIG_VERBOSE_LOG do log.errorf("Buffer creation failure: %v", result)
    }
    return buff, result == .SUCCESS
}

gpu_destroy_buffer :: proc(device: vk.Device, buffer: vk.Buffer, callbacks: ^vk.AllocationCallbacks) {
    vk.DestroyBuffer(device, buffer, callbacks)
}

gpu_get_buffer_requirements :: proc(device: vk.Device, buffer: vk.Buffer) -> vk.MemoryRequirements {
    req: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(device, buffer, &req)

    return req
}

gpu_get_storage_buffer_requirements :: proc(device: vk.Device, buffer: vk.Buffer, limits: vk.PhysicalDeviceLimits) -> vk.MemoryRequirements {
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
gpu_find_offset_for_resource :: proc(memory: GPU_Memory, alignment, size: vk.DeviceSize, search_free: bool) -> (offset : i64 = -1, free_region_index := -1) {
    off := gpu_find_offset_alloc_linear(memory, alignment, size)
    if off != -1 || !search_free do return off, -1

    return gpu_find_offset_free_regions(memory.free_regions[:], alignment, size)
}

gpu_find_offset_alloc_linear :: proc(memory: GPU_Memory, alignment, size: vk.DeviceSize) -> (offset: i64) {
    if memory.allocated + size > memory.size || memory.linear_write_offset + size > memory.size {
        return -1
    }

    off := find_aligned_offset_align_up(memory.linear_write_offset, alignment)

    if off + size > memory.size {
        return -1
    }

    return off
}

gpu_find_offset_free_regions :: proc(regions: []GPU_Region, alignment, size: vk.DeviceSize) -> (offset: i64, region_index: int) {
    for r, i in regions {
        if r.size < size do continue

        off := find_aligned_offset_align_up(r.offset, alignment)
        if off == -1 || off + size > r.size + r.offset do continue

        return off, i
    }

    return -1, -1
}

gpu_readjust_requirements_for_mapping :: proc(requirements: vk.MemoryRequirements, limits: vk.PhysicalDeviceLimits) -> (alignment, size: vk.DeviceSize) {
	final_align := max(requirements.alignment, limits.nonCoherentAtomSize)
	final_size := align_up_pow_2(requirements.size, final_align)

	return final_align, final_size
}

gpu_update_memory_addition :: proc(new_reg: GPU_Region_Resource, free_reg_index: int,  block: ^GPU_Memory) -> (taken_region_idx: int) {
	assert(block != nil)
	// If we've used free region index, we need to check if we used it all,
	// if so remove it ordered to not sort anymore
	// then add region to taken and sort the taken ones
	if free_reg_index >= 0 {
		free_reg := block.free_regions[free_reg_index]

		gpu_update_free_region_based_on_new_addition(block, free_reg, new_reg)

		append(&block.taken_regions, new_reg)
		sort.quick_sort_proc(block.taken_regions[:], gpu_region_sort_by_offset)

		// Find index after sorting
		for taken, i in block.taken_regions {
			if taken == new_reg {
				taken_region_idx = i
				break
			}
		}
	} else {
		// In this branch we've used linear write so we need to update write offset
		// and just append taken region, they we'll be sorted naturally
		block.linear_write_offset += new_reg.size
		append(&block.taken_regions, new_reg)
		taken_idx = len(block.taken_regions) - 1
	}

	block.allocated += new_reg.size

	return taken_region_idx
}

//FIX: Make procedure decrement linear_write_offset until valid block is found, currently it stops at first one.
gpu_update_memory_deletion :: proc(reg_idx: int, reg: GPU_Region_Resource, block: ^GPU_Memory) {
	assert(block != nil)
	// If the region is last and linear write offset is "in front" of the block,
	// (if I'm correct there shouldn't be a situation when a linear write offset is not at the end, and at the same time any resource is located before it)
	// we can just pop it from taken and move back linear write offset
	if reg.offset < block.linear_write_offset && block.taken_regions[len(block.taken_regions) - 1] == reg {
		pop(&block.taken_regions)
		block.linear_write_offset -= reg.size
	} else {
		ordered_remove(&block.taken_regions, reg_idx) // Ordered remove so we don't need to sort them
		append(&block.free_regions, {reg.offset, reg.size})
		sort.quick_sort_proc(block.free_regions[:], gpu_region_sort_by_offset) // We need to sort free regions tho
	}

	block.allocated -= reg.size
}

gpu_update_resources_addition :: proc(resource: GPU_Resource_Data, handle: GPU_Resource_Handle, res_state: ^GPU_Resources_State) -> (h: GPU_User_Handle) {
	assert(res_state != nil)
	// get the handle ID and update counter
	internal := GPU_Internal_Handle{handle, res_state._validation_id_counter}
	res_state._validation_id_counter += 1

	index: int

	// we search for any free space in handles if the flag is set to not append
	found: bool
	if !res_state._handles_append {
		for h, i in res_state.handles {
			if h == GPU_INTERNAL_HANDLE_NIL {
				found = true
				index = i
			}
		}
	}

	// if we do not found any we set it as true
	// (if the flag was true this will just set it to true again anyway)
	if !found {
		res_state._handles_append = true
	} else {
		res_state.handles[index] = internal
		// we do not set append flag to true here,
		// because we don't know if there are any empty indexes ledt
	}

	if res_state._handles_append {
		append(&res_state.handles, internal)
		index = len(res_state.handles) - 1
	}

	// Now we need data for user
	user_handle := GPU_User_Handle{index, internal.validation_id}

	// This shouldn't happen, so I'll check only in editor builds
	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		_, exists := res_state.resources_map[handle]
		if exists {
			log.warnf("GPU Resource with handle '%v' already exists in resources map, overwriting", reg.handle)
		}
	}

	res_state.resources_map[reg.handle] = resource

	return user_handle, true
}

// Returns `GPU_Resource_Handle` for resource destroying, this procedure should be called before allocator destroy call.
// WARN: Procedure sets handle at corespodning array index as `GPU_INTERNAL_HANDLE_NIL`, a local copy of Vulkan's handle will be returned for allocator's later usage.
gpu_update_resources_deletion :: proc(h: GPU_User_Handle, res_state: ^GPU_Resources_State) -> (GPU_Resource_Handle, bool) {
	assert(res_state != nil && h.index < len(res_state.handles))
	if res_state.handles[h.index].validation_id != h.validation_id {
		log.warnf("ID Validation failed, given handle ID '%v' does not match source handle ID '%v', aborting", h.validation_id, res_state.handles[h.index].validation_id)
		return
	}

	res_handle := res_state.handles[h.index].handle

	// Mark as nil and available to use
	res_state.handles[h.index] = GPU_INTERNAL_HANDLE_NIL
	res_state._handles_append = false

	res, exists := res_state.resources_map[res_handle]
	if !exists {
		log.warnf("Resource with handle '%v' does not exist in resources map", res_handle)
		return res_handle, true
	}

	// If somehow it happens, but it really shouldn't
	// REMEBER TO NOT DELETE FOR POOLS, SINCE WE MOST LIKELY NEED THIS WHEN ALLOCATOR PERFORMS FREE ALL!!
	if res.usage != .Pool {
		if res.pool_elems != nil do log.warnf("The resource usage is '%v', yet pool_elems is not nil", res.usage)
		delete(res.pool_elems)
	}

	delete_key(&res_state.resources_map, res_handle)
	return res_handle, true
}


gpu_region_sort_by_offset :: proc(first, second: GPU_Region) -> int {
	if first.offset < second.offset do return -1
	else if first.offset > second.offset do return 1
	else do return 0
}

gpu_update_free_region_based_on_new_addition :: proc(block: ^GPU_Memory, free_region, new_region: GPU_Region, free_region_idx: int) {
	assert(block != nil)

	if free_region_idx < 0 {
		return
	}

	// Best path
	if new_region.offset == free_region.offset {
		// We just need to remove free region cause we took all of it
		if new_region.size == free_region.size {
			ordered_remove(&block.free_regions, free_region_idx)
			return
		}

		// We need to shrink the old one
		new_size := free_region.size - new_region.size
		new_offset := free_region.offset + new_region.size

		block.free_regions[free_region_idx] = {new_offset, new_size}
		return
 	}

  	// when they end at the same offset, we just need to shrink old free region size
  	if new_region.offset + new_region.size == free_region.offset + free_region.size {
   		block.free_regions[free_region_idx].size = free_region.size - new_region.size
     		return
   	}

  	// Worst case, we need to split into two free regions (inject one, and shrink the old one)
   	// REMEMBER TO MAKE THEM ORDERED!!
   	old_reg := GPU_Region{
    		offset = free_region.offset,
      		size = new_region.offset - free_region.offset
    	}

    	after_split_reg := GPU_Region{
     		offset = new_region.offset + new_region.size,
       		size = (free_region.offset + free_region.size) - (new_region.offset + new_region.size)
     	}

      	block.free_regions[free_region_idx] = old_reg
  	inject_at(&block.free_regions, free_region_idx + 1, after_split_reg)
   	return
}

get_resource_handle_from_user_handle :: proc(handle: GPU_User_Handle, handles: []GPU_Internal_Handle) -> GPU_Resource_Handle {
	if handle == GPU_USER_HANDLE_NIL do return nil

	ensure(len(handles) > handle.index)
	h := handles[handle.index]

	if h.validation_id != handle.validation_id {
		return nil
	}

	return h.handle
}
