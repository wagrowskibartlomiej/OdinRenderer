package engine

import "core:log"
import "core:mem"
import "core:slice"

import "core:math/linalg/glsl"
import vk "vendor:vulkan"

Render_Pass_Kind :: enum {
	Triangle,
	Default_Mesh,
}

Graphics_Pipeline_Kind :: enum {
	Triangle,
	Default_Mesh,
}
Pipeline_Layout_Kind :: enum {
	Basic,
	Default_Mesh,
}
Shader_Kind :: enum {
	Triangle_Vertex,
	Triangle_Fragment,
	Default_Mesh_Vertex,
	Default_Mesh_Fragment,
}

Render_Passes_State :: struct {
	handles: [Render_Pass_Kind]vk.RenderPass,
}

Shaders_State :: struct {
	modules: [Shader_Kind]vk.ShaderModule,
}

Pipelines_State :: struct {
	datas:   [Graphics_Pipeline_Kind]Pipeline_Data,
	layouts: [Pipeline_Layout_Kind]vk.PipelineLayout,
	cache:   vk.PipelineCache,
}

Pipeline_Data :: struct {
	handle: vk.Pipeline,
	flags:  Pipeline_Data_Flags,
}

Pipeline_Data_Flag :: enum {
	Dynamic_Viewport,
}
Pipeline_Data_Flags :: bit_set[Pipeline_Data_Flag]

//TODO: Command State and command resource creation needs to be changed, but for now it's in the simplest form
Command_State :: struct {
	pool:    vk.CommandPool,
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
	sync:              []Frame_Sync,
	graphics_commands: []Command_State,
	resource_flags:    Frame_Resources_Flags,
	vertex:            GPU_Resource_Handle,
	index:             GPU_Resource_Handle,
	staging:           Staging_Buffer, // We need it for images transformation
}

Frame_Sync :: struct {
	can_record_frame:           vk.Fence,
	img_available, render_done: vk.Semaphore,
}

Staging_Buffer :: struct {
	handle:   GPU_Resource_Handle,
	fence:    vk.Fence, // for CPU to know when staging is ready for copy
	sem:      vk.Semaphore, // semaphore for queue ownership transfer, e.g. if using async transfer queue
	pool:     vk.CommandPool,
	cmd_buff: vk.CommandBuffer,
	flags:    Staging_Buffer_Flags,
}

Staging_Buffer_Flag :: enum {
	Vertex_Updated,
	Index_Updated,
	Dont_Wait_Fence, // error occured and fence cannot be signaled, do not wait for fence next time when using staging buffer
}
Staging_Buffer_Flags :: bit_set[Staging_Buffer_Flag]

VK_TIMEOUT_MAX :: max(u64)
VK_WHITE_COLOR :: [4]f32{1, 1, 1, 1}
VK_SKY_BLUE_COLOR :: [4]f32{0.53, 0.81, 0.98, 1.0}

create_render_passes :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	if .Render_Passes in core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Render_Passes)

	core.render_passes.handles[.Triangle] = create_triangle_render_pass(
		core.device.handle,
		core.swapchain.image_format.format,
		callbacks,
	) or_return
	core.render_passes.handles[.Default_Mesh] = create_default_mesh_render_pass(
		core.device.handle,
		core.swapchain.image_format.format,
		callbacks,
	) or_return

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Render_Passes)

	success = true
	return
}

create_triangle_render_pass :: proc(
	device: vk.Device,
	format: vk.Format,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	pass: vk.RenderPass,
	success: bool,
) {
	color_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pColorAttachments    = &color_ref,
		colorAttachmentCount = 1,
		pipelineBindPoint    = .GRAPHICS,
	}

	attachment_desc := vk.AttachmentDescription {
		finalLayout   = .PRESENT_SRC_KHR,
		loadOp        = .CLEAR,
		storeOp       = .STORE,
		format        = format,
		samples       = {._1},
		initialLayout = .UNDEFINED,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	render_pass_create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		pSubpasses      = &subpass,
		subpassCount    = 1,
		pAttachments    = &attachment_desc,
		attachmentCount = 1,
		pDependencies   = &dependency,
		dependencyCount = 1,
	}


	result := vk.CreateRenderPass(device, &render_pass_create_info, callbacks, &pass)
	if result != .SUCCESS {
		log.errorf("Render passes creation failed: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Render passes created")

	return pass, true
}

