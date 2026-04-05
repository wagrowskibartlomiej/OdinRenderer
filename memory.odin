#+feature using-stmt
package engine

import "core:log"
import "core:mem"

import sa "core:container/small_array"

import vk "vendor:vulkan"

ALLOCATE_RESOURCES_CAPACITY :: 16

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [3]f32

Vertex :: struct {
	position, color: Vec4
}

GPU_Resource_Identifier :: union {
	GPU_Member_Resource_Identifier,
	GPU_Independent_Resource_Identifier,
}

GPU_Resource_Handle :: union {
	vk.Buffer,
	vk.Image,
}

GPU_Member_Resource_Identifier :: struct {
	offset: i64, parent: ^GPU_Resource,
}

GPU_Independent_Resource_Identifier :: struct {
	block_index: int, offset: i64,
}

//NOTE: Maybe I should create separate types for pools and independent resources + sepearate raw and typed,
//	and then union it into typed and raw and at the end combine all of that into single Resource Type?


GPU_Resource_Type :: union {
	GPU_Raw_Resource_Type,
	GPU_Typed_Resource_Type,
}

GPU_Raw_Resource_Type :: enum {
	Vertex_Buffer,
	Vertex_Buffer_Pool,
}

GPU_Typed_Resource_Type :: enum {
	Default_Vertex_Pool,
	Default_Vertex_Pool_Member,
}
GPU_Typed_Resource_Type_Infos := #partial [GPU_Typed_Resource_Type]GPU_Resource_Configuration_Info{
	.Default_Vertex_Pool = {
		create_info = {buffer = {sType = .BUFFER_CREATE_INFO, sharingMode = .EXCLUSIVE, usage = {.TRANSFER_SRC, .TRANSFER_DST, .VERTEX_BUFFER}}},
		mem_block = .VRAM,
	}
}

GPU_Memory_Error :: enum {
	None,
	Out_Of_Memory,
	Already_Allocated,
	Invalid_Param,
	Creation_Error,
	GPU_Manager_Internal_Error, // This error is a way to describe that resource creation on Vulkan side went successfully but the memory manager failed to "track" the resource
}

GPU_Memory_Operation :: enum {
	None,
	Allocate,
	Move,
	Free,
	Enlarge,
	Reduce,
	Copy,
}

GPU_Memory_Block_Type :: enum {
	NONE,
	VRAM,
	STAGING,
	SPECIALIZED,
}
GPU_Defragmentation_Memory_Flags :: bit_set[GPU_Memory_Block_Type]

GPU_Resource_Create_Info :: struct #raw_union {
	buffer: vk.BufferCreateInfo,
	image: vk.ImageCreateInfo,
}

GPU_Resource_Configuration_Info :: struct {
	create_info: GPU_Resource_Create_Info,
	mem_block: GPU_Memory_Block_Type,
	fallback_block: GPU_Memory_Block_Type,
}

GPU_Memory_Manager :: struct {
	defrag_needed_flags: GPU_Defragmentation_Memory_Flags,
	memory_allocations_count: int,
	blocks: []GPU_Memory_Block,
	resources: map[GPU_Resource_Identifier]GPU_Resource, // TODO: I should eliminate copies of resources in map and with members arrays
}

GPU_Memory_Block :: struct {
	handle: vk.DeviceMemory,
	type: GPU_Memory_Block_Type,
	vulkan_types_index: int,
	allocated, size: i64,
	most_right_offset_available: i64, // if most_right_offset_available is equal or greater than size it means there is no space left without fragmentation search or without doing defragmentation
	resources: [dynamic]GPU_Resource_Identifier
}

// Represents actual vertex, image etc. data (pool, pool member or independent resource)
GPU_Resource :: struct {
	handle: GPU_Resource_Handle, // If member, the handle is of a containing pool last_operation: GPU_Memory_Operation,
	type: GPU_Resource_Type,
	data: GPU_Resource_Data,
	data_size, backing_size, offset: i64,
	metadata: rawptr, // Future use (probably for editor builds and debugging)
	user_data: rawptr,
}
// Maybe in future add reference counting system for GPU_Resource that is enabled in configs???

