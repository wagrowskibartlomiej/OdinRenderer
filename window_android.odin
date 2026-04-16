package engine

import "core:log"

import android "androidglue/ndkbindings"

// Retrieves an ANatvieWindow handle. Prefer `create_window`.
retrieve_android_window :: proc(window: ^Window_State) -> (success: bool) { 
	app := get_android_global_state().app_ptr
	if app == nil {
		log.errorf("Android App was nil, when expected a valid pointer")
		return false
	}
	
	if app.window == nil {
		log.errorf("ANatvieWindow was nil, when expected a valid pointer")
		return false
	}

	window.handle = app.window
	when CONFIG_VERBOSE_LOG do log.debug("Android window handle retrieved")
	return true
}
