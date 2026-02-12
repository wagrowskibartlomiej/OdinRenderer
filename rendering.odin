package render

import "core:log"
import "core:slice"

import vk "vendor:vulkan"

Render_Passes_State :: struct {
	main_render_pass: vk.RenderPass
}

Pipelines_State :: struct {
	traingle: Pipeline_State,
}

Pipeline_State :: struct {
	handle: vk.Pipeline,
	layout: vk.PipelineLayout,
	cache: vk.PipelineCache,
	vertex_module,
	fragment_module: vk.ShaderModule,
}

Commands_State :: struct {

}


Frame_Resource_Flag :: enum {
	Frame_Sync
}

Frame_Resources_Flags :: bit_set[Frame_Resource_Flag]

Frame_State :: struct {
	sync: []Frame_Sync,
	command: Commands_State,
	resources_flags: Frame_Resources_Flags,
}

Frame_Sync :: struct {
	frame_done: vk.Fence,
	render_done: vk.Semaphore,
	image_available: vk.Semaphore,
}

create_render_passes :: proc(state: ^Vulkan_Init_State, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	if .Render_Passes in state.resource_flags do log.warn("Called render pass creation while resource flag is set, possible error")

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
		storeOp = .DONT_CARE,
		format = state.swapchain.image_format.format,
		samples = {._1},
		initialLayout = .UNDEFINED,
	}

	dependency := vk.SubpassDependency{
		srcSubpass = vk.SUBPASS_EXTERNAL,
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
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
	when VERBOSE_LOG do log.debug("Render passes created")

	state.resource_flags |= {.Render_Passes}
	when VERBOSE_LOG do log.debug("Render passes resource flag set")

	success = true
	return
}

cleanup_renderer_passes :: proc(state: ^Vulkan_Init_State, callbacks: ^vk.AllocationCallbacks = nil) {
	if .Render_Passes not_in state.resource_flags {
		log.warn("Called render passes cleanup when resource flag is unset")
		return
	}

	vk.DestroyRenderPass(state.device.handle, state.render_passes.main_render_pass, callbacks)
	when VERBOSE_LOG do log.debug("Render passes destroyed")

	state.resource_flags &~= {.Render_Passes}
	when VERBOSE_LOG do log.debug("Render passes resource flag unset")
}

create_graphics_pipelines :: proc(state: ^Vulkan_Init_State, ass_state: ^Assets_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	if .Pipelines in state.resource_flags do log.warn("Called pipelines creation when resource flag is set, possible error")

	vertex, vertex_present := get_asset_memory(ass_state, .Shader, "default_vertex.spv", "spirv")
	if !vertex_present {
		log.error("Cannot create graphics pipelines: Missing vertex shader memory in assets pool")
		return
	}


	fragment, fragment_present := get_asset_memory(ass_state, .Shader, "default_fragment.spv", "spirv")
	if !fragment_present {
		log.error("Cannot create graphics pipelines: Missing vertex shader memory in assets pool")
		return
	}

	vertex_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		pCode = raw_data(vertex.([]u32)),
		codeSize = slice.size(vertex.([]u32)),
	}

	result := vk.CreateShaderModule(state.device.handle, &vertex_shader_create_info, callbacks, &state.pipelines.traingle.vertex_module)
	if result != .SUCCESS {
		log.errorf("Vertex shader module creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyShaderModule(state.device.handle, state.pipelines.traingle.vertex_module, callbacks)

	fragment_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		pCode = raw_data(fragment.([]u32)),
		codeSize = slice.size(fragment.([]u32)),
	}

	result = vk.CreateShaderModule(state.device.handle, &fragment_shader_create_info, callbacks, &state.pipelines.traingle.fragment_module)
	if result != .SUCCESS {
		log.errorf("Fragment shader module creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyShaderModule(state.device.handle, state.pipelines.traingle.fragment_module, callbacks)

	vertex_stage_create_info := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = state.pipelines.traingle.vertex_module,
		pName = "main",
		stage = {.VERTEX},
	}

	fragment_stage_create_info := vk.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = state.pipelines.traingle.fragment_module,
		pName = "main",
		stage = {.FRAGMENT},
	}

	stages := [?]vk.PipelineShaderStageCreateInfo{
		vertex_stage_create_info,
		fragment_stage_create_info,
	}

	attribute_desc := vk.VertexInputAttributeDescription{
	}
	binding_desc := vk.VertexInputBindingDescription{
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexAttributeDescriptions = &attribute_desc,
		vertexAttributeDescriptionCount = 1,
		pVertexBindingDescriptions = &binding_desc,
		vertexBindingDescriptionCount = 1
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_STRIP,
		primitiveRestartEnable = false,
	}

	tessellation := vk.PipelineTessellationStateCreateInfo{
		sType = .PIPELINE_TESSELLATION_STATE_CREATE_INFO,
	}

	viewport := vk.Viewport{
		minDepth = 0,
		maxDepth = 1,
		width = f32(state.swapchain.image_extent.width),
		height = f32(state.swapchain.image_extent.height),
	}
	scissors := vk.Rect2D{
		extent = state.swapchain.image_extent,
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
		rasterizerDiscardEnable = true,
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

	layout_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	result = vk.CreatePipelineLayout(state.device.handle, &layout_info, callbacks, &state.pipelines.traingle.layout)
	if result != .SUCCESS {
		log.errorf("Pipeline layout creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyPipelineLayout(state.device.handle, state.pipelines.traingle.layout, callbacks)

	depth := vk.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = false,
	}

	blend := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	}
	

	pipeline_create_info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pStages = raw_data(&stages),
		stageCount = u32(len(stages)),
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pTessellationState = &tessellation,
		pViewportState = &viewport_state, 
		pRasterizationState = &rasterization,
		pMultisampleState = &multisample,
		pDepthStencilState = &depth,
		pColorBlendState = &blend, 
		renderPass = state.render_passes.main_render_pass,
		subpass = 0,
		layout = state.pipelines.traingle.layout,
	}

	NO_CACHE : vk.PipelineCache : {}
	result = vk.CreateGraphicsPipelines(state.device.handle, NO_CACHE, 1, &pipeline_create_info, callbacks, &state.pipelines.traingle.handle)
	if result != .SUCCESS {
		log.errorf("Graphics pipelines creation fail: %v", result)
		return
	}
	when VERBOSE_LOG do log.debug("Graphics pipelines created")

	state.resource_flags |= {.Pipelines}
	when VERBOSE_LOG do log.debug("Graphics pipelines resource flag set")

	success = true
	return
}

