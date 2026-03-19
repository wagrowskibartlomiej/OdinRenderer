#+feature using-stmt
package engine

import os "core:os/old"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:reflect"
import "core:strconv"
import "core:unicode/utf8"
import "core:strings"

import "base:intrinsics"
import "base:runtime"

/*
	CONFIGURATION CHECKS
*/

// Allow other build variatns only for Pc targets
when CONFIG_BUILD_TARGET != Build_Targets[.Pc] && CONFIG_BUILD_VARIANT != Build_Variants[.Release] do #panic("Build variant '" + CONFIG_BUILD_VARIANT + "' is not supported with '" + CONFIG_BUILD_TARGET + "' build target")

/*
NOTE:
	Maybe in future I'll add support for Apple devices
	For the time I'm writing this Android is my only mobile priority
*/

// Check for Mac build
when CONFIG_BUILD_TARGET == Build_Targets[.Pc] && (ODIN_OS != .Windows && ODIN_OS != .Linux) do #panic("'" + Build_Targets[.Pc] + "' build target is only supported for Windows and Linux")
// Check for iPhone build
when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && (ODIN_PLATFORM_SUBTARGET == .iPhone || ODIN_PLATFORM_SUBTARGET == .iPhoneSimulator) do #panic("'" + Build_Targets[.Mobile] + "' build target is not suppored for iPhones")

/*
	CONSTANTS
*/

@rodata
ENGINE_CONFIGURATION_FILE_NAME := "configuration.engine"

@rodata
UNDEFINED_CONFIG_VALUE := [?]byte{'-', '-', '-'} // This is used mainly to signal that something went wrong

@rodata
CONFIG_FILE_SEPRATOR := [?]byte{':', ' '} // Space after colon is for readability only

@rodata
CONFIG_FILE_NEW_LINE := [?]byte{'\n'}

@rodata
OPTION_FLAG_TRUE_STRING := "ENABLED"

@rodata
OPTION_FLAG_FALSE_STRING := "DISABLED"

/*
	COMPILE TIME CONFIGS:
	All values that have a 'CONFIG_' prefix and are initalized with '#config' declaration.

	RUNTIME OPTIONS:
	Options are values used to configure runtime app that have discrete values.
	Odin's bit sets are used to store options that are only true or false, as flags. (See Option_Flags/Option_Feature_Flags)
	Options can also be enum type. (See Option/Option_Feature)

	RUNTIME SETTINGS:
	Settings are values used to configure a runtime app that have arbitrary or continuous values,
	defined only by their data type (e.g., any float for sensitivity).

	STATE SAVING IN FILES:
	State of options and settings can be saved to file called 'configuration.engine'

	Config struct tags are used as a key for Option, Option_Feature, enums and all settings values.

	Rules of .engine format:
	1. Each line defines a one key value pair (keys: strings | values: Odin's int, f32 and string)
	2. Key and value pairs are separated with colon
	3. Spaces ocurring before key/value and after key/value will be stripped only allowing ones inside the key
	4. Key can have only one value, the first occurence is read, after which other encountered values are ignored
	5. Conifg tags must be unique
	6. Feature options should always be checked at runtime for availability
	NOTE: Encoding is UTF-8 (file data is iterated as runes), but usage of some control characters like \t and \r etc. is not covered at the moment

	TODO: Maybe I should add something like a prefix tag for structs to add ability to reuse them (which is not possible because config tags need to be unique right now)
*/

/*
	CONFIGS:
*/

CONFIG_BUILD_TARGET :: #config(BUILD_TARGET, Build_Targets[.Pc])
CONFIG_BUILD_VARIANT :: #config(BUILD_VARIANT, Build_Variants[.Release])
CONFIG_VERBOSE_LOG :: #config(VERBOSE_LOGGING, false)
CONFIG_TRACKING_ALLOCATOR :: #config(TRACKING_ALLOCATOR, false)

@(private="file")
engine_configuration: Engine_Configuration // Here state is stored

/*
	TYPES
*/

Engine_Configuration :: struct {
	configs: Configs,
	settings: Settings,
	options: Options,
	_settings_strings_arena: Strings_Arena, // Holds values of settings strings
}

Configs :: struct {
	target: Build_Target,
	variant: Build_Variant,
	verbose_logging,
	tracking_allocator: bool,
}

Build_Target :: enum {
	Pc, // Windows and Linux
	Mobile, // Android (only ARM support)
}

Build_Targets :: [Build_Target]string {
	.Pc = "PC",
	.Mobile = "MOBILE",
}

Build_Variant :: enum {
	Release,
	Editor,
	Headless
}

Build_Variants :: [Build_Variant]string{
	.Release = "RELEASE",
	.Editor = "EDITOR",
	.Headless = "HEADLESS"
}

