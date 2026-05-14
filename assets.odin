package engine

import "base:intrinsics"
import "base:runtime"

import "obj"

import "core:c"
import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:os"
import fp "core:path/filepath"
import "core:slice"
import "core:strings"

import vk "vendor:vulkan"

MAX_ASSET_NAME_LEN :: 255
MAX_ASSET_PKG_LEN :: 255
DEFAULT_ASSETS_DIR_NAME :: "assets" // should be relative
DEFAULT_ASSETS_PKG_NAME :: DEFAULT_ASSETS_DIR_NAME
ASSET_FILE_NAME :: "assets.packed"
ASSET_FILE_NAME_TEMP :: "assets.packed.temp"
ASSET_FILE_HEADER :: "ASSETS PACKED COUNT: " // After this there is i64le representing total asset count
UNKNOWNPKG :: "UNKNOWNPKG"

Ignore_Files_By_Extension :: [?]string{".frag", ".vert"}

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
	resources:                  map[Asset_ID]Asset,
	hash_state:                 ^xxhash.XXH3_state, // used for ID generation
	allocator, asset_allocator: runtime.Allocator, // allocator used for allocations of hash state, map, map entries, string etc.//
	assets_file:                ^os.File, // Handle for accessing assets.packed file
	_strings_arena:             Assets_Strings_Arena, // to store names and pkgs strings
	_internal_metadata:         ^Assets_Manager_Editor_Metadata, // reserved for internal usage (i.e. tracking which assets will be added to assets.packed in Editor build variant etc.)
}
Assets_Manager_Editor_Metadata :: struct {
	tracking_file: ^os.File,
}
Asset_ID :: xxhash.xxh_u64
Asset :: struct {
	name, pkg:              string, // name is the filename of asset, pkg is the directory name in which asset is located (extracted using path.base proc)
	type:                   Asset_Type, // generic type
	file_type:              Asset_File_Type, // indicating which type of file data it is (e.g. Shader can be SPIRV or DXIL)
	file_offset, file_size: i64, // Where is actual asset data in assets.packed file, like Vertex bytes for mesh etc.
	flags:                  Asset_Flags,
	memory:                 Asset_Memory,
	data:                   Asset_Specific_Data,
	_internal_metadata:     ^Asset_Editor_Metadata, // reserved for future usage, place to store metadata for debugging or something
}

Asset_Editor_Metadata :: struct {
	source: ^os.File, // we need to keep it in case of loading an unloading memory that is not written into assets.packed
}
Asset_Flag :: enum {
	Loaded_RAM,
	Loaded_GPU, // For future use (maybe to track which can be released after adding flag like "LONG_LIVED_EXCLUSIVE_GPU_RESOURCE" or by any other way idk)
	Independent_File,
}

Asset_Specific_Data :: struct #raw_union {
	texture: Asset_Texture_Data,
}
Asset_Texture_Data :: struct {
	width, height, depth: i32,
}

Asset_Flags :: bit_set[Asset_Flag]
Asset_Memory :: struct #raw_union {
	regular: []byte,
	spirv:   []u32, // Stored as LE so we need to transpose it on BE systems
	mesh:    Asset_Mesh_Memory,
}

Asset_Mesh_Memory :: struct {
	indicies:  []u32,
	verticies: []Base_Vertex,
}

Descriptor_Mesh_Memory_Header :: i64le // specifies offset at which verticies begin, order is that first are indices then vertices
Asset_Packed_Descriptor_Texture_Memory_Header :: struct {
	width, height, depth: i32le,
} // specifies data for texture extent

Assets_Strings_Arena :: struct {
	handle:    mem.Dynamic_Arena,
	allocator: runtime.Allocator,
}
Asset_Packed_Descriptor :: struct #packed {
	name_count:  u8,
	name_bytes:  [MAX_ASSET_NAME_LEN]byte,
	pkg_count:   u8,
	pkg_bytes:   [MAX_ASSET_PKG_LEN]byte,
	asset_type:  i32le, // stores Asset_Type
	file_type:   i32le, // stores Asset_File_Type
	data_offset: i64le,
	data_size:   i64le,
}
Asset_Type :: enum i32 {
	UNRECOGNIZED = 0,
	Shader,
	Vertex_Data,
	Mesh,
	Texture,
}
Asset_File_Type :: enum i32 {
	UNRECOGNIZED = 0,
	SPIRV,
	OBJ,
	PNG, // when loading PNGs we're decompressing them with STBI, then that decompressed verion is packed into assets.packed
}
@(rodata)
Asset_File_Type_Strings := [Asset_File_Type]string {
	.UNRECOGNIZED = "",
	.SPIRV        = ".spv",
	.OBJ          = ".obj",
	.PNG          = ".png",
}