cleanup_graphics_pipelines :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) {
	if .Pipelines not_in state.resource_flags {
		log.warn("Called graphics pipelines cleanup when resource flag is unset")
		return
	}

	vk.DestroyPipeline(state.device.handle, state.pipelines.traingle.handle, callbacks)
	when VERBOSE_LOG do log.debug("Graphics pipelines destroyed")

	vk.DestroyPipelineLayout(state.device.handle, state.pipelines.traingle.layout, callbacks)
	when VERBOSE_LOG do log.debug("Pipeline layout destroyed")

	vk.DestroyShaderModule(state.device.handle, state.pipelines.traingle.vertex_module, callbacks)
	when VERBOSE_LOG do log.debug("Vertex shader module destroyed")

	vk.DestroyShaderModule(state.device.handle, state.pipelines.traingle.fragment_module, callbacks)
	when VERBOSE_LOG do log.debug("Fragment shader module destroyed")

	state.resource_flags &~= {.Pipelines}
	when VERBOSE_LOG do log.debug("Pipelines resource flag unset")
}

init_frame :: proc(init: ^Vulkan_Init_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (state: Frame_State) { 
	success := create_frame_sync(init, &state, allocator, temp_allocator, callbacks)
	if !success {
		log.fatal("Frame synchronization creation failed")
		return
	}

	when VERBOSE_LOG do log.debug("Frame initalization successful")
	return
}

cleanup_frame :: proc(init: ^Vulkan_Init_State, state: ^Frame_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) { 
	if .Frame_Sync in state.resources_flags do cleanup_frame_sync(init, state, allocator, callbacks)
}

draw_frame :: proc(init: ^Vulkan_Init_State, state: ^Frame_Sync) {
	
}

create_frame_sync :: proc(init: ^Vulkan_Init_State, state: ^Frame_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	if .Frame_Sync in state.resources_flags do log.warn("Called frame synchronization creation when resource flag is set, possible error")

	state.sync = make([]Frame_Sync, FRAMES_IN_FLIGHT, allocator)
	defer if !success do delete(state.sync, allocator)

	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	// used to track which ones are created if we need to exit when error occured, so it can be destroyed correctly
	fence_tracker := make([dynamic]vk.Fence, len(state.sync), temp_allocator)
	defer delete(fence_tracker)
	defer if !success do for f in fence_tracker do vk.DestroyFence(init.device.handle, f, callbacks)

	for i in 0 ..< FRAMES_IN_FLIGHT {
		result := vk.CreateFence(init.device.handle, &fence_create_info, callbacks, &state.sync[i].frame_done)
		if result != .SUCCESS {
			log.errorf("Fence creation error: %v", result)
			return
		} else do append(&fence_tracker, state.sync[i].frame_done)
	}
	
	semaphore_create_info := vk.SemaphoreCreateInfo{ sType = .SEMAPHORE_CREATE_INFO, }

	// same as fence tracker, but just for semaphores
	sem_tracker := make([dynamic]vk.Semaphore, len(state.sync), temp_allocator)
	defer delete(sem_tracker)
	defer if !success do for s in sem_tracker do vk.DestroySemaphore(init.device.handle, s, callbacks)

	for i in 0 ..< FRAMES_IN_FLIGHT {
		result := vk.CreateSemaphore(init.device.handle, &semaphore_create_info, callbacks, &state.sync[i].image_available)
		if result != .SUCCESS {
			log.errorf("Semaphore creation error: %v", result)
			return
		} else do append(&sem_tracker, state.sync[i].image_available)

		result = vk.CreateSemaphore(init.device.handle, &semaphore_create_info, callbacks, &state.sync[i].render_done)
		if result != .SUCCESS {
			log.errorf("Semaphore creation error: %v", result)
			return
		} else do append(&sem_tracker, state.sync[i].render_done)
	}


	state.resources_flags |= {.Frame_Sync}
	when VERBOSE_LOG do log.debug("Frame synchronization resource flag set")

	success = true
	return
}

cleanup_frame_sync :: proc(init: ^Vulkan_Init_State, state: ^Frame_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) {
	if .Frame_Sync not_in state.resources_flags {
		log.warn("Called frame synchronization cleanup when resource flag is unset, possible error")
		return
	}

	for s in state.sync {
		vk.DestroySemaphore(init.device.handle, s.image_available, callbacks)
		vk.DestroySemaphore(init.device.handle, s.render_done, callbacks)
		vk.DestroyFence(init.device.handle, s.frame_done, callbacks)
	}
	when VERBOSE_LOG do log.debug("Frame synchronization destroyed")

	delete(state.sync, allocator)
	when VERBOSE_LOG do log.debug("Frame synchronization cleaned up")

	state.resources_flags &~= {.Frame_Sync}
	when VERBOSE_LOG do log.debug("Frame synchronization resource flag unset")
}

create_command_resources :: proc() {

}