create_default_mesh_render_pass :: proc(
	device: vk.Device,
	format: vk.Format,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	pass: vk.RenderPass,
	success: bool,
) {
	color_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	depth_ref := vk.AttachmentReference {
		attachment = 1,
		layout     = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pColorAttachments       = &color_ref,
		colorAttachmentCount    = 1,
		pipelineBindPoint       = .GRAPHICS,
		pDepthStencilAttachment = &depth_ref,
	}

	descriptions: [2]vk.AttachmentDescription

	descriptions[0] = vk.AttachmentDescription {
		finalLayout   = .PRESENT_SRC_KHR,
		loadOp        = .CLEAR,
		storeOp       = .STORE,
		format        = format,
		samples       = {._1},
		initialLayout = .UNDEFINED,
	}

	descriptions[1] = vk.AttachmentDescription {
		initialLayout  = .UNDEFINED,
		finalLayout    = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		loadOp         = .CLEAR,
		storeOp        = .DONT_CARE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		format         = .D32_SFLOAT,
		samples        = {._1},
	}


	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
	}

	render_pass_create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		pSubpasses      = &subpass,
		subpassCount    = 1,
		pAttachments    = raw_data(descriptions[:]),
		attachmentCount = u32(len(descriptions)),
		pDependencies   = &dependency,
		dependencyCount = 1,
	}


	result := vk.CreateRenderPass(device, &render_pass_create_info, callbacks, &pass)
	if result != .SUCCESS {
		log.errorf("Render passes creation failed: %v", result)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Render passes created")

	return pass, true
}

cleanup_renderer_passes :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	if .Render_Passes not_in core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Render_Passes)
		return
	}

	vk.DestroyRenderPass(core.device.handle, core.render_passes.handles[.Triangle], callbacks)
	vk.DestroyRenderPass(core.device.handle, core.render_passes.handles[.Default_Mesh], callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Render passes destroyed")

	unset_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Render_Passes)
}