initialize_asset_manager :: proc(
	assets_manager: ^Assets_Manager,
	asset_file := ASSET_FILE_NAME,
	allocator := context.allocator,
	assets_allocator := context.allocator,
) -> (
	success: bool,
) {
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
	assets_manager._strings_arena.allocator = mem.dynamic_arena_allocator(
		&assets_manager._strings_arena.handle,
	)

	assets_manager.resources = make(map[Asset_ID]Asset, allocator)

	return true
}
cleanup_asset_manager :: proc(assets_manager: ^Assets_Manager) {
	for _, &ass in assets_manager.resources do cleanup_asset(&ass, assets_manager, destroy_key = false)
	delete(assets_manager.resources)

	mem.dynamic_arena_destroy(&assets_manager._strings_arena.handle)
	assets_manager._strings_arena.allocator = runtime.nil_allocator() // just to be safe I guess

	os.close(assets_manager.assets_file)

	err := xxhash.XXH3_destroy_state(assets_manager.hash_state, assets_manager.allocator)
	if err != nil do log.errorf("Hash state destroying failure: %v", err)
}
generate_asset_id :: proc(
	name, pkg: string,
	type: Asset_File_Type,
	state: ^xxhash.XXH3_state = get_global_state().assets.hash_state,
) -> (
	id: Asset_ID,
) {
	err := xxhash.XXH3_64_reset(state)
	assert(err == nil, "Unexpected XXH3 hashing error while generating ID for an asset")

	SEPARATOR := [?]byte{0}

	name_b := transmute([]byte)name
	pkg_b := transmute([]byte)pkg
	type_b := transmute([size_of(type)]byte)type

	xxhash.XXH3_64_update(state, name_b)
	xxhash.XXH3_64_update(state, SEPARATOR[:])
	xxhash.XXH3_64_update(state, pkg_b)
	xxhash.XXH3_64_update(state, SEPARATOR[:])
	xxhash.XXH3_64_update(state, type_b[:])

	id = xxhash.XXH3_64_digest(state)

	return id
}
get_asset :: proc {
	get_asset_by_id,
	get_asset_by_data,
}
get_asset_by_id :: proc(id: Asset_ID, manager: ^Assets_Manager) -> (a: Asset, exsists: bool) {
	return manager.resources[id]
}
get_asset_by_data :: proc(
	name, pkg: string,
	type: Asset_File_Type,
	manager: ^Assets_Manager,
) -> (
	a: Asset,
	exists: bool,
) {
	id := generate_asset_id(name, pkg, type, manager.hash_state)

	return manager.resources[id]
}
@(private = "file")
_get_asset_file_type :: proc(name: string) -> Asset_File_Type {
	extension := fp.ext(name)
	if extension == "" do return .UNRECOGNIZED

	for t in Asset_File_Type {
		if Asset_File_Type_Strings[t] == extension do return t
	}

	return .UNRECOGNIZED
}
@(private = "file")
_get_asset_type :: proc(asset: Asset) -> Asset_Type {
	switch asset.file_type {
	case .SPIRV:
		return .Shader
	case .UNRECOGNIZED:
		return .UNRECOGNIZED
	case .OBJ:
		return .Mesh
	case .PNG:
		return .Texture
	}

	return .UNRECOGNIZED
}
// Reads assets.packed into memory and makes it ready for usage
read_assets_packed :: proc(
	assets_file: ^os.File,
	manager: ^Assets_Manager,
	load_assets_mem := false,
	/* loads all assets memory at once, good when there are only few assets */
) {
	header_offset, map_start_offset, map_offset_counter: i64 // Should be zero at all times

	descriptor: Asset_Packed_Descriptor
	_count_file: Total_Assets_Count

	// move to the count
	map_start_offset += i64(len(ASSET_FILE_HEADER))

	// read the count
	os.read_at(
		assets_file,
		slice.bytes_from_ptr(&_count_file, size_of(_count_file)),
		map_start_offset,
	)
	map_start_offset += i64(size_of(_count_file))

	count := i64(_count_file) // assing to platform's natural endian

	// we're gonna set resource map cap into te total asset count
	err := reserve_map(&manager.resources, count)
	if err != nil do log.warnf("Map reservation failure: %v", err) // maybe panic?

	// assign counter
	map_offset_counter = map_start_offset

	if count == 0 do log.debug("Asset count read from file is 0")
	for i in 0 ..< count {
		asset: Asset
		os.read_at(
			assets_file,
			slice.bytes_from_ptr(&descriptor, size_of(descriptor)),
			map_offset_counter,
		)

		asset.file_offset = i64(descriptor.data_offset)
		asset.file_size = i64(descriptor.data_size)
		asset.file_type = Asset_File_Type(descriptor.file_type)
		asset.type = Asset_Type(descriptor.asset_type)

		//NOTE:
		// Deferred freeing on failure is not needed, remember we're using an arena for strings

		name, name_err := strings.clone_from_bytes(
			descriptor.name_bytes[:descriptor.name_count],
			manager._strings_arena.allocator,
		)
		if name_err != nil {
			log.errorf(
				"Asset name '%v' (at offset: %v ) cloning failure (SKIPPING): %v",
				descriptor.name_bytes[:descriptor.name_count],
				map_offset_counter,
				name_err,
			)
			continue
		}
		asset.name = name

		pkg, pkg_err := strings.clone_from_bytes(
			descriptor.pkg_bytes[:descriptor.pkg_count],
			manager._strings_arena.allocator,
		)
		if pkg_err != nil {
			log.errorf(
				"Asset '%v:%v' (at offset: %v ) cloning failure (SKIPPING): %v",
				descriptor.pkg_bytes[:descriptor.pkg_count],
				name,
				map_offset_counter,
				pkg_err,
			)
			continue
		}
		asset.pkg = pkg

		id := generate_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)

		_, exists := manager.resources[id]
		if exists {
			log.warnf(
				"Duplicate asset ID detected, got ID '%v' while it already exists in resources map (SKIPPING)",
				id,
			)
			continue
		}

		if load_assets_mem {
			mem_err := _load_asset_memory_internal(
				&asset,
				assets_file,
				manager.asset_allocator,
				true,
			)
			if mem_err != nil do log.errorf("Memory loading of asset '%v' failure: %v", asset.name, mem_err)
		}

		manager.resources[id] = asset
		when CONFIG_VERBOSE_LOG do log.debugf(
			"Added asset '%v:%v' (ID: %v)  to resources map",
			asset.pkg,
			asset.name,
			id,
		)
		map_offset_counter += size_of(Asset_Packed_Descriptor)
	}
}
find_asset_in_packed :: proc {
	find_asset_in_packed_by_id,
	find_asset_in_packed_by_data,
}
find_asset_in_packed_by_data :: proc(
	name, pkg: string,
	file_type: Asset_File_Type,
	manager: ^Assets_Manager,
	insert_asset_into_resources: bool,
) -> (
	found_at_map_location: i64 = -1,
	inserted := false,
) {
	_count_file: Total_Assets_Count
	map_offset: i64

	// get count
	map_offset += i64(len(ASSET_FILE_HEADER))
	os.read_at(
		manager.assets_file,
		slice.bytes_from_ptr(&_count_file, size_of(_count_file)),
		map_offset,
	)
	map_offset += size_of(_count_file)
	count := i64(_count_file)

	descriptor: Asset_Packed_Descriptor
	for i in 0 ..< count {
		os.read_at(
			manager.assets_file,
			slice.bytes_from_ptr(&descriptor, size_of(descriptor)),
			map_offset,
		)
		map_offset += size_of(descriptor)

		desc_name := string(descriptor.name_bytes[:descriptor.name_count])
		desc_pkg := string(descriptor.pkg_bytes[:descriptor.pkg_count])
		desc_type := Asset_File_Type(descriptor.file_type)
		if name == desc_name && pkg == desc_pkg && file_type == desc_type {
			if !insert_asset_into_resources do return i, false

			asset: Asset
			_descriptor_to_asset(&descriptor, &asset)
			id := generate_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)

			if find_if_asset_exists_by_id(id, manager) {
				log.errorf("Asset '%v:%v' of ID %v already exists", asset.pkg, asset.name, id)
				return i, false
			}

			manager.resources[id] = asset
			return i, true
		}
	}

	return
}
find_asset_in_packed_by_id :: proc(
	id: Asset_ID,
	manager: ^Assets_Manager,
	insert_asset_into_resources: bool,
) -> (
	found_at_map_location: i64 = -1,
	inserted := false,
) {
	_count_file: Total_Assets_Count
	map_offset: i64

	// get count
	map_offset += i64(len(ASSET_FILE_HEADER))
	os.read_at(
		manager.assets_file,
		slice.bytes_from_ptr(&_count_file, size_of(_count_file)),
		map_offset,
	)
	map_offset += size_of(_count_file)
	count := i64(_count_file)

	descriptor: Asset_Packed_Descriptor
	for i in 0 ..< count {
		os.read_at(
			manager.assets_file,
			slice.bytes_from_ptr(&descriptor, size_of(descriptor)),
			map_offset,
		)
		map_offset += size_of(descriptor)

		desc_name := string(descriptor.name_bytes[:descriptor.name_count])
		desc_pkg := string(descriptor.pkg_bytes[:descriptor.pkg_count])
		desc_type := Asset_File_Type(descriptor.file_type)
		desc_id := generate_asset_id(desc_name, desc_pkg, desc_type, manager.hash_state)

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
		}
	}

	return
}

