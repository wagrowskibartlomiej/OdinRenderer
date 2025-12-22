package render

import "core:fmt"
import "core:log"
import "core:mem"
import "base:runtime"


when DESKTOP_BUILD do main :: proc () {
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

	state: Renderer_State

	state.window = create_window()
	defer cleanup_window(&state.window)

	state = initialize_vulkan()
	if !check_all_flags(state.init.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		return
	}

	defer cleanup_vulkan(&state)
}