GPU_Resource_Data :: struct #raw_union {
	pool: GPU_Pool_Data,
	member: GPU_Member_Data,
	independent: GPU_Independent_Resource_Data,
}
GPU_Pool_Data :: struct {
	members: [dynamic]GPU_Member_Resource_Identifier,
	allocated: i64,
	block_index: int,
}
GPU_Member_Data :: struct {
	source: rawptr,
}
GPU_Independent_Resource_Data :: struct {
	source: rawptr,
	block_index: int,
}

// Used for counting holes with fragmentation
MAX_ALLOWED_MEMORY_FRAGMENTATION_HOLES_COUNTER :: 64
Memory_Fragementation_Hole :: struct {offset, size: i64}
Memory_Fragementation_Holes :: sa.Small_Array(MAX_ALLOWED_MEMORY_FRAGMENTATION_HOLES_COUNTER, Memory_Fragementation_Hole)

gpu_initialize_memory_manager :: proc(init_state: ^Vulkan_Init_State, gpu_memory: ^GPU_Memory_Manager, allocator := context.allocator) -> (success: bool) {
	using init_state.physical_devices.active.memory_properties

	when CONFIG_VERBOSE_LOG do for i in 0 ..< memoryHeapCount {
		if i == 0 do log.info("Vulkan reported memory heaps:")
		log.infof("%v. %v", i, memoryHeaps[i])
	}

	when CONFIG_VERBOSE_LOG do for i in 0 ..< memoryTypeCount {
		if i == 0 do log.info("Vulkan reported memory types:")
		log.infof("%v. %v", i, memoryTypes[i])
	}

	gpu_memory.blocks = make([]GPU_Memory_Block, 2, allocator)
	defer if !success do delete(gpu_memory.blocks, allocator)


	vram_type, vram_index := gpu_search_for_vram(&memoryTypes, &memoryHeaps)
	if vram_index < 0 {
		log.fatal("Failed to detect VRAM")
		return false
	}

	staging_type, staging_index := gpu_search_for_staging(&memoryTypes, &memoryHeaps)
	if staging_index < 0 {
		log.fatal("Failed to detect staging memory")
		return false
	}


	allocated_size: vk.DeviceSize
	success, allocated_size = vulkan_allocate_relaxed(&gpu_memory.blocks[0].handle, init_state, vram_index, vk.DeviceSize(f64(memoryHeaps[vram_type.heapIndex].size) * 0.8))
	if !success {
		log.fatal("Failed to allocate VRAM")
		return false
	}
	when CONFIG_VERBOSE_LOG do log.debugf("Allocated VRAM: %.2f MB", f64(allocated_size) / mem.Megabyte)

	gpu_memory.blocks[0].type = .VRAM
	gpu_memory.blocks[0].vulkan_types_index = vram_index
	gpu_memory.blocks[0].resources = make([dynamic]GPU_Resource_Identifier, ALLOCATE_RESOURCES_CAPACITY)
	gpu_memory.blocks[0].size = i64(allocated_size)

	fixed_size : vk.DeviceSize = mem.Megabyte * 128
	success = vulkan_allocate_fixed(&gpu_memory.blocks[1].handle, init_state, staging_index, fixed_size)
	if !success {
		log.fatal("Failed to allocate staging memory")
		return false
	}
	when CONFIG_VERBOSE_LOG do log.debugf("Allocated staging: %.2f MB", f64(fixed_size) / mem.Megabyte)

	gpu_memory.blocks[1].type = .STAGING
	gpu_memory.blocks[1].vulkan_types_index = staging_index
	gpu_memory.blocks[1].resources = make([dynamic]GPU_Resource_Identifier, ALLOCATE_RESOURCES_CAPACITY)
	gpu_memory.blocks[1].size = i64(fixed_size)

	when CONFIG_VERBOSE_LOG do log.debug("GPU Memory Manager initalized")

	return true
}

