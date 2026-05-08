package engine

import "base:runtime"
import "base:intrinsics"

import "core:log"
import "core:mem"

import vk "vendor:vulkan"

// WARN: When changing keep in mind uintptr size and 32bit systems when block maping!
// TODO: Maybe check this when calling gpu_alloc?
GPU_MAX_ALLOWED_ALLOCATION_SIZE :: mem.Gigabyte * 1
GPU_DEFAULT_ALLOCATION_SIZE :: mem.Megabyte * 128 // Blocks can mix different images and buffer, but not mix them together

GPU_MEMORY_HANDLE_BACKING_TYPE :: distinct u32
// Should always be set as a power of two, but 4096 is guaranteed by Vulkan and really should be more than enough. Soruces:
// [[https://docs.vulkan.org/spec/latest/chapters/limits.html#limits-maxMemoryAllocationCount]];
// [[https://docs.vulkan.org/spec/latest/chapters/limits.html#limits-minmax]];
GPU_MAX_MEMORY_ALLOCATIONS_COUNT :: 4096
GPU_MEMORY_HANDLE_INDEX_BITS :: intrinsics.constant_log2(GPU_MAX_MEMORY_ALLOCATIONS_COUNT)
GPU_MEMORY_HANDLE_ID_BITS :: (8 * size_of(GPU_MEMORY_HANDLE_BACKING_TYPE)) - GPU_MEMORY_HANDLE_INDEX_BITS
GPU_MEMORY_HANDLE_INDEX_MAX :: (1 << GPU_MEMORY_HANDLE_INDEX_BITS) - 1
GPU_MEMORY_HANDLE_ID_MAX :: (1 << GPU_MEMORY_HANDLE_ID_BITS) - 1
//NOTE: Should it be this way? It's less readable but more flexible, I guess it can stay like this since it isn't accessed often

// ID value that indicates end of free list (index can be ignored)
GPU_HANDLE_LIST_END_ID_VALUE :: -1
// ID value that indicates the index point to next free element in list
GPU_HANDLE_LIST_NEXT_ID_VALUE :: -2
// Used for setting `_free_elem_idx` when free elements list is empty
GPU_FREE_LIST_ABSENT_VALUE :: -1

GPU_ALLOCATED_MEMORY_INITIAL_CAP :: 4
GPU_TAKEN_REGIONS_INITAL_CAP :: 16
GPU_FREE_REGIONS_INITIAL_CAP :: 16

VRAM_FLAGS :: vk.MemoryPropertyFlags{.DEVICE_LOCAL}
STAGING_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE}
STAGING_SYNCED_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
DIRECT_TRANSFER_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .DEVICE_LOCAL}
DIRECT_TRANSFER_SYNCED_FLAGS :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .DEVICE_LOCAL, .HOST_COHERENT}

GPU_Memory_Allocator_Proc :: #type proc(mode: GPU_Allocator_Mode, request: GPU_Memory_Allocator_Request, handle: GPU_Memory_Handle, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Memory_Block, GPU_Error)
GPU_Resource_Allocator_Proc :: #type proc(mode: GPU_Allocator_Mode, request: GPU_Resource_Allocator_Request, handle: GPU_Resource_Handle, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Resource_Data, GPU_Error, int /* Index of free region in which element is located, for free region managments */)

GPU_Memory_Allocator_Request :: struct {
	category: GPU_Memory_Resource_Category,
	flags: vk.MemoryPropertyFlags,
	map_block: bool,
	size: vk.DeviceSize,
	allocator: runtime.Allocator,
}
GPU_Resource_Allocator_Request :: struct {
	type: GPU_Resource_Type,
	info: GPU_Resource_Create_Info,
	size, alignment: vk.DeviceSize,
	flags: vk.MemoryPropertyFlags,
	mappable: bool,
	allocator: runtime.Allocator,
}

GPU_Memory_State :: struct {
    memory_allocator: GPU_Memory_Allocator,
    internal_allocator: runtime.Allocator, // For Odin side allocation
    callbacks: ^vk.AllocationCallbacks,
    blocks: [dynamic]GPU_Memory_Block,
    _free_elem_idx: i32, // Valid index or `GPU_MEMORY_NO_FREE_ELEM_VALUE`
    _validation_id_counter: u32, // Since we only allow 4096 allocations, It'll serve as limit counter && at the same time ID generation
}

