package engine

import "core:log"
import "core:slice"

import vk "vendor:vulkan"

Triangle_Vertex :: struct {
	position: [2]f32,
	_padding: [2]f32,
	color: [4]f32,
}

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

/*
TODO: Implement
Cmd_Buffer :: struct {
	handle: vk.CommandBuffer,
	state: Cmd_Buffer_State,
	usage: Cmd_Buffer_Usage,
}
*/

Frame_Resource_Flag :: enum {
	Frame_Sync,
	Command,
}

Frame_Resources_Flags :: bit_set[Frame_Resource_Flag]

Dynamic_Vk_State :: struct {
	sync: []Frame_Sync,
	graphics_commands: []Command_State,
	resource_flags: Frame_Resources_Flags,
	vertex: GPU_Resource_Handle,
	staging: Maybe(Staging_Buffer), // Maybe, cause if we've mapped directly (e.g. SoC) we do not use it
}

Frame_Sync :: struct {
	can_record_frame: vk.Fence,
	img_available, render_done: vk.Semaphore
}

Staging_Buffer :: struct {
	handle: GPU_Resource_Handle,
	fence: vk.Fence, // for CPU to know when staging is ready for copy
	sem: vk.Semaphore, // semaphore for queue ownership transfer, e.g. if using async transfer queue
	pool: vk.CommandPool,
	cmd_buff: vk.CommandBuffer,
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

init_frame_resources :: proc(frame: ^Dynamic_Vk_State, init: ^Core_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
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

	frame.vertex = create_vertex_buffer() or_return

	parent := gpu_get_parent_data(frame.vertex)
	log.debugf("Parent: %v", parent)
	if parent.mapped_ptr == nil {
		frame.staging = create_staging_buffer() or_return
	}
	else {
		when CONFIG_VERBOSE_LOG do log.info("Detected vertex buffer located in mapped memory, omitting staging buffer creation")
		frame.staging = nil
	}

	when CONFIG_VERBOSE_LOG do log.debug("Frame initalization successful")
	return
}

cleanup_frame_resources :: proc(core: ^Core_Vk_State, dyn: ^Dynamic_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	vk.DeviceWaitIdle(core.device.handle)

	cleanup_vertex_buffer(dyn.vertex)
	if s, ok := &dyn.staging.?; ok {
		cleanup_staging_buffer(s, callbacks)
	}
	if .Frame_Sync in dyn.resource_flags do cleanup_frame_sync(core, dyn, allocator, callbacks)
	if .Command in dyn.resource_flags do cleanup_command_resources(core, dyn, allocator, callbacks)
}

draw_frame :: proc(init: ^Core_Vk_State, frame: ^Dynamic_Vk_State, window_handle: rawptr, frame_index: int, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (present_result: vk.Result) {
	assert(init != nil && frame != nil && window_handle != nil && frame_index >= 0)

	VK_NULL_HANDLE :: 0
	can_record_frame_sync := frame.sync[frame_index].can_record_frame
	img_available := frame.sync[frame_index].img_available
	render_done := frame.sync[frame_index].render_done

	wait_sem := []vk.Semaphore{img_available}

	wait_stages := []vk.PipelineStageFlags{
		{.COLOR_ATTACHMENT_OUTPUT},
	}

	vk.WaitForFences(init.device.handle, 1, &can_record_frame_sync, true, VK_TIMEOUT_MAX)

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

	offset: vk.DeviceSize = 0
	assert(validate_handle(frame.vertex))
	vertex := gpu_get_resource_from_handle(frame.vertex).(vk.Buffer)

	vk.DeviceWaitIdle(init.device.handle)
	begin_command_buffer(cmd_buffer)
	vk.CmdBindVertexBuffers(cmd_buffer, 0, 1, &vertex, &offset)
	vk.CmdBindPipeline(cmd_buffer, .GRAPHICS, init.pipelines.triangle.handle)
	vk.CmdBeginRenderPass(cmd_buffer, &beg_info, .INLINE)
	vk.CmdDraw(cmd_buffer, 3, 1, 0, 0)
	vk.CmdEndRenderPass(cmd_buffer)
	end_command_buffer(cmd_buffer)

	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &render_done,
		waitSemaphoreCount = u32(len(wait_sem)),
		pWaitSemaphores = raw_data(wait_sem),
		pWaitDstStageMask = raw_data(wait_stages),
	}

	res = vk.QueueSubmit(init.device.graphics, 1, &submit_info, frame.sync[frame_index].can_record_frame)
	if res != .SUCCESS do log.panicf("Queue submition failure: %v", res)

	present_info := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &render_done,
		swapchainCount = 1,
		pSwapchains = &init.swapchain.handle,
		pImageIndices = &img_index,
	}

	return vk.QueuePresentKHR(init.device.graphics, &present_info)
}

create_frame_sync :: proc(init: ^Core_Vk_State, state: ^Dynamic_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Frame_Sync in state.resource_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Frame_Sync)

	fif := get_engine_configuration().settings.Frames_In_Flight

	state.sync = make([]Frame_Sync, fif, allocator)
	defer if !success do delete(state.sync, allocator)

	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	sem_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}

	for i in 0 ..< fif {
		result := vk.CreateSemaphore(init.device.handle, &sem_info, callbacks, &state.sync[i].img_available)
		if result != .SUCCESS {
			log.panicf("Image available semaphore creation failure: %v", result)
		}

		result = vk.CreateSemaphore(init.device.handle, &sem_info, callbacks, &state.sync[i].render_done)
		if result != .SUCCESS {
			log.panicf("Render done semaphore creation failure: %v", result)
		}

		result = vk.CreateFence(init.device.handle, &fence_create_info, callbacks, &state.sync[i].can_record_frame)
		if result != .SUCCESS {
			log.panicf("Can record frame fence creation failure: %v", result)
		}
	}

	set_resource_flag(&state.resource_flags, Frame_Resource_Flag.Frame_Sync)

	return true
}