gpu_cleanup_memory_manager :: proc(init_state: ^Vulkan_Init_State, gpu_memory: ^GPU_Memory_Manager, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	for block in gpu_memory.blocks {
		for res_id in block.resources {
			res, exists := gpu_memory.resources[res_id]
			if !exists do continue

			switch type in res.type {
			case GPU_Raw_Resource_Type:
				switch type {
				case .Vertex_Buffer:
					buff, is_buffer := res.handle.(vk.Buffer)
					if !is_buffer {
						log.errorf("The handle is not detected as a buffer handle: %v", buff)
						continue
					}
					vk.DestroyBuffer(init_state.device.handle, buff, callbacks)
				case .Vertex_Buffer_Pool: 
					buff, is_buffer := res.handle.(vk.Buffer)
					if !is_buffer {
						log.errorf("The handle is not detected as a buffer handle: %v", buff)
						continue
					}
					vk.DestroyBuffer(init_state.device.handle, buff, callbacks)
					delete(res.data.pool.members)
				}
			case GPU_Typed_Resource_Type:
				switch type {
				case .Default_Vertex_Pool: 
					buff, is_buffer := res.handle.(vk.Buffer)
					if !is_buffer {
						log.errorf("The handle is not detected as a buffer handle: %v", buff)
						continue
					}
					vk.DestroyBuffer(init_state.device.handle, buff, callbacks)
				case .Default_Vertex_Pool_Member:
					buff, is_buffer := res.handle.(vk.Buffer)
					if !is_buffer {
						log.errorf("The handle is not detected as a buffer handle: %v", buff)
						continue
					}
					vk.DestroyBuffer(init_state.device.handle, buff, callbacks)
					delete(res.data.pool.members)
				}
			}
		}

		delete(block.resources)
		vk.FreeMemory(init_state.device.handle, block.handle, callbacks)
	}

	delete(gpu_memory.blocks, allocator)
	delete(gpu_memory.resources)
	when CONFIG_VERBOSE_LOG do log.debugf("GPU Memory Manager cleaned up")
}

vulkan_allocate :: proc{
	vulkan_allocate_fixed,
	vulkan_allocate_relaxed,
}

vulkan_allocate_fixed :: proc(memory: ^vk.DeviceMemory, init_state: ^Vulkan_Init_State, mem_index: int, size: vk.DeviceSize, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if init_state == nil || mem_index < 0 || memory == nil do return

	i := u32(mem_index)

	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = size,
		memoryTypeIndex = i,
	}

	result := vk.AllocateMemory(init_state.device.handle, &alloc_info, callbacks, memory)
	if result != .SUCCESS {
		log.errorf("Failed to allocate %.2f MB of memory: %v", f64(size) / mem.Megabyte, result)
		return false
	}
		
	return true
}

//TODO: Implement
//vulkan_allocate_fixed_search :: proc(init_state: ^Vulkan_Init_State, size: int) {}

/*
	Tries to allocate memory in spiecified memory type, if size is not available it'll scale down and try to get anything available until minimum value is reached
NOTE:
	Shoud be used only in loading times or at the start of the app
TODO:
	For now just use this, but in future add check for VK_EXT_memory_budget and use it if available with dedicated procedure
*/
vulkan_allocate_relaxed :: proc(memory: ^vk.DeviceMemory, init_state: ^Vulkan_Init_State, mem_index: int, size: vk.DeviceSize, min : vk.DeviceSize = 64 * mem.Megabyte, lower_by_percent: f64 = 0.1, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool, allocated_size: vk.DeviceSize) {
	if init_state == nil || memory == nil || size < min || mem_index < 0 || lower_by_percent <= 0 do return

	i := u32(mem_index)

	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = size,
		memoryTypeIndex = i,
	}

	for alloc_info.allocationSize >= min {
		when CONFIG_VERBOSE_LOG do log.debugf("Trying to allocate: %.2f MB", f64(alloc_info.allocationSize) / mem.Megabyte)

		result := vk.AllocateMemory(init_state.device.handle, &alloc_info, callbacks, memory)

		#partial switch result {
		case .SUCCESS: return true, alloc_info.allocationSize
		case .ERROR_OUT_OF_HOST_MEMORY, .ERROR_OUT_OF_DEVICE_MEMORY: 
			alloc_info.allocationSize -= cast(vk.DeviceSize) (f64(size) * lower_by_percent)
			continue
		case:
			log.errorf("Memory allocation failure: %v", result)
			return false, 0
		}
	}

	return false, 0
}

/*
	Tries to allocate memory, if size is not available it'll scale down and try to get anything available until minimum value is reached,
	if it can't allocate in first type it moves to the next one and repeats until every type is searched or until allocation is made
NOTE:
	Shoud be used only in loading times or at the start of the app
TODO:
	For now just use this, but in future add check for VK_EXT_memory_budget and use it if available with dedicated procedure
*/
//TODO: Implement
//vulkan_allocate_relaxed_serach :: proc(init_state: ^Vulkan_Init_State, size, min, max: int, lower_by: f64) -> (success: bool) {return}