GPU_Memory_Handle :: bit_field GPU_MEMORY_HANDLE_BACKING_TYPE {
	index: u16 | GPU_MEMORY_HANDLE_INDEX_BITS,
	id: i32 | GPU_MEMORY_HANDLE_ID_BITS, // used for validation
}
GPU_MEMORY_HANDLE_NIL :: GPU_Memory_Handle(max(GPU_MEMORY_HANDLE_BACKING_TYPE))

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

GPU_Taken_Region :: struct {
    using _: GPU_Region,
    handle: GPU_Resource_Handle,
}

//NOTE: For now GPU_Memory can only hold the same type of resource, so alignment calcualtion is simple, but it's subject to change
GPU_Memory_Block :: struct {
    category: GPU_Memory_Resource_Category, // We allow only one type of resource per allocation to avoid alignment edge cases like using vk.BufferImageGranularity
    flags: vk.MemoryPropertyFlags,
    flags_idx: int,
    handle: GPU_Memory_Handle, // used for free list managment
    size,
    allocated: vk.DeviceSize,
    linear_write_offset: vk.DeviceSize, // For fast path allocation
    memory: vk.DeviceMemory,
    mapped_ptr: rawptr, // If mapped (WARN: can only be mapped when allocating, mapping after allocation is forbidden)
    taken_regions: [dynamic]GPU_Taken_Region, // Allocations need to be sorted by offset if linear writes are used
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

GPU_Error :: enum {
	None = 0,
	Unknown,
	Out_Of_Memory,
	Invalid_Size,
	Memory_Not_Found,
	Invalid_Flags,
	Mode_Unsupported,
	Memory_Unsupported,
	Not_Implemented,
	Creation_Failure,
	Invalid_Handle,
	ID_Exhausted,
}


gpu_initalize_memory_state :: proc(mem_state: ^GPU_Memory_State, mem_alloc := GPU_Memory_Allocator{gpu_default_memory_allocator, nil}, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	mem_state.blocks = make([dynamic]GPU_Memory_Block, allocator)
	mem_state.memory_allocator = mem_alloc
	mem_state.internal_allocator = allocator
	mem_state.callbacks = callbacks
	mem_state._free_elem_idx = GPU_FREE_LIST_ABSENT_VALUE
}

gpu_allocate_default_memory_blocks :: proc() -> (vram_handle: GPU_Memory_Handle, staging_handle: Maybe(GPU_Memory_Handle)) {
	h, err := gpu_alloc(.Buffer, {.DEVICE_LOCAL, .HOST_VISIBLE}, true, mem.Kilobyte * 1)
	if err == nil {
		return h, nil
	}
	else {
		log.warnf("Cannot allocate mapped VRAM directly: %v", err)
		log.warn("Moving to VRAM <-> Staging architecture")
	}

	h, err = gpu_alloc(.Buffer, VRAM_FLAGS, false, mem.Kilobyte * 1)
	if err != nil {
		log.panic("Cannot allocate required VRAM")
	}

	s, s_err := gpu_alloc(.Buffer, STAGING_FLAGS, true, mem.Kilobyte * 1)
	if err != nil {
		log.panic("Cannot allocate required staging memory")
	}

	return h, s
}

gpu_cleanup_memory_state :: proc(mem_state: GPU_Memory_State) {
	for block in mem_state.blocks {
		gpu_free(block.handle)
	}

	delete(mem_state.blocks)
}

//gpu_default_ring_allocator
//gpu_default_linear_allocator


gpu_alloc :: proc(category: GPU_Memory_Resource_Category, flags: vk.MemoryPropertyFlags, map_block: bool, size: vk.DeviceSize) -> (handle: GPU_Memory_Handle, err: GPU_Error) {
	m := &get_global_state().renderer.memory
	if m._validation_id_counter >= GPU_MEMORY_HANDLE_ID_MAX do return {}, .ID_Exhausted
	request := GPU_Memory_Allocator_Request{
		category = category,
		map_block = map_block,
		allocator = m.internal_allocator,
		flags = flags,
		size = size
	}
	block := m.memory_allocator.procedure(.Allocate, request, {}, m.callbacks, m.memory_allocator.data) or_return
	h := _gpu_add_block_to_state(block, m)
	m.blocks[h.index].handle = h
	return h, nil
}

gpu_free :: proc(handle: GPU_Memory_Handle) {
	m := get_global_state().renderer.memory

	assert(int(handle.index) < len(m.blocks))
	block := m.blocks[handle.index]

	if !_validate_handles(handle, block.handle) {
		return
	}

	m.memory_allocator.procedure(.Free, {}, handle, m.callbacks, m.memory_allocator.data)
	_gpu_remove_block_from_state(handle, &m)
}

_gpu_add_block_to_state :: proc(block: GPU_Memory_Block, mem_state: ^GPU_Memory_State) -> (h: GPU_Memory_Handle) {
	assert(mem_state != nil)

	// Just append
	if mem_state._free_elem_idx == GPU_FREE_LIST_ABSENT_VALUE {
		append(&mem_state.blocks, block)

		return _gpu_generate_memory_handle(len(mem_state.blocks) - 1, &mem_state._validation_id_counter)
	}

	assert(int(mem_state._free_elem_idx) < len(mem_state.blocks))

	idx := mem_state._free_elem_idx
	b := mem_state.blocks[idx]

	switch b.handle.id {
	case GPU_HANDLE_LIST_END_ID_VALUE: mem_state._free_elem_idx = GPU_FREE_LIST_ABSENT_VALUE
	case GPU_HANDLE_LIST_NEXT_ID_VALUE: mem_state._free_elem_idx = i32(b.handle.index)
	case:
		log.warnf("Handle of memory block does not match expected values, got '%v'. Setting free elements list as not available, possible leaks.", b.handle)
		mem_state._free_elem_idx = GPU_FREE_LIST_ABSENT_VALUE
	}

	h = _gpu_generate_memory_handle(int(idx), &mem_state._validation_id_counter)
	b.handle = h

	mem_state.blocks[idx] = block

	return h
}

_gpu_remove_block_from_state :: proc(h: GPU_Memory_Handle, mem_state: ^GPU_Memory_State) {
	assert(mem_state != nil && int(h.index) < len(mem_state.blocks))
	if mem_state._free_elem_idx == GPU_FREE_LIST_ABSENT_VALUE {
		// if the last element, we do not create free list, we're going to pop it
		if int(h.index) == len(mem_state.blocks) - 1 {
			mem_state.blocks[h.index].handle = GPU_MEMORY_HANDLE_NIL
			pop(&mem_state.blocks)
			return
		}

		// update free element index and set it's handle id as the end of free list since it's only one
		mem_state._free_elem_idx = i32(h.index)
		mem_state.blocks[h.index].handle.id = GPU_HANDLE_LIST_END_ID_VALUE
		return
	}

	// add new free block and save last index inside
	idx := mem_state._free_elem_idx
	mem_state.blocks[h.index].handle = {id = GPU_HANDLE_LIST_NEXT_ID_VALUE, index = u16(idx)}
	mem_state._free_elem_idx = i32(h.index)
}

gpu_default_memory_allocator : GPU_Memory_Allocator_Proc : proc(mode: GPU_Allocator_Mode, r: GPU_Memory_Allocator_Request, handle: GPU_Memory_Handle, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (block: GPU_Memory_Block, err: GPU_Error) {
	c := get_global_state().renderer.core
	#partial switch mode {
	case .Allocate: return _gpu_default_memory_allocator_alloc(c.device.handle, r.category, r.size, c.physical_devices.active.memory_properties, r.flags, r.map_block, r.allocator, callbacks)
	case .Free:
		_gpu_default_memory_allocator_free(c.device.handle, handle, callbacks)
		return
	case: return {}, .Not_Implemented
	}
}

_gpu_default_memory_allocator_alloc :: proc(device: vk.Device, category: GPU_Memory_Resource_Category, size: vk.DeviceSize, phys_prop: vk.PhysicalDeviceMemoryProperties, flags: vk.MemoryPropertyFlags, map_block: bool, allocator: runtime.Allocator, callbacks: ^vk.AllocationCallbacks) -> (block: GPU_Memory_Block, err: GPU_Error) {
    if size == 0 || size > GPU_MAX_ALLOWED_ALLOCATION_SIZE {
        return {}, .Invalid_Size
    }

    if map_block && .HOST_VISIBLE not_in flags {
    	return {}, .Invalid_Flags
    }

    type_idx, _ := _gpu_find_memory_type(phys_prop, flags)
    if type_idx == -1 {
        return {}, .Memory_Not_Found
    }

    full_flags := phys_prop.memoryTypes[type_idx].propertyFlags

    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        memoryTypeIndex = u32(type_idx),
        allocationSize = size,
    }

    result := vk.AllocateMemory(device, &alloc_info, callbacks, &block.memory)
    #partial switch result {
        case .SUCCESS: when CONFIG_VERBOSE_LOG do log.debugf("Allocated %v %v of GPU memory with flags %v", logs_simplify_bytes(u64(size)), full_flags)
        case .ERROR_OUT_OF_HOST_MEMORY, .ERROR_OUT_OF_DEVICE_MEMORY: return {}, .Out_Of_Memory
        case:
            log.errorf("GPU Memory allocation failure: %v (wanted %v bytes | requested flags %v -> found: %v)", result, size, flags, full_flags)
            return {}, .Unknown
    }
    defer if err != nil do vk.FreeMemory(device, block.memory, callbacks)

    block.size = size
    block.flags = full_flags
    block.flags_idx = type_idx
    block.category = category

    block.taken_regions = make([dynamic]GPU_Taken_Region, 0, GPU_TAKEN_REGIONS_INITAL_CAP, allocator)
    block.free_regions = make([dynamic]GPU_Region, 0, GPU_FREE_REGIONS_INITIAL_CAP, allocator)
    defer if err != nil do delete(block.taken_regions)
    defer if err != nil do delete(block.free_regions)

    if map_block {
    	ptr: rawptr
    	result := vk.MapMemory(device, block.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), nil, &ptr)
     	if result != .SUCCESS {
      		log.errorf("Memory mapping failed: %v", result)
        	return {}, .Creation_Failure
        }
        block.mapped_ptr = ptr
    }

    return block, nil
}