Options :: struct {
	Vulkan: Vulkan_Options
}

All_Options_Flag :: union {
	Vulkan_Option_Flag
}

/*
	Option_Feature "config" tag used for parsing configuration file if this struct is inside another.
	
	Foo :: struct {
		some_option: Option_Feature(Some_Enum) "conifg:SOME OPTION NAME"
		other_values: int,
		etc...
	}
WARN:	This structure is not intended to be used as 'root'/'standalone' struct
*/

// WARN: do not change option field name because it is used for parsing
Option :: struct($T: typeid) where intrinsics.type_is_enum(T) {
	option: T,
	names: ^[T]string, // Here names field is used to provide string values for configuration file and key is retrieved from "config" tag
}

Option_Feature :: struct($T: typeid) where intrinsics.type_is_enum(T) {
	available: bit_set[T],
	using _: Option(T), // Here names field is used to provide string values for configuration file and key is retrieved from "config" tag
}

// WARN: do not change bits field name because it is used for parsing
Option_Flags :: struct($T: typeid) where intrinsics.type_is_enum(T) {
	bits: bit_set[T],
	names: ^[T]string, // Here names field is used to provide string values for configuration file as keys and values are defined in OPTION_FLAG_TRUE_STRING & OPTION_FLAG_FALSE_STRING
}

Option_Feature_Flags :: struct($T: typeid) where intrinsics.type_is_enum(T) {
	available: bit_set[T],
	using _: Option_Flags(T), // Here names field is used to provide string values for configuration file as keys and values are defined in OPTION_FLAG_TRUE_STRING & OPTION_FLAG_FALSE_STRING
}

Vulkan_Options :: struct {
	features: Option_Feature_Flags(Vulkan_Option_Flag),
	presentation: Option_Feature(Vulkan_Presentation_Option) "config:Vulkan V-Sync",
}

Vulkan_Option_Flag :: enum {
	Debug_Layers,
}
Vulkan_Option_Flags :: bit_set[Vulkan_Option_Flag]
@rodata
Vulkan_Option_Flags_Names := [Vulkan_Option_Flag]string{
	.Debug_Layers = "Vulkan debug layers"
}

Vulkan_Presentation_Option :: enum {
	FIFO,
	Immediate,
	Mailbox,
	FIFO_Relaxed,
}
@rodata
Vulkan_Presentation_Option_Names := [Vulkan_Presentation_Option]string{
	.FIFO = "ENABLED",
	.Immediate = "DISABLED",
	.Mailbox = "FAST",
	.FIFO_Relaxed = "ADAPTIVE"
}

Settings :: struct {
	Frames_In_Flight: int "config:Frames in flight"
}

Strings_Arena :: struct {
	handle: mem.Dynamic_Arena,
	allocator: mem.Allocator
}

get_engine_configuration :: proc() -> Engine_Configuration {
	return engine_configuration
}

initialize_engine_configuration :: proc (arena_allocator := context.allocator, block_allocator := context.allocator, temp_allocator := context.temp_allocator) {
	// Just to group all configuration in one place
	engine_configuration.configs.target = get_enum_based_on_string(CONFIG_BUILD_TARGET, Build_Targets)
	engine_configuration.configs.variant = get_enum_based_on_string(CONFIG_BUILD_VARIANT, Build_Variants)
	engine_configuration.configs.verbose_logging = CONFIG_VERBOSE_LOG
	engine_configuration.configs.tracking_allocator = CONFIG_TRACKING_ALLOCATOR

	engine_configuration_set_default_values()
	// TODO: There is an way to check for every options struct that has flags and if it has names field,
	//	 then either log warning or crash app if build variant is editor,
	//	 but for now just assigning names hardcoded way is the way to go, the rest is more important
	engine_configuration.options.Vulkan.features.names = &Vulkan_Option_Flags_Names


	init_settings_strings_arena(arena_allocator, block_allocator)
	load_configuration(temp_allocator)
}

cleanup_engine_configuration :: proc() {
	save_configuration()
	cleanup_settings_strings_arena()
}

/*
	Values here will be overriden if they can be retrieved from configuraiton file
	WARN: If values are not specified here they will default to Odin's zeroed state depending on type
*/
engine_configuration_set_default_values :: proc() {
	set_all_default_options()
	set_all_default_settings()
}

/*
 NOTE:
	I would like to name enum Build_Variant as 'Build_Type', but for unknown to me reason it makes Odin check crash
	I don't know if it is something on my end or if it's bug in Odin's check code
*/


/*
	OPTIONS:
*/