@(private = "file")
_descriptor_to_asset :: proc(desc: ^Asset_Packed_Descriptor, ass: ^Asset) {
	ass.file_offset = auto_cast desc.data_offset
	ass.file_size = auto_cast desc.data_size
	ass.file_type = auto_cast desc.file_type
	ass.type = auto_cast desc.asset_type
	ass.name = string(desc.name_bytes[:desc.name_count])
	ass.pkg = string(desc.pkg_bytes[:desc.pkg_count])
}
// Can fail if assets name/pkg is larger than descriptor buffers size (uses copy to move string data into descriptor bytes arrays)
@(private = "file")
_asset_to_descriptor :: proc(
	file_offset: i64,
	ass: ^Asset,
	desc: ^Asset_Packed_Descriptor,
) -> (
	success: bool,
) {
	if len(ass.name) > MAX_ASSET_NAME_LEN || len(ass.pkg) > MAX_ASSET_PKG_LEN do return
	desc.data_offset = auto_cast file_offset
	switch ass.file_type {
	case .UNRECOGNIZED, .PNG:
		desc.data_size = auto_cast len(ass.memory.regular)
	case .OBJ:
		desc.data_size =
			auto_cast (slice.size(ass.memory.mesh.indicies) +
				slice.size(ass.memory.mesh.verticies)) +
			size_of(i64le)
	case .SPIRV:
		desc.data_size = auto_cast slice.size(ass.memory.spirv) // it holds []u32 so we need to multiply it for bytes
	}
	desc.file_type = auto_cast ass.file_type
	desc.asset_type = auto_cast ass.type
	desc.name_count = auto_cast copy(desc.name_bytes[:], transmute([]byte)ass.name)
	desc.pkg_count = auto_cast copy(desc.pkg_bytes[:], transmute([]byte)ass.pkg)

	return true
}
// Builds assets.packed file from loaded assets and every file in assets directory
//NOTE: Maybe in future it'd be a good idea to add something like new asset tracker into metadata to only append to created assets.packed instead of rebuilding it
build_asset_packed :: proc(
	manager: ^Assets_Manager,
	fallback_assets_name := ASSET_FILE_NAME,
	temp_name := ASSET_FILE_NAME_TEMP,
	temp_allocator := context.temp_allocator,
) -> (
	success: bool,
) {
	assert(manager != nil)

	f, err := engine_open(temp_name, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err != nil {
		log.errorf("Opening '%v' for building failure: %v", temp_name, err)
		return false
	}

	_old_name := os.name(manager.assets_file)
	_old_name = strings.clone(_old_name, temp_allocator) or_else fallback_assets_name
	_old_file := manager.assets_file
	manager.assets_file = f

	map_start_offset, map_offset_counter, binary_data_start_offset, binary_data_offset_counter: i64
	descriptor: Asset_Packed_Descriptor
	// maybe check if has the one opened has right permissions?

	// get to the count offset
	map_start_offset += i64(len(ASSET_FILE_HEADER))

	// write the count
	count: Total_Assets_Count = i64le(len(manager.resources))
	os.write_at(
		manager.assets_file,
		slice.bytes_from_ptr(&count, size_of(count)),
		map_start_offset,
	)

	map_start_offset += i64(size_of(count))
	map_offset_counter = map_start_offset

	// calculate binary data offset
	binary_data_start_offset = map_start_offset + (size_of(descriptor) * i64(count))
	binary_data_offset_counter = binary_data_start_offset
	// TODO: Set up assets_tracker.temp file for tracking which one to add when building assets.packed

	for _, &ass in manager.resources {
		if .Loaded_RAM not_in ass.flags {
			log.warnf(
				"Asset '%v:%v' does not have loaded memory, cannot write it into '%v' (SKIPPING)",
				ass.pkg,
				ass.name,
				ASSET_FILE_NAME,
			)
			continue
		}
		if len(ass.name) > len(descriptor.name_bytes) {
			log.warnf(
				"Asset '%v:%v' name is larget than allowed %v bytes, cannot write it into '%v' (SKIPPING)",
				ass.pkg,
				ass.name,
				len(descriptor.name_bytes),
				ASSET_FILE_NAME,
			)
			continue
		}
		if len(ass.pkg) > len(descriptor.pkg_bytes) {
			log.warnf(
				"Asset '%v:%v' pkg is larger than allowed %v bytes, cannot write it into '%v' (SKIPPING)",
				ass.pkg,
				ass.name,
				len(descriptor.name_bytes),
				ASSET_FILE_NAME,
			)
			continue
		}

		_asset_to_descriptor(binary_data_offset_counter, &ass, &descriptor) or_continue

		name_bytes_offset := map_offset_counter + i64(offset_of(descriptor.name_bytes))
		pkg_bytes_offset := map_offset_counter + i64(offset_of(descriptor.pkg_bytes))
		// write all the data
		os.write_at(
			manager.assets_file,
			slice.bytes_from_ptr(&descriptor, size_of(descriptor)),
			map_offset_counter,
		)
		map_offset_counter += size_of(descriptor)

		// write the remaning strings data
		os.write_at(manager.assets_file, transmute([]byte)ass.name, name_bytes_offset)
		os.write_at(manager.assets_file, transmute([]byte)ass.pkg, pkg_bytes_offset)

		write_err: os.Error
		switch ass.file_type {
		case .UNRECOGNIZED:
			write_err = _assets_packed_write_regular(
				ass,
				manager.assets_file,
				&binary_data_offset_counter,
			)
		case .OBJ:
			write_err = _assets_packed_write_obj(
				ass,
				manager.assets_file,
				&binary_data_offset_counter,
			)
		case .SPIRV:
			write_err = _assets_packed_write_spriv(
				ass,
				manager.assets_file,
				&binary_data_offset_counter,
			)
		case .PNG:
			write_err = _assets_packed_write_texture(
				ass,
				manager.assets_file,
				&binary_data_offset_counter,
			)
		}

		if write_err != nil {
			log.warnf(
				"Asset '%v:%v' writing into '%v' failure: %v (SKIPPING)",
				ass.pkg,
				ass.name,
				ASSET_FILE_NAME,
				write_err,
			)
			continue
		}

		when CONFIG_VERBOSE_LOG do log.debugf(
			"Written asset '%v:%v' into '%v' successfully",
			ass.pkg,
			ass.name,
			ASSET_FILE_NAME,
		)
	}

	when CONFIG_VERBOSE_LOG do log.debug("Starting replacement of asset file")
	os.close(manager.assets_file)
	rm_err := os.remove(_old_name)
	if rm_err == .Not_Exist {
		log.info("Assets file not detected, writing new one normally")
		os.rename(temp_name, ASSET_FILE_NAME)
		return true
	} else if rm_err != nil {
		log.errorf("Asset file removal failure: %v", rm_err)
	}

	rn_err := os.rename(temp_name, _old_name)
	if rn_err != nil {
		log.errorf("Asset file replacement failure: %v", rn_err)
	}

	return true
}
@(private = "file")
_assets_packed_write_regular :: proc(
	asset: Asset,
	file: ^os.File,
	counter: ^i64,
) -> (
	err: os.Error,
) {
	os.write_at(file, asset.memory.regular, counter^) or_return
	counter^ += i64(slice.size(asset.memory.regular))

	return nil
}

@(private = "file")
_assets_packed_write_spriv :: proc(
	asset: Asset,
	file: ^os.File,
	counter: ^i64,
) -> (
	err: os.Error,
) {
	data: []u32le
	when ODIN_ENDIAN == .Big {
		data = _slice_u32_to_u32le(asset.memory.spirv)
		defer _slice_u32le_to_u32(data)
	} else {
		data = transmute([]u32le)asset.memory.spirv
	}

	os.write_at(file, slice.reinterpret([]byte, data), counter^) or_return
	counter^ += i64(slice.size(data))

	return nil
}

@(private = "file")
_assets_packed_write_obj :: proc(asset: Asset, file: ^os.File, counter: ^i64) -> (err: os.Error) {
	counter_local := counter^

	indicies: []u32le
	when ODIN_ENDIAN == .Big {
		indicies = _slice_u32_to_u32le(asset.memory.mesh.indicies)
		defer _slice_u32le_to_u32(indicies)
	} else {
		indicies = transmute([]u32le)asset.memory.mesh.indicies
	}

	os.write_at(file, slice.reinterpret([]byte, indicies), counter^ + size_of(i64le)) or_return
	counter^ += i64(slice.size(indicies)) + size_of(i64le)

	// After we know at which offset the vertices will start we need to write it at the first 8 bytes of asset's packed memory chunk
	os.write_at(file, slice.bytes_from_ptr(counter, size_of(counter^)), counter_local)

	when ODIN_ENDIAN == .Big {
		for &v in asset.memory.mesh.verticies {
			v = _assets_base_vertex_native_to_le(v)
		}
		defer for &v in asset.memory.mesh.verticies {
			v = _assets_base_vertex_le_to_native(v)
		}
	}
	os.write_at(file, slice.reinterpret([]byte, asset.memory.mesh.verticies), counter^) or_return
	counter^ += i64(slice.size(asset.memory.mesh.verticies))

	return nil
}

@(private = "file")
_slice_u32_to_u32le :: proc(data: []u32) -> []u32le {
	for word, i in data {
		ptr := cast(^u32le)&data[i]
		ptr^ = u32le(word)
	}
	return transmute([]u32le)data
}

@(private = "file")
_slice_u32le_to_u32 :: proc(data: []u32le) -> []u32 {
	for word, i in data {
		ptr := cast(^u32)&data[i]
		ptr^ = u32(word)
	}
	return transmute([]u32)data
}

@(private = "file")
_assets_base_vertex_native_to_le :: proc(vertex: Base_Vertex) -> (v: Base_Vertex) {
	for n, i in vertex.normals {
		ptr := cast(^f32le)&v.normals[i]
		ptr^ = f32le(n)
	}

	for p, i in vertex.position {
		ptr := cast(^f32le)&v.position[i]
		ptr^ = f32le(p)
	}

	for u, i in vertex.uv {
		ptr := cast(^f32le)&v.uv[i]
		ptr^ = f32le(u)
	}

	return
}

@(private = "file")
_assets_base_vertex_le_to_native :: proc(vertex: ^Base_Vertex) -> (v: Base_Vertex) {
	for n, i in vertex.normals {
		ptr := cast(^f32le)&vertex.normals[i]
		v.normals[i] = f32(ptr^)
	}

	for p, i in vertex.position {
		ptr := cast(^f32le)&vertex.position[i]
		v.position[i] = f32(ptr^)
	}

	for u, i in vertex.uv {
		ptr := cast(^f32le)&vertex.uv[i]
		v.uv[i] = f32(ptr^)
	}

	return
}

// Read asset file into asset manager
read_asset_file :: proc(
	file: string,
	manager: ^Assets_Manager,
	load_data := false,
	append_to_packed_build := true,
	temp_allocator := context.temp_allocator,
) -> (
	err: Assets_Error,
) {
	if should_ingore_file(file) do return .Asset_On_Ignore_List

	f, o_err := os.open(file)
	if o_err != nil {
		log.errorf("Opening file '%v' failure: %v", file, o_err)
		return o_err
	}
	defer os.close(f)

	abs_path, abs_err := fp.abs(file, temp_allocator)
	if abs_err != nil {
		log.errorf("Failed to get absolute path for %v: %v", file, abs_err)
		return abs_err
	}

	name := fp.base(file)

	pkg := fp.base(fp.dir(abs_path))

	if pkg == "." || pkg == "" || pkg == "/" || pkg == "\\" {
		pkg = UNKNOWNPKG
	}

	ass: Asset
	ass._internal_metadata = new(Asset_Editor_Metadata, manager.allocator)

	ass._internal_metadata.source = f
	ass.pkg = pkg
	ass.name = name
	ass.file_type = _get_asset_file_type(file)

	id := generate_asset_id(ass.name, ass.pkg, ass.file_type, manager.hash_state)

	if id in manager.resources {
		log.errorf("Asset of ID: %v (%v) already exists", id, ass.name)
		free(ass._internal_metadata, manager.allocator)
		return .Asset_Already_Exists
	}

	ass.pkg = strings.clone(ass.pkg, manager._strings_arena.allocator)
	ass.name = strings.clone(ass.name, manager._strings_arena.allocator)

	ass.flags += {.Independent_File}
	ass.type = _get_asset_type(ass)
	ass.file_offset = 0

	size, size_err := os.file_size(f)
	if size_err != nil do log.warnf("File size retrieval failure: %v", size_err)
	ass.file_size = size

	if load_data {
		mem_err := _load_asset_memory_internal(&ass, f, manager.asset_allocator, false)
		if mem_err != nil {
			log.errorf("Loading asset's '%v:%v' memory failure: %v", ass.pkg, ass.name, mem_err)
		} else {
			ass.flags += {.Loaded_RAM}
		}
	}

	manager.resources[id] = ass

	log.infof("[ASSET] Loaded: %v (ID: %v, Pkg: %v)", ass.name, id, ass.pkg)

	return nil
}

// Unloads asset, frees all allocated memory and destroys entry in resource map if specified
// NOTE: Asset's `file type` should be set before calling to ensure proper cleanup
cleanup_asset :: proc(asset: ^Asset, manager: ^Assets_Manager, destroy_key: bool) {
	unload_asset_memory(asset, manager)

	if asset._internal_metadata != nil {
		err := os.close(asset._internal_metadata.source)
		if err != nil do log.errorf("Asset file closing failure: %v", err)

		// Free despite not closing, I don't think there is much to do if something like this happens
		free_err := free(asset._internal_metadata, manager.allocator)
		asset._internal_metadata = nil
	}

	id := generate_asset_id(asset.name, asset.pkg, asset.file_type, manager.hash_state)
	if destroy_key do delete_key(&manager.resources, id)
}
// Loads asset memory from assets.packed file with assets allocator
// NOTE: Asset's `file type` should be set before calling to ensure proper loading
load_asset_memory :: proc(asset: ^Asset, manager: ^Assets_Manager) -> os.Error {
	err := _load_asset_memory_internal(asset, manager.assets_file, manager.asset_allocator, true)
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
@(private = "file")
_load_asset_memory_internal :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator: runtime.Allocator,
	packed: bool,
	temp_allocator := context.temp_allocator,
) -> (
	err: os.Error,
) {
	if asset == nil do return

	if .Loaded_RAM in asset.flags do return nil

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	switch asset.file_type {
	case .UNRECOGNIZED:
		asset.memory.regular = _load_asset_binary_data_regular(asset, file, allocator) or_return
	case .SPIRV:
		_load_asset_binary_data_spirv(asset, file, allocator) or_return
	case .OBJ:
		_handle_obj_load(asset, file, allocator, packed) or_return
	case .PNG:
		_handle_png_load(asset, file, allocator, temp_allocator, packed) or_return
	}

	asset.flags += {.Loaded_RAM}
	return nil
}

@(private = "file")
_handle_obj_load :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator: runtime.Allocator,
	packed: bool,
) -> (
	err: os.Error,
) {
	if packed {
		return _load_asset_binary_data_obj(asset, file, allocator)
	}

	mesh, mesh_err := obj.load_mesh(file, allocator)
	if mesh_err != nil {
		log.errorf("OBJ Mesh loading error: %v", err)
		return .Unknown
	}
	defer obj.destroy_mesh(&mesh)

	vert, ind := obj.bake_mesh(mesh, allocator)
	asset.memory.mesh = {ind, vert}

	return nil
}

