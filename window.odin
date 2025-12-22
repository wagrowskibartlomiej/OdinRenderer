#+private file

package render

import "core:log"

import "vendor:glfw"

import android "androidglue/ndkbindings"

create_glfw_window :: proc() -> (window: Window_State) {
	if !glfw.Init() do log.panic("Glfw not initialized")
	when VERBOSE_LOG do log.debug("Glfw initialized")

	return
}
cleanup_glfw_window :: proc(state: ^Window_State) {
	when VERBOSE_LOG do log.debug("Glfw cleaned up")
}

get_android_window :: proc(user_data: rawptr) -> (window: Window_State) { 
	assert(user_data != nil)
	window.handle = cast(^android.ANativeWindow)user_data
	when VERBOSE_LOG do log.debug("Android window state created")
	return
}
cleanup_android_window :: proc() {
	when VERBOSE_LOG do log.debug("Android window state cleaned up")
}

@(private="package")
Window_State :: struct {
	handle: rawptr, // Either GLFW Handle or ANativeWindow
}

@(private="package")
create_window :: proc(user_data: rawptr = nil) -> (window: Window_State) {
	when DESKTOP_BUILD do return create_glfw_window()
	else do return get_android_window(user_data)
}

@(private="package")
cleanup_window :: proc(state: ^Window_State) {
	when DESKTOP_BUILD do cleanup_glfw_window(state)
	else do cleanup_android_window()
}


