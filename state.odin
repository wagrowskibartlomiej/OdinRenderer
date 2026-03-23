#+feature using-stmt
package engine

import "base:runtime"

import "core:mem"
import "core:log"
import "core:fmt"

Engine_Global_State :: struct {
	app_context: Context_State,
	assets: Assets_State,
	window: Window_State,
	renderer: Renderer_State,
	user_data: rawptr,
}

Context_State :: struct {
	ctx: runtime.Context,
	allocator_data: Allocator_Data,
	resource_flags: Context_Resource_Flags,
	user_ptr: rawptr,
}

Engine_State_Create_Procs :: struct {}
Engine_State_Cleanup_Procs :: struct {}

Allocator_Data :: union {
	Tracking_Allocator_Data,
	runtime.Allocator
}

Context_State_Create_Procs :: struct {
	create_allocator: Engine_Create_Allocator_Proc,
	create_logger: Engine_Create_Logger_Proc,
	allocator_data, logger_data: rawptr,
}

Context_State_Cleanup_Procs :: struct {
	cleanup_allocator: Engine_Cleanup_Allocator_Proc,
	cleanup_logger: Engine_Cleanup_Logger_Proc,
	allocator_data, logger_data: rawptr,
}

Context_Resource_Flag :: enum {
	Logger,
	Allocator,
}
Context_Resource_Flags :: bit_set[Context_Resource_Flag]

Tracking_Allocator_Data :: struct {
	allocator: runtime.Allocator,
	tracking: mem.Tracking_Allocator,
}



setup_engine_state :: proc(engine_state: ^Engine_Global_State, procs: Engine_State_Create_Procs = {}) {
	engine_create_default_context(engine_state)
}

cleanup_engine_state :: proc(state: ^Engine_Global_State, procs: Engine_State_Cleanup_Procs = {}) {
	engine_cleanup_default_context(&state.app_context)
}

Engine_Create_Logger_Proc :: #type proc(allocator := context.allocator, data: rawptr = nil) -> log.Logger
Engine_Cleanup_Logger_Proc :: #type proc(logger: log.Logger, allocator := context.allocator, data: rawptr = nil)
Engine_Create_Allocator_Proc :: #type proc(state: ^Context_State, data: rawptr = nil)
Engine_Cleanup_Allocator_Proc :: #type proc(allocator: ^Allocator_Data, data: rawptr = nil)
Engine_Create_Context_Proc :: #type proc(engine_state: ^Engine_Global_State /* State pointer will be set in user_ptr inside context */, procs: Context_State_Create_Procs = {}, data: rawptr = nil)
Engine_Cleanup_Context_Proc :: #type proc(context_state: ^Context_State, procs: Context_State_Cleanup_Procs = {}, data: rawptr = nil)

engine_create_default_context : Engine_Create_Context_Proc : proc(engine_state: ^Engine_Global_State, procs: Context_State_Create_Procs = {}, data: rawptr = nil) {
	engine_state.app_context.ctx = runtime.default_context()

	procs := set_default_context_create_procs(procs)

	procs.create_allocator(&engine_state.app_context, procs.allocator_data)

	switch v in engine_state.app_context.allocator_data {
	case runtime.Allocator: engine_state.app_context.ctx.allocator = v
	case Tracking_Allocator_Data: engine_state.app_context.ctx.allocator = v.allocator
	}
	set_resource_flag(&engine_state.app_context.resource_flags, Context_Resource_Flag.Allocator)

	engine_state.app_context.ctx.logger = procs.create_logger(engine_state.app_context.ctx.allocator, procs.logger_data)
	set_resource_flag(&engine_state.app_context.resource_flags, Context_Resource_Flag.Logger)

	// Set pointer in context
	engine_state.app_context.ctx.user_ptr = engine_state
}

engine_cleanup_default_context : Engine_Cleanup_Context_Proc : proc(context_state: ^Context_State, procs: Context_State_Cleanup_Procs = {}, data: rawptr = nil) {
	procs := set_default_context_cleanup_procs(procs)

	using context_state 
	if .Logger in resource_flags do procs.cleanup_logger(ctx.logger, ctx.allocator, procs.logger_data)
	unset_resource_flag(&resource_flags, Context_Resource_Flag.Logger)

	if .Allocator in resource_flags do procs.cleanup_allocator(&allocator_data, procs.allocator_data)
	unset_resource_flag(&resource_flags, Context_Resource_Flag.Allocator)
}


engine_create_default_logger : Engine_Create_Logger_Proc : proc(allocator := context.allocator, data: rawptr = nil) -> log.Logger {
	opts := log.Options{.Level,.Terminal_Color,.Thread_Id}
	ident := "ENGINE"

	when ODIN_DEBUG || CONFIG_VERBOSE_LOG do opts |= {.Short_File_Path, .Line}
	else when CONFIG_BUILD_VARIANT == Build_Variants[.Headless] do opts |= {.Line, .Date, .Time}
	else do opts |= {.Date, .Time}

	return log.create_console_logger(opt = opts, ident = ident, allocator = allocator)
}

engine_cleanup_default_logger : Engine_Cleanup_Logger_Proc : proc(logger: log.Logger, allocator := context.allocator, data: rawptr = nil) {
	log.destroy_console_logger(logger, allocator)
}


engine_create_default_allocator : Engine_Create_Allocator_Proc : proc(state: ^Context_State, data: rawptr = nil) {
	when CONFIG_TRACKING_ALLOCATOR {
		if state.allocator_data == nil do state.allocator_data = Tracking_Allocator_Data{}
		#partial switch &v in state.allocator_data {
		case Tracking_Allocator_Data:
			mem.tracking_allocator_init(&v.tracking, context.allocator)
			v.allocator = mem.tracking_allocator(&v.tracking)
		}
	} else do return
}

engine_cleanup_default_allocator : Engine_Cleanup_Allocator_Proc : proc(allocator: ^Allocator_Data, data: rawptr = nil) {
	when CONFIG_TRACKING_ALLOCATOR {
		alloc := allocator.(Tracking_Allocator_Data)
		if len(alloc.tracking.allocation_map) > 0 {
			log.errorf("=== %v allocations not freed: ===\n", len(alloc.tracking.allocation_map))
			for _, entry in alloc.tracking.allocation_map do log.errorf("- %v bytes @ %v (%v)\n", entry.size, entry.location, entry.mode)
		}

		mem.tracking_allocator_destroy(&alloc.tracking)
		when CONFIG_VERBOSE_LOG do log.debug("Tracking allocator cleaned up")
	}
}

set_default_context_create_procs :: proc(procs: Context_State_Create_Procs) -> Context_State_Create_Procs {
	procs := procs

	if procs.create_allocator == nil do procs.create_allocator = engine_create_default_allocator
	if procs.create_logger == nil do procs.create_logger = engine_create_default_logger

	return procs
}

set_default_context_cleanup_procs :: proc(procs: Context_State_Cleanup_Procs) -> Context_State_Cleanup_Procs {
	procs := procs

	if procs.cleanup_allocator == nil do procs.cleanup_allocator = engine_cleanup_default_allocator
	if procs.cleanup_logger == nil do procs.cleanup_logger = engine_cleanup_default_logger

	return procs
}

change_logger_ident :: proc(new_ident: string, state: ^Context_State) {
	d := cast(^log.File_Console_Logger_Data)state.ctx.logger.data
	d.ident = new_ident
}
