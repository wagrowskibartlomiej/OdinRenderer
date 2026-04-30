package engine

import "core:log"
import "core:mem"
import "core:slice"
import "core:os"
import sa "core:container/small_array"

import vk "vendor:vulkan"

Render_Passes_State :: struct {
	main_render_pass: vk.RenderPass
}

Pipelines_State :: struct {
	triangle: Pipeline_State,
	cache: vk.PipelineCache,
}

Pipeline_State :: struct {
	handle: vk.Pipeline,
	layout: vk.PipelineLayout,
	vertex_module,
	fragment_module: vk.ShaderModule,
}

//TODO: Command State and command resource creation needs to be changed, but for now it's in the simplest form
Command_State :: struct {
	pool: vk.CommandPool,
	buffers: [dynamic]vk.CommandBuffer,
}


Frame_Resource_Flag :: enum {
	Frame_Sync,
	Command,
}

Frame_Resources_Flags :: bit_set[Frame_Resource_Flag]

Dynamic_Vk_State :: struct {
	sync: []Frame_Sync,
	swap_img_renderer: []vk.Semaphore,
	graphics_commands: []Command_State,
	resources_flags: Frame_Resources_Flags,
	staging: Staging_Buffer,
	vertex: Buffer,
}

Frame_Sync :: struct {
	can_record_frame: vk.Fence,
	img_available: vk.Semaphore,
}

Staging_Buffer :: struct {
	using _: Buffer,
	ptr: rawptr,
	fence: vk.Fence, // signals when we can copy to mapped
	sem: vk.Semaphore, // for gpu to know when data can be read
	gpu_wait_for_data: bool, // when not sending data every frame (which we won't with vertexes most of the time) we use this to wait or not on data semaphore
}
Buffer :: struct {
	id: GPU_Resource_Identifier,
	handle: GPU_Resource_Handle,
}

VK_TIMEOUT_MAX :: max(u64)
VK_WHITE_COLOR :: [4]f32{1, 1, 1, 1}

create_render_passes :: proc(state: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Render_Passes in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Render_Passes)

	color_ref := vk.AttachmentReference{
		attachment = 0,
		layout = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription{
		pColorAttachments = &color_ref,
		colorAttachmentCount = 1,
		pipelineBindPoint = .GRAPHICS,
	}

	attachment_desc := vk.AttachmentDescription{
		finalLayout = .PRESENT_SRC_KHR,
		loadOp = .CLEAR,
		storeOp = .STORE,
		format = state.swapchain.image_format.format,
		samples = {._1},
		initialLayout = .UNDEFINED,
	}

	dependency := vk.SubpassDependency{
		srcSubpass = vk.SUBPASS_EXTERNAL,
		dstSubpass = 0,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE}
	}
	render_pass_create_info := vk.RenderPassCreateInfo{
		sType = .RENDER_PASS_CREATE_INFO,
		pSubpasses = &subpass,
		subpassCount = 1,
		pAttachments = &attachment_desc,
		attachmentCount = 1,
		pDependencies = &dependency,
		dependencyCount = 1,
	}


	result := vk.CreateRenderPass(state.device.handle, &render_pass_create_info, callbacks, &state.render_passes.main_render_pass)
	if result != .SUCCESS {
		log.errorf("Render passes creation failed: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Render passes created")

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Render_Passes)

	success = true
	return
}

cleanup_renderer_passes :: proc(state: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Render_Passes not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Render_Passes)
		return
	}

	vk.DestroyRenderPass(state.device.handle, state.render_passes.main_render_pass, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Render passes destroyed")

	unset_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Render_Passes)
}