options_enable :: proc(option: All_Options_Flag) {
	switch v in option {
	case Vulkan_Option_Flag:
		_options_enable_with_check(&engine_configuration.options.Vulkan.features.bits, engine_configuration.options.Vulkan.features.available, v)
	}
}

options_disable :: proc(option: All_Options_Flag) {
	switch v in option {
	case Vulkan_Option_Flag:
		_options_enable(&engine_configuration.options.Vulkan.features.bits, v)
	}
}

options_get :: proc(option: All_Options_Flag) -> Maybe(bool) {
	switch v in option {
	case Vulkan_Option_Flag:
		if options_check_feature_availability(option) do _options_get(engine_configuration.options.Vulkan.features.bits, v)
		else do return nil
	case:
		log.errorf("Option '%v' is not recognized")
		return nil
	}

	return nil
}

// Same as options_get but without availablity check (best to use for options that are always available)
options_get_unsafe :: proc(option: All_Options_Flag) -> bool {
	switch v in option {
	case Vulkan_Option_Flag:
		return _options_get(engine_configuration.options.Vulkan.features.bits, v)
	case:
		log.errorf("Option '%v' is not recognized")
		return false
	}
}

options_check_feature_availability :: proc(option: All_Options_Flag) -> bool {
	switch v in option {
	case Vulkan_Option_Flag:
		return _options_check(v, &engine_configuration.options.Vulkan.features)
	case:
		log.errorf("Option '%v' is not recognized")
		return false
	}
}

options_set_feature_available :: proc(option: All_Options_Flag) {
	switch v in option {
	case Vulkan_Option_Flag:
		_options_set_available(&engine_configuration.options.Vulkan.features.available, v)
	case:
		log.warnf("Option '%v' does not have availablity state (either always is avaliable or error ocurred)", v)
	}
}

options_get_all :: proc() -> Options {
	return engine_configuration.options
}

options_vulkan_get_all :: proc() -> Vulkan_Options {
	return engine_configuration.options.Vulkan
}

set_all_default_options :: proc() {
	for field in reflect.struct_fields_zipped(Options) {
		switch field.name {
		case "Vulkan_Options":
			set_default_vulkan_options()
		case:
			// When it's not editor build I don't want to crash app just log the warning
			when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] do log.panic("Unhandled setting of default options of field '%v'", field.name)
			else do log.warnf("Unhandled setting of default options of field '%v'", field.name)
		}
	}
}

set_default_vulkan_options :: proc "contextless" () {
	using engine_configuration.options.Vulkan
	features.bits = Vulkan_Option_Flags{}
	presentation.option = .FIFO // Should be available on all devices that support Vulkan presentation
	presentation.names = &Vulkan_Presentation_Option_Names
}

@(private="file")
_options_enable :: proc(options: ^bit_set[$T], option: T) where intrinsics.type_is_enum(T) {
	if option in options {
		log.debugf("Requested to enable option '%v' when it's already enabled", option)
		return
	}
	options^ |= bit_set[T]{option}
	when CONFIG_VERBOSE_LOG do log.debugf("Option '%v' enabled", option)
} 

@(private="file")
_options_enable_with_check :: proc(options: ^bit_set[$T], available: bit_set[T], option: T) where intrinsics.type_is_enum(T) {
	if option in available do _options_enable(options, option)
	else do log.debugf("Requested to enable option '%v' when it's set as not available feature")
} 

@(private="file")
_options_disable :: proc(options: ^bit_set[$T], option: T) where intrinsics.type_is_enum(T) {
	if option not_in options {
		log.debugf("Requested to disable option '%v', when it's already is disabled")
		return
	}
	options &~= option
	when CONFIG_VERBOSE_LOG do log.debugf("Option '%v' disabled", option)
}

@(private="file")
_options_set_available :: proc(options: ^bit_set[$T], option: T) where intrinsics.type_is_enum(T) {
	if option in options {
		log.debugf("Requested to set option '%v' as available feature, but it already is marked as available")
		return
	}
	options^ |= bit_set[T]{option}
	when CONFIG_VERBOSE_LOG do log.debugf("Option '%v' enabled", option)
} 

@(private="file")
_options_get :: proc(options: bit_set[$T], option: T) -> bool where intrinsics.type_is_enum(T) {
	if option in options do return true
	else do return false
}

@(private="file")
_options_check :: proc(option: $T, options: ^Option_Feature_Flags(T)) -> bool where intrinsics.type_is_enum(T) {
	if option in options.available do return true
	else do return false
}

/*
	SETTINGS:
*/


get_all_settings :: proc() -> Settings {
	return engine_configuration.settings
}

