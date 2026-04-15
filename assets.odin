package engine

import "base:runtime"
import "base:intrinsics"

import "core:os"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:hash/xxhash"
import fp "core:path/filepath"

MAX_ASSET_NAME_LEN :: 255
MAX_ASSET_PKG_LEN :: 255
DEFAULT_ASSETS_DIR_NAME :: "assets" // should be relative
ASSET_FILE_NAME :: "assets.packed"
ASSET_FILE_HEADER :: "ASSETS PACKED COUNT: " // After this there is i64le representing total asset count
UNKNOWNPKG :: "UNKNOWNPKG"

Ignore_Files_By_Extension :: [?]string{
	".frag",
	".vert"
}

Assets_Error :: union #shared_nil {
	os.Error,
	Assets_Specific_Error,
}

Assets_Specific_Error :: enum {
	Asset_Already_Exists,
	ID_Creation_Failure,
	Asset_On_Ignore_List,
}
Total_Assets_Count :: i64le // Used to set capacity for resources map

// TODO: Add strings interner to avoid duplicate pkgs
Assets_Manager :: struct {
	resources: map[Asset_ID]Asset,
	hash_state: ^xxhash.XXH3_state, // used for ID generation
	allocator, // allocator used for allocations of hash state, map, map entries, string etc.
	asset_allocator: runtime.Allocator, // 
	assets_file: ^os.File, // Handle for accessing assets.packed file
	_strings_arena: Assets_Strings_Arena, // to store names and pkgs strings
	_internal_metadata: ^Assets_Manager_Editor_Metadata, // reserved for internal usage (i.e. tracking which assets will be added to assets.packed in Editor build variant etc.)
}
Assets_Manager_Editor_Metadata :: struct {
	tracking_file: ^os.File,
}
Asset_ID :: xxhash.xxh_u64
Asset :: struct {
	name, pkg: string, // name is the filename of asset, pkg is the directory name in which asset is located (extracted using path.base proc)
	type: Asset_Type, // generic type
	file_type: Asset_File_Type, // indicating which type of file data it is (e.g. Shader can be SPIRV or DXIL) 
	file_offset, file_size: i64, // Where is actual asset data in assets.packed file, like Vertex bytes for mesh etc.
	flags: Asset_Flags,
	memory: Asset_Memory,
	_internal_metadata: ^Asset_Editor_Metadata, // reserved for future usage, place to store metadata for debugging or something
} 
Asset_Editor_Metadata :: struct {
	source: ^os.File, // we need to keep it in case of loading an unloading memory that is not written into assets.packed
}
Asset_Flag :: enum {
	Loaded_RAM,
	Loaded_GPU, // For future use (maybe to track which can be released after adding flag like "LONG_LIVED_EXCLUSIVE_GPU_RESOURCE" or by any other way idk)
	Independent_File,
}
Asset_Flags :: bit_set[Asset_Flag]
Asset_Memory :: struct #raw_union {
	regular: []byte,
	spirv: []u32, // Stored as LE so we need to transpose it on BE systems
}
Assets_Strings_Arena :: struct {
	handle: mem.Dynamic_Arena,
	allocator: runtime.Allocator,
}
Asset_Packed_Descriptor :: struct #packed {
	name_count: u8,
	name_bytes: [MAX_ASSET_NAME_LEN]byte,
	pkg_count: u8,
	pkg_bytes: [MAX_ASSET_PKG_LEN]byte,
	asset_type: i32le, // stores Asset_Type
	file_type: i32le, // stores Asset_File_Type
	data_offset: i64le,
	data_size: i64le,
}
Asset_Type :: enum i32 {
	UNRECOGNIZED = 0,
	Shader,
	Vertex_Data,
}
Asset_File_Type :: enum i32 {
	UNRECOGNIZED = 0,
	SPIRV
}
@rodata
Asset_File_Type_Strings := [Asset_File_Type]string{
	.UNRECOGNIZED = "",
	.SPIRV = ".spv"
}