_gpu_default_memory_allocator_free :: proc(device: vk.Device, handle: GPU_Memory_Handle, callbacks: ^vk.AllocationCallbacks) {
	m := get_global_state().renderer.memory
	block := m.blocks[handle.index]

	delete(block.taken_regions)
	delete(block.free_regions)
	if block.mapped_ptr != nil {
		vk.UnmapMemory(device, block.memory)
	}
	vk.FreeMemory(device, block.memory, callbacks)
}

_gpu_find_memory_type :: proc(props: vk.PhysicalDeviceMemoryProperties, flags: vk.MemoryPropertyFlags) -> (type_idx := -1, heap_idx := -1) {
    for i in 0 ..< props.memoryTypeCount {
        if props.memoryTypes[i].propertyFlags & flags == flags {
            return int(i), int(props.memoryTypes[i].heapIndex)
        }
    }

    return
}

// Default GPU static resource allocator does not support custom types yet.
gpu_default_static_resource_allocator : GPU_Resource_Allocator_Proc : proc(mode: GPU_Allocator_Mode, r: GPU_Resource_Allocator_Request, handle: GPU_Resource_Handle, callbacks: ^vk.AllocationCallbacks, data: rawptr) -> (GPU_Resource_Data, GPU_Error, int) {
    rend := get_global_state().renderer
    device := rend.core.device.handle
    #partial switch mode {
        case .Create: return _gpu_default_static_resource_allocator_create(device, r.type, r.size, rend.memory.blocks[:], r.flags, r.mappable, rend.core.physical_devices.active.properties.limits, callbacks)
        case .Destroy: return {}, _gpu_default_static_resource_allocator_destroy(handle, rend.resources.datas[handle.index], device, callbacks), -1
        case: return {}, .Mode_Unsupported, -1
     }
}