create_graphics_pipelines :: proc(
	core: ^Core_Vk_State,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	if .Pipelines in core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Pipelines)

	cache_create_info := vk.PipelineCacheCreateInfo {
		sType = .PIPELINE_CACHE_CREATE_INFO,
	}
	result := vk.CreatePipelineCache(
		core.device.handle,
		&cache_create_info,
		callbacks,
		&core.pipelines.cache,
	)
	if result != .SUCCESS {
		log.errorf("Failed to create pipeline cache")
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	result = vk.CreatePipelineLayout(
		core.device.handle,
		&layout_info,
		callbacks,
		&core.pipelines.layouts[.Basic],
	)
	if result != .SUCCESS {
		log.errorf("Pipeline layout creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyPipelineLayout(core.device.handle, core.pipelines.layouts[.Basic], callbacks)

	push_range := vk.PushConstantRange {
		offset     = 0,
		size       = size_of(glsl.mat4),
		stageFlags = {.VERTEX},
	}

	layout_info.pPushConstantRanges = &push_range
	layout_info.pushConstantRangeCount = 1
	layout_info.pSetLayouts = &core.descriptors.layout
	layout_info.setLayoutCount = 1

	result = vk.CreatePipelineLayout(
		core.device.handle,
		&layout_info,
		callbacks,
		&core.pipelines.layouts[.Default_Mesh],
	)
	if result != .SUCCESS {
		log.errorf("Pipeline layout creation fail: %v", result)
		return
	}
	defer if !success do vk.DestroyPipelineLayout(core.device.handle, core.pipelines.layouts[.Default_Mesh], callbacks)

	core.pipelines.datas[.Triangle].handle = create_triangle_pipeline_internal(
		core.device.handle,
		core.render_passes.handles[.Triangle],
		core.pipelines.layouts[.Basic],
		core.shaders.modules[.Triangle_Vertex],
		core.shaders.modules[.Triangle_Fragment],
		core.swapchain.image_extent,
		core.pipelines.cache,
		false,
		callbacks,
	) or_return

	core.pipelines.datas[.Default_Mesh].handle = create_default_mesh_pipeline_internal(
		core.device.handle,
		core.render_passes.handles[.Default_Mesh],
		core.pipelines.layouts[.Default_Mesh],
		core.shaders.modules[.Default_Mesh_Vertex],
		core.shaders.modules[.Default_Mesh_Fragment],
		core.swapchain.image_extent,
		core.pipelines.cache,
		false,
		callbacks,
	) or_return

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Pipelines)

	success = true
	return
}

create_triangle_pipeline_internal :: proc(
	device: vk.Device,
	pass: vk.RenderPass,
	layout: vk.PipelineLayout,
	vertex, fragment: vk.ShaderModule,
	extent: vk.Extent2D,
	cache: vk.PipelineCache,
	dynamic_viewport: bool,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	vk.Pipeline,
	bool,
) {
	vertex_stage_create_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = vertex,
		pName  = "main",
		stage  = {.VERTEX},
	}

	fragment_stage_create_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = fragment,
		pName  = "main",
		stage  = {.FRAGMENT},
	}

	stages := [?]vk.PipelineShaderStageCreateInfo {
		vertex_stage_create_info,
		fragment_stage_create_info,
	}

	attribute_desc := []vk.VertexInputAttributeDescription {
		{
			location = 0,
			format = .R32G32_SFLOAT,
			offset = cast(u32)offset_of(Triangle_Vertex, position),
		},
		{
			location = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = cast(u32)offset_of(Triangle_Vertex, color),
		},
	}

	binding_desc := vk.VertexInputBindingDescription {
		inputRate = .VERTEX,
		stride    = size_of(Triangle_Vertex),
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexAttributeDescriptions    = raw_data(attribute_desc),
		vertexAttributeDescriptionCount = u32(len(attribute_desc)),
		pVertexBindingDescriptions      = &binding_desc,
		vertexBindingDescriptionCount   = 1,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}


	states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		pDynamicStates    = raw_data(states),
		dynamicStateCount = u32(len(states)),
	}

	viewport := vk.Viewport {
		minDepth = 0,
		maxDepth = 1,
		width    = f32(extent.width),
		height   = f32(extent.height),
	}
	scissors := vk.Rect2D {
		extent = extent,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissors,
	}

	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		rasterizerDiscardEnable = false,
		cullMode                = {},
		polygonMode             = .FILL,
		lineWidth               = 1,
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	depth := vk.PipelineDepthStencilStateCreateInfo {
		sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = false,
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable    = false,
	}

	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		pAttachments    = &blend_attachment,
		attachmentCount = 1,
	}

	pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pStages             = raw_data(stages[:]),
		stageCount          = u32(len(stages)),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pRasterizationState = &rasterization,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth,
		pColorBlendState    = &blend,
		renderPass          = pass,
		subpass             = 0,
		layout              = layout,
		pDynamicState       = &dynamic_info if dynamic_viewport else nil,
		pViewportState      = &viewport_state if !dynamic_viewport else nil,
	}

	pipeline: vk.Pipeline
	result := vk.CreateGraphicsPipelines(
		device,
		cache,
		1,
		&pipeline_create_info,
		callbacks,
		&pipeline,
	)
	if result != .SUCCESS {
		log.errorf("Graphics pipelines creation fail: %v", result)
		return {}, false
	}
	when CONFIG_VERBOSE_LOG do log.debug("Graphics pipelines created")

	return pipeline, true
}

