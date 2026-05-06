#+build linux
package engine

import "base:runtime"

import android "./androidglue/ndkbindings"
import "core:log"
import "core:slice"

import vk "vendor:vulkan"

@(export)
android_main :: proc "c" (android_app_state: ^android.android_app) {
	context = runtime.default_context()
	state := new(Engine_Android_Global_State, runtime.heap_allocator())
	defer free(state, runtime.heap_allocator())
	context = engine_init_android(android_app_state, state)

	tri:  [3]Triangle_Vertex
	tri[0].color = {1, 0, 0, 1}
	tri[0].position = {0, 0.5}

	tri[1].color = {0, 1, 0, 1}
	tri[1].position = {-0.5, -0.5}

	tri[2].color = {0, 0, 1, 1}
	tri[2].position = {0.5, -0.5}
	context = init_android_state(android_app_state, state)

	for engine_is_running(state) {
		context = state.app_context.ctx

		engine_poll_events(state)

		if .Focus in state.flags && .Rendering_Ready in state.flags {
			engine_process_input()

			engine_update(raw_data(tri[:]), slice.size(tri[:]), true)

			res := engine_draw_frame(state, state.current_frame_index)

			if res == vk.Result.SUCCESS {
				state.current_frame_index =
					(state.current_frame_index + 1) %
					get_engine_configuration().settings.Frames_In_Flight
			} else {
				log.errorf("Draw frame failed: %v", res)
			}
		}
	}
}

handle_android_cmd: Proc_Handle_Anroid_CMD : proc "c" (
	app: ^android.android_app,
	cmd: android.AppCmd,
) {
	assert_contextless(app != nil)

	state := cast(^Engine_Android_Global_State)app.userData
	assert_contextless(state != nil)

	context = state.app_context.ctx

	#partial switch cmd {
	case .START:
		state.flags += {.Engine_Initalized}
	case .INIT_WINDOW:
		log.info("Android CMD: INIT_WINDOW - Initializing Renderer")
		if app.window != nil {
			success := engine_renderer_init(state)
			if success {
				state.flags += {.Rendering_Ready}
			} else {
				log.error("Renderer initialization failed")
				android.ANativeActivity_finish(app.activity)
			}
		}

	case .TERM_WINDOW:
		log.info("Android CMD: TERM_WINDOW - Cleaning up Renderer")
		state.flags -= {.Rendering_Ready}
		engine_renderer_cleanup(state)

	case .GAINED_FOCUS:
		log.info("Android CMD: GAINED_FOCUS")
		state.flags += {.Focus}

	case .LOST_FOCUS:
		log.info("Android CMD: LOST_FOCUS")
		state.flags -= {.Focus}

	case .DESTROY:
		log.info("Android CMD: DESTROY")
		engine_cleanup_android(state)
		state.flags -= {.Engine_Initalized}

	case .WINDOW_REDRAW_NEEDED:
		if .Rendering_Ready in state.flags {
			engine_draw_frame(state, state.current_frame_index)
		}

	case .WINDOW_RESIZED, .CONTENT_RECT_CHANGED:
		log.info("Android CMD: Resize/Content Rect Changed")

	case:
		log.warnf("Unhandled Android CMD: %v", cmd)
	}
}

android_poll_events :: proc(engine_state: ^Engine_Android_Global_State) {
	if engine_state == nil do return
	POLL :: 0
	SLEEP :: -1

	events: i32
	source: ^android.android_poll_source

	// If app is not active we "sleep" to not drain the battery
	timeout: i32 = POLL //.Focus in engine_state.flags ? POLL : SLEEP
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
