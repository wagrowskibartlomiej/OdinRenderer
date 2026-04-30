package engine

import "base:runtime"

import "core:log"
import "core:mem"

import vk "vendor:vulkan"

GPU_MAX_ALLOWED_ALLOCATION_SIZE :: mem.Gigabyte * 1
GPU_DEFAULT_ALLOCATED_MEMORY_SIZE :: mem.Megabyte * 128 // Blocks can mix different images and buffer, but not mix them together

GPU_ALLOCATED_MEMORY_INITIAL_CAP :: 4
GPU_TAKEN_REGIONS_INITAL_CAP :: 16
GPU_FREE_REGIONS_INITIAL_CAP :: 16

VRAM_FLAGS :: vk.MemoryPropertyFlags{.DEVICE_LOCAL}
STAGING_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE}
STAGING_SYNCED_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
DIRECT_TRANSFER_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .DEVICE_LOCAL}
DIRECT_TRANSFER_SYNCED_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .DEVICE_LOCAL, .HOST_COHERENT}

GPU_Memory_Allocator_Proc :: #type proc(mode: GPU_Allocator_Mode, category: GPU_Memory_Resource_Category, flags: vk.MemoryPropertyFlags, map_block: bool, size: vk.DeviceSize, allocator: runtime.Allocator, memory: GPU_Memory, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Memory, GPU_Allocator_Error)

GPU_Resource_Allocator_Proc :: #type proc(mode: GPU_Allocator_Mode,  type: GPU_Resource_Type, info: GPU_Resource_Create_Info, size, alignment: vk.DeviceSize, flags: vk.MemoryPropertyFlags, mapable: bool, allocator: runtime.Allocator, handle: GPU_Resource_Handle, res: GPU_Resource_Data, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Resource_Data, GPU_Resource_Handle, GPU_Allocator_Error)


GPU_Memory_State :: struct {
    memory_allocator: GPU_Memory_Allocator,
    allocated_blocks: [dynamic]GPU_Memory,
    internal_allocator: runtime.Allocator, // For Odin side allocation
    callbacks: ^vk.AllocationCallbacks,
}

GPU_Memory_Allocator :: struct {
    procedure: GPU_Memory_Allocator_Proc,
    data: rawptr,
}

GPU_Resource_Allocator :: struct {
    procedure: GPU_Resource_Allocator_Proc,
    data: rawptr,
}

GPU_Region :: struct {
    offset, size: vk.DeviceSize,
}

GPU_Region_Resource :: struct {
    using _: GPU_Region,
    handle: GPU_Resource_Handle, // I think we don't need id since we're not gonna be called after handle destruction
}

//NOTE: For now GPU_Memory can only hold the same type of resource, so alignment calcualtion is simple, but it's subject to change
GPU_Memory :: struct {
    category: GPU_Memory_Resource_Category, // We allow only one type of resource per allocation to avoid alignment edge cases like using vk.BufferImageGranularity
    flags: vk.MemoryPropertyFlags,
    flags_idx: int,
    size,
    allocated: vk.DeviceSize,
    linear_write_offset: vk.DeviceSize, // For fast path allocation
    handle: vk.DeviceMemory,
    mapped_ptr: rawptr, // If mapped (WARN: can only be mapped when allocating, mapping after allocation is forbidden)
    taken_regions: [dynamic]GPU_Region_Resource, // Allocations need to be sorted by offset if linear writes are used
    free_regions: [dynamic]GPU_Region, // For fragmentation management, this is a simple approach and can be optimized later if needed
}

GPU_Allocator_Mode :: enum {
    Allocate,
    Free,
    Create,
    Destroy,
    Append,
    Remove,
    Free_All,
}

GPU_Memory_Error :: enum {
    None = 0,
    Unknown,
    Out_Of_Memory,
    Invalid_Size,
    Memory_Not_Found,
    Invalid_Flags,
}