// Procedure `info` parameter is ignored for now since default allocators do not support custom types yet.
// FIX: Now it's searching until first success/failure, and then return which is not ideal, we need to search until the last memory block.
_gpu_default_static_resource_allocator_create :: proc(device: vk.Device, type: GPU_Resource_Type, size: vk.DeviceSize, blocks: []GPU_Memory_Block, memory_flags: vk.MemoryPropertyFlags, mappable: bool, limits: vk.PhysicalDeviceLimits, callbacks: ^vk.AllocationCallbacks) -> (data: GPU_Resource_Data, err: GPU_Error, free_reg_idx: int) {
	usage: GPU_Resource_Usage = .Static
	#partial switch type {
	case .Vertex_Buffer:
		info := GPU_Resource_Create_Info_Presets[type]
		info.buffer.size = size

		buffer, ok := _gpu_create_buffer(device, &info.buffer, callbacks)
		if !ok {
			return {}, .Creation_Failure, -1
		}

		defer if err != nil {
			vk.DestroyBuffer(device, buffer, callbacks)
		}

		req := _gpu_get_buffer_requirements(device, buffer)

		mem_index, adjust := _gpu_find_compatibile_memory_index(blocks, .Buffer, req, memory_flags, mappable)
		if mem_index == -1 {
			return {}, .Memory_Not_Found, -1
		}

		final_req := req
		if adjust {
			final_req.alignment, final_req.size = _gpu_readjust_requirements_for_mapping(final_req, limits)
		}

		offset, free_region_index := _gpu_find_offset_for_resource(blocks[mem_index], final_req.alignment, final_req.size, search_free = true)

		if offset == -1  {
			return {}, .Memory_Not_Found, -1
		}

		success := _gpu_bind_buffer_memory(device, buffer, blocks[mem_index].memory, vk.DeviceSize(offset))
		if !success {
			return {}, .Creation_Failure, -1
		}

		data.type = .Vertex_Buffer
		data.usage = usage
		data.backing_size = final_req.size
		data.offset = vk.DeviceSize(offset)
		data.data_size = size
		data.parent_idx = mem_index
		data.resource = buffer

		return data, nil, free_region_index
	case: return {}, .Not_Implemented, -1
	}
}