init_settings_strings_arena :: proc(arena_allocator := context.allocator, block_allocator := context.allocator, block_size := mem.Kilobyte * 4,  out_band_size := mem.DYNAMIC_ARENA_OUT_OF_BAND_SIZE_DEFAULT, alignment := mem.DEFAULT_ALIGNMENT) {
	mem.dynamic_arena_init(&engine_configuration._settings_strings_arena.handle, arena_allocator, block_allocator, block_size, out_band_size, alignment)
	engine_configuration._settings_strings_arena.allocator = mem.dynamic_arena_allocator(&engine_configuration._settings_strings_arena.handle)
}

cleanup_settings_strings_arena :: proc() {
	mem.dynamic_arena_destroy(&engine_configuration._settings_strings_arena.handle)
}

set_all_default_settings :: proc() {
	engine_configuration.settings.Frames_In_Flight = 2
}

/*
	FILE:
*/


/*
	SAVING:
*/


save_configuration :: proc() -> (success: bool) {
	h, err := os.open(ENGINE_CONFIGURATION_FILE_NAME, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, 0o644)
	if err != nil {
		log.errorf("Engine configuration save attempt failed: %v", err)
		return false
	}
	defer os.close(h)

	current_offset: i64
	conf := get_engine_configuration()

	save_handle_options(h, &current_offset, &conf.options)
	// Handle settings
	fields := reflect.struct_fields_zipped(type_of(conf.settings))

	for f, i in fields {
		field := f

		tag := string(f.tag)
		tag_b := transmute([]byte)tag

		os.write_at(h, tag_b[:], current_offset)
		current_offset += i64(len(tag_b))

		os.write_at(h, CONFIG_FILE_SEPRATOR[:], current_offset)
		current_offset += i64(len(CONFIG_FILE_SEPRATOR))

		val_any := reflect.struct_field_value(conf.settings, f)

		switch t in val_any {
		case int:
			int_buff: [64]byte
			int_str := transmute([]byte) strconv.write_int(int_buff[:], i64(t), 10)
			os.write_at(h, int_str[:], current_offset)
			current_offset += i64(len(int_str))
		case string:
			s := transmute([]byte)t
			os.write_at(h, s[:], current_offset)
			current_offset += i64(len(s[:]))
		case f32:
			float_buff: [64]byte
			float_str := transmute([]byte) strconv.write_float(float_buff[:], f64(t), 'G', -1, 32)
			os.write_at(h, float_str[:], current_offset)
			current_offset += i64(len(float_str))
		case:
			os.write_at(h, UNDEFINED_CONFIG_VALUE[:], current_offset)
			current_offset += i64(len(UNDEFINED_CONFIG_VALUE))
		}

		os.write_at(h, CONFIG_FILE_NEW_LINE[:], current_offset)
		current_offset += i64(len(CONFIG_FILE_NEW_LINE))
	}

	when CONFIG_VERBOSE_LOG do log.debugf("Saving of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)
	success = true
	return
}

save_handle_options :: proc(h: os.Handle, offset: ^i64, structure: any) {
	for field in reflect.struct_fields_zipped(type_of(structure)) {
		field_value_any := reflect.struct_field_value(structure, field)
		config_tag := reflect.struct_tag_get(field.tag, "config")
		#partial switch v in field.type.variant {
		case runtime.Type_Info_Struct:
			if intrinsics.type_is_specialization_of(type_of(field_value_any), Option) do save_handle_option(config_tag, h, offset, field_value_any)
			else if intrinsics.type_is_specialization_of(type_of(field_value_any), Option_Flags) do save_handle_option_flags(h, offset, field_value_any)
			else do save_handle_options(h, offset, field_value_any)
		case runtime.Type_Info_Bit_Set: 
			when CONFIG_BUILD_TARGET != Build_Variants[.Release] && CONFIG_VERBOSE_LOG do log.warnf("Using plain bit_set in options is not recommended")
			save_handle_bit_set(h, offset, field_value_any)
		case runtime.Type_Info_Enum: 
			when CONFIG_BUILD_TARGET != Build_Variants[.Release] && CONFIG_VERBOSE_LOG do log.warnf("Using plain enum in options is not recommended")
			save_handle_enum(config_tag, h, offset, field_value_any)
		case:
		}

	}
}