initialize_asset_manager :: proc(assets_manager: ^Assets_Manager, asset_file := ASSET_FILE_NAME, allocator := context.allocator, assets_allocator := context.allocator) -> (success: bool) {
	assets_manager.allocator = allocator
	assets_manager.asset_allocator = assets_allocator

	state, err := xxhash.XXH3_create_state(allocator)
	if err != nil {
		log.fatalf("Hashing state creation failure: %v", err)
		return
	} else do assets_manager.hash_state = state
	defer if !success do xxhash.XXH3_destroy_state(assets_manager.hash_state, assets_manager.allocator)

	assets, open_err := engine_open(asset_file)
	if open_err != nil {
		when CONFIG_BUILD_VARIANT == Build_Variants[.Release] {
			log.fatalf("Opening of assets file failed: %v", open_err)
			return false
		}
	}
	assets_manager.assets_file = assets

	/*
	Maybe read assets count from map and then set capacity initially? I guess streaming of this is not in my interest conisdering sizes that I'll want to handle
	count_b: [size_of(Total_Assets_Count)]byte
	os.read_at(assets_manager.assets_file, count_b[:], size_of(ASSET_FILE_HEADER))
	*/

	// For now I'm gonna hold strings in dynamic arena, but probably later I'd get rid off using string and prebake all assets into enum 
	// but leave the ability for using strings, this flexibility might be really usefull
	mem.dynamic_arena_init(&assets_manager._strings_arena.handle)
	assets_manager._strings_arena.allocator = mem.dynamic_arena_allocator(&assets_manager._strings_arena.handle)

	assets_manager.resources = make(map[Asset_ID]Asset, allocator)

	return true
}
cleanup_asset_manager :: proc(assets_manager: ^Assets_Manager) {
	for _, ass in assets_manager.resources {
		if .Loaded_RAM in ass.flags {
			switch ass.file_type {
			case .SPIRV: delete(ass.memory.spirv, assets_manager.asset_allocator)
			case .UNRECOGNIZED: delete(ass.memory.regular, assets_manager.asset_allocator)
			}
		}
	}
	delete(assets_manager.resources)


	mem.dynamic_arena_destroy(&assets_manager._strings_arena.handle)
	assets_manager._strings_arena.allocator = runtime.nil_allocator() // just to be safe I guess
	
	os.close(assets_manager.assets_file)

	err := xxhash.XXH3_destroy_state(assets_manager.hash_state, assets_manager.allocator)
	if err != nil do log.errorf("Hash state destroying failure: %v", err)
}
get_asset_id :: proc(name, pkg: string, type: Asset_File_Type, state: ^xxhash.XXH3_state) -> (id: Asset_ID, success: bool) {
	if state == nil do return

	err := xxhash.XXH3_64_reset(state)
	if err != nil do return 

	SEPARATOR := [?]byte{0}

	name_b := transmute([]byte)name
	pkg_b := transmute([]byte)name
	type_b := transmute([size_of(type)]byte)type

	xxhash.XXH3_64_update(state, name_b)
	xxhash.XXH3_64_update(state, SEPARATOR[:])
	xxhash.XXH3_64_update(state, pkg_b)
	xxhash.XXH3_64_update(state, SEPARATOR[:])
	xxhash.XXH3_64_update(state, type_b[:])

	id = xxhash.XXH3_64_digest(state)
	
	return id, true
}
get_asset :: proc{
	get_asset_by_id,
	get_asset_by_data
}
get_asset_by_id :: proc(id: Asset_ID, manager: ^Assets_Manager) -> (a: Asset, exsists: bool) {
	return manager.resources[id]
}
get_asset_by_data :: proc(name, pkg: string, type: Asset_File_Type, manager: ^Assets_Manager) -> (a: Asset, exists: bool) {
	id := get_asset_id(name, pkg, type, manager.hash_state) or_return

	return manager.resources[id]
}
@(private="file")
_get_asset_file_type :: proc(name: string) -> Asset_File_Type {
	extension := fp.ext(name)
	if extension == "" do return .UNRECOGNIZED

	for t in Asset_File_Type {
		if Asset_File_Type_Strings[t] == extension do return t
	}
	
	return .UNRECOGNIZED
}
@(private="file")
_get_asset_type :: proc(asset: Asset) -> Asset_Type {
	switch asset.file_type {
	case .SPIRV: return .Shader
	case .UNRECOGNIZED: return .UNRECOGNIZED
	}

	return .UNRECOGNIZED
}
// Reads assets.packed into memory and makes it ready for usage
read_assets_packed :: proc(assets_file: ^os.File, manager: ^Assets_Manager, load_assets_mem := false /* loads all assets memory at once, good when there are only few assets */ ) {
	header_offset, // Should be zero at all times
	map_start_offset,
	map_offset_counter: i64 

	descriptor: Asset_Packed_Descriptor
	_count_file: Total_Assets_Count
	asset: Asset

	// move to the count
	map_start_offset += i64(len(ASSET_FILE_NAME))

	// read the count
	os.read_at(assets_file, slice.bytes_from_ptr(&_count_file, size_of(_count_file)), map_start_offset)
	map_start_offset += i64(size_of(_count_file))

	count := i64(_count_file) // assing to platform's natural endian


	// we're gonna set resource map cap into te total asset count
	err := reserve_map(&manager.resources, count)
	if err != nil do log.warnf("Map reservation failure: %v", err) // maybe panic?

	// assign counter 
	map_offset_counter = map_start_offset

	for i in 0 ..< count {
		os.read_at(assets_file, slice.bytes_from_ptr(&descriptor, size_of(descriptor)), map_offset_counter)

		asset.file_offset = i64(descriptor.data_offset)
		asset.file_size = i64(descriptor.data_size)
		asset.file_type = Asset_File_Type(descriptor.file_type)
		asset.type = Asset_Type(descriptor.asset_type)

		//NOTE:
		// Deferred freeing on failure is not needed, remember we're using an arena for strings

		name, name_err := strings.clone_from_bytes(descriptor.name_bytes[:descriptor.name_count], manager._strings_arena.allocator)
		if name_err != nil {
			log.errorf("Asset name '%v' (at offset: %v ) cloning failure (SKIPPING): %v", descriptor.name_bytes[:descriptor.name_count], map_offset_counter, name_err)
			continue
		}
		asset.name = name

		pkg, pkg_err := strings.clone_from_bytes(descriptor.pkg_bytes[:descriptor.pkg_count], manager._strings_arena.allocator)
		if pkg_err != nil {
			log.errorf("Asset '%v:%v' (at offset: %v ) cloning failure (SKIPPING): %v", descriptor.pkg_bytes[:descriptor.pkg_count], name, map_offset_counter, pkg_err)
			continue
		}
		asset.pkg = pkg

		id, ok := get_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)
		if !ok {
			log.errorf("Cannot determine ID for asset '%v:%v' (Type: '%v') (SKIPPING)", asset.pkg, asset.name, asset.file_type)
			continue
		}

		_, exists := manager.resources[id]
		if exists {
			log.warnf("Duplicate asset ID detected, got ID '%v' while it already exists in resources map (SKIPPING)", id)
			continue
		}


		if load_assets_mem {
			mem_err := _load_asset_memory_internal(&asset, assets_file, manager.asset_allocator)
			if mem_err != nil do log.errorf("Memory loading of asset '%v' failure: %v", asset.name, mem_err)
		}

		manager.resources[id] = asset
		when CONFIG_VERBOSE_LOG do log.debugf("Added asset '%v:%v' (ID: %v)  to resources map", asset.pkg, asset.name, id)
	}
}
find_asset_in_packed :: proc{
	find_asset_in_packed_by_id,
	find_asset_in_packed_by_data,
}
find_asset_in_packed_by_data:: proc(name, pkg: string, file_type: Asset_File_Type, manager: ^Assets_Manager, insert_asset_into_resources: bool) -> (found_at_map_location : i64 = -1, inserted := false) {
	_count_file: Total_Assets_Count
	map_offset: i64

	// get count
	map_offset += i64(len(ASSET_FILE_HEADER))
	os.read_at(manager.assets_file, slice.bytes_from_ptr(&_count_file, size_of(_count_file)), map_offset)
	map_offset += size_of(_count_file)
	count := i64(_count_file)

	descriptor: Asset_Packed_Descriptor
	for i in 0 ..< count {
		os.read_at(manager.assets_file, slice.bytes_from_ptr(&descriptor, size_of(descriptor)), map_offset)
		desc_name := string(descriptor.name_bytes[:descriptor.name_count])
		desc_pkg := string(descriptor.pkg_bytes[:descriptor.pkg_count])
		desc_type := Asset_File_Type(descriptor.file_type)
		if name == desc_name && pkg == desc_pkg && file_type == desc_type {
			if !insert_asset_into_resources do return i, false
			
			asset: Asset
			_descriptor_to_asset(&descriptor, &asset)
			id, ok := get_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)
			if !ok {
				log.errorf("Asset's '%v:%v' ID retrieval failure", asset.pkg, asset.name)
				return i, false
			}

			if find_if_asset_exists_by_id(id, manager) {
				log.errorf("Asset '%v:%v' of ID %v already exists", asset.pkg, asset.name, id)
				return i, false
			}
			
			manager.resources[id] = asset
			return i, true
		} else do map_offset += size_of(descriptor)
	}

	return
}
find_asset_in_packed_by_id :: proc(id: Asset_ID, manager: ^Assets_Manager, insert_asset_into_resources: bool) -> (found_at_map_location : i64 = -1, inserted := false) {
	_count_file: Total_Assets_Count
	map_offset: i64

	// get count
	map_offset += i64(len(ASSET_FILE_HEADER))
	os.read_at(manager.assets_file, slice.bytes_from_ptr(&_count_file, size_of(_count_file)), map_offset)
	map_offset += size_of(_count_file)
	count := i64(_count_file)

	descriptor: Asset_Packed_Descriptor
	for i in 0 ..< count {
		os.read_at(manager.assets_file, slice.bytes_from_ptr(&descriptor, size_of(descriptor)), map_offset)

		desc_name := string(descriptor.name_bytes[:descriptor.name_count])
		desc_pkg := string(descriptor.pkg_bytes[:descriptor.pkg_count])
		desc_type := Asset_File_Type(descriptor.file_type)
		desc_id := get_asset_id(desc_name, desc_pkg, desc_type, manager.hash_state) or_continue
		
		if desc_id == id {
			if !insert_asset_into_resources do return i, false

			if find_if_asset_exists_by_id(id, manager) {
				log.errorf("Asset of ID %v already exists", id)
				return i, false
			}
			
			asset: Asset
			_descriptor_to_asset(&descriptor, &asset)
			
			manager.resources[id] = asset
			return i, true
		} else do map_offset += size_of(descriptor)
	}

	return
}

