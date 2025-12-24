#+build linux

package render

import android "./androidglue/ndkbindings"

get_android_window :: proc(user_data: rawptr) -> (window: Window_State) { 
	assert(user_data != nil)
	window.handle = cast(^android.ANativeWindow)user_data
	when VERBOSE_LOG do log.debug("Android window state created")
	return
}
cleanup_android_window :: proc() {
	when VERBOSE_LOG do log.debug("Android window state cleaned up")
}