save_handle_option :: proc(tag: string, h: os.Handle, offset: ^i64, structure: any) {
	option_any := reflect.struct_field_value_by_name(structure, "option", allow_using = true)
	if option_any == nil {
		log.errorf("Expected option field in '%v' structure while saving, but it was not found", structure)
		return
	}


	option_info := type_info_of(option_any.id)
	base_enum_info, success := unwrap_enum_from_named(option_info)
	if !success {
		log.errorf("Error occured while trying to save value '%v'", option_any)
		return
	}

	enum_info := base_enum_info.variant.(runtime.Type_Info_Enum)

	names_any := reflect.struct_field_value_by_name(structure, "names", allow_using = true)
	names: []string

	if names_any == nil || (cast(^[^]string)names_any.data)^ == nil do names = enum_info.names
	else do names = ((cast(^[^]string)names_any.data)^)[:len(enum_info.values)]

	tag_b := transmute([]byte)tag
	os.write_at(h, tag_b, offset^)
	offset^ += i64(slice.size(tag_b))

	os.write_at(h, CONFIG_FILE_SEPRATOR[:], offset^)
	offset^ += i64(len(CONFIG_FILE_SEPRATOR))

	for v, i in enum_info.values do check_and_write_enum_from_rawptr(h, offset, option_any.data, base_enum_info.size, v, names[i])

	os.write_at(h, CONFIG_FILE_NEW_LINE[:], offset^)
	offset^ += i64(len(CONFIG_FILE_NEW_LINE))
}

save_handle_option_flags :: proc(h: os.Handle, offset: ^i64, structure: any) {
	bits_any := reflect.struct_field_value_by_name(structure, "bits", allow_using = true)
	if bits_any == nil {
		log.errorf("Expected bits field in '%v' structure while saving, but it was not found", structure)
		return
	}
	info := type_info_of(bits_any.id)
	bits_info := info.variant.(runtime.Type_Info_Bit_Set)
	base_enum_info, success := unwrap_enum_from_named(bits_info.elem)
	if !success {
		log.errorf("Error occured while trying to save value '%v'", bits_any)
		return
	}

	enum_info := base_enum_info.variant.(runtime.Type_Info_Enum)

	names_any := reflect.struct_field_value_by_name(structure, "names", allow_using = true)
	names: []string

	if names == nil || (cast(^[^]string)names_any.data)^ == nil do names = enum_info.names
	else do names = ((cast(^[^]string)names_any.data)^)[:len(enum_info.values)]

	for v, i in enum_info.values {
		name_b := transmute([]byte)names[i]

		os.write_at(h, name_b, offset^)
		offset^ += i64(slice.size(name_b))

		os.write_at(h, CONFIG_FILE_SEPRATOR[:], offset^)
		offset^ += i64(slice.size(CONFIG_FILE_SEPRATOR[:]))

		flag: []byte

		if value_in_bit_set_by_rawptr(v, bits_info.lower, bits_info.underlying.size, bits_any.data) do flag = transmute([]byte)OPTION_FLAG_TRUE_STRING
		else do flag = transmute([]byte)OPTION_FLAG_FALSE_STRING

		os.write_at(h, flag, offset^)
		offset^ += i64(slice.size(flag))
		
		os.write_at(h, CONFIG_FILE_NEW_LINE[:], offset^)
		offset^ += i64(slice.size(CONFIG_FILE_NEW_LINE[:]))
	}
}

save_handle_bit_set :: proc(h: os.Handle, offset: ^i64, _bit_set: any) {
	info := type_info_of(_bit_set.id)
	bit_set_info := info.variant.(runtime.Type_Info_Bit_Set)

	base_enum_info, success := unwrap_enum_from_named(bit_set_info.elem)
	if !success do return

	enum_info := base_enum_info.variant.(runtime.Type_Info_Enum)
	
	for v, i in enum_info.values {
	name := transmute([]byte)enum_info.names[i]

	os.write_at(h, name, offset^)
	offset^ += i64(slice.size(name))

	os.write_at(h, CONFIG_FILE_SEPRATOR[:], offset^)
	offset^ += i64(slice.size(CONFIG_FILE_SEPRATOR[:]))

	flag: []byte
	if value_in_bit_set_by_rawptr(v, bit_set_info.lower, info.size, _bit_set.data) do flag = transmute([]byte)OPTION_FLAG_TRUE_STRING
	else do flag = transmute([]byte)OPTION_FLAG_FALSE_STRING

	os.write_at(h, flag, offset^)
	offset^ += i64(slice.size(flag))

	os.write_at(h, CONFIG_FILE_NEW_LINE[:], offset^)
	offset^ += i64(slice.size(CONFIG_FILE_NEW_LINE[:]))
	}
}

