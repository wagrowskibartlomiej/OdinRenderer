package engine

import "core:os"

engine_open :: proc(name: string, flags := os.File_Flags{.Read}, perm := os.Permissions_Default) -> (^os.File, os.Error) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do return os.open(name, flags, perm)
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET == .Android do return open_android()
	else do #panic(#procedure + " is not implemented for target " + CONFIG_BUILD_TARGET + " (subtarget " + ODIN_PLATFORM_SUBTARGET + ")")
}