create_graphics_pipelines :: proc(state: ^Core_Vk_State, assets: ^Assets_Manager, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Pipelines in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Pipelines)

	cache_create_info := vk.PipelineCacheCreateInfo{
		sType = .PIPELINE_CACHE_CREATE_INFO,
	}
	result := vk.CreatePipelineCache(state.device.handle, &cache_create_info, callbacks, &state.pipelines.cache)
	if result != .SUCCESS {
		log.errorf("Failed to create pipeline cache")
	}

	v, vertex_present := get_asset("default_vertex.spv", "spirv", .SPIRV, assets)
	if !vertex_present {
		log.error("Cannot create graphics pipelines: Missing vertex shader memory in assets pool")
		return
	}


	f, fragment_present := get_asset("default_fragment.spv", "spirv", .SPIRV, assets)
	if !fragment_present {
		log.error("Cannot create graphics pipelines: Missing fragment shader memory in assets pool")
		return
	}

	vertex := v.memory.spirv
	fragment := f.memory.spirv

	log.infof("Vertex shader size: %v bytes", slice.size(vertex))
	log.infof("Fragment shader size: %v bytes", slice.size(fragment))

	vertex_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		pCode = raw_data(vertex),
		codeSize = slice.size(vertex),
	}

	result = vk.CreateShaderModule(state.device.handle, &vertex_shader_create_info, callbacks, &state.pipelines.triangle.vertex_module)
	if result != .SUCCESS {
		log.errorf("Vertex shader module creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyShaderModule(state.device.handle, state.pipelines.triangle.vertex_module, callbacks)

	fragment_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		pCode = raw_data(fragment),
		codeSize = slice.size(fragment),
	}

	result = vk.CreateShaderModule(state.device.handle, &fragment_shader_create_info, callbacks, &state.pipelines.triangle.fragment_module)
	if result != .SUCCESS {
		log.errorf("Fragment shader module creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyShaderModule(state.device.handle, state.pipelines.triangle.fragment_module, callbacks)

	layout_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	result = vk.CreatePipelineLayout(state.device.handle, &layout_info, callbacks, &state.pipelines.triangle.layout)
	if result != .SUCCESS {
		log.errorf("Pipeline layout creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyPipelineLayout(state.device.handle, state.pipelines.triangle.layout, callbacks)


	pip := &state.pipelines
	pip_tri := &state.pipelines.triangle

	pip_tri.handle = create_triangle_pipeline_internal(
		state.device.handle,
		state.render_passes.main_render_pass,
		pip_tri.layout,
		pip_tri.vertex_module,
		pip_tri.fragment_module,
		state.swapchain.image_extent,
		pip.cache,
		callbacks
	) or_return

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Pipelines)

	success = true
	return
}
create_triangle_pipeline_internal :: proc(device: vk.Device, pass: vk.RenderPass, layout: vk.PipelineLayout, vertex, fragment: vk.ShaderModule, extent: vk.Extent2D, cache: vk.PipelineCache, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (vk.Pipeline, bool) {
	vertex_stage_create_info := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = vertex,
		pName = "main",
		stage = {.VERTEX},
	}

	fragment_stage_create_info := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = fragment,
		pName = "main",
		stage = {.FRAGMENT},
	}

	stages := [?]vk.PipelineShaderStageCreateInfo{
		vertex_stage_create_info,
		fragment_stage_create_info,
	}

	attribute_desc := []vk.VertexInputAttributeDescription{
		{location = 0, format = .R32G32_SFLOAT, offset = cast(u32)offset_of(Triangle_Vertex, position)},
		{location = 1, format = .R32G32B32A32_SFLOAT, offset = cast(u32)offset_of(Triangle_Vertex, color)},
	}

	binding_desc := vk.VertexInputBindingDescription{
		inputRate = .VERTEX,
		stride = size_of(Triangle_Vertex),
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexAttributeDescriptions = raw_data(attribute_desc),
		vertexAttributeDescriptionCount = u32(len(attribute_desc)),
		pVertexBindingDescriptions = &binding_desc,
		vertexBindingDescriptionCount = 1
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	log.debugf("The extent: %v x %v", extent.width, extent.height)
	viewport := vk.Viewport{
		minDepth = 0,
		maxDepth = 1,
		width = f32(extent.width),
		height = f32(extent.height),
	}
	scissors := vk.Rect2D{
		extent = extent,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports = &viewport,
		scissorCount = 1,
		pScissors = &scissors,
	}

	rasterization := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		rasterizerDiscardEnable = false,
		cullMode = {},
		polygonMode = .FILL,
		lineWidth = 1,
		frontFace = .COUNTER_CLOCKWISE,
		depthBiasEnable = false,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	depth := vk.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = false,
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable = false,
	}

	blend := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false,
		pAttachments = &blend_attachment,
		attachmentCount = 1,
	}

	pipeline_create_info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pStages = raw_data(stages[:]),
		stageCount = u32(len(stages)),
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState = &viewport_state,
		pRasterizationState = &rasterization,
		pMultisampleState = &multisample,
		pDepthStencilState = &depth,
		pColorBlendState = &blend,
		renderPass = pass,
		subpass = 0,
		layout = layout,
	}

	pipeline: vk.Pipeline
	result := vk.CreateGraphicsPipelines(device, cache, 1, &pipeline_create_info, callbacks, &pipeline)
	if result != .SUCCESS {
		log.errorf("Graphics pipelines creation fail: %v", result)
		return {}, false
	}
	when CONFIG_VERBOSE_LOG do log.debug("Graphics pipelines created")

	return pipeline, true
}

