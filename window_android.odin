package engine

import "core:log"

import android "androidglue/ndkbindings"

// Retrieves an ANatvieWindow handle. Prefer `create_window`.
retrieve_android_window :: proc(window: ^Window_State, app: rawptr) -> (success: bool) { 
	if app == nil {
		log.errorf("ANatvieWindow was nil, when expected a valid pointer")
		return false
	}

	ptr := cast(^android.ANativeWindow)app

	window.handle = ptr
	when CONFIG_VERBOSE_LOG do log.debug("Android window handle retrieved")
	return true
}
