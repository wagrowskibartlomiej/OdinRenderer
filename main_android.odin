#+build linux
package engine


import android "./androidglue/ndkbindings"
import "core:slice"

@(export)
android_main :: proc "c" (android_app_state: ^android.android_app) {
	engine_state: ^Engine_Android_Global_State

	context, engine_state = engine_init_android(android_app_state)
	defer engine_cleanup_android(engine_state)

	tri:  [3]Triangle_Vertex
	tri[0].color = {1, 0, 0, 1}
	tri[0].position = {0, 0.5}

	tri[1].color = {0, 1, 0, 1}
	tri[1].position = {-0.5, -0.5}

	tri[2].color = {0, 0, 1, 1}
	tri[2].position = {0.5, -0.5}

	for engine_is_running(engine_state) {
		engine_calculate_delta(engine_state)
		engine_poll_events(engine_state)

		if android_should_initalize_renderer(engine_state) {
			engine_renderer_init_android(engine_state)
		}
	 	else if android_should_cleanup_renderer(engine_state) {
			engine_renderer_cleanup_android(engine_state)
		}

		if .Focus in engine_state.flags do engine_process_input()

		if android_can_draw(engine_state) {
			engine_update_gpu(raw_data(tri[:]), slice.size(tri[:]), true)
			engine_draw_frame(engine_state, engine_state.renderer.current_frame_index)
			engine_update_current_frame_idx(engine_state)
		}
	}

}

android_should_initalize_renderer :: proc(engine_state: ^Engine_Android_Global_State) -> bool {
	return .Window_Ready in engine_state.flags && .Renderer_Initalized not_in engine_state.flags
}
android_should_cleanup_renderer :: proc(engine_state: ^Engine_Android_Global_State) -> bool {
	return .Window_Ready not_in engine_state.flags && .Renderer_Initalized in engine_state.flags
}
android_can_draw :: proc(engine_state: ^Engine_Android_Global_State) -> bool {
	return .Window_Ready in engine_state.flags && .Renderer_Initalized in engine_state.flags
}

handle_android_cmd: Proc_Handle_Anroid_CMD : proc "c" (
	app: ^android.android_app,
	cmd: android.AppCmd,
) {
	assert_contextless(app != nil && app.userData != nil, "App pointer and global state pointer needs to be set")
	state := cast(^Engine_Android_Global_State)app.userData

	#partial switch cmd {
	case .INIT_WINDOW: if app.window != nil do state.flags += {.Window_Ready}
	case .TERM_WINDOW: state.flags -= {.Window_Ready}
	case .GAINED_FOCUS: state.flags += {.Focus}
	case .LOST_FOCUS: state.flags -= {.Focus}
	}
}

android_poll_events :: proc(engine_state: ^Engine_Android_Global_State) {
	if engine_state == nil do return
	POLL :: 0
	SLEEP :: -1

	events: i32
	source: ^android.android_poll_source

	timeout: i32 = POLL //POLL if .Window_Ready in engine_state.flags else SLEEP
	for {
		ident := android.ALooper_pollOnce(timeout, nil, &events, cast(^rawptr)&source)
		if ident < 0 do break

		if source != nil do source.process(engine_state.app_ptr, source)
	}
}

android_is_running :: proc(state: ^Engine_Android_Global_State) -> bool {
	return true if state.app_ptr.destroyRequested == 0 else false
}