cleanup_graphics_pipelines :: proc(state: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Pipelines not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Pipelines)
		return
	}

	vk.DestroyPipeline(state.device.handle, state.pipelines.triangle.handle, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Graphics pipelines destroyed")

	vk.DestroyPipelineLayout(state.device.handle, state.pipelines.triangle.layout, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Pipeline layout destroyed")

	vk.DestroyShaderModule(state.device.handle, state.pipelines.triangle.vertex_module, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Vertex shader module destroyed")

	vk.DestroyShaderModule(state.device.handle, state.pipelines.triangle.fragment_module, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Fragment shader module destroyed")

	vk.DestroyPipelineCache(state.device.handle, state.pipelines.cache, callbacks)

	state.resource_flags &~= {.Pipelines}
	when CONFIG_VERBOSE_LOG do log.debug("Pipelines resource flag unset")
}

init_frame_resources :: proc(frame: ^Dynamic_Vk_State, init: ^Core_Vk_State, manager: ^GPU_Memory_Manager, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	success = create_frame_sync(init, frame, allocator, temp_allocator, callbacks)
	if !success {
		log.fatal("Frame synchronization creation failed")
		return
	}

	success = create_command_resources(init, frame, allocator, callbacks)
	if !success {
		log.fatalf("Failed to create command resources")
		return
	}

	frame.staging, frame.vertex = create_buffers(init, manager)

	when CONFIG_VERBOSE_LOG do log.debug("Frame initalization successful")
	return
}

cleanup_frame_resources :: proc(stat: ^Core_Vk_State, dyn: ^Dynamic_Vk_State, memory: ^GPU_Memory_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	vk.DeviceWaitIdle(stat.device.handle)
	cleanup_buffers(stat, memory, dyn)
	if .Frame_Sync in stat.resources_flags do cleanup_frame_sync(stat, dyn, allocator, callbacks)
	if .Command in stat.resources_flags do cleanup_command_resources(stat, state, allocator, callbacks)
}

move_data_to_vertex_buffer :: proc(stat: ^Core_Vk_State, dyn: ^Dynamic_Vk_State, data: rawptr, size: int) -> (success: bool) {
	//nuke way but idc
	vk.DeviceWaitIdle(stat.device.handle)
	res := vk.GetFenceStatus(stat.device.handle, dyn.staging.fence)
	if res != .SUCCESS do vk.WaitForFences(stat.device.handle, 1, &dyn.staging.fence, true, VK_TIMEOUT_MAX)

	vk.ResetFences(stat.device.handle, 1, &dyn.staging.fence)
	{
		p, ok, flushing, s, o, h:= _map_vertex_if_possible(stat, dyn)
		if ok {
			mem.copy_non_overlapping(p, data, size)
			if flushing {
				res := vk.FlushMappedMemoryRanges(stat.device.handle, 1, &vk.MappedMemoryRange{
				sType = .MAPPED_MEMORY_RANGE,
				memory = h,
				offset = o,
				size = s,
			})
			if res != .SUCCESS do log.errorf("Failed to flush mapped memory range: %v", res)
			else do return true
			}
		}
	}
	mem.copy_non_overlapping(dyn.staging.ptr, data, size)
	//TODO: Check coherence and flush if needed

	cmd_buff := dyn.graphics_commands[0].buffers[0]

	region  := vk.BufferCopy{
		dstOffset = 0,
		srcOffset = 0,
		size = vk.DeviceSize(size),
	}

	begin_command_buffer(cmd_buff)
	vk.CmdCopyBuffer(cmd_buff, dyn.staging.handle.(vk.Buffer), dyn.vertex.handle.(vk.Buffer), 1, &region)
	end_command_buffer(cmd_buff)

	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buff,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &dyn.staging.sem,
	}

	res = vk.QueueSubmit(stat.device.graphics, 1, &submit_info, dyn.staging.fence)

	if res != .SUCCESS do return
	else {
		dyn.staging.gpu_wait_for_data = true
		return true
	}
}

@(private="file")
_map_vertex_if_possible :: proc(init: ^Core_Vk_State, frame: ^Dynamic_Vk_State) -> (ptr: rawptr, ok: bool, flush_needed := true, _flush_size, _flush_offset: vk.DeviceSize, _handle: vk.DeviceMemory) {
	assert(context.user_ptr != nil, #procedure + " should only be called from with valid context state pointer as user data")
	state := cast(^Engine_Global_State)context.user_ptr
	res, exists := state.renderer.memory.resources[frame.vertex.id]
	if !exists do return
	block := state.renderer.memory.blocks[res.data.independent.block_index]
	flags := init.physical_devices.active.memory_properties.memoryTypes[block.vulkan_types_index].propertyFlags
	if .HOST_COHERENT in flags do flush_needed = false
	if .HOST_VISIBLE in flags {
		result := vk.MapMemory(init.device.handle, block.handle, vk.DeviceSize(res.offset), vk.DeviceSize(res.data_size), nil, &ptr)
		if result != .SUCCESS do return


		_flush_size = vk.DeviceSize(res.data_size)
		_flush_offset = vk.DeviceSize(res.offset)
		_handle = block.handle
		ok = true
		return
	}

	return
}

draw_frame :: proc(init: ^Core_Vk_State, frame: ^Dynamic_Vk_State, window_handle: rawptr, frame_index: int, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (present_result: vk.Result) {
	assert(init != nil && frame != nil && window_handle != nil && frame_index >= 0)

	SEM_CAP :: 2
	Wait_Semaphores :: sa.Small_Array(SEM_CAP, vk.Semaphore)

	VK_NULL_HANDLE :: 0
	can_record_frame_sync := frame.sync[frame_index].can_record_frame
	img_available := frame.sync[frame_index].img_available

	wait_sem: Wait_Semaphores
	sa.append(&wait_sem, img_available)

	wait_stages := [SEM_CAP]vk.PipelineStageFlags{
		{.COLOR_ATTACHMENT_OUTPUT},
		{.VERTEX_INPUT}
	}

	// Add semaphore to the first frame that encounters the change, to halt execution til data is ready to read
	if frame.staging.gpu_wait_for_data {
		sa.append(&wait_sem, frame.staging.sem)
		frame.staging.gpu_wait_for_data = false
	}

	vk.WaitForFences(init.device.handle, 1, &can_record_frame_sync, true, VK_TIMEOUT_MAX)
	if frame_index == 0 do vk.WaitForFences(init.device.handle, 1, &frame.staging.fence, true, VK_TIMEOUT_MAX)


	img_index: u32
	res := vk.AcquireNextImageKHR(init.device.handle, init.swapchain.handle, VK_TIMEOUT_MAX, img_available, VK_NULL_HANDLE, &img_index)
	#partial switch res {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR:
		recreate_swapchain(init, window_handle, allocator, callbacks)
		return
	case .SUBOPTIMAL_KHR: log.warn("Aquire next image reports suboptimal")
	case: log.panicf("Image acquiring failure: %v", res)
	}


	rendered := frame.swap_img_renderer[img_index]


	vk.ResetFences(init.device.handle, 1, &can_record_frame_sync)

	frame_commands := frame.graphics_commands[frame_index]
	assert(len(frame_commands.buffers) >= 1)

	cmd_buffer := frame_commands.buffers[0]

	clear := vk.ClearValue{
		color = vk.ClearColorValue{float32 = VK_WHITE_COLOR},
	}
	beg_info := vk.RenderPassBeginInfo{
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = init.render_passes.main_render_pass,
		framebuffer = init.framebuffers.swapchain[img_index],
		clearValueCount = 1,
		pClearValues = &clear,
		renderArea = {extent = init.swapchain.image_extent, offset = {0, 0}}
	}

	uber := vk.MemoryBarrier{
	sType = .MEMORY_BARRIER,
	srcAccessMask = {.TRANSFER_WRITE, .HOST_WRITE},
	dstAccessMask = {.VERTEX_ATTRIBUTE_READ, .INDEX_READ, .UNIFORM_READ}
	}

	offset: vk.DeviceSize = 0

	begin_command_buffer(cmd_buffer)
	vk.CmdBindVertexBuffers(cmd_buffer, 0, 1, &frame.vertex.handle.(vk.Buffer), &offset)
	vk.CmdBindPipeline(cmd_buffer, .GRAPHICS, init.pipelines.triangle.handle)
	vk.CmdPipelineBarrier(cmd_buffer, {.ALL_COMMANDS}, {.ALL_COMMANDS}, {}, 1, &uber, 0, nil, 0, nil)
	vk.CmdBeginRenderPass(cmd_buffer, &beg_info, .INLINE)
	vk.CmdDraw(cmd_buffer, 3, 1, 0, 0)
	vk.CmdEndRenderPass(cmd_buffer)
	end_command_buffer(cmd_buffer)

	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &rendered,
		waitSemaphoreCount = u32(sa.len(wait_sem)),
		pWaitSemaphores = raw_data(sa.slice(&wait_sem)),
		pWaitDstStageMask = raw_data(wait_stages[:]),
	}

	res = vk.QueueSubmit(init.device.graphics, 1, &submit_info, frame.sync[frame_index].can_record_frame)
	if res != .SUCCESS do log.panicf("Queue submition failure: %v", res)

	present_info := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &rendered,
		swapchainCount = 1,
		pSwapchains = &init.swapchain.handle,
		pImageIndices = &img_index,
	}

	return vk.QueuePresentKHR(init.device.graphics, &present_info)
}

create_frame_sync :: proc(init: ^Core_Vk_State, state: ^Dynamic_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Frame_Sync in state.resources_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Frame_Sync)

	fif := get_engine_configuration().settings.Frames_In_Flight

	state.sync = make([]Frame_Sync, fif, allocator)
	defer if !success do delete(state.sync, allocator)

	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	// used to track which ones are created if we need to exit when error occured, so it can be destroyed correctly
	fence_tracker := make([dynamic]vk.Fence, len(state.sync), temp_allocator)
	defer delete(fence_tracker)
	defer if !success do for f in fence_tracker do vk.DestroyFence(init.device.handle, f, callbacks)

	for i in 0 ..< fif {
		result := vk.CreateFence(init.device.handle, &fence_create_info, callbacks, &state.sync[i].can_record_frame)
		if result != .SUCCESS {
			log.errorf("Fence creation error: %v", result)
			return false
		} else do append(&fence_tracker, state.sync[i].can_record_frame)
	}

	semaphore_create_info := vk.SemaphoreCreateInfo{ sType = .SEMAPHORE_CREATE_INFO, }

	// same as fence tracker, but just for semaphores
	sem_tracker := make([dynamic]vk.Semaphore, len(state.sync), temp_allocator)
	defer delete(sem_tracker)
	defer if !success do for s in sem_tracker do vk.DestroySemaphore(init.device.handle, s, callbacks)

	for i in 0 ..< fif {
		result := vk.CreateSemaphore(init.device.handle, &semaphore_create_info, callbacks, &state.sync[i].img_available)
		if result != .SUCCESS {
			log.errorf("Semaphore creation error: %v", result)
			return false
		} else do append(&sem_tracker, state.sync[i].img_available)
	}
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization resources created")

	assert(len(init.swapchain.images) > 0)
	state.swap_img_renderer = make([]vk.Semaphore, len(init.swapchain.images), allocator)
	defer if !success do delete(state.swap_img_renderer, allocator)
	for i in 0 ..< len(init.swapchain.images) {
		res := vk.CreateSemaphore(init.device.handle, &semaphore_create_info, callbacks, &state.swap_img_renderer[i])
		if res != .SUCCESS {
			for j in 0 ..< i {
				vk.DestroySemaphore(init.device.handle, state.swap_img_renderer[j], callbacks)
			}
			return false
		}
	}

	set_resource_flag(&state.resources_flags, Frame_Resource_Flag.Frame_Sync)

	return true
}

