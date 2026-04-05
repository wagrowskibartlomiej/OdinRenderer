#+feature using-stmt
package engine

import "base:runtime"

import os "core:os/old"
import "core:log"
import "core:slice"
import "core:strings"
import "core:hash/xxhash"
import fp "core:path/filepath"

/*
TODO:   I should rehaul this assets pack building method, cause it is really not ideal
	to rely on Asset_Descriptor and manually adding size to the procedure get_asset_descriptor_file_byte_size
*/

ASSET_PACK_NAME : string : "assets.pack"
ASSET_PACK_HEADER : string : "ODINRENDERERASSETPACK"
ASSET_PACK_VERSION : u64 : 1

PKG_BACKUP_NAME :: "PKGUNRESLOVED"
// TODO: Optimally building proccess should generate enum values of packages and use that instead of strings
// NOTE: Maybe add copy_number field to the structure to allow independent copies
Asset_Runtime :: struct {
	type: Asset_Type,
	extension: Asset_Supported_File_Extension,
	pkg: string,
	name: string,
	memory: Asset_Memory,
	references: int,
	metadata: rawptr,
	user_data: rawptr,
}

Asset_Editor_Metadata :: struct {
	filepath: string,
	editor_user_data: rawptr,
}

// Used for assets pack building and parsing
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
	allocator: runtime.Allocator, // Used for items map, pkgs interner
	binary_data_allocator: runtime.Allocator, // Used for binary data of assets like raw data of texture, sounds etc.
	items: map[xxhash.xxh_u64]Asset_Runtime,
	pkgs: strings.Intern,
	asset_pack_handle: Asset_Pack_Handle, // Handle to default asset pack (used in build mode)
	hash_state: xxhash.XXH3_state, // State for handling asstes ID generation, either for building assets pack or generating hash ID to retrieve asset
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

get_asset :: proc{
	get_asset_copy,
	get_asset_ptr
}

get_asset_copy :: proc(state: ^Assets_State, type: Asset_Type, name, pkg: string) -> (asset: Asset_Runtime, exists: bool) {
	asset_id := generate_id_for_asset(&state.hash_state, type, name, pkg)
	asset, exists = state.items[asset_id]
	
	return
}

get_asset_ptr :: proc(asset: ^Asset_Runtime, state: ^Assets_State, type: Asset_Type, name, pkg: string) -> (exists: bool) {
	asset := asset

	asset_id := generate_id_for_asset(&state.hash_state, type, name, pkg)
	asset, exists = &state.items[asset_id]
	
	return
}

get_asset_memory :: proc(state: ^Assets_State, type: Asset_Type, name, pkg: string) -> (mem: Asset_Memory, exists: bool) {
	asset_id := generate_id_for_asset(&state.hash_state, type, name, pkg)
	asset: Asset_Runtime

	asset, exists = state.items[asset_id]
	if !exists do return

	mem = asset.memory
	return
}

initalize_assets :: proc(allocator := context.allocator, binary_data_allocator := context.allocator, temp_allocator := context.temp_allocator) -> (state: Assets_State, success: bool) {
	// for both inizalize structure datas with map pkg interner ect,
	// give option to pass custom allocators
	// then for EDITOR load assets dir to map editor etc.
	// for BUILD load asset pack
	state.allocator = allocator
	state.binary_data_allocator = binary_data_allocator

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		state.items = make(map[xxhash.xxh_u64]Asset_Runtime, allocator)
		defer if !success do delete(state.items)

		err := strings.intern_init(&state.pkgs, allocator, allocator)
		if err != nil {
			log.errorf("Pkgs name interner creation failed: %v", err)
			success = false
			return
		}
		defer if !success do strings.intern_destroy(&state.pkgs)

		success = load_assets_dir_to_map_editor(&state, temp_allocator)
		success or_return
	} else {

	}

	when CONFIG_VERBOSE_LOG do log.debug("Assets state initialization successful")

	success = true
	return
}


