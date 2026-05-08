package engine

import "base:runtime"

import "core:mem"
import "core:log"
import "core:fmt"
import "core:c"
import "core:strings"

import android "androidglue/ndkbindings"

Proc_Handle_Anroid_CMD :: #type proc "system" (app: ^android.android_app, cmd: android.AppCmd)
Proc_Handle_Android_Input :: #type proc "system" (app: ^android.android_app, event: ^android.AInputEvent) -> c.int32_t

Engine_Android_Global_State :: struct {
	using _: Engine_Global_State,
	app_ptr: ^android.android_app,
	cmd_proc: Proc_Handle_Anroid_CMD,
	input_proc: Proc_Handle_Android_Input,
	flags: Engine_Android_Flags,
}

Engine_Android_Flag :: enum {
	Focus,
	Window_Ready,
	Renderer_Initalized,
}
Engine_Android_Flags :: bit_set[Engine_Android_Flag]

Android_Logger_Data :: struct {
	arena: mem.Arena,
	backing: []byte,
	allocator: mem.Allocator,
	ident: cstring,
	missed_logs: bool,
}

engine_connect_andorid_with_state :: proc "c" (android_app_state: ^android.android_app, engine_state: ^Engine_Android_Global_State) {
	engine_state.cmd_proc = handle_android_cmd
	engine_state.input_proc = handle_android_input
	engine_state.app_ptr = android_app_state
	engine_state.platform_context = engine_state

	android_app_state.userData = engine_state
	android_app_state.onAppCmd = engine_state.cmd_proc
	android_app_state.onInputEvent = engine_state.input_proc
}

// Wrapper for `engine_init` to set values for android like Android's CMD callback etc.
engine_init_android :: proc "contextless" (android_app_state: ^android.android_app, procs := Engine_State_Create_Procs{ctx = {create_logger = create_android_logger, assert_proc = android_assert_proc}}) -> (runtime.Context, ^Engine_Android_Global_State) {
	context = runtime.default_context()
	state := new(Engine_Android_Global_State, runtime.heap_allocator())
	engine_connect_andorid_with_state(android_app_state, state)
	return engine_init(state, procs), state
}

// Wrapper for `engine_renderer_init` to set flags for Android state.
engine_renderer_init_android :: proc(engine_state: ^Engine_Android_Global_State) {
	success := engine_renderer_init(engine_state)
	if !success {
		log.panic("Engine renderer initalization failed")
	}
	engine_state.flags += {.Renderer_Initalized}
}

// Wrapper for `engine_renderer_cleanup` to unset flags for Android state.
engine_renderer_cleanup_android :: proc(engine_state: ^Engine_Android_Global_State) {
	engine_renderer_cleanup(engine_state)
	engine_state.flags -= {.Renderer_Initalized}
}


engine_cleanup_android :: proc(engine_state: ^Engine_Android_Global_State, procs := Engine_State_Cleanup_Procs{ctx = {cleanup_logger = cleanup_android_logger}}) {
	if .Renderer_Initalized in engine_state.flags do engine_renderer_cleanup_android(engine_state)
	engine_cleanup(engine_state, procs)
	free(engine_state, runtime.heap_allocator())
}

android_logger_proc : log.Logger_Proc : proc(logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	d := cast(^Android_Logger_Data)logger_data

	priority: android.LogPriority

	ctext, err := strings.clone_to_cstring(text, d.allocator)
	if err == .Out_Of_Memory {
		free_all(d.allocator)
		ctext, err = strings.clone_to_cstring(text, d.allocator)
		if err != nil {
			d.missed_logs = true
		}
	} else if err != nil {
		d.missed_logs = true
	}

	switch level {
	case .Debug: priority = .DEBUG
	case .Info: priority = .INFO
	case .Warning: priority = .WARN
	case .Error: priority = .ERROR
	case .Fatal: priority = .FATAL
	}

	android.__android_log_write(priority, d.ident, ctext)
}

create_android_logger : Engine_Create_Logger_Proc : proc(options := DEFAULT_LOGGER_OPTIONS, ident := DEFAULT_LOGGER_IDENT, default_configuration := true, allocator := context.allocator, data: rawptr) -> log.Logger {
	d := new(Android_Logger_Data, allocator)

	cident := strings.clone_to_cstring(ident, allocator)

	d.ident = cident

	size := 4 * mem.Kilobyte

	d.backing = make([]byte, mem.Kilobyte, allocator)
	mem.arena_init(&d.arena, d.backing)
	d.allocator = mem.arena_allocator(&d.arena)

	return {procedure = android_logger_proc, data = d}
}

cleanup_android_logger : Engine_Cleanup_Logger_Proc : proc(logger: log.Logger, allocator := context.allocator, data: rawptr) {
	d := cast(^Android_Logger_Data)logger.data

	delete(d.ident, allocator)
	delete(d.backing, allocator)

	free(d, allocator)
}

android_assert_proc : runtime.Assertion_Failure_Proc : proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "[%v] %v @ %v:%v", prefix, message, loc.line, loc.procedure)
	mess := strings.to_cstring(&builder)
	tag := strings.clone_to_cstring(prefix)
	// Is it even worth to delete?

	android.__android_log_assert(nil, "ENGINE ASSERTION", mess)
	runtime.trap()
}


handle_android_input : Proc_Handle_Android_Input : proc "c" (app: ^android.android_app, event: ^android.AInputEvent) -> c.int32_t {
	return 0
}

get_android_global_state :: proc() -> ^Engine_Android_Global_State {
	g := get_global_state()
	assert(g.platform_context != nil)
	return cast(^Engine_Android_Global_State)g.platform_context
}
