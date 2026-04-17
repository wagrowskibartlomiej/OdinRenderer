#+build linux
package engine

import "base:runtime"

import "core:log"
import android "./androidglue/ndkbindings"

@export
android_main :: proc "c" (android_app_state: ^android.android_app) {
	state: Engine_Android_Global_State

	// actual custom context will be created later, for now we need context with user_ptr set to global state
	context = init_android_state(android_app_state, &state)

	for engine_is_running(&state) {
		engine_poll_events(&state)
		context = state.app_context.ctx // here we assign actual context?

		if .Focus in state.flags {
			engine_process_input()
			engine_update_logic()
			if .Rendering_Ready in state.flags do engine_draw_frame()
		}
	}
}

handle_android_cmd : Proc_Handle_Anroid_CMD : proc "c" (app: ^android.android_app, cmd: android.AppCmd) {
	state := cast(^Engine_Android_Global_State)app.userData

	context = state.app_context.ctx

	#partial switch cmd {
	case .START:
		context = engine_init_android(app, state)
		state.flags += {.Engine_Initalized}
	case .DESTROY: 
		engine_cleanup_android(state)
		state.flags -= {.Engine_Initalized}
	case .INIT_WINDOW: 
		success := engine_renderer_init(state) 
		if !success {
			log.error("Renderer initalization failed")
			engine_renderer_cleanup(state)
			android.ANativeActivity_finish(app.activity)
		} else do state.flags += {.Rendering_Ready}
	case .TERM_WINDOW: 
		engine_renderer_cleanup(state)
		state.flags -= {.Rendering_Ready}
	case .WINDOW_RESIZED, .CONTENT_RECT_CHANGED: // recreate swapchain
	case .GAINED_FOCUS: state.flags += {.Focus}
	case .LOST_FOCUS: state.flags -= {.Focus}
	case: log.warnf("Unhandled CMD: %v", cmd)
	}
}


android_poll_events :: proc(engine_state: ^Engine_Android_Global_State) {
	if engine_state == nil do return
	POLL :: 0
	SLEEP :: -1
	
	events: i32
	source: ^android.android_poll_source

	// If app is not active we "sleep" to not drain the battery
	timeout : i32 = .Focus in engine_state.flags ? POLL : SLEEP
	// Process all events here
	// TODO: Add input queue if input will be handled to not
	for {
		ident := android.ALooper_pollAll(timeout, nil, &events, cast(^rawptr)&source)
		if ident < 0 do break

		if source != nil do source.process(engine_state.app_ptr, source)
	}
}

android_is_running :: proc(state: ^Engine_Android_Global_State) -> bool {
	return state.app_ptr.destroyRequested == 0 ? true : false
}