GPU_Allocator_Error :: union #shared_nil {
    GPU_Memory_Error,
    GPU_Resource_Error
}


gpu_initalize_memory_state :: proc(mem_state: ^GPU_Memory_State, mem_alloc := GPU_Memory_Allocator{gpu_default_memory_allocator, nil}, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	mem_state.allocated_blocks = make([dynamic]GPU_Memory, allocator)
	mem_state.memory_allocator = mem_alloc
	mem_state.internal_allocator = allocator
	mem_state.callbacks = callbacks
}

gpu_cleanup_memory_state :: proc(mem_state: GPU_Memory_State) {
	for block in mem_state.allocated_blocks {
		gpu_free()
	}
}

//gpu_default_ring_allocator
//gpu_default_linear_allocator


gpu_alloc :: proc(category: GPU_Memory_Resource_Category, flags: vk.MemoryPropertyFlags, map_block: bool, size: vk.DeviceSize) -> (err: GPU_Allocator_Error) {
	assert(context.user_ptr != nil)
	g := (^Engine_Global_State)(context.user_ptr)
	memory := g.renderer.memory

	block, err := memory.memory_allocator.procedure(.Allocate, category, flags, map_block, size, memory.internal_allocator, {}, memory.callbacks, memory.memory_allocator.data)
}

gpu_free :: proc() {

}

// Make it use handles like the other ones, with handle tracking and leaving fragmentation to append it in index that was zeroed + make vaildation_id also use them
// make sure that indexes won't change until cleanup, I mean if someone frees it okay, but indexes must be valid unitl the ones that do not change them
#panic("TUTAJ")
gpu_update_memory_state_addition :: proc() {}
gpu_update_memory_state_deletion :: proc() {}

gpu_default_memory_allocator : GPU_Memory_Allocator_Proc : proc(mode: GPU_Allocator_Mode, category: GPU_Memory_Resource_Category, flags: vk.MemoryPropertyFlags, map_block: bool, size: vk.DeviceSize, allocator: runtime.Allocator, memory: GPU_Memory, callback: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Memory, GPU_Allocator_Error) {
	assert(context.user_ptr != nil)
	g := (^Engine_Global_State)(context.user_ptr)
	#partial switch mode {
	case .Allocate: return gpu_default_memory_allocator_alloc(g.renderer.core.device.handle, category, size, g.renderer.core.physical_devices.active.properties, flags, map_block, allocator, callbacks)
	case .Free:
		gpu_default_memory_allocator_free(g.renderer.core.device.handle, memory, callbacks)
		return {}, nil
	case: return {}, .Not_Implemented
	}
	return
}

gpu_default_memory_allocator_alloc :: proc(device: vk.Device, category: GPU_Memory_Resource_Category, size: vk.DeviceSize, phys_prop: vk.PhysicalDeviceMemoryProperties, flags: vk.MemoryPropertyFlags, map_block: bool, allocator: runtime.Allocator, callbacks: ^vk.AllocationCallbacks) -> (memory: GPU_Memory, err: GPU_Allocator_Error) {
    if size == 0 || size > GPU_MAX_ALLOWED_ALLOCATION_SIZE {
        return {}, .Invalid_Size
    }

    if map_block && .HOST_VISIBLE not_in flags {
    	return {}, .Invalid_Flags
    }

    type_idx, _ := gpu_find_memory_type(phys_prop, flags)
    if type_idx == -1 {
        return {}, .Memory_Not_Found
    }

    full_flags := phys_prop.memoryTypes[type_idx].propertyFlags

    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        memoryTypeIndex = u32(type_idx),
        allocationSize = size,
    }

    result := vk.AllocateMemory(device, &alloc_info, callbacks, &memory.handle)
    switch result {
        case .SUCCESS: when CONFIG_VERBOSE_LOG do log.debugf("Allocated %v bytes of GPU memory with flags %v", size, full_flags)
        case .ERROR_OUT_OF_HOST_MEMORY, .ERROR_OUT_OF_DEVICE_MEMORY: return {}, .Out_Of_Memory
        case:
            log.errorf("GPU Memory allocation failure: %v (wanted %v bytes | requested flags %v -> found: %v)", result, size, flags, full_flags)
            return {}, .Unknown
    }

    memory.size = size
    memory.taken_regions = make([dynamic]GPU_Region_Resource, 0, GPU_TAKEN_REGIONS_INITAL_CAP, allocator)
    memory.free_regions = make([dynamic]GPU_Region, 0, GPU_FREE_REGIONS_INITIAL_CAP, allocator)
    memory.flags = full_flags
    memory.flags_idx = type_idx
    memory.category = category

    if map_block {
    	result := vk.MapMemory(device, mem, 0, vk.WHOLE_SIZE, nil, &memory.mapped_ptr)
     	if result != .SUCCESS {
      		log.errorf("Memory mapping failed: %v", result)
        	memory.mapped_ptr = nil // just to be sure
        }
    }

    return memory, nil
}

