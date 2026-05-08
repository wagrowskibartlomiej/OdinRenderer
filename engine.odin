package engine


import "base:runtime"

import "core:log"
import "core:time"
import "core:math/rand"

import vk "vendor:vulkan"

engine_init :: proc "contextless" (state: ^Engine_Global_State, procs := Engine_State_Create_Procs{}) -> (ctx: runtime.Context) {
	context = setup_engine_state(state, procs)

	initialize_engine_configuration()
	load_configuration(get_engine_configuration()._settings_strings_arena.allocator)

	initialize_asset_manager(&state.assets)

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success := read_assets_dir_recursive(&state.assets, load_assets_mem = true)
		if !success do log.panicf("Unable to continue without assets")
	} else do read_assets_packed(state.assets.assets_file, &state.assets, true)

	return context
}

engine_cleanup :: proc(state: ^Engine_Global_State, procs := Engine_State_Cleanup_Procs{}) {
	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success := build_asset_packed(&state.assets)
		if !success do log.error("Building assets file failed")
	}
	cleanup_asset_manager(&state.assets)
	cleanup_engine_configuration()
	cleanup_engine_state(state, procs)
	//free_all(context.temp_allocator)
}

engine_renderer_init :: proc(state: ^Engine_Global_State) -> (success: bool) {
	success = create_window(&state.window)
	success or_return

	initialize_vulkan(&state.renderer, state)
	if !check_all_flags(state.renderer.core.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		cleanup_vulkan(&state.renderer)
		return
	}

	gpu_initalize_memory_state(&state.renderer.memory)
	gpu_initalize_resources(&state.renderer.resources)
	gpu_allocate_default_memory_blocks()

	success = init_frame_resources(&state.renderer.dyn, &state.renderer.core)
	success or_return


	return true
}
engine_renderer_cleanup :: proc(state: ^Engine_Global_State) {
	cleanup_frame_resources(&state.renderer.core, &state.renderer.dyn)
	gpu_cleanup_resources(&state.renderer.resources)
	gpu_cleanup_memory_state(state.renderer.memory)
	cleanup_vulkan(&state.renderer)
	cleanup_window(&state.window)
}

engine_poll_events :: proc(state: ^Engine_Global_State) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do glfw_poll_events()
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET != .Android do #panic(#procedure + " is not implemented for " + CONFIG_BUILD_TARGET + "target (" + ODIN_PLATFORM_SUBTARGET + ") subtarget")
	else do android_poll_events(cast(^Engine_Android_Global_State)state.platform_context)
}

engine_is_running :: proc(state: ^Engine_Global_State) -> bool {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do return glfw_is_running(state)
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET == .Android do return android_is_running(cast(^Engine_Android_Global_State)state)
	else do #panic(#procdure + " is not implemented for " + CONFIG_BUILD_TARGET + " target (subtarget " + ODIN_PLATFORM_SUBTARGET + ")")
}

engine_process_input :: proc() {}

engine_update_logic :: proc() {}
engine_update_gpu :: proc(data: rawptr, size: int, update: bool) {
	if !update {
		return
	}
	@(static) counter: time.Duration
	counter += get_frame_time()
	if counter < time.Millisecond * 300 {
		return
	} else {
		counter = 0
	}

	d := ([^]Triangle_Vertex)(data)[:3]
	rgb := [3]f32{rand.float32(), rand.float32(), rand.float32()}

	d[0].color.rgb = rgb
	d[1].color.rgb = rgb
	d[2].color.rgb = rgb

	r := get_global_state().renderer
	actions, success := gpu_move_data_to_buffer(data, size, r.dyn.vertex, r.dyn.staging)
	if !success {
		log.errorf("Failed to update vertex buffer")
		return
	}

	if .Flush_Destination in actions {
		success = gpu_flush_resource(r.dyn.vertex)
		if !success {
			log.errorf("Failed to flush vertex buffer")
		}
	}

	if .Flush_Staging in actions {
		success = gpu_flush_resource(r.dyn.staging.(Staging_Buffer).handle)
		if !success {
			log.errorf("Failed to flush staging buffer")
		}
	}

	if .Submit_Cmd_Buffer in actions {
		// TODO: Check for queue transfer ownership, right now it's ignored cause we use only graphics
		s := r.dyn.staging.?
		graphics := r.core.device.graphics
		submit_info := vk.SubmitInfo{
			sType = .SUBMIT_INFO,
			commandBufferCount = 1,
			pCommandBuffers = &s.cmd_buff,
			/*
			Since we're not using separate transfer queue, we ignore these
			pSignalSemaphores = &s.sem,
			signalSemaphoreCount = 1,
			*/
		}
		result := vk.QueueSubmit(graphics, 1, &submit_info, s.fence)
		if result != .SUCCESS {
			log.errorf("Queue submition for buffer copy failed: %v", result)
		}
	}
}
engine_draw_frame :: proc(state: ^Engine_Global_State, frame_index: int, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> vk.Result {
	res := draw_frame(&state.renderer.core, &state.renderer.dyn, state.window.handle, frame_index, allocator, callbacks)
	#partial switch res {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR: recreate_swapchain(&state.renderer.core, state.window.handle, allocator, callbacks)
	case: log.panicf("Drawing failure: %v", res)
	}

	return res
}

engine_update_current_frame_idx :: proc(state: ^Engine_Global_State) {
	assert(state != nil)
	state.renderer.current_frame_index = (state.renderer.current_frame_index + 1) % get_engine_configuration().settings.Frames_In_Flight
}

engine_calculate_delta :: proc(state: ^Engine_Global_State) {
	assert(state != nil)

	n := time.now()

	state.time.frame_diff = time.diff(state.time.last_frame_start, n)
	state.time.delta = time.duration_seconds(state.time.frame_diff)
	state.time.last_frame_start = n
}