@(private = "file")
_handle_png_load :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator, temp_allocator: runtime.Allocator,
	packed: bool,
) -> (
	err: os.Error,
) {
	if packed {
		return _load_asset_binary_data_texture(asset, file, allocator)
	}

	// In theory this would be a problem on android cause I do not remember if file info is supported,
	// but we don't allow Editor on android so it's alright
	info: os.File_Info
	info, err = os.fstat(file, temp_allocator)
	if err != nil {
		log.errorf("Unable to get filename from handle '%v': %v", file, err)
		return err
	}

	mem, data, ok := _load_png(info.fullpath, allocator, temp_allocator)
	if !ok {
		log.error("Failed to load PNG data for asset")
		return .Unknown
	}

	asset.memory.regular = mem
	asset.data.texture = data
	return nil
}

@(private = "file")
_load_asset_binary_data_regular :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator := context.allocator,
) -> (
	buff: []byte,
	err: os.Error,
) {
	buff = make([]byte, asset.file_size, allocator) or_return
	defer if err != nil do delete(buff, allocator)

	read := os.read_at(file, buff, asset.file_offset) or_return
	if read != len(buff) do log.warnf("Allocated buffer for asset '%v:%v' size: %v bytes - read %v bytes", asset.pkg, asset.name, len(buff), read)

	return buff, nil
}