cleanup_frame_sync :: proc(init: ^Core_Vk_State, state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Frame_Sync not_in state.resources_flags {
		log_called_when_resource_unset(#procedure, Frame_Resource_Flag.Frame_Sync)
		return
	}

	for s in state.sync {
		vk.DestroySemaphore(init.device.handle, s.img_available, callbacks)
		vk.DestroyFence(init.device.handle, s.can_record_frame, callbacks)
	}

	for sem in state.swap_img_renderer {
		vk.DestroySemaphore(init.device.handle, sem, callbacks)
	}
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization resources destroyed")

	delete(state.swap_img_renderer, allocator)
	delete(state.sync, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization memory freed")

	unset_resource_flag(&state.resources_flags, Frame_Resource_Flag.Frame_Sync)
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization cleaned up")
}

create_command_resources :: proc(init_state: ^Core_Vk_State, frame_state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Command in frame_state.resources_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Command)
	fif := get_all_settings().Frames_In_Flight

	frame_state.graphics_commands = make([]Command_State, fif, allocator)
	defer if !success do delete(frame_state.graphics_commands, allocator)

	// For now, we're just gonna use graphics queue only
	//TODO: get advantage of async queues if they're available
	pool_create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = u32(init_state.physical_devices.active.queue_indexes.graphics),
		flags = {.RESET_COMMAND_BUFFER},
	}

	for &state, i in frame_state.graphics_commands {
		result := vk.CreateCommandPool(init_state.device.handle, &pool_create_info, callbacks, &state.pool)
		if result != .SUCCESS {
			log.errorf("Command pool creation failure: %v", result)
			return false
		}

		defer if !success {
			vk.DestroyCommandPool(init_state.device.handle, state.pool, callbacks)
			for j in 0 ..< i {
				vk.DestroyCommandPool(init_state.device.handle, frame_state.graphics_commands[j].pool, callbacks)
				delete(frame_state.graphics_commands[j].buffers)
			}
		}

		state.buffers = make([dynamic]vk.CommandBuffer, 1, allocator)
		defer if !success do delete(state.buffers)

		alloc_info := vk.CommandBufferAllocateInfo{
			sType = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandBufferCount = 1,
			commandPool = state.pool,
			level = .PRIMARY,
		}

		result = vk.AllocateCommandBuffers(init_state.device.handle, &alloc_info, &state.buffers[0])
		if result != .SUCCESS {
			log.errorf("Command buffer allocation failure: %v", result)
			return false
		}

		success = true
	}
	when CONFIG_VERBOSE_LOG do log.debug("Command resources created")


	set_resource_flag(&frame_state.resources_flags, Frame_Resource_Flag.Command)
	return true
}

