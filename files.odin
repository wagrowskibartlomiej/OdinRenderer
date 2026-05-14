package engine

import "core:os"

//NOTE: There currently is a bug when writing in Android in external or internal storage. Android is for now limited to only read from APK Assets.
engine_open :: proc(name: string, flags := os.File_Flags{.Read}, perm := os.Permissions_Default, android_options := Android_Search_Everywhere_Not_Thread_Safe_Flags) -> (^os.File, os.Error) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do return os.open(name, flags, perm)
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET == .Android do return android_open(name, flags, perm, android_options)
	else do #panic(#procedure + " is not implemented for target " + CONFIG_BUILD_TARGET + " (subtarget " + ODIN_PLATFORM_SUBTARGET + ")")
}

// Used only when Opening Android's APK
Android_File_Impl_Flag :: enum {
	Search_Assets,
	Search_Internal_Storage,
	Search_External_Storage,
	Thread_Safe_APK,
	Storage_Permision, // Storage permision granted by user if included in manifest, must be set by a caller
}
Android_File_Impl_Flags :: bit_set[Android_File_Impl_Flag]
Android_Search_Everywhere_Not_Thread_Safe_Flags := Android_File_Impl_Flags{.Search_Assets, .Search_Internal_Storage, .Search_External_Storage}