@(private = "file")
_load_asset_binary_data_spirv :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator := context.allocator,
) -> (
	err: os.Error,
) {
	buffer := _load_asset_binary_data_regular(asset, file, allocator) or_return

	// SPIRV is packed as u32le (and most of the times it won't need the endian swap)
	asset.memory.spirv = slice.reinterpret([]u32, buffer)
	when ODIN_ENDIAN == .Big {
		for op_code, i in asset.memory.spirv do asset.memory.spirv[i] = intrinsics.byte_swap(op_code)
	}

	return nil
}

@(private = "file")
_load_asset_binary_data_obj :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator := context.allocator,
) -> (
	err: os.Error,
) {
	// parse the first i64le that indicates offset at which vertices begin (indicies begin at offset + 8 bytes)
	vertices_offset: i64le
	os.read_at(
		file,
		slice.bytes_from_ptr(&vertices_offset, size_of(vertices_offset)),
		asset.file_offset,
	) or_return

	indicies_size_bytes := i64(vertices_offset) - asset.file_offset - size_of(vertices_offset)
	vertices_size_bytes := asset.file_size - indicies_size_bytes - size_of(vertices_offset)

	indicies := make([]u32, indicies_size_bytes / size_of(u32), allocator) or_return
	vertices := make(
		[]Base_Vertex,
		vertices_size_bytes / size_of(Base_Vertex),
		allocator,
	) or_return

	os.read_at(
		file,
		slice.reinterpret([]byte, indicies),
		asset.file_offset + size_of(vertices_offset),
	) or_return
	os.read_at(file, slice.reinterpret([]byte, vertices), i64(vertices_offset)) or_return

	when ODIN_ENDIAN == .Big {
		for &ind in indicies {
			ind = intrinsics.byte_swap(ind)
		}
		for &v in vertices {
			v = _assets_base_vertex_le_to_native(v)
		}
	}

	asset.memory.mesh = {indicies, vertices}
	return nil
}
@(private = "file")
_load_asset_binary_data_texture :: proc(
	asset: ^Asset,
	file: ^os.File,
	allocator := context.allocator,
) -> (
	err: os.Error,
) {
	header: Asset_Packed_Descriptor_Texture_Memory_Header
	os.read_at(file, slice.bytes_from_ptr(&header, size_of(header)), asset.file_offset) or_return

	asset.data.texture = {cast(i32)header.width, cast(i32)header.height, cast(i32)header.depth}

	data := make([]byte, asset.file_size, allocator) or_return
	os.read_at(file, data, asset.file_offset + size_of(header)) or_return

	asset.memory.regular = data
	return nil
}

