package engine

import "base:intrinsics"
import "core:log"

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

find_aligned_offset_align_down :: proc(offset, alignment: u64) -> i64 {
	if alignment == 0 {
		return -1
	}

	if offset % alignment == 0 {
		return offset
	}

	how_many_fits := (offset / alignment)

	return how_many_fits * alignment
}

find_aligned_offset_align_up :: proc(offset, alignment: u64) -> i64 {
	if alignment == 0 {
		return -1
	}

	if offset % alignment == 0 {
		return offset
	}

	how_many_fits := (offset / alignment)

	return (how_many_fits + 1) * alignment
}

align_up_pow_2 :: proc(value, alignment: u64) -> u64 {
	assert(alignment > 0 && (alignment & (alignment - 1)) == 0)

	return (value + alignment - 1) & ~(alignment - 1)
}
