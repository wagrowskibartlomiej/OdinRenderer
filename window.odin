package engine

Window_State :: struct {
	created: bool,
	handle, // Either GLFW Handle or ANativeWindow
	user_data: rawptr,
}

// Creates window with GLFW for desktop targets or retrieves it for Android from passed platform context.
create_window :: proc(window: ^Window_State, platform_context: rawptr) -> (success: bool) {
	if window == nil do return false

	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do return create_glfw_window(window)
	else {
		when ODIN_PLATFORM_SUBTARGET == .Android do return retrieve_android_window(window, platform_context)
		else do #panic(#procedure + " is not implemented for " + ODIN_PLATFORM_SUBTARGET + " subtarget")
	}
}

// Cleanes up window created with GLFW for desktop targets.
cleanup_window :: proc(state: ^Window_State, platform_context: rawptr) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do cleanup_glfw_window(state)
	else when ODIN_PLATFORM_SUBTARGET != .Android do #panic(#procedure + " is not implemented for " + ODIN_PLATFORM_SUBTARGET + " subtarget")
}
