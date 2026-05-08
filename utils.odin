package engine

import "base:intrinsics"
import "core:log"
import "core:mem"

APPLICATION_NAME :: "ODIN_RENDERER"
ENGINE_NAME :: "ODIN_RENDERER_ENGINE"

// Extracts variant part of version from Vulkan encoded version number.
decode_vk_version_variant :: proc "contextless" (version: u32) -> u32 {
	return version >> 29
}
// Extracts patch part of version from Vulkan encoded version number.
decode_vk_version_patch :: proc "contextless" (version: u32) -> u32 {
	return version & 0xFFF
}
// Extracts minor part of version from Vulkan encoded version number.
decode_vk_version_minor :: proc "contextless" (version: u32) -> u32 {
	return (version >> 12) & 0x3FF
}
// Extracts major part of version from Vulkan encoded version number.
decode_vk_version_major :: proc "contextless" (version: u32) -> u32 {
	return (version >> 22) & 0x7F
}
// Returns decoded Vulkan version in fixed order [MAJOR, MINOR, PATCH, VARIANT].
decode_vk_version :: proc "contextless" (version: u32) -> [4]u32 {
	return {
		decode_vk_version_major(version),
		decode_vk_version_minor(version),
		decode_vk_version_patch(version),
		decode_vk_version_variant(version),
	}
}

set_resource_flag :: #force_inline proc(flags: ^bit_set[$T], flag: T) where intrinsics.type_is_enum(T) {
	flags^ |= bit_set[T]{flag}
	when CONFIG_VERBOSE_LOG do log.debugf("%v resource flag set", flag)
}

unset_resource_flag :: #force_inline proc(flags: ^bit_set[$T], flag: T) where intrinsics.type_is_enum(T) {
	flags^ |= bit_set[T]{flag}
	when CONFIG_VERBOSE_LOG do log.debugf("%v resource flag unset", flag)
}

log_called_when_resource_set :: proc(proc_name: string, resource_flag: $T) where intrinsics.type_is_enum(T) {
	log.warnf("Called '%v' when resource flag '%v' is set", proc_name, resource_flag)
}

log_called_when_resource_unset :: proc(proc_name: string, resource_flag: $T) where intrinsics.type_is_enum(T) {
	log.warnf("Called '%v' when resource flag '%v' is not set", proc_name, resource_flag)
}

find_aligned_offset_align_down :: proc(offset, alignment: u64) -> (off: u64, ok: bool) {
	if alignment == 0 {
		return
	}

	if offset % alignment == 0 {
		return offset, true
	}

	how_many_fits := (offset / alignment)

	return how_many_fits * alignment, true
}

find_aligned_offset_align_up :: proc(offset, alignment: u64) -> i64 {
	if alignment == 0 {
		return -1
	}

	if offset % alignment == 0 {
		return i64(offset)
	}

	how_many_fits := (offset / alignment)

	return i64((how_many_fits + 1) * alignment)
}

align_up_pow_2 :: proc(value, alignment: u64) -> u64 {
	assert(alignment > 0 && (alignment & (alignment - 1)) == 0)

	return (value + alignment - 1) & ~(alignment - 1)
}

get_global_state :: proc() -> ^Engine_Global_State {
	assert(context.user_ptr != nil)
	return cast(^Engine_Global_State) context.user_ptr
}

/*
	- Returns bytes in highest unit with correspoding string symbol.
	- Which unit will be returned depends on that if there are enough bytes to have at least 1 whole of a given unit.
	- Maximum converted unit is a Exabyte.
	- Usually should only be used for logging purposes.
*/
logs_simplify_bytes :: proc(bytes: u64) -> (num: f64, symbol: string) {
	switch bytes {
	case 0..< 1 * mem.Kilobyte:
		symbol = "B"
		num = f64(bytes)
	case 1 * mem.Kilobyte ..< 1 * mem.Megabyte:
		symbol = "KB"
		num = f64(bytes) / mem.Kilobyte
	case 1 * mem.Megabyte ..< 1 * mem.Gigabyte:
		symbol = "MB"
		num = f64(bytes) / mem.Megabyte
	case 1 * mem.Gigabyte ..< 1 * mem.Terabyte:
		symbol = "GB"
		num = f64(bytes) / mem.Gigabyte
	case 1 * mem.Terabyte ..< 1 * mem.Petabyte:
		symbol = "TB"
		num = f64(bytes) / mem.Terabyte
	case 1 * mem.Petabyte ..< 1 * mem.Exabyte:
		symbol = "PB"
		num = f64(bytes) / mem.Petabyte
	case:
		symbol = "EB"
		num = f64(bytes) / mem.Exabyte
	}

	return
}