// NOTE: Asset's `file type` should be set before calling to ensure proper cleanup
@(private = "file")
_unload_asset_memory_internal :: proc(asset: ^Asset, allocator: runtime.Allocator) {
	switch asset.file_type {
	case .UNRECOGNIZED, .PNG:
		delete(asset.memory.regular, allocator)
	case .SPIRV:
		delete(asset.memory.spirv, allocator)
	case .OBJ:
		delete(asset.memory.mesh.indicies, allocator)
		delete(asset.memory.mesh.verticies, allocator)
	}
}

find_if_asset_exists :: proc {
	find_if_asset_exists_by_id,
	find_if_asset_exists_by_data,
}
find_if_asset_exists_by_id :: proc(id: Asset_ID, manager: ^Assets_Manager) -> (exists: bool) {
	_, exists = manager.resources[id]
	return
}
find_if_asset_exists_by_data :: proc(
	name, pkg: string,
	type: Asset_File_Type,
	manager: ^Assets_Manager,
) -> (
	exists: bool,
) {
	id := generate_asset_id(name, pkg, type, manager.hash_state)

	return find_if_asset_exists_by_id(id, manager)
}

read_assets_dir_recursive :: proc(
	manager: ^Assets_Manager,
	dir_name := DEFAULT_ASSETS_DIR_NAME,
	allocator := context.temp_allocator,
	load_assets_mem := false,
) -> (
	success: bool,
) {
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
	// in case someone passes other allocator? (maybe temp one wouldn't be sufficient?)
	defer for i in infos do os.file_info_delete(i, allocator)
	defer delete(infos, allocator)

	for i in infos {
		#partial switch i.type {
		case .Directory:
			read_assets_dir_recursive(manager, i.fullpath, allocator, load_assets_mem)
		case .Regular:
			asset_err := read_asset_file(i.fullpath, manager, load_assets_mem)
			if asset_err != nil && asset_err != .Asset_On_Ignore_List do log.errorf("Unable to read asset from file '%v'", i.name)
		case:
			log.warnf("Got '%v' while reading assets directory, omitting", i.type)
			continue
		}
	}

	return true
}