cleanup_command_resources :: proc(init_state: ^Core_Vk_State, frame_state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Command not_in frame_state.resources_flags do log_called_when_resource_unset(#procedure, Frame_Resource_Flag.Command)
	for state in frame_state.graphics_commands {
		delete(state.buffers)
		vk.DestroyCommandPool(init_state.device.handle, state.pool, callbacks)
	}

	delete(frame_state.graphics_commands, allocator)

	when CONFIG_VERBOSE_LOG do log.debug("Command resources cleaned up")

	unset_resource_flag(&frame_state.resources_flags, Frame_Resource_Flag.Command)
}

begin_command_buffer :: proc(buff: vk.CommandBuffer) -> (success: bool) {
	beg_info := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT}
	}
	result := vk.BeginCommandBuffer(buff, &beg_info)
	if result != .SUCCESS {
		log.errorf("Command buffer begin failure: %v", result)
		return false
	} else do return true
}

end_command_buffer :: proc(buff: vk.CommandBuffer) -> (success: bool) {
	result := vk.EndCommandBuffer(buff)
	if result != .SUCCESS {
		log.errorf("Command buffer ending failure: %v", result)
		return false
	} else do return true
}


create_buffers :: proc(init: ^Core_Vk_State, memory: ^GPU_Memory_State) -> (staging: Staging_Buffer, vertex: Buffer) {
	ok: bool
	staging, ok = create_staging(init, manager)
	assert(ok)

	vertex, ok = create_vertex(init, manager)
	assert(ok)

	return
}

