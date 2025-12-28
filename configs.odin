package render

VERBOSE_LOG :: #config(VERBOSE_LOG, false)
DESKTOP_BUILD :: #config(DESKTOP_BUILD, true)
TRACKING_ALLOCATOR :: #config(TRACKING_ALLOCATOR, false)
FRAMES_IN_FLIGHT := 2

change_frames_in_flight :: proc() {}
