package engine

import vk "vendor:vulkan"

import "base:runtime"
import "core:log"

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

	success = gpu_initialize_memory_manager(&state.renderer.core, &state.renderer.memory)
	success or_return

	success = init_frame_resources(&state.renderer.dyn, &state.renderer.core, &state.renderer.memory)
	success or_return

	return true
}
engine_renderer_cleanup :: proc(state: ^Engine_Global_State) {
	cleanup_frame_resources(&state.renderer.core, &state.renderer.dyn, &state.renderer.memory)
	gpu_cleanup_memory_manager(&state.renderer.core, &state.renderer.memory)
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

engine_update :: proc(state: ^Engine_Global_State, data: rawptr, size: int, update: bool) {
	if update do move_data_to_vertex_buffer(&state.renderer.core, &state.renderer.dyn, data, size)
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