gpu_search_for_vram :: proc(types: ^[vk.MAX_MEMORY_TYPES]vk.MemoryType, heaps: ^[vk.MAX_MEMORY_HEAPS]vk.MemoryHeap) -> (vram: vk.MemoryType, index: int = -1){
	if types == nil || heaps == nil do return

	for t, i in types {
		if .DEVICE_LOCAL in t.propertyFlags {
			// If we have none
			if index == -1 {
				vram = t
				index = i
			} else if heaps[vram.heapIndex].size < heaps[t.heapIndex].size { // For now just choose biggest one
				vram = t
				index = i
			}
		} else do continue
	}

	return
}

gpu_search_for_staging :: proc(types: ^[vk.MAX_MEMORY_TYPES]vk.MemoryType, heaps: ^[vk.MAX_MEMORY_HEAPS]vk.MemoryHeap) -> (staging: vk.MemoryType, index := -1) {
	if types == nil || heaps == nil do return

	for t, i in types {
		if .HOST_VISIBLE in t.propertyFlags {
			// If we have none or we have ones that are local and visible, get the biggest one of them (usually this will be mobile)
			if (index == -1 || (.DEVICE_LOCAL in staging.propertyFlags && heaps[t.heapIndex].size > heaps[staging.heapIndex].size)) {
				staging = t
				index = i
			} else if .DEVICE_LOCAL not_in t.propertyFlags {
				// Get if it is pure RAM (usually on desktop, and it'll be the biggest pool available in most configurations)
				staging = t 
				index = i
			}
		}
	}

	return
}

GPU_Specialzied_Search_Type :: enum {
	CPU_Speed = 1,
	Transfer_Speed,
	Coherence,
}

gpu_search_for_specialized :: proc(search_for: GPU_Specialzied_Search_Type, types: ^[vk.MAX_MEMORY_TYPES]vk.MemoryType, heaps: ^[vk.MAX_MEMORY_HEAPS]vk.MemoryHeap) -> (specialized: vk.MemoryType, index := -1) {
	if types == nil || heaps == nil || search_for == nil do return

	switch search_for {
	case .CPU_Speed: for t, i in types do if .HOST_CACHED in t.propertyFlags do return t, i
	case .Transfer_Speed: for t, i in types do if .DEVICE_LOCAL in t.propertyFlags && .HOST_VISIBLE in t.propertyFlags do return t, i
	case .Coherence: for t, i in types do if .HOST_COHERENT in t.propertyFlags do return t, i
	case: return
	}

	return
}

/*
I would need to change into this in future if i'd implement other graphics APIs and some other things i guess
Raw unions or tagged?
 
GPU_Memory_Flags :: struct #raw_union {
	vk.MemoryPropertyFlags
}

GPU_Memory_Handle :: union {
	vk.DeviceMemory
}
*/
//NOTE: maybe just rawptr and cast it to CreateInfo type depending on handle? 
//	and move to the allocator proc way
//	I should add also way to just free memory of resource and allocate when it's already created in gpu manager


gpu_create_resource_typed :: proc(type: GPU_Typed_Resource_Type) -> () {}