cleanup_assets :: proc(state: ^Assets_State) -> (success: bool) {
	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] do cleanup_assets_editor(state)

	when CONFIG_VERBOSE_LOG do log.debug("Assets state cleanup successful")
	success = true
	return
}

// You can pass pkg name to procedure to make it use within asset, but if left empty attempt will be made to get it from directory that contains the asset
load_asset_editor :: proc(filename: string, pkg: string = "", allocator := context.allocator, binary_data_allocator := context.allocator, temp_allocator := context.temp_allocator) -> (asset: Asset_Runtime, success: bool) {
	file_handle, err := os.open(filename)
	if err != nil {
		log.errorf("Cannot open file '%v', error: %v", filename, err)
		return
	}
	defer {
		err = os.close(file_handle)
		if err != nil do log.errorf("File '%v' closing error: %v", err)
	}

	if pkg == "" {
		dir_name, _ := get_file_pkg(filename, allocator, temp_allocator)
		asset.pkg = dir_name
	} else do asset.pkg = pkg

	asset.type, asset.extension = get_asset_type_from_filename_extension(filename, temp_allocator)

	if asset.extension == nil {
		log.errorf("Unsupported asset extension of file '%v'", filename)
		return
	} else if asset.extension == .PACK {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when CONFIG_VERBOSE_LOG do log.debugf("Asset extension of file '%v' detected as: %v", filename, asset.extension)

	if asset.type == nil {
		log.errorf("Cannot determine asset type that file '%v' contains", filename)
		return
	} else if asset.type == .Asset_Pack {
		log.error("Asset pack cannot be loaded with this procedure")
		return
	}
	when CONFIG_VERBOSE_LOG do log.debugf("Asset type from file '%v' detected as: %v", filename, asset.type)

	// Memory loading from file will be pretty much the same for every type
	byte_mem, read_err := os.read_entire_file_or_err(file_handle, binary_data_allocator)
	if read_err != nil {
		log.errorf("Reading of file '%v' failed, error: %v", filename, read_err)
		success = false
		return
	}

	switch asset.type {
		case .Asset_Pack:
			log.error("If this code branch gets executed, it probably means that there is a serious bug")
			return
		case .Shader:
			asset.memory = slice.reinterpret([]u32, byte_mem)
			when CONFIG_VERBOSE_LOG do log.debugf("Loaded shader data from file '%v'", filename)
		case .Mesh: 
			asset.memory = byte_mem
			when CONFIG_VERBOSE_LOG do log.debugf("Loaded mesh data from file '%v'", filename)
		case .Texture:
			asset.memory = byte_mem
			when CONFIG_VERBOSE_LOG do log.debugf("Loaded texture data from file '%v'", filename)
		case .Primitive_Triangle:
			asset.memory = byte_mem
			when CONFIG_VERBOSE_LOG do log.debugf("Loaded primitve data from file '%v'", filename)
	}

	// Just in case I'll add other functionality I'll leave the check here
	defer if !success {
		if asset.type == .Shader do delete(asset.memory.([]u32), binary_data_allocator)
		else do delete(asset.memory.([]byte), binary_data_allocator)

		asset.memory = nil
	}

	name := fp.base(filename)
	metadata := new(Asset_Editor_Metadata, allocator)
	metadata.filepath = filename
	asset.metadata = metadata
	asset.name = name

	success = true
	return
}

load_asset_to_map_editor :: proc(filename: string, state: ^Assets_State, pkg: string = "", temp_allocator := context.temp_allocator) -> (success: bool) {
	asset: Asset_Runtime
	asset, success = load_asset_editor(filename, pkg, state.allocator, state.binary_data_allocator, temp_allocator)
	pkg_interned, resolved_err := strings.intern_get(&state.pkgs, asset.pkg)

	if resolved_err != nil {
		log.errorf("Interning of pkg '%v' failed: %v", asset.pkg, resolved_err)
		if pkg == "" do delete(asset.pkg, state.allocator)
		asset.pkg = PKG_BACKUP_NAME
	} else {
		if pkg == "" do delete(asset.pkg, state.allocator)
		asset.pkg = pkg_interned
	}

	success or_return

	h := generate_id_for_asset(&state.hash_state, asset.type, asset.name, asset.pkg)

	a, exists := state.items[h]

	if exists {
		log.errorf("Cannot load asset from '%v', generated ID is already taken by '%v'", filename, a.name)
		success = false
		return
	} else {
		state.items[h] = asset
		when CONFIG_VERBOSE_LOG do log.debugf("Loaded asset from filename '%v' and added it to assets map", filename)
	}

	success = true
	return
}

load_assets_dir_to_map_editor :: proc(state: ^Assets_State, temp_allocator := context.temp_allocator) -> (success: bool) {
	success = load_assets_from_dir("assets", state, temp_allocator)
	if !success do cleanup_assets_map_editor(state)

	return
}

get_file_pkg :: proc(filename: string, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (dir: string, success: bool) {
	absolute, path_err := fp.abs(filename, temp_allocator)
	if path_err != nil {
		log.errorf("Cannot get a directory of a file '%v'", filename)
		success = false
		return
	}
	defer delete(absolute, temp_allocator)

	dirs := fp.dir(absolute, temp_allocator)
	defer delete(dirs, temp_allocator)
	if dirs == "." {
		dir = PKG_BACKUP_NAME
		success = true
		return
	}

	dir_backing := make([dynamic]byte, 0, 256, allocator)

	// TODO: Could maybe be improved to just search from reverse
	for i in 0..<len(absolute) {
		switch absolute[i] {
			case fp.SEPARATOR:
				clear(&dir_backing)
			case:
				append(&dir_backing, absolute[i])
		}
	}

	_, err := shrink(&dir_backing)
	if err != nil do log.errorf("Cannot shrink buffer of '%v': %v", string(dir_backing[:]), err)
	dir = string(dir_backing[:])
	success = true
	return
}

get_file_pkg_to_map :: proc(filename: string, state: ^Assets_State, temp_allocator := context.temp_allocator) {
	pkg, _ := get_file_pkg(filename, state.allocator, temp_allocator)
	defer delete(pkg, state.allocator)
	_, err := strings.intern_get(&state.pkgs, pkg)
	if err != nil do log.errorf("Cannot get string '%v' from packages intern: %v", err)
}

load_assets_from_dir :: proc(dir: string, state: ^Assets_State, temp_allocator := context.temp_allocator) -> (success: bool) {
	handle, err := os.open(dir)
	if err != nil {
		log.errorf("Cannot open %v directory: %v", dir, err)
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

	if len(file_infos) <= 0 {
		when CONFIG_VERBOSE_LOG do log.debugf("Empty directory detected '%v'", dir)
		return
	}

	pkg, _ := get_file_pkg(dir, state.allocator, temp_allocator)
	defer delete(pkg, state.allocator)
	pkg_interned, interning_err := strings.intern_get(&state.pkgs, pkg)
	if interning_err != nil do pkg_interned = PKG_BACKUP_NAME

	for f in file_infos {
		if f.is_dir {
			success = load_assets_from_dir(f.fullpath, state, temp_allocator)
			if !success do log.errorf("Loading of directory '%v' failed", f.name)
		} else {
			path, err := strings.clone(f.fullpath, state.allocator)
			if err != nil {
				log.errorf("Cannot clone file path '%v' some functionality may not work properly: %v", f.fullpath, err)
				path = f.fullpath
			}

			success = load_asset_to_map_editor(path, state, pkg_interned, temp_allocator)
			if !success {
				log.errorf("Loading of '%v' failed", f.name)
				if err == nil do delete(path, state.allocator) // Delete path copy if it was created 
			}
		}
	}

	when CONFIG_VERBOSE_LOG do log.debugf("Directory %v loaded successfuly", dir)
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

build_asset_pack :: proc(assets: ^map[xxhash.xxh_u64]Asset_Runtime) {
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
	size += size_of(Asset_Descriptor{}.name_len)
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
	_, is_descriptor := a.memory.(Asset_Memory_File_Entry)
	if !is_descriptor {
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
load_assets_immediate :: proc(handle: Asset_Pack_Handle, allocator := context.allocator, binary_data_allocator := context.allocator) -> (m: map[xxhash.xxh_u64]Asset_Runtime, pkgs: strings.Intern, success: bool) {
	m, pkgs, success = load_assets_map(handle, allocator)
	if !success {
		log.error("Cannot load assets map")
		return
	}

	for _, &ass in m do load_asset_mem(&ass, handle, binary_data_allocator)

	return
}

load_assets_map :: proc(handle: Asset_Pack_Handle, allocator := context.allocator) -> (m: map[xxhash.xxh_u64]Asset_Runtime, pkgs: strings.Intern, success: bool) {	
	header_offset: i64
	
	asset_pack_name_b := transmute([]byte)ASSET_PACK_NAME
	header_offset += i64(slice.size(asset_pack_name_b))
	header_offset += size_of(ASSET_PACK_VERSION)
	asset_count: i64 
	
	n, err := os.read_at(handle.(os.Handle), slice.bytes_from_ptr(&asset_count, size_of(asset_count)), header_offset)
	if err != nil || n != size_of(i64le) {
		log.errorf("Cannot read assets map count from file (bytes read: %v), error: %v", n, err)
		return
	}
	header_offset += size_of(asset_count)

	m = make(map[xxhash.xxh_u64]Asset_Runtime, asset_count, allocator)
	defer if !success do delete(m)

	strings.intern_init(&pkgs, allocator, allocator)
	defer if !success do strings.intern_destroy(&pkgs)

	offset_counter := header_offset
	a: Asset_Descriptor

	defer if !success do for _, asset in m {
		if len(asset.name) > 0 do delete(asset.name, allocator)
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
		defer delete(a._pkg_backing, allocator)

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

		pkg, intern_err := strings.intern_get(&pkgs, string(a._pkg_backing[:]))
		if intern_err != nil {
			log.errorf("Cannot get the pkg '%v' from pkgs interner: %v", string(a._pkg_backing[:]), intern_err)
			pkg = PKG_BACKUP_NAME
		}

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

	when CONFIG_VERBOSE_LOG do log.debug("Assets map loaded")
	success = true
	return
}

cleanup_assets_mem :: proc(state: ^Assets_State) {
	for _, a in state.items {
		#partial switch a.type {
		case .Shader:
			delete(a.memory.([]u32), state.binary_data_allocator)
		case:
			delete(a.memory.([]byte), state.binary_data_allocator)
		}
	}
}

cleanup_assets_map :: proc(state: ^Assets_State) {
	for _, a in state.items {
		#partial switch a.type {
		case .Shader:
			delete(a.memory.([]u32), state.binary_data_allocator)
		case:
			delete(a.memory.([]byte), state.binary_data_allocator)
		}
		delete(a.name, state.allocator)
	}

	strings.intern_destroy(&state.pkgs)
	delete(state.items)
}

cleanup_assets_map_editor :: proc(state: ^Assets_State) {
	for _, a in state.items {
		#partial switch a.type {
		case .Shader:
			delete(a.memory.([]u32), state.binary_data_allocator)
		case:
			delete(a.memory.([]byte), state.binary_data_allocator)
		}
		metadata := cast(^Asset_Editor_Metadata)a.metadata

		delete(metadata.filepath, state.allocator)
		free(metadata, state.allocator)
	}
	delete(state.items)
}

cleanup_assets_editor :: proc(state: ^Assets_State) {
	strings.intern_destroy(&state.pkgs)
	cleanup_assets_map_editor(state)
}
