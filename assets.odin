package render

import "base:runtime"
import "core:os"
import "core:log"
import "core:slice"
import "core:hash/xxhash"
import fp "core:path/filepath"

ASSET_PACK_NAME : string : "assets.pack"
ASSET_PACK_HEADER : string : "ODIN_RENDERER_ASSET_PACK"
ASSET_PACK_VERSION : u64 : 1

// TODO: Optimally building proccess should generate enum values of packages and use that instead of strings
Asset_Runtime :: struct {
	type: Asset_Type,
	extension: Asset_Supported_File_Extension,
	pkg: string,
	name: string,
	memory: Asset_Memory,
	references: int,
	meta_data: rawptr,
	user_data: rawptr,
}

Asset_Descriptor :: struct {
	hash: u64le, 
	type: i32le,
	extension: i32le,
	pkg_len: i64le,
	name_len: i64le,
	using _: Asset_Memory_File_Entry,
	_pkg_backing: []byte,
	_name_backing: []byte,
}

Assets_State :: struct {
	allocator: runtime.Allocator,
	assets: map[xxhash.xxh_u64]Asset_Runtime,
	asset_pack_handle: Asset_Pack_Handle,
	hash_state: xxhash.XXH3_state,
}

Opaque_Struct :: struct {}

// Union to share Android and Desktop Code
Asset_Pack_Handle :: union {
	Opaque_Struct,
	os.Handle,
}

Asset_Memory_File_Entry :: struct {
	offset, length: i64,
}

Asset_Memory :: union {
	[]byte,
	[]u32,
	Asset_Memory_File_Entry
}

Asset_Type :: enum i32 {
	Primitive_Triangle,
	Mesh,
	Texture,
	Shader,
	Asset_Pack,
}

Asset_Supported_File_Extension :: enum i32 {
	JPG,
	PNG,
	OBJ,
	PACK,
	SPIRV,
	TRIANGLE,
}

Asset_Supported_File_Extension_String :: [Asset_Supported_File_Extension]string {
	.JPG = "jpg",
	.PNG = "png",
	.OBJ = "obj",
	.PACK = "pack",
	.SPIRV = "spv",
	.TRIANGLE = "tri"
}

load_asset :: proc{
	load_asset_editor,
	load_asset_to_map_editor,
	load_asset_mem,
}