should_ingore_file :: proc(file: string) -> (ignore: bool) {
	ext := fp.ext(file)
	for ignore_ext in Ignore_Files_By_Extension {
		if ext == ignore_ext {
			when CONFIG_VERBOSE_LOG do log.debugf(
				"Detected asset '%v' as one on ingore list",
				file,
			)
			return true
		}
	}
	return false
}


_load_png :: proc(
	filename: string,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	memory: []byte,
	data: Asset_Texture_Data,
	success: bool,
) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] && CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		return _load_png_desktop(filename, allocator, temp_allocator)
	} else {
		return
	}
}


@(private = "file")
_assets_packed_write_texture :: proc(asset: Asset, file: ^os.File, counter: ^i64) -> os.Error {
	header := Asset_Packed_Descriptor_Texture_Memory_Header {
		cast(i32le)asset.data.texture.width,
		cast(i32le)asset.data.texture.height,
		cast(i32le)asset.data.texture.depth,
	}

	os.write_at(file, slice.bytes_from_ptr(&header, size_of(header)), counter^) or_return
	counter^ += i64(size_of(header))

	return _assets_packed_write_regular(asset, file, counter)
}

get_vulkan_extent_from_texture_data :: proc(data: Asset_Texture_Data) -> vk.Extent3D {
	return {u32(data.width), u32(data.height), u32(data.depth)}
}