create_default_mesh_pipeline_internal :: proc(
	device: vk.Device,
	pass: vk.RenderPass,
	layout: vk.PipelineLayout,
	vertex, fragment: vk.ShaderModule,
	extent: vk.Extent2D,
	cache: vk.PipelineCache,
	dynamic_viewport: bool,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	vk.Pipeline,
	bool,
) {
	vertex_stage_create_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = vertex,
		pName  = "main",
		stage  = {.VERTEX},
	}

	fragment_stage_create_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		module = fragment,
		pName  = "main",
		stage  = {.FRAGMENT},
	}

	stages := [?]vk.PipelineShaderStageCreateInfo {
		vertex_stage_create_info,
		fragment_stage_create_info,
	}

	attribute_desc := []vk.VertexInputAttributeDescription {
		{
			location = 0,
			format = .R32G32B32_SFLOAT,
			offset = cast(u32)offset_of(Base_Vertex, position),
		},
		{
			location = 1,
			format = .R32G32B32_SFLOAT,
			offset = cast(u32)offset_of(Base_Vertex, normals),
		},
		{location = 2, format = .R32G32_SFLOAT, offset = cast(u32)offset_of(Base_Vertex, uv)},
	}

	binding_desc := vk.VertexInputBindingDescription {
		inputRate = .VERTEX,
		stride    = size_of(Base_Vertex),
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexAttributeDescriptions    = raw_data(attribute_desc),
		vertexAttributeDescriptionCount = u32(len(attribute_desc)),
		pVertexBindingDescriptions      = &binding_desc,
		vertexBindingDescriptionCount   = 1,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		pDynamicStates    = raw_data(states),
		dynamicStateCount = u32(len(states)),
	}

	viewport := vk.Viewport {
		minDepth = 0,
		maxDepth = 1,
		width    = f32(extent.width),
		height   = f32(extent.height),
	}
	scissors := vk.Rect2D {
		extent = extent,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissors,
	}

	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		rasterizerDiscardEnable = false,
		cullMode                = {.BACK},
		polygonMode             = .FILL,
		lineWidth               = 1,
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	depth := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable    = false,
	}

	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		pAttachments    = &blend_attachment,
		attachmentCount = 1,
	}

	pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pStages             = raw_data(stages[:]),
		stageCount          = u32(len(stages)),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pRasterizationState = &rasterization,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth,
		pColorBlendState    = &blend,
		renderPass          = pass,
		subpass             = 0,
		layout              = layout,
		pDynamicState       = &dynamic_info if dynamic_viewport else nil,
		pViewportState      = &viewport_state if !dynamic_viewport else nil,
	}

	pipeline: vk.Pipeline
	result := vk.CreateGraphicsPipelines(
		device,
		cache,
		1,
		&pipeline_create_info,
		callbacks,
		&pipeline,
	)
	if result != .SUCCESS {
		log.errorf("Graphics pipelines creation fail: %v", result)
		return {}, false
	}
	when CONFIG_VERBOSE_LOG do log.debug("Graphics pipelines created")

	return pipeline, true
}

cleanup_graphics_pipelines :: proc(
	state: ^Core_Vk_State,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	if .Pipelines not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Pipelines)
		return
	}

	for pip, kind in state.pipelines.datas {
		vk.DestroyPipeline(state.device.handle, pip.handle, callbacks)
		when CONFIG_VERBOSE_LOG do log.debug("Graphics pipeline '%v' destroyed", kind)
	}

	for lay, kind in state.pipelines.layouts {
		vk.DestroyPipelineLayout(state.device.handle, lay, callbacks)
		when CONFIG_VERBOSE_LOG do log.debugf("Pipeline layout '%v' destroyed", kind)
	}

	vk.DestroyPipelineCache(state.device.handle, state.pipelines.cache, callbacks)

	state.resource_flags &~= {.Pipelines}
	when CONFIG_VERBOSE_LOG do log.debug("Pipelines resource flag unset")
}