save_handle_enum :: proc(tag: string, h: os.Handle, offset: ^i64, _enum: any) {
	info := type_info_of(_enum.id)
	enum_info := info.variant.(runtime.Type_Info_Enum)
	
	tag_b := transmute([]byte)tag

	os.write_at(h, tag_b, offset^)
	offset^ += i64(slice.size(tag_b))

	os.write_at(h, CONFIG_FILE_SEPRATOR[:], offset^)
	offset^ += i64(slice.size(CONFIG_FILE_SEPRATOR[:]))

	val := cast_enum_value_to_i64(_enum.data, info.size)

	for v, i in enum_info.values {
		if val == i64(v) {
		name := transmute([]byte)enum_info.names[i]

		os.write_at(h, name, offset^)
		offset^ += i64(slice.size(name))

		os.write_at(h, CONFIG_FILE_NEW_LINE[:], offset^)
		offset^ += i64(slice.size(CONFIG_FILE_NEW_LINE[:]))

		return
		}
	}

	os.write_at(h, UNDEFINED_CONFIG_VALUE[:], offset^)
	offset^ += i64(slice.size(UNDEFINED_CONFIG_VALUE[:]))

	os.write_at(h, CONFIG_FILE_NEW_LINE[:], offset^)
	offset^ += i64(slice.size(CONFIG_FILE_NEW_LINE[:]))
}

check_and_write_enum_from_rawptr :: proc(handle: os.Handle, offset: ^i64, data: rawptr, size: int, value: runtime.Type_Info_Enum_Value, to_write: string) {
	bytes := transmute([]byte)to_write
	val := i64(value)
	enum_val := cast_enum_value_to_i64(data, size)

	if val == enum_val {
		os.write_at(handle, bytes, offset^) 
		offset^ += i64(slice.size(bytes))
	}
}

value_in_bit_set_by_rawptr :: proc(value: runtime.Type_Info_Enum_Value, lowest: i64, size: int, data: rawptr) -> bool {
	switch size {
	case 1: 
		num := (cast(^u8)data)^ 
		mask := u8(1 << (u8(value) - u8(lowest)))
		return num & mask == mask
	case 2:
		num := (cast(^u16)data)^ 
		mask := u16(1 << (u16(value) - u16(lowest)))
		return num & mask == mask
	case 4:
		num := (cast(^u32)data)^ 
		mask := u32(1 << (u32(value) - u32(lowest)))
		return num & mask == mask
	case 8:
		num := (cast(^u64)data)^ 
		mask := u64(1 << (u64(value) - u64(lowest)))
		return num & mask == mask
	case 16:
		num := (cast(^u128)data)^ 
		mask := u128(1 << (u128(value) - u128(lowest)))
		return num & mask == mask
	case: return false
	}
}

cast_enum_value_to_i64 :: proc(enum_ptr: rawptr, size: int) -> i64 {
	switch size {
	case 1: return i64((cast(^u8)enum_ptr)^)
	case 2: return i64((cast(^u16)enum_ptr)^)
	case 4: return i64((cast(^u32)enum_ptr)^)
	case 8: return i64((cast(^u64)enum_ptr)^)
	case: return 0
	}
}


/*
	LOADING:
*/