@(private="file")
_descriptor_to_asset :: proc(desc: ^Asset_Packed_Descriptor, ass: ^Asset) {
	ass.file_offset = auto_cast desc.data_offset
	ass.file_size = auto_cast desc.data_size
	ass.file_type = auto_cast desc.file_type
	ass.type = auto_cast desc.asset_type
	ass.name = string(desc.name_bytes[:desc.name_count])
	ass.pkg = string(desc.pkg_bytes[:desc.pkg_count])
}
// Can fail if assets name/pkg is larger than descriptor buffers size (uses copy to move string data into descriptor bytes arrays)
@(private="file")
_asset_to_descriptor :: proc(ass: ^Asset, desc: ^Asset_Packed_Descriptor) -> (success: bool) {
	if len(ass.name) > MAX_ASSET_NAME_LEN || len(ass.pkg) > MAX_ASSET_PKG_LEN do return
	desc.data_offset = auto_cast ass.file_offset
	desc.data_size = auto_cast ass.file_size
	desc.file_type = auto_cast ass.file_type
	desc.asset_type = auto_cast ass.type
	desc.name_count =  auto_cast copy(desc.name_bytes[:], transmute([]byte)ass.name)
	desc.pkg_count =  auto_cast copy(desc.pkg_bytes[:], transmute([]byte)ass.pkg)

	return true
}
// Builds assets.packed file from loaded assets and every file in assets directory
//NOTE: Maybe in future it'd be a good idea to add something like new asset tracker into metadata to only append to created assets.packed instead of rebuilding it
build_asset_packed :: proc(manager: ^Assets_Manager) -> (success: bool) {
	// If not opened, create/open
	if manager.assets_file == nil {
		f, err := engine_open(ASSET_FILE_NAME, {.Write, .Create, .Trunc})
		if err != nil {
			log.errorf("Opening '%v' for building failure: %v", ASSET_FILE_NAME, err)
			return false
		}
		manager.assets_file = f
	}

	map_start_offset, map_offset_counter,
	binary_data_start_offset,binary_data_offset_counter: i64
	descriptor: Asset_Packed_Descriptor
	// maybe check if has the one opened has right permissions?

	// get to the count offset
	map_start_offset += i64(len(ASSET_FILE_HEADER))

	// write the count
	count: Total_Assets_Count = i64le(len(manager.resources))
	os.write_at(manager.assets_file, slice.bytes_from_ptr(&count, size_of(count)), map_start_offset)

	map_start_offset += i64(size_of(count))

	// calculate binary data offset
	binary_data_start_offset = map_start_offset + (size_of(descriptor) * i64(count))
	binary_data_offset_counter = binary_data_start_offset
	// TODO: Set up assets_tracker.temp file for tracking which one to add when building assets.packed

	for _, ass in manager.resources {
		if .Loaded_RAM not_in ass.flags {
			log.warnf("Asset '%v:%v' does not have loaded memory, cannot write it into '%v' (SKIPPING)", ass.pkg, ass.name, ASSET_FILE_NAME)
			continue
		}
		if len(ass.name) > len(descriptor.name_bytes) {
			log.warnf("Asset '%v:%v' name is larget than allowed %v bytes, cannot write it into '%v' (SKIPPING)", ass.pkg, ass.name, len(descriptor.name_bytes), ASSET_FILE_NAME)
			continue
		}
		if len(ass.pkg) > len(descriptor.pkg_bytes) {
			log.warnf("Asset '%v:%v' pkg is larger than allowed %v bytes, cannot write it into '%v' (SKIPPING)", ass.pkg, ass.name, len(descriptor.name_bytes), ASSET_FILE_NAME)
			continue
		}

		descriptor.asset_type  = cast(type_of(descriptor.asset_type))	ass.type
		descriptor.file_type   = cast(type_of(descriptor.file_type))	ass.file_type
		descriptor.data_size   = cast(type_of(descriptor.data_size))	len(ass.memory.regular)
		descriptor.data_offset = cast(type_of(descriptor.data_offset))	binary_data_start_offset
		descriptor.name_count  = cast(type_of(descriptor.name_count))	len(ass.name)
		descriptor.pkg_count   = cast(type_of(descriptor.pkg_count))	len(ass.pkg)

		name_bytes_offset := map_start_offset + i64(offset_of(descriptor.name_bytes))
		pkg_bytes_offset := map_start_offset + i64(offset_of(descriptor.pkg_bytes))
		// write all the data 
		os.write_at(manager.assets_file, slice.bytes_from_ptr(&descriptor, size_of(descriptor)), map_offset_counter)
		map_start_offset += size_of(descriptor)

		// write the remaning strings data
		os.write_at(manager.assets_file, transmute([]byte)ass.name, name_bytes_offset)
		os.write_at(manager.assets_file, transmute([]byte)ass.pkg, pkg_bytes_offset)

		// write the memory of asset
		os.write_at(manager.assets_file, ass.memory.regular, binary_data_offset_counter)
		binary_data_offset_counter += i64(len(ass.memory.regular))

		when CONFIG_VERBOSE_LOG do log.debugf("Written asset '%v:%v' into '%v' successfully", ass.pkg, ass.name, ASSET_FILE_NAME)
	}

	return true
}
// Read asset file into asset manager
read_asset_file :: proc(file: string, manager: ^Assets_Manager, load_data := false, append_to_packed_build := true /* Implement */, temp_allocator := context.temp_allocator) -> (err: Assets_Error) {
	file := file
	if should_ingore_file(file) do return .Asset_On_Ignore_List

	f: ^os.File
	f, err = os.open(file)
	if err != nil {
		log.errorf("Opening file '%v' failure: %v", file, err)
		return err
	}
	defer if err != nil do os.close(f)

	// temp strings, if asset would be added, then we clone pkg and name into strings arena
	pkg, name, abs: string

	if !fp.is_abs(file) {
		name = file
		abs, err = fp.abs(file, temp_allocator)

		if err != nil do pkg = UNKNOWNPKG
		else do pkg = fp.base(fp.dir(abs, temp_allocator))
	} else {
		abs = file
		name = fp.base(abs)
		pkg = fp.base(fp.dir(abs, temp_allocator))
	}

	if pkg == "." do pkg = UNKNOWNPKG // base can return '.' if empty string

	ass: Asset
	ass._internal_metadata = new(Asset_Editor_Metadata, manager.allocator)
	defer if err != nil do free(ass._internal_metadata, manager.allocator) 

	ass._internal_metadata.source = f
	ass.pkg = pkg
	ass.name = name
	ass.file_type = _get_asset_file_type(file)
	
	id, ok := get_asset_id(ass.name, ass.pkg, ass.file_type, manager.hash_state)
	if !ok {
		log.errorf("Asset '%v:%v' ID retrieval failure", ass.pkg, ass.name)
		return .ID_Creation_Failure
	}

	exists := find_if_asset_exists_by_id(id, manager)
	if exists {
		log.errorf("Asset of ID: %v already exists", id)
		return .Asset_Already_Exists
	}

	// Backup strings into strings arena
	ass.pkg = strings.clone(ass.pkg, manager._strings_arena.allocator)
	ass.name = strings.clone(ass.name, manager._strings_arena.allocator)

	ass.flags += {.Independent_File}
	ass.type = _get_asset_type(ass)

	ass.file_offset = 0
	size, size_err := os.file_size(f)
	if size_err != nil do log.warnf("File size retrieval failure: %v", size_err)
	ass.file_size = size // set despite error, detection of the file should be made using flags anyway

	if load_data {
		mem_err := _load_asset_memory_internal(&ass, f, manager.asset_allocator)
		if mem_err != nil do log.errorf("Loading asset's '%v:%v' memory failure: %v", ass.pkg, ass.name, mem_err)
	}
	
	manager.resources[id] = ass

	return nil
}
// Unloads asset, frees all allocated memory and destroys entry in resource map
// NOTE: Asset's `file type` should be set before calling to ensure proper cleanup
cleanup_asset :: proc(asset: ^Asset, manager: ^Assets_Manager) {
	unload_asset_memory(asset, manager)

	if asset._internal_metadata != nil {
		free(asset._internal_metadata, manager.allocator) 
		err := os.close(asset._internal_metadata.source)
		if err != nil do log.errorf("Asset '%v:%v' file closing failure: %v", asset.pkg, asset.name, err)
	}
	
	id, ok := get_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)
	if !ok {
		log.errorf("Asset '%v:%v' ID retrieval failed, unable to delete entry from resource map", asset.pkg, asset.name)
		return
	}
	delete_key(&manager.resources, id)
}
// Loads asset memory from assets.packed file with assets allocator
// NOTE: Asset's `file type` should be set before calling to ensure proper loading
load_asset_memory :: proc(asset: ^Asset, manager: ^Assets_Manager) -> os.Error {
	err := _load_asset_memory_internal(asset, manager.assets_file, manager.asset_allocator)
	if err != nil {
		log.errorf("Loading asset '%v:%v' memory failure: %v", asset.pkg, asset.name, err)
		return err
	}

	return nil
}
// Unloads asset memory, but doesn't remove resource entry
// NOTE: Asset's `file type` should be set before calling to ensure proper cleanup
unload_asset_memory :: proc(asset: ^Asset, manager: ^Assets_Manager) {
	_unload_asset_memory_internal(asset, manager.asset_allocator)

}
// NOTE: Asset's `file type` should be set before calling to ensure proper loading
@(private="file")
_load_asset_memory_internal :: proc(asset: ^Asset, file: ^os.File, allocator: runtime.Allocator) -> (err: os.Error) {
	if asset == nil do return

	if .Loaded_RAM in asset.flags do return nil

	buff := make([]byte, asset.file_size, allocator) or_return
	defer if err != nil do delete(buff, allocator)

	read := os.read_at(file, buff, asset.file_offset) or_return
	if read != len(buff) do log.warnf("Allocated buffer for asset '%v:%v' size: %v bytes - read %v bytes", asset.pkg, asset.name, len(buff), read)
	
	switch asset.file_type {
	case .SPIRV:
		// SPIRV is packed as u32le (and most of the times it won't need the endian swap)
		asset.memory.spirv = slice.reinterpret([]u32, buff)
		when ODIN_ENDIAN == .Big {
			for op_code, i in asset.memory.spirv do asset.memory.spirv[i] = intrinsics.byte_swap(op_code)
		}
	case .UNRECOGNIZED: asset.memory.regular = buff
	}

	asset.flags += {.Loaded_RAM}
	return nil
}
// NOTE: Asset's `file type` should be set before calling to ensure proper cleanup
@(private="file")
_unload_asset_memory_internal :: proc(asset: ^Asset, allocator: runtime.Allocator) {
	switch asset.file_type {
	case .SPIRV: delete(asset.memory.spirv, allocator)
	case .UNRECOGNIZED: delete(asset.memory.regular, allocator)
	}
}