init_frame_resources :: proc(
	frame: ^Dynamic_Vk_State,
	init: ^Core_Vk_State,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
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
	frame.index = create_index_buffer() or_return

	frame.staging = create_staging_buffer() or_return

	when CONFIG_VERBOSE_LOG do log.debug("Frame initalization successful")
	return
}

cleanup_frame_resources :: proc(
	core: ^Core_Vk_State,
	dyn: ^Dynamic_Vk_State,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	vk.DeviceWaitIdle(core.device.handle)

	cleanup_vertex_buffer(dyn.index)
	cleanup_vertex_buffer(dyn.vertex)
	cleanup_staging_buffer(dyn.staging, callbacks)

	if .Frame_Sync in dyn.resource_flags do cleanup_frame_sync(core, dyn, allocator, callbacks)
	if .Command in dyn.resource_flags do cleanup_command_resources(core, dyn, allocator, callbacks)
}

draw_frame :: proc(
	core: ^Core_Vk_State,
	dyn: ^Dynamic_Vk_State,
	window_handle: rawptr,
	frame_index: int,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	present_result: vk.Result,
) {
	assert(core != nil && dyn != nil && window_handle != nil && frame_index >= 0)

	VK_NULL_HANDLE :: 0
	can_record_frame_sync := dyn.sync[frame_index].can_record_frame
	img_available := dyn.sync[frame_index].img_available
	render_done := dyn.sync[frame_index].render_done

	wait_sem := []vk.Semaphore{img_available}

	wait_stages := []vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}

	//TODO: Cleanup barriers, make some system that manages them and maybe combine into one vkCmd call and just change passed lenght based on flags?
	// Insert the barrier when staging buffer is in use
	insert_vertex_barrier := true if .Vertex_Updated in dyn.staging.flags else false
	defer if insert_vertex_barrier {
		dyn.staging.flags -= {.Vertex_Updated}
	}

	insert_index_barrier := true if .Index_Updated in dyn.staging.flags else false
	defer if insert_index_barrier {
		dyn.staging.flags -= {.Index_Updated}
	}

	vk.WaitForFences(core.device.handle, 1, &can_record_frame_sync, true, VK_TIMEOUT_MAX)

	img_index: u32
	res := vk.AcquireNextImageKHR(
		core.device.handle,
		core.swapchain.handle,
		VK_TIMEOUT_MAX,
		img_available,
		VK_NULL_HANDLE,
		&img_index,
	)
	#partial switch res {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR:
		recreate_swapchain(.Default_Mesh, allocator, callbacks)
		return
	case .SUBOPTIMAL_KHR:
		log.warn("Aquire next image reports suboptimal")
	case:
		log.panicf("Image acquiring failure: %v", res)
	}

	vk.ResetFences(core.device.handle, 1, &can_record_frame_sync)

	frame_commands := dyn.graphics_commands[frame_index]
	assert(len(frame_commands.buffers) >= 1)

	cmd_buffer := frame_commands.buffers[0]

	clears := [2]vk.ClearValue {
		{color = vk.ClearColorValue{float32 = VK_SKY_BLUE_COLOR}},
		{depthStencil = {depth = 1.0}},
	}
	beg_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = core.render_passes.handles[.Default_Mesh],
		framebuffer = core.framebuffers.swapchain_default_mesh[img_index],
		clearValueCount = u32(len(clears)),
		pClearValues = raw_data(clears[:]),
		renderArea = {extent = core.swapchain.image_extent, offset = {0, 0}},
	}

	offset: vk.DeviceSize = 0
	assert(validate_handle(dyn.vertex))
	vertex := gpu_get_resource_from_handle(dyn.vertex).(vk.Buffer)

	assert(validate_handle(dyn.index))
	index := gpu_get_resource_from_handle(dyn.index).(vk.Buffer)

	vertex_barrier := vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		buffer        = vertex,
		offset        = 0,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
	}

	index_barrier := vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		buffer        = index,
		offset        = 0,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.INDEX_READ},
	}

	assert(validate_handle(dyn.index))
	index_buff := gpu_get_resource_from_handle(dyn.index).(vk.Buffer)
	mvp := get_mvp(get_global_state().mesh)
	mesh_data, exists := get_asset(
		"example_mesh.obj",
		DEFAULT_ASSETS_DIR_NAME,
		.OBJ,
		&get_global_state().assets,
	)
	assert(exists)

	begin_command_buffer(cmd_buffer)
	if insert_vertex_barrier do vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.VERTEX_INPUT}, nil, 0, nil, 1, &vertex_barrier, 0, nil)
	if insert_index_barrier do vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.VERTEX_INPUT}, nil, 0, nil, 1, &index_barrier, 0, nil)
	vk.CmdBindVertexBuffers(cmd_buffer, 0, 1, &vertex, &offset)
	vk.CmdBindIndexBuffer(cmd_buffer, index_buff, 0, .UINT32)
	vk.CmdBindPipeline(cmd_buffer, .GRAPHICS, core.pipelines.datas[.Default_Mesh].handle)
	vk.CmdBeginRenderPass(cmd_buffer, &beg_info, .INLINE)
	vk.CmdBindDescriptorSets(
		cmd_buffer,
		.GRAPHICS,
		core.pipelines.layouts[.Default_Mesh],
		0,
		1,
		&core.descriptors.set,
		0,
		nil,
	)
	vk.CmdPushConstants(
		cmd_buffer,
		core.pipelines.layouts[.Default_Mesh],
		{.VERTEX},
		0,
		u32(size_of(mvp)),
		&mvp,
	)
	vk.CmdDrawIndexed(cmd_buffer, u32(len(mesh_data.memory.mesh.indicies)), 1, 0, 0, 0)
	vk.CmdEndRenderPass(cmd_buffer)
	end_command_buffer(cmd_buffer)

	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		commandBufferCount   = 1,
		pCommandBuffers      = &cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &render_done,
		waitSemaphoreCount   = u32(len(wait_sem)),
		pWaitSemaphores      = raw_data(wait_sem),
		pWaitDstStageMask    = raw_data(wait_stages),
	}

	res = vk.QueueSubmit(
		core.device.graphics,
		1,
		&submit_info,
		dyn.sync[frame_index].can_record_frame,
	)
	if res != .SUCCESS do log.panicf("Queue submition failure: %v", res)

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &render_done,
		swapchainCount     = 1,
		pSwapchains        = &core.swapchain.handle,
		pImageIndices      = &img_index,
	}

	return vk.QueuePresentKHR(core.device.graphics, &present_info)
}