gpu_create_resource_raw :: proc(init_state: ^Vulkan_Init_State, gpu_manager: ^GPU_Memory_Manager, type: GPU_Raw_Resource_Type, handle: ^GPU_Resource_Handle, info: ^GPU_Resource_Create_Info, source_data: rawptr, block_index: int, pool_index := -1, pool_resources_count := ALLOCATE_RESOURCES_CAPACITY, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS, create_handle := true) -> (id: GPU_Resource_Identifier, err: GPU_Memory_Error, handle_created: bool) {
	if info == nil || handle == nil || block_index < 0 || block_index >= len(gpu_manager.blocks) do return nil, .Invalid_Param, false
	block := gpu_manager.blocks[block_index]

	switch &t in handle {
	case vk.Buffer:
		// If the request is to append the member to a pool of given index,
		// checking if the type is correct is responsibility of the caller - we cant have that info other than basic types which we check
		if pool_index >= 0 && pool_index < len(block.resources) {
			//TODO: Implement adding resource to the pool
			panic("Implement")
		}


		// Create handle if we need to
		if create_handle && pool_index < 0 {
			result := vk.CreateBuffer(init_state.device.handle, &info.buffer, callbacks, &t)
			if result != .SUCCESS {
				when CONFIG_VERBOSE_LOG do log.errorf(
					"Buffer creation failure: %v (DATA | handle: %v, creation_info: %v, block_index: %v, pool_index: %v)",
					result, handle, info, block_index, pool_index
				)
				else do log.errorf("Buffer creation failure: %v", result)
				return nil, .Creation_Error, false
			}
		}

		req: vk.MemoryRequirements
		vk.GetBufferMemoryRequirements(init_state.device.handle, t, &req)

		// Check if memory type is available
		mask : u32 = (1 << u32(block.vulkan_types_index))
		if (mask & req.memoryTypeBits) != mask do return nil, .Creation_Error ,true

		// Now calculate the alignment depending on specific needs
		alignment: vk.DeviceSize
		switch type {
		case .Vertex_Buffer:
			//TODO: Make it search for different resource and then decide if image granurality restriction should be taken into the account
			//	For now just grab the bigger one (which most of the time will be the granurality)
			alignment = max(init_state.physical_devices.active.properties.limits.bufferImageGranularity, req.alignment)
		case .Vertex_Buffer_Pool: panic("Implement")
		case: return nil, .Invalid_Param, true
		}

		// Determine offset with calculated alignment
		offset, _ := search_memory_block(i64(req.size), i64(alignment), &block, &gpu_manager.resources, false)
		if offset == -1 do return nil, .Out_Of_Memory, true

		// We need to bind 
		result := vk.BindBufferMemory(init_state.device.handle, handle.(vk.Buffer), block.handle, vk.DeviceSize(offset))
		if result != .SUCCESS {
			log.errorf("Buffer memory binding failure: %v", result)
			return nil, .Creation_Error, true
		}

		// Now we need to create resources needed for our GPU Memory Manager to add it to resources map and to resource dyn array of the block in which we're operating
		id = GPU_Independent_Resource_Identifier{block_index = block_index, offset = offset}
		_, exists := gpu_manager.resources[id]
		if exists do return id, .Already_Allocated, true

		res := GPU_Resource{
			backing_size = i64(req.size),
			data_size = i64(info.buffer.size),
			handle = handle^,
			offset = offset,
			type = type,
			data = GPU_Resource_Data{independent = {block_index = block_index, source = source_data}},
		}

		gpu_manager.resources[id] = res
	
		//Now update the block data
		if res.offset >= gpu_manager.blocks[block_index].most_right_offset_available do gpu_manager.blocks[block_index].most_right_offset_available = res.offset + res.backing_size
		gpu_manager.blocks[block_index].allocated += res.backing_size
		append(&gpu_manager.blocks[block_index].resources, id)


		return id, .None, true
	case vk.Image: panic("Implement")
	case: return nil, .Invalid_Param, false
	}

	return
}

gpu_destroy_resource_typed :: proc(placeholder: int){panic("Implement")}

gpu_destroy_resource_raw :: proc(init_state: ^Vulkan_Init_State, gpu_manager: ^GPU_Memory_Manager, id: GPU_Resource_Identifier, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	elem, exists := gpu_manager.resources[id]
	if !exists do return

	switch v in id {
	case GPU_Member_Resource_Identifier:
		v.parent.data.pool.allocated -= elem.backing_size
		for m, i in v.parent.data.pool.members {
			if m == id do unordered_remove(&v.parent.data.pool.members, i)
		}
		delete_key(&gpu_manager.resources, id)
	case GPU_Independent_Resource_Identifier:
		switch elem.type {
		case .Vertex_Buffer_Pool, .Default_Vertex_Pool: // Handle pools
			for member_id in elem.data.pool.members do delete_key(&gpu_manager.resources, member_id)
			delete(elem.data.pool.members)

			gpu_manager.blocks[elem.data.pool.block_index].allocated -= elem.backing_size

			switch h in elem.handle {
			case vk.Buffer: vk.DestroyBuffer(init_state.device.handle, h, callbacks)
			case vk.Image: vk.DestroyImage(init_state.device.handle, h, callbacks)
			}

			delete_key(&gpu_manager.resources, id)
		case .Vertex_Buffer: // Handle independent ones
			gpu_manager.blocks[elem.data.independent.block_index].allocated -= elem.backing_size

			switch h in elem.handle {
			case vk.Buffer: vk.DestroyBuffer(init_state.device.handle, h, callbacks)
			case vk.Image: vk.DestroyImage(init_state.device.handle, h, callbacks)
			}

			delete_key(&gpu_manager.resources, id)
		}
	}
}