gpu_default_memory_allocator_free :: proc(device: vk.Device, memory: GPU_Memory, callbacks: ^vk.AllocationCallbacks) {
	delete(memory.taken_regions)
	delete(memory.free_regions)
	if memory.mapped_ptr != nil {
		vk.UnmapMemory(device, memory.handle)
	}
	vk.FreeMemory(device, memory.handle, callbacks)
}

gpu_find_memory_type :: proc(props: vk.PhysicalDeviceMemoryProperties, flags: vk.MemoryPropertyFlags) -> (type_idx := -1, heap_idx := -1) {
    for i in 0 ..< props.memoryTypeCount {
        if props.memoryTypes[i].propertyFlags & flags == flags {
            return int(i), int(props.memoryTypes[i].heapIndex)
        }
    }

    return
}

// Default GPU static resource allocator does not support custom types yet.
gpu_default_static_resource_allocator : GPU_Resource_Allocator_Proc : proc(mode: GPU_Allocator_Mode, type: GPU_Resource_Type, info: GPU_Resource_Create_Info, size, alignment: vk.DeviceSize, flags: vk.MemoryPropertyFlags, mapable: bool, allocator: runtime.Allocator, handle: GPU_Resource_Handle, res: GPU_Resource_Data, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Resource_Data, GPU_Resource_Handle, GPU_Allocator_Error) {
    assert(context.user_ptr != nil)
    g := (^Engine_Global_State)(context.user_ptr)
    rend := g.renderer
    switch mode {
        case .Free_All, .Append, .Allocate, .Free: return {}, {}, .Mode_Unsupported
        case .Create: return gpu_default_static_resource_allocator_create(rend.core.device.handle, type, size, rend.memory.allocated_blocks[:], flags, mapable, rend.core.physical_devices.active.properties.limits, callbacks)
        case .Destroy: return {}, nil, gpu_default_static_resource_allocator_destroy(handle, res, rend.core.device.handle, callbacks)
    }
}