cleanup_buffers :: proc(stat: ^Core_Vk_State, memory: ^GPU_Memory_State, dyn: ^Dynamic_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	destroy_staging(stat, dyn, manager, dyn.staging.id, callbacks)
	destroy_vertex(stat, manager, dyn.vertex.id, callbacks)
}

create_staging :: proc(init: ^Core_Vk_State, manager: ^GPU_Memory_Manager, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (staging: Staging_Buffer, ok: bool) {
	staging.handle = vk.Buffer{}
	idx: int
	block: GPU_Memory_Block
	for b, i in manager.blocks {
		if b.type == .STAGING {
			idx = i
			block = b
		}
	}
	info := GPU_Resource_Create_Info{
		buffer = {
			sType = .BUFFER_CREATE_INFO,
			usage = {.TRANSFER_SRC, .TRANSFER_DST},
			size = vk.DeviceSize(block.size),
			sharingMode = .EXCLUSIVE,
		}
	}
	res_id, err, handle_created := gpu_create_resource_raw(init, manager, .Vertex_Buffer, &staging.handle, &info, nil, idx, callbacks = callbacks)
	defer if !ok && handle_created {
		vk.DestroyBuffer(init.device.handle, staging.handle.(vk.Buffer), callbacks)
	}
	if err != nil do return
	staging.id = res_id

	res := vk.MapMemory(init.device.handle, block.handle, 0, vk.DeviceSize(block.size), nil,  &staging.ptr)
	if res != .SUCCESS do return
	defer if !ok do vk.UnmapMemory(init.device.handle, block.handle)

	fence_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	res = vk.CreateFence(init.device.handle, &fence_info, callbacks, &staging.fence)
	if res != .SUCCESS do return

	sem_info := vk.SemaphoreCreateInfo{
		sType = .SEMAPHORE_CREATE_INFO,
	}
	res = vk.CreateSemaphore(init.device.handle, &sem_info, callbacks, &staging.sem)
	if res != .SUCCESS do return

	ok = true
	return
}

destroy_staging :: proc(init: ^Core_Vk_State, frame: ^Dynamic_Vk_State, manager: ^GPU_Memory_Manager, id: GPU_Resource_Identifier, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	res := manager.resources[id]
	block := manager.blocks[res.data.independent.block_index]

	vk.UnmapMemory(init.device.handle, block.handle)
	vk.DestroyFence(init.device.handle, frame.staging.fence, callbacks)
	vk.DestroySemaphore(init.device.handle, frame.staging.sem, callbacks)
	gpu_destroy_resource_raw(init, manager, id, callbacks)
}

create_vertex :: proc(init: ^Core_Vk_State, manager: ^GPU_Memory_Manager, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (vertex: Buffer, ok: bool) {
	vertex.handle = vk.Buffer{}
	idx: int
	block: GPU_Memory_Block
	for b, i in manager.blocks {
		if b.type == .VRAM {
			idx = i
			block = b
		}
	}
	info := GPU_Resource_Create_Info{
		buffer = {
			sType = .BUFFER_CREATE_INFO,
			usage = {.TRANSFER_SRC, .TRANSFER_DST, .VERTEX_BUFFER},
			size = size_of([3]Triangle_Vertex),
			sharingMode = .EXCLUSIVE,
		}
	}
	res_id, err, handle_created := gpu_create_resource_raw(init, manager, .Vertex_Buffer, &vertex.handle, &info, nil, idx, callbacks = callbacks)
	if err != nil {
		log.warnf("Vertex creation failed: %v", err)
		vk.DestroyBuffer(init.device.handle, vertex.handle.(vk.Buffer), callbacks)
		return
	}
	vertex.id = res_id

	ok = true
	return
}

destroy_vertex :: proc(init: ^Core_Vk_State, manager: ^GPU_Memory_Manager, id: GPU_Resource_Identifier, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	gpu_destroy_resource_raw(init, manager, id, callbacks)
}