load_configuration :: proc(settings_string_allocator: runtime.Allocator, temp_allocator := context.temp_allocator) {
	h, err := os.open(ENGINE_CONFIGURATION_FILE_NAME)
	if err != nil {
		when CONFIG_BUILD_VARIANT != Build_Variants[.Release] do fmt.eprintfln("Failed to open '%v' file to read enigne configuration: %v", ENGINE_CONFIGURATION_FILE_NAME, err)
		return
	}
	defer os.close(h)

	m := parse_engine_configuration_file(h, temp_allocator)
	defer delete(m)

	for k, v in m do load_value(k, v, settings_string_allocator)

	when CONFIG_VERBOSE_LOG do log.debugf("Loading of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)
}

parse_engine_configuration_file :: proc(h: os.Handle, allocator := context.allocator) -> map[string]string {
	/***************************************************
		NOTE:
		I don't really know at the moment how I want to handle some characters like: '\t' or '\r' etc.
		So at the moment I will just treat them like normal chars and let default case handle them,
		but I don't want it to stay that way, so this code needs a revisit later on.
		Also truncating only to spaces is somewhat distrubing me, but it's okay for now.
	***************************************************/

	data_b, success := os.read_entire_file_from_handle(h)
	if !success do return nil
	defer delete(data_b)

	data := string(data_b[:]) // convert to string to iterate as rune for utf8 encoding


	// 128 characters should be more than enough
	key_buff := make([dynamic]rune, 0, 128) 
	defer delete(key_buff)

	val_buff := make([dynamic]rune, 0, 128)
	defer delete(val_buff)

	values := make(map[string]string, allocator)
	
	reading_key := true // to know when we string that's being read is key or value
	start_reading := false // used to ignore the spaces before actual key/value string (spaces after are truncated by strings.truncate_to_byte)
	for char in data {
		switch char {
		case ' ':
			if !start_reading do continue
			else {
				if reading_key do append(&key_buff, char)
				else do append(&val_buff, char)
			}
		case '\n':
			reading_key = true
			start_reading = false

			// ut8.runes_to_string makes an copy
			key_raw := utf8.runes_to_string(key_buff[:], allocator)
			defer delete(key_raw, allocator)

			val_raw := utf8.runes_to_string(val_buff[:], allocator)
			defer delete(val_raw, allocator)

			key := strings.truncate_to_byte(key_raw, ' ')
			val := strings.truncate_to_byte(val_raw, ' ')

			_, exists := values[key]
			if !exists && key != "" {
				if val != "" do values[key] = val
				else do values[key] = string(UNDEFINED_CONFIG_VALUE[:])
			}
			else do when CONFIG_VERBOSE_LOG do log.warnf("Duplicate configuration value detected: %v: %v", key, val)

			clear(&key_buff)
			clear(&val_buff)
		case ':':
			reading_key = false
			start_reading = false
		case:
			if !start_reading {
				start_reading = true
			}
			if reading_key do append(&key_buff, char)
			else do append(&val_buff, char)
		}
	}

	key_raw := utf8.runes_to_string(key_buff[:], allocator)
	defer delete(key_raw)

	val_raw := utf8.runes_to_string(val_buff[:], allocator)
	defer delete(val_raw)

	key := strings.truncate_to_byte(key_raw, ' ')
	val := strings.truncate_to_byte(val_raw, ' ')

	_, exists := values[key]
	if !exists && key != "" {
		if val != "" do values[key] = val
		else do values[key] = string(UNDEFINED_CONFIG_VALUE[:])
	}
	else do when CONFIG_VERBOSE_LOG do log.warnf("Duplicate configuration value detected: %v: %v", key, val)

	return values
}

load_value :: proc(key, value: string, settings_strings_allocator: runtime.Allocator, settings := engine_configuration.settings, options := engine_configuration.options) {
	setting_loaded := load_value_settings(key, value, settings, settings_strings_allocator)
	if setting_loaded do return
		
	load_value_options(key, value, options)
}

load_value_settings :: proc(key, value: string, structure: any, strings_allocator: runtime.Allocator) -> (loaded: bool) {
	for field in reflect.struct_fields_zipped(type_of(structure)) {
		field_any := reflect.struct_field_value(structure, field)
		config_tag := reflect.struct_tag_get(field.tag, "config")
		#partial switch t in field.type.variant {
		case runtime.Type_Info_Float:
			if config_tag != key do continue

			if field.type.size != 4 do return

			float, ok := strconv.parse_f32(value)
			if !ok do continue

			(cast(^f32)field_any.data)^ = float
			return true
		case runtime.Type_Info_Integer: 
			if config_tag != key do continue

			integer, ok := strconv.parse_int(value)
			if !ok do continue

			(cast(^int)field_any.data)^ = integer
			return true
		case runtime.Type_Info_String:
			if config_tag != key do continue

			cloned, err := strings.clone(value, strings_allocator)
			if err != nil do return

			(cast(^string)field_any.data)^ = cloned
			return true
		case runtime.Type_Info_Struct: load_value_settings(key, value, field_any, strings_allocator)
		case: continue
		}
	}

	return false
}

load_value_options :: proc(key, value: string, structure: any) {
	// if option is false or undefined, leave as Odin's zero value
	if value == OPTION_FLAG_FALSE_STRING || value == string(UNDEFINED_CONFIG_VALUE[:]) do return 

	for field in reflect.struct_fields_zipped(type_of(structure)) {
		config_tag := reflect.struct_tag_get(field.tag, "config") // we need conifg tag for certain types
		field_any := reflect.struct_field_value(structure, field)
		if field_any.data == nil do return // check if there is a field

		#partial switch &t in field.type.variant {
		case runtime.Type_Info_Named: load_handle_named(config_tag, key, value, field_any, &t)
		case runtime.Type_Info_Struct:
			if config_tag != "" && config_tag == key && intrinsics.type_is_specialization_of(type_of(field_any), Option) do load_handle_option_struct(value, field_any)
			else if intrinsics.type_is_specialization_of(type_of(field_any), Option_Flags) do load_handle_option_flags_struct(key, field_any)
			else do load_value_options(key, value, field_any)
		case runtime.Type_Info_Enum: 
			if config_tag != "" && config_tag == key do load_handle_enum(value, field_any)
			else do continue
		case runtime.Type_Info_Bit_Set: load_handle_bit_set(key, field_any)
		case: continue
		}
	}
}


@(private="file")
load_handle_named :: proc(tag, key, value: string, field: any, named: ^runtime.Type_Info_Named) {
	#partial switch t in named.base.variant {
	case runtime.Type_Info_Enum: if tag != "" && tag == key do load_handle_enum(value, field)
	case runtime.Type_Info_Bit_Set: load_handle_bit_set(key, field)
	case runtime.Type_Info_Struct: load_value_options(key, value, field)
	case runtime.Type_Info_Named: load_handle_named(tag, key, value, field, named)
	case: return
	}
}

