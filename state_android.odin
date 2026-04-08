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
	window_ready, app_active, recreate_swapchain: bool,
	cmd_proc: Proc_Handle_Anroid_CMD,
	input_proc: Proc_Handle_Android_Input,
}

Android_Logger_Data :: struct {
	scratch: mem.Scratch_Allocator,
	allocator: mem.Allocator,
	ident: cstring,
}

// Wrapper for `engine_init` to set values for android like Android's CMD callback etc.
engine_init_android :: proc "contextless" (android_app_state: ^android.android_app, engine_state: ^Engine_Android_Global_State, procs := Engine_State_Create_Procs{ctx = {create_logger = create_android_logger, assert_proc = android_assert_proc}}) -> runtime.Context {
	engine_state.cmd_proc = handle_android_cmd
	engine_state.input_proc = handle_android_input
	engine_state.app_ptr = android_app_state

	android_app_state.userData = engine_state
	android_app_state.onAppCmd = engine_state.cmd_proc
	android_app_state.onInputEvent = engine_state.input_proc

	return engine_init(engine_state, procs)
}

engine_cleanup_android :: proc(engine_state: ^Engine_Android_Global_State, procs := Engine_State_Cleanup_Procs{ctx = {cleanup_logger = cleanup_android_logger}}) {
	engine_cleanup(engine_state, procs)
}

android_logger_proc : log.Logger_Proc : proc(logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	d := cast(^Android_Logger_Data)logger_data
	context.allocator = d.allocator

	priority: android.LogPriority

	ctext := strings.clone_to_cstring(text)

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

	size := mem.Kilobyte * 64

	mem.scratch_init(&d.scratch, size, allocator)
	d.allocator = mem.scratch_allocator(&d.scratch)

	return {procedure = android_logger_proc, data = d}
}

cleanup_android_logger : Engine_Cleanup_Logger_Proc : proc(logger: log.Logger, allocator := context.allocator, data: rawptr) {
	d := cast(^Android_Logger_Data)logger.data

	mem.scratch_destroy(&d.scratch)

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

handle_android_cmd : Proc_Handle_Anroid_CMD : proc "c" (app: ^android.android_app, cmd: android.AppCmd) {
	state := cast(^Engine_Android_Global_State)app.userData
	context = state.app_context.ctx

	#partial switch cmd {
	case .INIT_WINDOW: state.window_ready = true
	case .TERM_WINDOW:
		engine_renderer_cleanup(state, state.app_ptr) // for now just recreate all, we'll move to swapchain recreation later
		state.window_ready = false
		state.recreate_swapchain = true
	case .GAINED_FOCUS: state.app_active = true
	case .LOST_FOCUS: state.app_active = false
	case .WINDOW_RESIZED: state.recreate_swapchain = true
	case: log.warnf("Unhandled android CMD: %v", cmd)
	}
}

handle_android_input : Proc_Handle_Android_Input : proc "c" (app: ^android.android_app, event: ^android.AInputEvent) -> c.int32_t {
	return 0
}