load_asset_editor :: proc(filename: string, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (asset: Asset_Runtime, success: bool) {
	file_handle, err := os.open(filename)
	if err != nil {
		log.errorf("Cannot open file '%v', error: %v", filename, err)
		return
	}
	defer {
		err = os.close(file_handle)
		if err != nil do log.errorf("File '%v' closing error: %v", err)
	}

	asset.type, asset.extension = get_asset_type_from_filename_extension(filename, temp_allocator)

	if asset.extension == nil {
		log.errorf("Unsupported asset extension of file '%v'", filename)
		return
	} else if asset.extension == .PACK {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when VERBOSE_LOG do log.debugf("Asset extension of file '%v' detected as: %v", filename, asset.extension)

	if asset.type == nil {
		log.errorf("Cannot determine asset type that file '%v' contains", filename)
		return
	} else if asset.type == .Asset_Pack {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when VERBOSE_LOG do log.debugf("Asset type from file '%v' detected as: %v", filename, asset.type)

	switch asset.type {
		case .Asset_Pack:
			log.error("If this code branch gets executed, it probably means that there is a serious bug")
			return
		case:
			// Memory loading from file will be pretty much the same for every type
			byte_mem, err := os.read_entire_file_or_err(filename, allocator)
			if err != nil {
				log.errorf("Reading of file '%v' failed, error: %v", filename, err)
				success = false
				return
			}
			asset.memory = byte_mem
			fallthrough
		case .Shader:
			asset.memory = slice.reinterpret([]u32, asset.memory.([]byte))
			when VERBOSE_LOG do log.debugf("Loaded shader data from file '%v'", filename)
		case .Mesh: 
			when VERBOSE_LOG do log.debugf("Loaded mesh data from file '%v'", filename)
		case .Texture:
			when VERBOSE_LOG do log.debugf("Loaded texture data from file '%v'", filename)
		case .Primitive_Triangle:
			when VERBOSE_LOG do log.debugf("Loaded primitve data from file '%v'", filename)
	}

	// Just in case I'll add other functionality I'll leave the check here
	defer if !success {
		if asset.type == .Shader do delete(asset.memory.([]u32), allocator)
		else do delete(asset.memory.([]byte), allocator)

		asset.memory = nil
	}

	asset.name = filename
	success = true
	return
}

load_asset_to_map_editor :: proc(filename: string, state: ^Assets_State, temp_allocator := context.temp_allocator) -> (success: bool) {
	asset: Asset_Runtime
	asset, success = load_asset_editor(filename, state.allocator, temp_allocator)
	success or_return

	h := generate_id_for_asset(&state.hash_state, asset.type, asset.name, asset.pkg)

	a, exists := state.assets[h]

	if exists {
		log.errorf("Cannot load asset from '%v', generated ID is already taken by '%v'", filename, a.name)
		success = false
		return
	} else {
		state.assets[h] = asset
		when VERBOSE_LOG do log.debugf("Loaded asset from filename '%v' and added it to assets map", filename)
	}

	success = true
	return
}

load_assets_dir_to_map_editor :: proc(state: ^Assets_State, temp_allocator := context.temp_allocator) -> (success: bool) {
	success = load_assets_from_dir("assets", state, temp_allocator)
	if !success do cleanup_assets_map_editor(state)

	return
}


load_assets_from_dir :: proc(dir: string, state: ^Assets_State, temp_allocator := context.temp_allocator) -> (success: bool) {
	handle, err := os.open(dir)
	if err != nil {
		log.errorf("Cannot open %v directory: %v", err)
		return false
	}
	defer os.close(handle)
	
	file_infos: []os.File_Info
	file_infos, err = os.read_dir(handle, 0, temp_allocator)
	if err != nil {
		log.errorf("Error when reading assets from directory %v: %v", dir, err)
		return
	}
	defer delete(file_infos, temp_allocator)

	for f in file_infos {
		if f.is_dir do success = load_assets_from_dir(f.name, state, temp_allocator)
		else do success = load_asset_to_map_editor(f.name, state, temp_allocator)
		success or_return
	}

	when VERBOSE_LOG do log.debugf("Directory %v loaded successfuly", dir)
	return true
}

// Procedure assumes that file extensions are ASCII
get_asset_type_from_filename_extension :: proc(name: string, temp_allocator := context.temp_allocator) -> (type: Asset_Type, extension: Asset_Supported_File_Extension) {
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
	for name, ext in Asset_Supported_File_Extension_String{
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


build_asset_pack :: proc(assets: map[xxhash.xxh_u64]Asset_Runtime, allocator := context.allocator, temp_allocator := context.temp_allocator) {
	handle, err := os.open(ASSET_PACK_NAME, os.O_TRUNC | os.O_CREATE | os.O_WRONLY, 0o644)
	if err != nil {
		log.errorf("Asset pack file creation error: %v", err)
	}

	header_offset: i64

	asset_pack_name_b := transmute([]byte)ASSET_PACK_NAME
	os.write_at(handle, asset_pack_name_b[:], header_offset)
	header_offset += i64(slice.size(asset_pack_name_b))

	ver := transmute([size_of(ASSET_PACK_VERSION)]byte)ASSET_PACK_VERSION
	os.write_at(handle, ver[:], header_offset)
	header_offset += size_of(ASSET_PACK_VERSION)

	count := transmute([size_of(i64)]byte) i64(len(assets))
	os.write_at(handle, count[:], header_offset)
	header_offset += size_of(i64)

	map_offset_counter := header_offset
	// Calculate all map offset size, to make writes to entries in file and their binary data
	map_offset := map_offset_counter
	for h, &a in assets do map_offset += get_asset_descriptor_file_byte_size(&a)

	binary_data_offset := map_offset
	// Convert to bytes and write all needed Asset_Runtime data
	for h, a in assets {
		hash_b := transmute([size_of(Asset_Descriptor{}.hash)]byte) cast(u64le)h
		os.write_at(handle, hash_b[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.hash)

		type_b := transmute([size_of(Asset_Descriptor{}.type)]byte) cast(i32le)a.type
		os.write_at(handle, type_b[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.type)

		ext_b := transmute([size_of(Asset_Descriptor{}.extension)]byte) cast(i32le)a.extension
		os.write_at(handle, ext_b[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.extension)

		pkg_len_b := transmute([size_of(Asset_Descriptor{}.pkg_len)]byte) cast(i64le)len(a.pkg)
		os.write_at(handle, pkg_len_b[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.pkg_len)

		pkg_b := transmute([]byte)a.pkg
		os.write_at(handle, pkg_b, map_offset_counter)
		map_offset_counter += i64(len(pkg_b)) * size_of(pkg_b[0])

		name_len_b := transmute([size_of(Asset_Descriptor{}.name_len)]byte) cast(i64le)len(a.name)
		os.write_at(handle, name_len_b[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.name_len)

		name_b := transmute([]byte)a.name
		os.write_at(handle, name_b, map_offset_counter)
		map_offset_counter += i64(len(name_b)) * size_of(name_b[0])

		mem: []byte

		if a.type == .Shader do mem = slice.reinterpret([]byte, a.memory.([]u32))
		else do mem = a.memory.([]byte)

		os.write_at(handle, mem, binary_data_offset)

		binary_data_len := transmute([size_of(Asset_Descriptor{}.length)]byte) cast(i64le)len(mem)
		os.write_at(handle, binary_data_len[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.length)

		b_offset := transmute([size_of(Asset_Descriptor{}.offset)]byte)binary_data_offset
		os.write_at(handle, b_offset[:], map_offset_counter)
		map_offset_counter += size_of(Asset_Descriptor{}.offset)

		binary_data_offset += i64(slice.size(mem))
	}

}

get_asset_descriptor_file_byte_size :: proc(a: ^Asset_Runtime) -> (size: i64) {
	size += size_of(Asset_Descriptor{}.hash)
	size += size_of(a.type)
	size += size_of(a.extension)
	size += size_of(Asset_Descriptor{}.pkg_len)
	size += (i64(len(a.pkg)) * size_of(byte))
	size += (i64(len(a.name)) * size_of(byte)) 
	size += size_of(Asset_Descriptor{}.length)
	size += size_of(Asset_Descriptor{}.offset)

	return
}

generate_id_for_asset :: proc(hash_state: ^xxhash.XXH3_state, type: Asset_Type, name, pkg: string) -> xxhash.xxh_u64 {
	type := type

	err := xxhash.XXH3_64_reset(hash_state)
	if err != nil do return 0

	separator := [1]byte{0}

	xxhash.XXH3_64_update(hash_state, slice.bytes_from_ptr(&type, size_of(type)))
	xxhash.XXH3_64_update(hash_state, separator[:])
	xxhash.XXH3_64_update(hash_state, transmute([]byte)name)
	xxhash.XXH3_64_update(hash_state, separator[:])
	xxhash.XXH3_64_update(hash_state, transmute([]byte)pkg)

	return xxhash.XXH3_64_digest(hash_state)
}

load_asset_mem :: proc(a: ^Asset_Runtime, handle: Asset_Pack_Handle, allocator := context.allocator) -> (success: bool) {
	if type_of(a.memory) != Asset_Memory_File_Entry {
		log.warn("Called load asset memory while memory was not recognized as unloaded, possible error")
		return false
	}

	mem, alloc_err := make([]byte, a.memory.(Asset_Memory_File_Entry).length, allocator)
	if alloc_err != nil {
		log.errorf("Cannot allocate memory for resource '%v', error: %v", a.name, alloc_err)
		return false
	}

	n, err := os.read_at(handle.(os.Handle), mem, a.memory.(Asset_Memory_File_Entry).offset)
	if n != len(mem) do log.warnf("Memory for asset '%v' read was less than there is allocated, possible error: ALLOCATED [%v] | READ [%v]", a.name, len(mem), n)
	if err != nil {
		log.errorf("Error occured when loading asset '%v' memory, error: %v", a.name, err)
		delete(mem, allocator)
		return false
	}

	if a.type == .Shader do a.memory = slice.reinterpret([]u32, mem)
	else do a.memory = mem
	return true
}

unload_asset_memory :: proc(a: ^Asset_Runtime, allocator := context.allocator) -> (err: os.Error) {
	switch v in a.memory {
		case Asset_Memory_File_Entry:
			log.warnf("Called memory cleanup on asset '%v' when memory is detected as not loaded and being a descriptor of file entry", a.name)
			return .Not_Exist
		case []u32:
			err = delete(a.memory.([]u32), allocator)
			if err != nil do log.errorf("Error when trying to delete 32bit word size memory of asset '%v' (TYPE: %v): %v", a.name, a.type, err)
		case []byte:
			err = delete(a.memory.([]byte), allocator)
			if err != nil do log.errorf("Error when trying to delete byte size memory of asset '%v' (TYPE: %v): %v", a.name, a.type, err)
	}

	return
}

// WARN: USE ONLY FOR TESTING OR WHEN YOU KNOW WHAT YOU'RE DOING
// Loads whole asset pack map and memory of all assets 
load_assets_immediate :: proc(handle: Asset_Pack_Handle, allocator := context.allocator) -> (m: map[xxhash.xxh_u64]Asset_Runtime, success: bool) {
	m, success = load_assets_map(handle, allocator)
	if !success {
		log.error("Cannot load assets map")
		return
	}

	for _, &ass in m do load_asset_mem(&ass, handle, allocator)

	return
}


load_assets_map :: proc(handle: Asset_Pack_Handle, allocator := context.allocator) -> (m: map[xxhash.xxh_u64]Asset_Runtime, success: bool) {	
	header_offset: i64
	
	asset_pack_name_b := transmute([]byte)ASSET_PACK_NAME
	header_offset += i64(slice.size(asset_pack_name_b))
	header_offset += size_of(ASSET_PACK_VERSION)
	asset_count: i64 
	asset_count_b := transmute([size_of(asset_count)]byte)asset_count
	
	n, err := os.read_at(handle.(os.Handle), asset_count_b[:], header_offset)
	if err != nil || n != size_of(i64le) {
		log.errorf("Cannot read assets map count from file (bytes read: %v), error: %v", n, err)
		return
	}
	header_offset += size_of(asset_count)

	m = make(map[xxhash.xxh_u64]Asset_Runtime, asset_count, allocator)
	defer if !success do delete(m)

	offset_counter := header_offset
	a: Asset_Descriptor

	defer if !success do for _, asset in m {
		if len(asset.name) > 0 do delete(asset.name, allocator)
		if len(asset.pkg) > 0 do delete(asset.pkg, allocator)
	}

	for i in 0 ..< asset_count {
		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&a.hash, size_of(a.hash)), offset_counter)
		if n != size_of(a.hash) || err != nil {
			log.errorf(
				"(ENTRY: %v) Cannot read asset hash (bytes read: %v, expected size %v) error: %v",
				i, n, size_of(a.hash), err
			)
			success = false
			return
		}
		offset_counter += size_of(a.hash)

		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&a.type, size_of(a.type)), offset_counter)
		if n != size_of(a.type) || err != nil {
			log.errorf(
				"(UID: %v) Cannot read asset type (bytes read: %v, expected size %v) error: %v",
				a.hash, n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(a.type)

		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&a.extension, size_of(a.extension)), offset_counter)
		if n != size_of(a.extension) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v) Cannot read asset extension (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(a.extension)

		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&a.pkg_len, size_of(a.pkg_len)), offset_counter)
		if n != size_of(a.pkg_len) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v) Cannot read package name length (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(a.pkg_len)

		a._pkg_backing = make([]byte, int(a.pkg_len), allocator)
		defer if !success do delete(a._pkg_backing, allocator)

		n, err = os.read_at(handle.(os.Handle), a._pkg_backing[:], offset_counter)
		if n != slice.size(a._pkg_backing) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v) Cannot read package name (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += i64(slice.size(a._pkg_backing))

		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&a.name_len, size_of(a.name_len)), offset_counter)
		if n != size_of(a.name_len) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v | PKG: %v) Cannot read name length (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), string(a._pkg_backing[:]), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(a.name_len)

		a._name_backing = make([]byte, int(a.name_len), allocator)
		defer if !success do delete(a._name_backing, allocator)

		n, err = os.read_at(handle.(os.Handle), a._name_backing[:], offset_counter)
		if n != slice.size(a._name_backing) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v | PKG: %v) Cannot read name (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), string(a._pkg_backing[:]), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += i64(slice.size(a._name_backing))

		mem_len: i64le
		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&mem_len, size_of(mem_len)), offset_counter)
		if n != size_of(a.length) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v | PKG: %v | NAME: %v) Cannot read memory length (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), string(a._pkg_backing[:]), string(a._name_backing[:]), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(mem_len)
		a.length = i64(mem_len)

		mem_offset: i64le
		n, err = os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&mem_offset, size_of(mem_offset)), offset_counter)
		if n != size_of(a.offset) || err != nil {
			log.errorf(
				"(UID: %v | TYPE: %v | PKG: %v | NAME: %v) Cannot read memory file offset (bytes read: %v, expected size %v) error: %v",
				a.hash, Asset_Type(a.type), string(a._pkg_backing[:]), string(a._name_backing[:]), n, size_of(a.type), err
			)
			success = false
			return
		}
		offset_counter += size_of(mem_offset)
		a.offset = i64(mem_offset)

		m[cast(xxhash.xxh_u64)a.hash] = {
			type = cast(Asset_Type)a.type,
			extension = cast(Asset_Supported_File_Extension)a.extension,
			pkg = string(a._pkg_backing[:]),
			name = string(a._name_backing[:]),
			memory = Asset_Memory_File_Entry{a.offset, a.length}
		}

		success = true
	}

	when VERBOSE_LOG do log.debug("Assets map loaded")
	success = true
	return
}

cleanup_assets_mem :: proc(state: ^Assets_State) {
	for _, a in state.assets {
		#partial switch a.type {
		case .Shader:
			delete(a.memory.([]u32), state.allocator)
		case:
			delete(a.memory.([]byte), state.allocator)
		}
	}
}

cleanup_assets_map :: proc(state: ^Assets_State) {
	for _, a in state.assets {
		#partial switch a.type {
		case .Shader:
			delete(a.memory.([]u32), state.allocator)
		case:
			delete(a.memory.([]byte), state.allocator)
		}
		delete(a.name, state.allocator)
		delete(a.pkg, state.allocator)
	}

	delete(state.assets)
}

cleanup_assets_map_editor :: proc(state: ^Assets_State) {
	cleanup_assets_mem(state)
	delete(state.assets)
}
