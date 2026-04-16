package engine

import "base:runtime"
import "core:log"

engine_init :: proc "contextless" (state: ^Engine_Global_State, procs := Engine_State_Create_Procs{}) -> (ctx: runtime.Context) {
	setup_engine_state(state, procs)
	context = state.app_context.ctx

	initialize_engine_configuration()
	load_configuration(get_engine_configuration()._settings_strings_arena.allocator)

	initialize_asset_manager(&state.assets)

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success := read_assets_dir_recursive(&state.assets, load_assets_mem = true)
		if !success do log.panicf("Unable to continue without assets")
	} else do read_assets_packed(state.assets.assets_file, &state.assets, true)

	return state.app_context.ctx
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
	if !check_all_flags(state.renderer.init.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		cleanup_vulkan(&state.renderer)
		return
	}

	success = gpu_initialize_memory_manager(&state.renderer.init, &state.renderer.memory)
	success or_return

	success = init_frame_resources(&state.renderer.frame, &state.renderer.init)
	success or_return

	return true
}
engine_renderer_cleanup :: proc(state: ^Engine_Global_State) {
	cleanup_frame_resources(&state.renderer.init, &state.renderer.frame)
	gpu_cleanup_memory_manager(&state.renderer.init, &state.renderer.memory)
	cleanup_vulkan(&state.renderer)
	cleanup_window(&state.window)
}

engine_poll_events :: proc(state: ^Engine_Global_State) -> (running: bool) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] {
		if state == nil do log.panicf("Expected a valid Engine state pointer, got: %v", state)
		return glfw_poll_events(&state.window)
	}
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET != .Android do #panic(#procedure + " is not implemented for " + CONFIG_BUILD_TARGET + "target (" + ODIN_PLATFORM_SUBTARGET + ") subtarget")
	else do return android_poll_events(cast(^Engine_Android_Global_State)state.platform_context)
}

engine_process_input :: proc() {}
engine_update_logic :: proc() {}
engine_draw_frame :: proc() {}