gpu_move_resource_typed :: proc(placeholder: int){panic("Implement")}

gpu_move_resource_raw :: proc(){panic("Implement")}

gpu_copy_resource_typed :: proc(placeholder: int){panic("Implement")}

gpu_copy_resource_raw :: proc(){panic("Implement")}

gpu_find_block_for_typed_resource :: proc(type: GPU_Typed_Resource_Type, gpu_manager: ^GPU_Memory_Manager) -> (block_index := -1) {
	search_for: GPU_Memory_Block_Type

	#partial switch type {
	case .Default_Vertex_Pool: search_for = .VRAM
	}

	for b, i in gpu_manager.blocks do if b.type == search_for do return i
	
	return
}

// This procedure searches for compatibile block in memory, used for allocation
@(private="file")
search_memory_block :: proc(size, alignment: i64, block: ^GPU_Memory_Block, resources: ^map[GPU_Resource_Identifier]GPU_Resource, search_fragmented: bool) -> (offset : i64 = -1, defragmentation_needed: bool) {
	if size > block.size - block.allocated || block.size <= block.allocated do return // if there even is total space
	else { 
		closest := find_aligned_offset_align_up(block.allocated, alignment)
		if closest < block.size && block.size - closest >= size do return closest, false // if mmost right available offset is valid offset and the space is sufficient
	}

	if !search_fragmented do return

	holes: Memory_Fragementation_Holes
	appended: bool

	for res_id, i in block.resources {
		res, exists := resources[res_id]
		if !exists do continue

		if i == 0 {
			if res.offset > 0 {
				appended = sa.append(&holes, Memory_Fragementation_Hole{offset = 0, size = res.offset})
				if !appended {
					log.warn("Memory fragmentation is more than allowed, defragmentation needed")
					return -1, true
				}
			}
			rest_hole := Memory_Fragementation_Hole{offset = res.offset + res.backing_size, size = block.size - (res.offset + res.backing_size)}
			appended = sa.append(&holes, rest_hole)
			if !appended {
				log.warn("Memory fragmentation is more than allowed, defragmentation needed")
				return -1, true
			}
			continue
		}

		for i in 0 ..< sa.len(holes)  {
			hole := holes.data[i]

			// element is in hole
			if hole.offset <= res.offset && res.offset < hole.offset + hole.size {

				// element does not cover all space to the end, so we need to split and add new hole or adjust the old one
				if res.offset + res.backing_size < hole.offset + hole.size {
					new_hole := Memory_Fragementation_Hole{offset = res.offset + res.backing_size, size = (hole.offset + hole.size) - (res.offset + res.backing_size)}
					appended = sa.append(&holes, new_hole)
					if !appended {
						log.warn("Memory fragmentation is more than allowed, defragmentation needed")
						return -1, true
					}


					// if element does not start at the beginning of a hole, there is hole on the left, but it's easier to just change the size
					if res.offset != hole.offset do holes.data[i].size = res.offset - hole.offset 
					else do holes.data[i] = new_hole // we're removing the hole, by just replacing it with new hole values

				} else { // element covers the hole to the end, so either we shrink or eliminate the hole

					if res.offset == hole.offset do sa.unordered_remove(&holes, i) // element covers all the hole, so we need to remove it
					else do holes.data[i].size = res.offset - hole.offset // shrink the hole
				}

			} else do continue
		}
	}

	for i in 0 ..< sa.len(holes)  {
		hole := holes.data[i]

		if hole.size < size do continue // too small even without padding
		
		aligned_up := find_aligned_offset_align_up(hole.offset, alignment)

		if hole.size - aligned_up < size do continue // won't fit in
		else do return aligned_up, false
	}

	return -1, true
}