cleanup_frame_sync :: proc(init: ^Core_Vk_State, state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Frame_Sync not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Frame_Resource_Flag.Frame_Sync)
		return
	}

	for s in state.sync {
		vk.DestroySemaphore(init.device.handle, s.img_available, callbacks)
		vk.DestroySemaphore(init.device.handle, s.render_done, callbacks)
		vk.DestroyFence(init.device.handle, s.can_record_frame, callbacks)
	}
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization resources destroyed")

	delete(state.sync, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization memory freed")

	unset_resource_flag(&state.resource_flags, Frame_Resource_Flag.Frame_Sync)
	when CONFIG_VERBOSE_LOG do log.debug("Frame synchronization cleaned up")
}

create_command_resources :: proc(init_state: ^Core_Vk_State, frame_state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Command in frame_state.resource_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Command)
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


	set_resource_flag(&frame_state.resource_flags, Frame_Resource_Flag.Command)
	return true
}

cleanup_command_resources :: proc(init_state: ^Core_Vk_State, frame_state: ^Dynamic_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Command not_in frame_state.resource_flags do log_called_when_resource_unset(#procedure, Frame_Resource_Flag.Command)
	for state in frame_state.graphics_commands {
		delete(state.buffers)
		vk.DestroyCommandPool(init_state.device.handle, state.pool, callbacks)
	}

	delete(frame_state.graphics_commands, allocator)

	when CONFIG_VERBOSE_LOG do log.debug("Command resources cleaned up")

	unset_resource_flag(&frame_state.resource_flags, Frame_Resource_Flag.Command)
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

create_vertex_buffer :: proc() -> (handle: GPU_Resource_Handle, success: bool) {
	h, err := gpu_create(.Vertex_Buffer, .Static, 128, VRAM_FLAGS, false)
	if err != nil {
		log.errorf("Vertex buffer creation failure: %v", err)
		return
	}

	return h, true
}

cleanup_vertex_buffer :: proc(handle: GPU_Resource_Handle) {
	err := gpu_destroy(handle)
	if err != nil {
		log.errorf("Vertex buffer cleanup failure, possible leaks: %v", err)
	}
}

create_staging_buffer :: proc(callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (staging: Staging_Buffer, success: bool) {
	//TODO: Implement general staging buffer instead of using .Vertex_Buffer
	h, err := gpu_create(.Vertex_Buffer, .Static, 128, STAGING_FLAGS, true)
	if err != nil {
		log.errorf("Staging buffer creation failure: %v", err)
		return
	}

	defer if !success {
	 	gpu_destroy(h)
	}
	staging.handle = h

	c := get_global_state().renderer.core

	pool_create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = u32(c.physical_devices.active.queue_indexes.graphics), // TODO: Change this to use dedicated transfer if available
		flags = {}, // We do not need resetting individual command buffers
	}
	pool: vk.CommandPool
	result := vk.CreateCommandPool(c.device.handle, &pool_create_info, callbacks, &pool)
	if result != .SUCCESS {
		log.errorf("Command pool for staging buffer creation failure: %v", result)
		return
	}

	defer if !success {
		vk.DestroyCommandPool(c.device.handle, pool, callbacks)
	}
	staging.pool = pool

	cmd_alloc_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandBufferCount = 1,
		commandPool = pool,
		level = .PRIMARY,
	}
	cmd_buffer: vk.CommandBuffer
	result = vk.AllocateCommandBuffers(c.device.handle, &cmd_alloc_info, &cmd_buffer)
	if result != .SUCCESS {
		log.errorf("Alocation of command buffer from staging buffer pool failure: %v", result)
		return
	}
	staging.cmd_buff = cmd_buffer

	sem_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	sem: vk.Semaphore
	result = vk.CreateSemaphore(c.device.handle, &sem_info, callbacks, &sem)
	if result != .SUCCESS {
		log.errorf("Staging buffer semaphore creation failure: %v", result)
	}
	defer if !success {
		vk.DestroySemaphore(c.device.handle, sem, callbacks)
	}
	staging.sem = sem

	fence_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED}
	}
	fence: vk.Fence
	result = vk.CreateFence(c.device.handle, &fence_info, callbacks, &fence)
	if result != .SUCCESS {
		log.errorf("Staging buffer fence creation failure: %v", result)
		return
	}
	staging.fence = fence

	return staging, true
}

cleanup_staging_buffer :: proc(staging: ^Staging_Buffer, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	err := gpu_destroy(staging.handle)
	if err != nil {
		log.errorf("Staging buffer cleanup failure: %v", err)
	}

	device := get_global_state().renderer.core.device.handle

	vk.DestroyCommandPool(device, staging.pool, callbacks)
	vk.DestroyFence(device, staging.fence, callbacks)
	vk.DestroySemaphore(device, staging.sem, callbacks)
}
