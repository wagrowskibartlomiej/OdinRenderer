package render

import "core:fmt"
import "core:log"
import "core:mem"
import "base:runtime"

Global_State :: struct {
	assets: Assets_State,
	window: Window_State,
	render: Renderer_State,
	user_data: rawptr,
}


when DESKTOP_BUILD do main :: proc () {
	global_app_state: Global_State
	when TRACKING_ALLOCATOR {
		alloc: mem.Tracking_Allocator
		mem.tracking_allocator_init(&alloc, context.allocator)
		context.allocator = mem.tracking_allocator(&alloc)

		defer {
			if len(alloc.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(alloc.allocation_map))
				for _, entry in alloc.allocation_map do fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}

			mem.tracking_allocator_destroy(&alloc)
		}
	}

	opts := log.Options{.Level,.Terminal_Color,.Thread_Id}
	when ODIN_DEBUG || VERBOSE_LOG {
		opts |= {.Short_File_Path, .Line}
		ident := ""
	} else {
		opts |= {.Date, .Time}
		ident := "RENDERER"
	}

	context.logger = log.create_console_logger(opt = opts, ident = ident)
	defer log.destroy_console_logger(context.logger)

	context.user_ptr = &global_app_state
	
	if EDITOR_BUILD {
		load_assets_dir_to_map_editor(&global_app_state.assets, context.temp_allocator)
		defer cleanup_assets_map_editor(&global_app_state.assets)
	} else {
		loaded: bool
		global_app_state.assets.assets, loaded = load_assets_immediate(global_app_state.assets.asset_pack_handle, context.allocator)
		if !loaded do return
		defer cleanup_assets_map(&global_app_state.assets)
	}

	window_state := create_window(nil)
	defer cleanup_window(&window_state)

	state := initialize_vulkan(&window_state)
	if !check_all_flags(state.init.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		cleanup_vulkan(&state)
		return
	}

	defer cleanup_vulkan(&state)
}
