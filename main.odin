package engine

import os "core:os/old"
import "core:fmt"
import "core:log"
import "core:mem"
import "base:runtime"

import vk "vendor:vulkan"

when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do main :: proc () {
	state: Engine_Global_State

	setup_engine_state(&state)
	context = state.app_context.ctx
	defer cleanup_engine_state(&state)

	initialize_engine_configuration()
	defer cleanup_engine_configuration()

	load_configuration(get_engine_configuration()._settings_strings_arena.allocator)
	//defer save_configuration()

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success: bool

		state.assets, success = initalize_assets()
		if !success do panic("Cannot initalize assets")

		defer {
			build_asset_pack(&state.assets.items)
			success = cleanup_assets(&state.assets)
			if !success do panic("Cannot cleanup assets")
		}
	} else {
		state.assets.allocator = context.allocator
		state.assets.binary_data_allocator = context.allocator

		h, err := os.open("assets.pack")
		if err != nil {
			log.fatalf("Assets pack is missing.")
			return
		}
		defer os.close(h)
		state.assets.asset_pack_handle = h

		loaded: bool
		state.assets.items, state.assets.pkgs, loaded = load_assets_immediate(state.assets.asset_pack_handle, context.allocator)
		if !loaded do return
		defer cleanup_assets_map(&state.assets)
	}

	state.window = create_window(nil)
	defer cleanup_window(&state.window)

	state.renderer = initialize_vulkan(&state.window, &state.assets, &state.app_context)
	if !check_all_flags(state.renderer.init.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		cleanup_vulkan(&state.renderer)
		return
	}
	defer cleanup_vulkan(&state.renderer)

	init_frame(&state.renderer.frame, &state.renderer.init)
	defer cleanup_frame(&state.renderer.init, &state.renderer.frame)

	gpu_initialize_memory_manager(&state.renderer.init, &state.renderer.memory)
	defer gpu_cleanup_memory_manager(&state.renderer.init, &state.renderer.memory)
}