find_if_asset_exists :: proc{
	find_if_asset_exists_by_id,
	find_if_asset_exists_by_data
}
find_if_asset_exists_by_id :: proc(id: Asset_ID, manager: ^Assets_Manager) -> (exists: bool) {
	_, exists = manager.resources[id]
	return
}
find_if_asset_exists_by_data :: proc(name, pkg: string, type: Asset_File_Type, manager: ^Assets_Manager) -> (exists: bool) {
	id := get_asset_id(name, pkg, type, manager.hash_state) or_return // error should only occur when passing nil pointer as hash state, so I should never happen

	return find_if_asset_exists_by_id(id, manager)
}

read_assets_dir_recursive :: proc(manager: ^Assets_Manager, dir_name := DEFAULT_ASSETS_DIR_NAME, allocator := context.allocator, load_assets_mem := false) -> (success: bool) {
	d, err := engine_open(dir_name, nil)

	if err != nil {
		log.errorf("Directory '%v' opening failure: %v", dir_name, err)
		return
	}
	defer os.close(d)

	pkg := fp.base(dir_name)

	infos, dir_err := os.read_all_directory(d, allocator)
	if dir_err != nil {
		log.errorf("Reading '%v' directory failure: %v", dir_name, dir_err)
		return false
	}

	for i in infos {
		#partial switch i.type {
		case .Directory: read_assets_dir_recursive(manager, i.fullpath, allocator, load_assets_mem)
		case .Regular: 
			asset_err := read_asset_file(i.fullpath, manager, load_assets_mem)
			if asset_err != nil && asset_err != .Asset_On_Ignore_List do log.errorf("Unable to read asset from file '%v'", i.name)
		case: continue
		}
	}

	return true
}

should_ingore_file :: proc(file: string) -> (ignore: bool) {
	ext := fp.ext(file)
	for ignore_ext in Ignore_Files_By_Extension {
		if ext == ignore_ext do return true
	}

	when CONFIG_VERBOSE_LOG do log.debugf("Detected asset '%v' as one on ingore list", file)
	return false
}
