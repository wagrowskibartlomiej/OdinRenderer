package render

import "core:os"
import "core:log"
import "core:slice"



Asset :: struct {
	type: Asset_Type,
	extension: Supported_File_Extension,
	memory: Memory_Slice,
}


Memory_Slice :: union {
	[]byte,
	[]u32
}


Asset_Type :: enum {
	Primitive_Triangle,
	Mesh,
	Texture,
	Shader,
	Asset_Pack,
}

Supported_File_Extension :: enum {
	JPG,
	PNG,
	OBJ,
	PACK,
	SPIRV,
	TRIANGLE,
}

Supported_File_Extension_String :: [Supported_File_Extension]string {
	.JPG = "jpg",
	.PNG = "png",
	.OBJ = "obj",
	.PACK = "pack",
	.SPIRV = "spv",
	.TRIANGLE = "tri"
}

load_asset :: proc {
	load_from_asset_dir,
	load_from_asset_pack,
}

load_from_asset_dir :: proc(name: string, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (asset: Asset, success: bool) {
	file_handle, err := os.open(name)
	if err != nil {
		log.errorf("Cannot open file '%v', error: %v", name, err)
		return
	}
	defer {
		err = os.close(file_handle)
		if err != nil do log.errorf("File '%v' closing error: %v", err)
	}

	asset.type, asset.extension = get_asset_type_from_filename_extension(name, temp_allocator)

	if asset.extension == nil {
		log.errorf("Unsupported asset extension of file '%v'", name)
		return
	} else if asset.extension == .PACK {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when VERBOSE_LOG do log.debugf("Asset extension of file '%v' detected as: %v", name, asset.extension)

	if asset.type == nil {
		log.errorf("Cannot determine asset type that file '%v' contains", name)
		return
	} else if asset.type == .Asset_Pack {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when VERBOSE_LOG do log.debugf("Asset type from file '%v' detected as: %v", name, asset.type)

	switch asset.type {
		case .Mesh: 
			asset.memory = load_mesh()
		case .Texture:
			asset.memory = load_texture()
		case .Primitive_Triangle:
			asset.memory = load_primitive()
		case .Shader:
			asset.memory, success = load_shader(file_handle, allocator)
		case .Asset_Pack:
			asset.memory = load_asset_pack()
	}

	if !success {
		log.errorf("Reading file '%v' failed", name)
		return
	}
	
	success = true
	return
}

// Procedure assumes that file extensions are ASCII
get_asset_type_from_filename_extension :: proc(name: string, temp_allocator := context.temp_allocator) -> (type: Asset_Type, extension: Supported_File_Extension) {
	buffer := make([dynamic]byte, 8, temp_allocator)
	defer delete(buffer)

	prev_state: bool
	start_recording: bool
	for i in 0..<len(name) {

		char := name[i]
		
		switch char {
		case '.':
			if len(buffer) > 0 do clear(&buffer)
			start_recording = true
		case: 
			if start_recording do append(&buffer, char)
		}
	}

	if len(buffer) <= 0 do return nil, nil
	
	ext_name := string(buffer[:])
	for name, ext in Supported_File_Extension_String{
		if name == ext_name {
			extension = ext
			break
		}
	}

	switch extension {
	case .JPG, .PNG:
		type = .Texture
	case .OBJ:
		type = .Mesh
	case .PACK:
		type = .Asset_Pack
	case .SPIRV:
		type = .Shader
	case .TRIANGLE:
		type = .Primitive_Triangle
	case: 
		type = nil
	}

	return
}

load_from_asset_pack :: proc(name: string, asset_pack_handle: rawptr) -> (asset: Asset, success: bool) {
	when DESKTOP_BUILD do return load_from_asset_pack_desktop(name, asset_pack_handle)
	else do return load_from_asset_pack_android(name, asset_pack_handle)
}

load_from_asset_pack_desktop :: proc(name: string, asset_pack_handle: rawptr) -> (asset: Asset, success: bool) {
	log.panic("Load from asset pack desktop is not implemnted")
}

build_asset_pack :: proc() {
	log.panic("Build asset pack not implemented")
}

load_mesh :: proc() -> []byte {
	log.panic("Load mesh not implemented")
}
load_texture :: proc() -> []byte {
	log.panic("Load texture not implemented")
}
load_asset_pack :: proc() -> []byte {
	log.panic("Load asset pack not implemented")
}
load_shader :: proc(file: os.Handle, allocator := context.allocator) -> (data: []u32, success: bool) {
	bytes, err := os.read_entire_file_from_handle_or_err(file, allocator)
	if err != nil {
		log.errorf("Shader file reading error: %v", err)
		return
	}

	data = slice.reinterpret([]u32, bytes)
	success = true
	return

}
load_primitive :: proc() -> []byte {
	log.panic("Load primitive not implemented")
}
