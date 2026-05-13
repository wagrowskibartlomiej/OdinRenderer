package engine

import "base:runtime"

import "core:c"
import "core:log"
import "core:slice"
import "core:strings"

import stbi "vendor:stb/image"

_load_png_desktop :: proc(
	filename: string,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	memory: []byte,
	data: Asset_Texture_Data,
	success: bool,
) {
	STBI_RGBA_CHANNELS :: 4
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	cfilename, err := strings.clone_to_cstring(filename, temp_allocator)
	if err != nil {
		log.errorf("PNG loading of file '%v' failed, cannot use cstring name: %v", filename, err)
		return
	}

	width, height, channels: c.int

	bytes := stbi.load(cfilename, &width, &height, &channels, STBI_RGBA_CHANNELS)
	if bytes == nil {
		log.errorf("STBI failed to load file '%v', got: %v", cfilename, bytes)
		return
	}
	defer stbi.image_free(bytes)

	data.width = i32(width)
	data.height = i32(height)
	data.depth = 1 // It's PNG so it'll be 1

	size := width * height * STBI_RGBA_CHANNELS
	img_bytes := bytes[:size]

	memory, err = slice.clone(img_bytes, allocator)
	if err != nil {
		log.errorf(
			"Failed to clone PNG data from STBI memory to applications allocated one: %v",
			err,
		)
		return
	}

	when CONFIG_VERBOSE_LOG do log.debugf("PNG file '%v' loaded successfully", filename)
	return memory, data, true
}