_gpu_default_static_resource_allocator_destroy :: proc(handle: GPU_Resource_Handle, res: GPU_Resource_Data, device: vk.Device, callbacks: ^vk.AllocationCallbacks) -> GPU_Error {
	g := get_global_state()
	#partial switch res.type {
	case .Vertex_Buffer:
		vk.DestroyBuffer(device, gpu_get_resource_from_handle(handle).(vk.Buffer), callbacks)
		return nil
	case: return .Not_Implemented
	}
}


_gpu_bind_buffer_memory :: proc(device: vk.Device, buffer: vk.Buffer, memory: vk.DeviceMemory, offset: vk.DeviceSize) -> (success: bool) {
    result := vk.BindBufferMemory(device, buffer, memory, offset)
    if result != .SUCCESS {
        when CONFIG_VERBOSE_LOG do log.errorf("Buffer memory binding failure: %v", result)
        return false
    }
    return true
}


// Passing value to `start_from` will start searching from given index onwards. It's mainly used if previous searches failed and we need to search again.
// If `adjust_for_mapped_range` is set to true, requirements need to be adjusted to be compliant with physical device limit `nonCoherentAtomSize` if mapping is desired.
_gpu_find_compatibile_memory_index :: proc(memory_blocks: []GPU_Memory_Block, category: GPU_Memory_Resource_Category, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, mappable: bool, start_from := 0) -> (index: int, adjust_for_mapped_range: bool) {
    for i in start_from ..< len(memory_blocks) {
        if memory_blocks[i].category != category || !_gpu_check_flags_support(memory_blocks[i].flags_idx, requirements.memoryTypeBits) || flags & memory_blocks[i].flags != flags || mappable && memory_blocks[i].mapped_ptr == nil do continue

        if mappable && .HOST_COHERENT not_in memory_blocks[i].flags {
        	return i, true
        }

        return i, false
    }

    return -1, false
}

_gpu_get_resource_category_from_type :: proc(type: GPU_Resource_Type) -> GPU_Memory_Resource_Category {
    switch type {
        case .Custom_Buffer, .Vertex_Buffer: return .Buffer
        case .Custom_Image: return .Image
    }

    log.panicf("The procedure '%v' has expected valid resource type, got: %v", #procedure, type)
}

_gpu_check_flags_support :: proc(index: int, memory_bits: u32) -> (supported: bool) {
    if index < 0 || index >= 32 do return false

    mask : u32 = 1 << uint(index)
    if mask & memory_bits == mask do return true
    return false
}

_gpu_generate_memory_handle :: proc(index: int, counter: ^u32) -> (h: GPU_Memory_Handle) {
	h.index = u16(index)
	h.id = i32(counter^)
	counter^ += 1
	return h
}

_gpu_generate_resource_handle :: proc(index: int, counter: ^u64) -> (h: GPU_Resource_Handle){
	h.index = u32(index)
	h.id = i64(counter^)
	counter^ += 1
	return h
}
