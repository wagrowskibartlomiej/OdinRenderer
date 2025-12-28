#+private file

package render

import "core:log"

import "vendor:glfw"

import android "androidglue/ndkbindings"

create_glfw_window :: proc() -> (window: Window_State) {
	if !glfw.Init() do log.panic("Glfw not initialized")
	when VERBOSE_LOG do log.debug("Glfw initialized")

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window.handle = glfw.CreateWindow(800, 600, "Odin Renderer", nil, nil)

	return
}
cleanup_glfw_window :: proc(state: ^Window_State) {
	glfw.DestroyWindow(glfw.WindowHandle(state.handle))
	when VERBOSE_LOG do log.debug("Glfw cleaned up")
}

when !DESKTOP_BUILD {
get_android_window :: proc(user_data: rawptr) -> (window: Window_State) { 
	assert(user_data != nil)
	window.handle = cast(^android.ANativeWindow)user_data
	when VERBOSE_LOG do log.debug("Android window state created")
	return
}
cleanup_android_window :: proc() {
	when VERBOSE_LOG do log.debug("Android window state cleaned up")
}
}


@(private="package")
Window_State :: struct {
	handle: rawptr, // Either GLFW Handle or ANativeWindow
}

@(private="package")
create_window :: proc(user_data: rawptr) -> (window: Window_State) {
	when DESKTOP_BUILD do return create_glfw_window()
	else do return get_android_window(user_data)
}

@(private="package")
cleanup_window :: proc(state: ^Window_State) {
	when DESKTOP_BUILD do cleanup_glfw_window(state)
	else do cleanup_android_window()
}


