package render

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
