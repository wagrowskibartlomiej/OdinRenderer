#+build linux
package engine

import android "./androidglue/ndkbindings"

@export
android_main :: proc "contextless" (android_app_state: ^android.android_app) {
	engine_state: Engine_Android_Global_State

	context = engine_init_android(android_app_state, &engine_state)
	defer engine_cleanup_android(&engine_state)

	engine_state.recreate_swapchain = true //TODO: TEMP SOLUTION IT CURRENTLY DESTROYS WHOLE RENDERER STATE
	defer engine_renderer_cleanup(&engine_state, android_app_state)

	for {
		running := engine_poll_events(nil, &engine_state)
		running or_break

		if engine_state.window_ready && engine_state.recreate_swapchain {
			success := engine_renderer_init(&engine_state, android_app_state)
			if !success do return
			engine_state.recreate_swapchain = false
		}

		if engine_state.app_active {
			engine_process_input()
			engine_update_logic()
			engine_draw_frame()
		}
	}
}

android_poll_events :: proc(engine_state: ^Engine_Android_Global_State) -> (running: bool) {
	POLL :: 0
	SLEEP :: -1
	
	events: i32
	source: ^android.android_poll_source

	// If app is not active we "sleep" to not drain the battery
	timeout : i32 = engine_state.app_active ? POLL : SLEEP

	// Process all events here
	// TODO: Add input queue if input will be handled to not
	for {
		ident := android.ALooper_pollAll(timeout, nil, &events, cast(^rawptr)&source)
		if ident < 0 do break

		if source != nil do source.process(engine_state.app_ptr, source)
		if engine_state.app_ptr.destroyRequested != 0 do return false
	}

	return true
}
