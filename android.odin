package render

import "core:log"
import "core:mem"
import "core:strings"
import "core:fmt"
import "base:runtime"
import "core:c"

import android "./androidglue/ndkbindings"

when !DESKTOP_BUILD {
Android_State :: struct {
	app_ptr: ^android.android_app,
	app_active: bool,
	cmd_proc: Proc_Handle_Anroid_CMD,
	input_proc: Proc_Handle_Android_Input,
	renderer: Renderer_State,
	window: Window_State,
	ctx: runtime.Context,
	logger: Android_Logger_Arena,
	some_mem: []byte,
}

Proc_Handle_Anroid_CMD :: #type proc "system" (app: ^android.android_app, cmd: android.AppCmd)
Proc_Handle_Android_Input :: #type proc "system" (app: ^android.android_app, event: ^android.AInputEvent) -> c.int32_t

android_logger :: proc(logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	logger_arena := cast(^Android_Logger_Arena)logger_data
	context.allocator = logger_arena.allocator

	priority: android.LogPriority

	ctext := strings.clone_to_cstring(text)

	switch level {
	case .Debug:
		priority = .DEBUG
	case .Info:
		priority = .INFO
	case .Warning:
		priority = .WARN
	case .Error:
		priority = .ERROR
	case .Fatal:
		priority = .FATAL
	}
	
	android.__android_log_write(priority, "ODIN_RENDERER", ctext)
}

Android_Logger_Arena :: struct {
	memory: []byte,
	handle: mem.Arena,
	scratch: mem.Scratch_Allocator,
	allocator: mem.Allocator
}

handle_android_cmd :: proc "c" (app: ^android.android_app, cmd: android.AppCmd) {
	state := cast(^Android_State)app.userData
	context = state.ctx

	#partial switch cmd {
	case .INIT_WINDOW:
		if state.app_ptr.window != nil {
			state.window = create_window(state.app_ptr.window)
			state.renderer = initialize_vulkan(&state.window)
		}
	case .TERM_WINDOW:
		cleanup_vulkan(&state.renderer)
		cleanup_window(&state.window)
	case:
		log.warnf("Unhandled android CMD: %v", cmd)
	/*
	case .WINDOW_RESIZED:
		// Recreate resources and redraw
	case .GAINED_FOCUS:
	    state.app_active = true
	case .LOST_FOCUS:
	    state.app_active = false
	*/
	}
}

handle_android_input:: proc "c" (app: ^android.android_app, event: ^android.AInputEvent) -> c.int32_t {
	return 0
}

@(export)
android_main :: proc "contextless" (state: ^android.android_app) {
	context = runtime.default_context()

	app_state: Android_State

	app_state.cmd_proc = handle_android_cmd
	app_state.input_proc = handle_android_input

	state.userData = &app_state
	state.onAppCmd = app_state.cmd_proc
	state.onInputEvent = app_state.input_proc
	app_state.app_ptr = state

	app_state.logger.memory = make([]byte, 100 * mem.Kilobyte)

	mem.arena_init(&app_state.logger.handle, app_state.logger.memory)

	size := size_of(app_state.logger.memory[0]) * len(app_state.logger.memory)

	mem.scratch_init(&app_state.logger.scratch, size)
	app_state.logger.allocator = mem.scratch_allocator(&app_state.logger.scratch)

	app_state.ctx.logger = log.Logger{
		procedure = android_logger,
		data = rawptr(&app_state.logger)
	}

	context.logger = app_state.ctx.logger
	context.assertion_failure_proc = android_assert_proc
	app_state.ctx = context

	for {
		events: i32
		source: ^android.android_poll_source

		ident := android.ALooper_pollAll(app_state.app_active ? 0 : -1, nil, &events, cast(^rawptr)&source)
		for ident >= 0 {
			if source != nil do source.process(state, source)

			if state.destroyRequested != 0 {
				cleanup_vulkan(&app_state.renderer)
				cleanup_window(&app_state.window)
				return
			}

			ident = android.ALooper_pollAll(app_state.app_active ? 0 : -1, nil, &events, cast(^rawptr)&source)
		}

		if (app_state.app_active) do log.info("APP ACTIVE")
	}
}
}

android_assert_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, prefix, " ", message, " AT: ", loc.file_path, ":", loc.line, "|", loc.procedure)
	mess := strings.to_cstring(&builder)
	tag := strings.clone_to_cstring(prefix)
	// Is it even worth to delete?

	android.__android_log_write(.FATAL, "ODIN ASSERT", mess)
	runtime.trap()
}