@(private="file")
load_handle_enum :: proc(value: string, field: any) {
	info := type_info_of(type_of(field))
	enum_info := info.variant.(runtime.Type_Info_Enum)

	for n, i in enum_info.names {
		if n == value do set_enum_value_by_rawptr(field.data, info.size, enum_info.values[i])
	}
}

@(private="file")
load_handle_bit_set :: proc(key: string, field: any) {
	info := type_info_of(type_of(field))
	bit_set_info := info.variant.(runtime.Type_Info_Bit_Set)

	base_enum_info, success := unwrap_enum_from_named(bit_set_info.elem)
	if !success do return
	
	enum_info := base_enum_info.variant.(runtime.Type_Info_Enum)

	for n, i in enum_info.names {
		if n == key do set_bit_set_value_by_rawptr(field.data, bit_set_info.lower, info.size, enum_info.values[i])
	}
}

@(private="file")
load_handle_option_struct :: proc(value: string, structure: any) {
	option_any := reflect.struct_field_value_by_name(structure, "option", allow_using = true) // enum
	names_any := reflect.struct_field_value_by_name(structure, "names", allow_using = true) // enumerated array
	if option_any == nil do return

	option_info := type_info_of(option_any.id)
	base_enum_info, success := unwrap_enum_from_named(option_info)
	if !success do return
	
	enum_info := base_enum_info.variant.(runtime.Type_Info_Enum)

	names: []string // these are value names

	// get names from enum directly if they're not present
	if names_any == nil || (cast(^[^]string)names_any.data)^ == nil do names = enum_info.names
	else do names = ((cast(^[^]string)names_any.data)^)[:len(enum_info.values)]
	
	for n, i in names {
		if value == n do set_enum_value_by_rawptr(option_any.data, option_info.size, enum_info.values[i])
	}
}

@(private="file")
load_handle_option_flags_struct :: proc(key: string, structure: any) {
	bits_any := reflect.struct_field_value_by_name(structure, "bits", allow_using = true) // enum
	names_any := reflect.struct_field_value_by_name(structure, "names", allow_using = true) // enumerated array
	if bits_any == nil do return
	
	bits_info := type_info_of(bits_any.id)
	bit_set_info, is_bits := bits_info.variant.(runtime.Type_Info_Bit_Set)
	if !is_bits do return
	
	enum_base_info, success := unwrap_enum_from_named(bit_set_info.elem)
	if !success do return
	
	enum_info := enum_base_info.variant.(runtime.Type_Info_Enum)

	names: []string

	if names_any == nil || (cast(^[^]string)names_any.data)^ == nil do names = enum_info.names
	else do names = ((cast(^[^]string)names_any.data)^)[:len(enum_info.values)]

	for n, i in names {
		if n == key do set_bit_set_value_by_rawptr(bits_any.data, bit_set_info.lower, bits_info.size, enum_info.values[i])
	}
}

@(private="file")
set_enum_value_by_rawptr :: proc(data: rawptr, size: int, value: runtime.Type_Info_Enum_Value) {
	switch size {
	case 1: (cast(^u8)data)^ = u8(value)
	case 2: (cast(^u16)data)^ = u16(value)
	case 4: (cast(^u32)data)^ = u32(value)
	case 8: (cast(^u64)data)^ = u64(value)
	case: return
	}
}

@(private="file")
set_bit_set_value_by_rawptr :: proc(data: rawptr, lowest: i64, size: int, value: runtime.Type_Info_Enum_Value) {
	switch size {
	case 1: (cast(^u8)data)^ |= (1 << u8((i64(value) - lowest)))
	case 2: (cast(^u16)data)^ |= (1 << u16(i64(value) - lowest))
	case 4: (cast(^u32)data)^ |= (1 << u32(i64(value) - lowest))
	case 8: (cast(^u64)data)^ |= (1 << u64(i64(value) - lowest))
	case 16: (cast(^u128)data)^ |= (1 << u128(i64(value) - lowest))
	case: return
	}
}

/*
	UTILITY:
*/


get_enum_based_on_string :: proc "contextless" (value: string, enumerated_array: [$T]string) -> T where intrinsics.type_is_enum(T) {
	for s, e in enumerated_array {
		if s == value do return e
	}
	return nil
}

unwrap_enum_from_named :: proc(info: ^runtime.Type_Info) -> (enum_info: runtime.Type_Info, success: bool) {
	enum_info = info^
	for {
		#partial switch t in info.variant {
		case runtime.Type_Info_Enum: return
		case runtime.Type_Info_Named: enum_info = t.base^
		case: return {}, false
		}
	}
}