// Procedure `info` parameter is ignored for now since default allocators do not support custom types yet.
// FIX: Now it's searching until first success/failure, and then return which is not ideal, we need to search until the last memory block.
gpu_default_static_resource_allocator_create :: proc(device: vk.Device, type: GPU_Resource_Type, size: vk.DeviceSize, memory: []GPU_Memory, memory_flags: vk.MemoryPropertyFlags, mapable: bool, limits: vk.PhysicalDeviceLimits, callbacks: ^vk.AllocationCallbacks) -> (resource: GPU_Resource_Data, handle: GPU_Resource_Handle, err: GPU_Allocator_Error) {
	usage: GPU_Resource_Usage = .Static
	switch type {
	case .Vertex_Buffer:
		info := GPU_Resource_Create_Info_Presets[type]
		info.buffer.size = size

		buffer, ok := create_buffer(device, info, callbacks)
		if !ok {
			return nil, .Creation_Failure
		}

		defer if err != nil {
			destroy_buffer(device, buffer, callbacks)
		}

		req := get_buffer_requirements(device, buffer)

		mem_index, adjust := gpu_find_compatibile_memory_index(memory, .Buffer, req, memory_flags, mapable)
		if mem_index == -1 {
			return nil, .Memory_Not_Found
		}

		final_req := req
		if adjust {
			final_req.alignment, final_req.size = readjust_requirements_for_mapping(final_req, limits)
		}

		offset, free_region_index := gpu_find_offset_for_resource(memory[mem_index], final_req.alignment, final_req.size, search_free = true)

		if offset == -1  {
			return nil, .Memory_Not_Found
		}

		success := gpu_bind_buffer_memory(device, buffer, memory[index].handle, offset, callbacks)
		if !success {
			return nil, .Creation_Failure
		}

		res: GPU_Resource_Data
		res.type = .Vertex_Buffer
		res.usage = usage
		res.backing_size = final_req.size
		res.offset = offset
		res.data_size = size
		res.parent_idx = mem_index

		region := GPU_Region_Resource{
			handle = buffer,
			offset = res.offset,
			size = res.backing_size
		}

		res.taken_region_idx = gpu_update_memory_addition(reg, free_region_index, &memory[mem_index])
		return res, buffer, nil
	case .Custom_Buffer, .Custom_Image: return {}, nil, .Not_Implemented
	}
}

gpu_default_static_resource_allocator_destroy :: proc(handle: GPU_Resource_Handle, res: GPU_Resource_Data, device: vk.Device, callbacks: ^vk.AllocationCallbacks) -> GPU_Allocator_Error {
	switch type {
	case .Vertex_Buffer:
		gpu_update_memory_deletion(res.taken_region_idx, {handle = handle, offset = res.offset, res.backing_size})
		destroy_buffer(device, handle.(vk.Buffer), callbacks)
		return .None
	case .Custom_Buffer, .Custom_Image: return .Not_Implemented
	}
}


gpu_bind_buffer_memory :: proc(device: vk.Device, buffer: vk.Buffer, memory: vk.DeviceMemory, offset: vk.DeviceSize, callbacks: ^vk.AllocationCallbacks) -> (success: bool) {
    result := vk.BindBufferMemory(device, buffer, memory, offset)
    if result != .SUCCESS {
        when CONFIG_VERBOSE_LOG do log.errorf("Buffer memory binding failure: %v", result)
    }
    return result == .SUCCESS
}


// Passing value to `start_from` will start searching from given index onwards. It's mainly used if previous searches failed and we need to search again.
// If `adjust_for_mapped_range` is set to true, requirements need to be adjusted to be compliant with physical device limit `nonCoherentAtomSize` if mapping is desired.
gpu_find_compatibile_memory_index :: proc(memory_blocks: []GPU_Memory, category: GPU_Memory_Resource_Category, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, mapable: bool, start_from : u64 = 0) -> (index: int, adjust_for_mapped_range: bool) {
    for i in start_from ..< len(memory_blocks) {
        if memory_blocks[i].category != category || !gpu_check_flags_support(memory_blocks[i].flags_idx, requirements.memoryTypeBits) || flags & memory_blocks[i].flags != flags do continue

        if mapable && .HOST_COHERENT not_in memory_blocks[i].flags {
        	return i, true
        }

        return i, false
    }

    return -1, false
}

gpu_get_resource_category_from_type :: proc(type: GPU_Resource_Type) -> GPU_Memory_Resource_Category {
    switch type {
        case .Custom_Buffer, .Vertex_Buffer: return .Buffer
        case .Custom_Image: return .Image
    }
}

gpu_check_flags_support :: proc(index: int, memory_bits: u32) -> (supported: bool) {
    if index < 0 || index >= 32 do return false

    mask : u32 = 1 << index
    if mask & memory_bits == mask do return true
    return false
}