create_frame_sync :: proc(
	init: ^Core_Vk_State,
	state: ^Dynamic_Vk_State,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	if .Frame_Sync in state.resource_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Frame_Sync)

	fif := get_engine_configuration().settings.Frames_In_Flight

	state.sync = make([]Frame_Sync, fif, allocator)
	defer if !success do delete(state.sync, allocator)

	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	for i in 0 ..< fif {
		result := vk.CreateSemaphore(
			init.device.handle,
			&sem_info,
			callbacks,
			&state.sync[i].img_available,
		)
		if result != .SUCCESS {
			log.panicf("Image available semaphore creation failure: %v", result)
		}

		result = vk.CreateSemaphore(
			init.device.handle,
			&sem_info,
			callbacks,
			&state.sync[i].render_done,
		)
		if result != .SUCCESS {
			log.panicf("Render done semaphore creation failure: %v", result)
		}

		result = vk.CreateFence(
			init.device.handle,
			&fence_create_info,
			callbacks,
			&state.sync[i].can_record_frame,
		)
		if result != .SUCCESS {
			log.panicf("Can record frame fence creation failure: %v", result)
		}
	}

	set_resource_flag(&state.resource_flags, Frame_Resource_Flag.Frame_Sync)

	return true
}

cleanup_frame_sync :: proc(
	init: ^Core_Vk_State,
	state: ^Dynamic_Vk_State,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
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

create_command_resources :: proc(
	init_state: ^Core_Vk_State,
	frame_state: ^Dynamic_Vk_State,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	success: bool,
) {
	if .Command in frame_state.resource_flags do log_called_when_resource_set(#procedure, Frame_Resource_Flag.Command)
	fif := get_all_settings().Frames_In_Flight

	frame_state.graphics_commands = make([]Command_State, fif, allocator)
	defer if !success do delete(frame_state.graphics_commands, allocator)

	// For now, we're just gonna use graphics queue only
	//TODO: get advantage of async queues if they're available
	pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = u32(init_state.physical_devices.active.queue_indexes.graphics),
		flags            = {.RESET_COMMAND_BUFFER},
	}

	for &state, i in frame_state.graphics_commands {
		result := vk.CreateCommandPool(
			init_state.device.handle,
			&pool_create_info,
			callbacks,
			&state.pool,
		)
		if result != .SUCCESS {
			log.errorf("Command pool creation failure: %v", result)
			return false
		}

		defer if !success {
			vk.DestroyCommandPool(init_state.device.handle, state.pool, callbacks)
			for j in 0 ..< i {
				vk.DestroyCommandPool(
					init_state.device.handle,
					frame_state.graphics_commands[j].pool,
					callbacks,
				)
				delete(frame_state.graphics_commands[j].buffers)
			}
		}

		state.buffers = make([dynamic]vk.CommandBuffer, 1, allocator)
		defer if !success do delete(state.buffers)

		alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandBufferCount = 1,
			commandPool        = state.pool,
			level              = .PRIMARY,
		}

		result = vk.AllocateCommandBuffers(
			init_state.device.handle,
			&alloc_info,
			&state.buffers[0],
		)
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

cleanup_command_resources :: proc(
	init_state: ^Core_Vk_State,
	frame_state: ^Dynamic_Vk_State,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
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
	beg_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
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
	h, err := gpu_create(.Vertex_Buffer, .Static, 4 * mem.Megabyte, VRAM_FLAGS, false)
	if err != nil {
		log.errorf("Vertex buffer creation failure: %v", err)
		return
	}

	return h, true
}

create_index_buffer :: proc() -> (handle: GPU_Resource_Handle, success: bool) {
	h, err := gpu_create(.Index_Buffer, .Static, 4 * mem.Megabyte, VRAM_FLAGS, false)
	if err != nil {
		log.errorf("Index buffer creation failure: %v", err)
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

cleanup_index_buffer :: proc(handle: GPU_Resource_Handle) {
	err := gpu_destroy(handle)
	if err != nil {
		log.errorf("Index buffer cleanup failure, possible leaks: %v", err)
	}
}

create_staging_buffer :: proc(
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	staging: Staging_Buffer,
	success: bool,
) {
	//TODO: Implement general staging buffer instead of using .Vertex_Buffer
	h, err := gpu_create(.Staging_Buffer, .Static, 4 * mem.Megabyte, STAGING_FLAGS, true)
	if err != nil {
		log.errorf("Staging buffer creation failure: %v", err)
		return
	}

	defer if !success {
		gpu_destroy(h)
	}
	staging.handle = h

	c := get_global_state().renderer.core

	pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = u32(c.physical_devices.active.queue_indexes.graphics), // TODO: Change this to use dedicated transfer if available
		flags            = {}, // We do not need resetting individual command buffers
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

	cmd_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandBufferCount = 1,
		commandPool        = pool,
		level              = .PRIMARY,
	}
	cmd_buffer: vk.CommandBuffer
	result = vk.AllocateCommandBuffers(c.device.handle, &cmd_alloc_info, &cmd_buffer)
	if result != .SUCCESS {
		log.errorf("Alocation of command buffer from staging buffer pool failure: %v", result)
		return
	}
	staging.cmd_buff = cmd_buffer

	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	sem: vk.Semaphore
	result = vk.CreateSemaphore(c.device.handle, &sem_info, callbacks, &sem)
	if result != .SUCCESS {
		log.errorf("Staging buffer semaphore creation failure: %v", result)
	}
	defer if !success {
		vk.DestroySemaphore(c.device.handle, sem, callbacks)
	}
	staging.sem = sem

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
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

cleanup_staging_buffer :: proc(
	staging: Staging_Buffer,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	err := gpu_destroy(staging.handle)
	if err != nil {
		log.errorf("Staging buffer cleanup failure: %v", err)
	}

	device := get_global_state().renderer.core.device.handle

	vk.DestroyCommandPool(device, staging.pool, callbacks)
	vk.DestroyFence(device, staging.fence, callbacks)
	vk.DestroySemaphore(device, staging.sem, callbacks)
}

initalize_shaders_state :: proc(core: ^Core_Vk_State) -> (success: bool) {
	if .Shaders in core.resource_flags {
		log_called_when_resource_set(#procedure, Vulkan_Core_State_Resource_Flag.Shaders)
	}

	core.shaders.modules[.Triangle_Vertex] = create_shader_module(
		generate_asset_id("triangle_vertex.spv", "spirv", .SPIRV),
	) or_return
	core.shaders.modules[.Triangle_Fragment] = create_shader_module(
		generate_asset_id("triangle_fragment.spv", "spirv", .SPIRV),
	) or_return
	core.shaders.modules[.Default_Mesh_Vertex] = create_shader_module(
		generate_asset_id("default_mesh_vertex.spv", "spirv", .SPIRV),
	) or_return
	core.shaders.modules[.Default_Mesh_Fragment] = create_shader_module(
		generate_asset_id("default_mesh_fragment.spv", "spirv", .SPIRV),
	) or_return

	set_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Shaders)
	return true
}

cleanup_shaders_state :: proc(
	core: ^Core_Vk_State,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) {
	if .Shaders not_in core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Core_State_Resource_Flag.Shaders)
	}
	for module, kind in core.shaders.modules {
		vk.DestroyShaderModule(core.device.handle, module, callbacks)
		when CONFIG_VERBOSE_LOG do log.debugf("Shader module '%v' destroyed", kind)
	}

	unset_resource_flag(&core.resource_flags, Vulkan_Core_State_Resource_Flag.Shaders)
}

create_shader_module :: proc(
	id: Asset_ID,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> (
	module: vk.ShaderModule,
	ok: bool,
) {
	g := get_global_state()
	shader, exists := get_asset(id, &g.assets)

	if !exists {
		log.warnf("Tried to create shader module from asset id '%v' but asset does not exist", id)
		return
	}

	if .Loaded_RAM not_in shader.flags {
		when CONFIG_VERBOSE_LOG do log.warnf(
			"Tried to create shader module from asset '%v:%v' but it looks like it is not loaded in memory (missing flag)",
			shader.pkg,
			shader.name,
		)
		return
	}

	spirv := shader.memory.spirv
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		pCode    = raw_data(spirv),
		codeSize = slice.size(spirv),
	}

	result := vk.CreateShaderModule(g.renderer.core.device.handle, &info, callbacks, &module)
	if result != .SUCCESS {
		log.errorf(
			"Shader module creation from asset '%v:%v' failure: %v",
			shader.pkg,
			shader.name,
			result,
		)
		return
	}
	when CONFIG_VERBOSE_LOG do log.debugf(
		"Shader module creation from asset '%v:%v' succeded",
		shader.pkg,
		shader.name,
	)

	return module, true
}
