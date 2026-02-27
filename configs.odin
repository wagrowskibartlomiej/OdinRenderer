package engine

import "core:os"
import "core:log"
import "core:fmt"
import "core:reflect"
import "core:strconv"

import "base:intrinsics"

@rodata
ENGINE_CONFIGURATION_FILE_NAME := "configuration.engine"

@rodata
UNDEFINED_CONFIG_VALUE := [?]byte{'-', '-', '-'}

/*
	COMPILE TIME CONFIGS:
	All values that have a 'CONFIG_' prefix and are initalized with '#config' declaration.

	RUNTIME OPTIONS:
	Options are values used to configure runtime app that have discrete values.
	Odin's bit sets are used to store options that are only true or false, as flags.

	RUNTIME SETTINGS:
	Settings are values used to configure a runtime app that have arbitrary or continuous values,
	defined only by their data type (e.g., any float for sensitivity).

	STATE SAVING IN FILES:
	State of options and settings can be saved to file called 'configuration.engine'

	Rules of .engine format:
	1. Each line defines a one key value pair (keys: strings, values: Odin's int, f32 and string)
	2. Key and value pairs are separated with colon
	3. Whitespaces are ignored
	4. Key can have only one value, the first occurence is read, after which other encountered values are ignored
*/

/*
	CONFIGS:
*/

CONFIG_BUILD_TARGET :: #config(BUILD_TARGET, Build_Targets[.Pc])
CONFIG_BUILD_VARIANT :: #config(BUILD_VARIANT, Build_Variants[.Release])
CONFIG_VERBOSE_LOG :: #config(VERBOSE_LOGGING, false)
CONFIG_TRACKING_ALLOCATOR :: #config(TRACKING_ALLOCATOR, false)

Engine_Configuration :: struct {
	configs: Configs,
	settings: Settings,
	options: Options,
}

@(private="file")
engine_configuration: Engine_Configuration

Configs :: struct {
	target: Build_Target,
	variant: Build_Variant,
	verbose_logging,
	tracking_allocator: bool,
}

get_engine_configuration :: proc() -> Engine_Configuration {
	return engine_configuration
}

@(init, private="file")
assign_configs_to_global_struct :: proc "contextless" () {
	// Just to group all configuration in one place
	engine_configuration.configs.target = get_enum_based_on_string(CONFIG_BUILD_TARGET, Build_Targets)
	engine_configuration.configs.variant = get_enum_based_on_string(CONFIG_BUILD_VARIANT, Build_Variants)
	engine_configuration.configs.verbose_logging = CONFIG_VERBOSE_LOG
	engine_configuration.configs.tracking_allocator = CONFIG_TRACKING_ALLOCATOR

}

/*
	Values here will be overriden if they can be retrieved from configuraiton file
	WARN: If values are not specified here they will default to Odin's zeroed state depending on type
*/
@init
enigne_configuration_set_default_values :: proc "contextless" () {
	engine_configuration.settings.Frames_In_Flight = 2
}

Build_Target :: enum {
	Pc, // Windows and Linux
	Mobile, // Android (only ARM support)
}

Build_Targets :: [Build_Target]string {
	.Pc = "PC",
	.Mobile = "MOBILE",
}

/*
 NOTE:
	I would like to name enum Build_Variant as 'Build_Type', but for unknown to me reason it makes Odin check crash
	I don't know if it is something on my end or if it's bug in Odin's check code
*/


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

// Allow other build variatns only for Pc targets
when CONFIG_BUILD_TARGET != Build_Targets[.Pc] && CONFIG_BUILD_VARIANT != Build_Variants[.Release] do #panic("Build variant '" + CONFIG_BUILD_VARIANT + "' is not supported with '" + CONFIG_BUILD_TARGET + "' build target")

/*
NOTE:
	Maybe in future I'll add support for Apple devices
	For the time I'm writing this Android is my only mobile priority
*/

// Check for Mac build
when CONFIG_BUILD_TARGET == Build_Targets[.Pc] && (ODIN_OS != .Windows && ODIN_OS != .Linux) do #panic("Pc build target is only supported for Windows and Linux")
// Check for iPhone build
when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && (ODIN_PLATFORM_SUBTARGET == .iPhone || ODIN_PLATFORM_SUBTARGET == .iPhoneSimulator) do #panic("Mobile build target is not suppored for iPhones")

/*
	OPTIONS:
*/

@rodata
OPTION_FLAG_TRUE_STRING := "enable"

@rodata
OPTION_FLAG_FALSE_STRING := "disable"

Options :: struct {
	Vulkan: Vulkan_Options
}

Option_Flag :: union {
	Vulkan_Option_Flag
}

options_enable :: proc(option: Option_Flag) {
	switch v in option {
	case Vulkan_Option_Flag:
		_options_enable(&engine_configuration.options.Vulkan.flags, v)
	}
}

@(private="file")
_options_enable :: proc(options: ^bit_set[$T], option: T) where intrinsics.type_is_enum(T) {
	options^ |= bit_set[T]{option}
	when CONFIG_VERBOSE_LOG do log.debugf("Option '%v' enabled", option)
} 

options_disable :: proc(option: Option_Flag) {
	switch v in option {
	case Vulkan_Option_Flag:
		_options_enable(&engine_configuration.options.Vulkan.flags, v)
	}
}

@(private="file")
_options_disable :: proc(options: ^bit_set[$T], option: T) where intrinsics.type_is_enum(T) {
	options &~= option
	when CONFIG_VERBOSE_LOG do log.debugf("Option '%v' disabled", option)
}

options_get :: proc(option: Option_Flag) -> bool {
	switch v in option {
	case Vulkan_Option_Flag:
		return _options_get(engine_configuration.options.Vulkan.flags, v)
	case:
		log.errorf("Option '%v' is not recognized")
		return false
	}
}
@(private="file")
_options_get :: proc(options: bit_set[$T], option: T) -> bool where intrinsics.type_is_enum(T) {
	if option in options do return true
	else do return false
}
options_get_all :: proc() -> Options {
	return engine_configuration.options
}

Vulkan_Options :: struct {
	flags: Vulkan_Option_Flags,
}

Vulkan_Option_Flag :: enum {
	Debug_Layers,
}
Vulkan_Option_Flags :: bit_set[Vulkan_Option_Flag]
@rodata
Vulkan_Option_Flags_Names := [Vulkan_Option_Flag]string{
	.Debug_Layers = "DEBUG_LAYERS"
}

options_vulkan_get_all :: proc() -> Vulkan_Options {
	return engine_configuration.options.Vulkan
}

/*
	SETTINGS:
*/

Settings :: struct {
	Frames_In_Flight: int "FRAMES-IN-FLIGHT"
}

get_all_settings :: proc() -> Settings {
	return engine_configuration.settings
}

/*
	FILE:
*/


load_configuration :: proc() {
	h, err := os.open(ENGINE_CONFIGURATION_FILE_NAME)
	if err != nil {
		when CONFIG_BUILD_VARIANT != Build_Variants[.Release] do fmt.eprintfln("Failed to open '%v' file to read enigne configuration: %v", ENGINE_CONFIGURATION_FILE_NAME, err)
		return
	}
	defer os.close(h)

	m := parse_engine_configuration_file(h)
	defer delete(m)

	for k, v in m do handle_values(k, v)


	when CONFIG_VERBOSE_LOG do log.debugf("Loading of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)

}

save_configuration :: proc() -> (success: bool) {
	h, err := os.open(ENGINE_CONFIGURATION_FILE_NAME, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, 0o644)
	if err != nil {
		log.errorf("Engine configuration save attempt failed: %v", err)
		return false
	}
	defer os.close(h)

	current_offset: i64
	conf := get_engine_configuration()
	separator := [?]byte{':', ' '}
	new_line := [?]byte{'\n'}

	// Handle options
	for f in conf.options.Vulkan.flags {
		str := transmute([]byte)Vulkan_Option_Flags_Names[f]
		os.write_at(h, str[:], current_offset)
		current_offset += i64(len(str))

		os.write_at(h, separator[:], current_offset)
		current_offset += i64(len(separator))

		if f in conf.options.Vulkan.flags {
			flag_true := transmute([]byte)OPTION_FLAG_TRUE_STRING
			os.write_at(h, flag_true[:], current_offset)
			current_offset += i64(len(flag_true))
		} else {
			flag_false := transmute([]byte)OPTION_FLAG_FALSE_STRING
			os.write_at(h, flag_false[:], current_offset)
			current_offset += i64(len(flag_false))
		}

		os.write_at(h, new_line[:], current_offset)
		current_offset += i64(len(new_line))
	}
	// Handle settings
	fields := reflect.struct_fields_zipped(type_of(conf.settings))

	for f, i in fields {
		field := f

		tag := string(f.tag)
		tag_b := transmute([]byte)tag

		os.write_at(h, tag_b[:], current_offset)
		current_offset += i64(len(tag_b))

		os.write_at(h, separator[:], current_offset)
		current_offset += i64(len(separator))

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

		os.write_at(h, new_line[:], current_offset)
		current_offset += i64(len(new_line))
	}

	when CONFIG_VERBOSE_LOG do log.debugf("Saving of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)
	success = true
	return
}

parse_engine_configuration_file :: proc(h: os.Handle) -> map[string]string {
	data, success := os.read_entire_file_from_handle(h)
	if !success do return nil
	defer delete(data)

	// 128 characters should be more than enough
	key_buff := make([dynamic]byte, 0, 128) 
	defer delete(key_buff)

	val_buff := make([dynamic]byte, 0, 128)
	defer delete(val_buff)

	values := make(map[string]string)
	
	reading_key := true
	for char in data {
		switch char {
		case ' ':
			continue
		case '\n':
			reading_key = true
			key := string(key_buff[:])
			val := string(val_buff[:])

			_, exists := values[key]
			if !exists do handle_values(key, val)

			clear(&key_buff)
			clear(&val_buff)
		case ':':
			reading_key = false
		case:
			if reading_key do append(&key_buff, char)
			else do append(&val_buff, char)
		}
	}

	key := string(key_buff[:])
	val := string(val_buff[:])
	_, exists := values[key]
	if key != "" && len(val_buff) != 0 && !exists do handle_values(key, val)

	return values
}

@(private="file")
handle_values :: proc(key: string, value: string) {
	switch key {
		case Vulkan_Option_Flags_Names[.Debug_Layers]:
			handle_option_value(value, .Debug_Layers)
		case:
			handle_settings_values(key, value)
	}
}

@(private="file")
handle_option_value :: proc(value: string, option: Option_Flag) {
	if value == OPTION_FLAG_TRUE_STRING do options_enable(option)
	else if value == OPTION_FLAG_FALSE_STRING do options_disable(option)
	else do log.errorf("Value for option '%v' is not valid (allowed values are '%V' & '%v'): %v", option, OPTION_FLAG_TRUE_STRING, OPTION_FLAG_FALSE_STRING, value)
}

@(private="file")
handle_settings_values :: proc(key, value: string) {
	settings := engine_configuration.settings

	fields := reflect.struct_fields_zipped(type_of(settings))

	for &f in fields {
		if key != string(f.tag) do continue

		struct_field := reflect.struct_field_value(engine_configuration.settings, f)

		switch &field in struct_field {
		case int:
			integer, ok := strconv.parse_int(value)
			if !ok {
				log.errorf("Failed to parse integer from string when handling settings values: value '%v' of key '%v' for struct tag '%v'", value, key, string(f.tag))
				break
			}

			field = integer
		case string:
			field = value
		case f32:
			floating, ok := strconv.parse_f32(value)
			if !ok {
				log.errorf("Failed to parse 32bit float from string when handling settings values: value '%v' of key '%v' for struct tag '%v'", value, key, string(f.tag))
				break
			}

			field = floating
		case:
			log.errorf("Unhandled settings value '%v' of key '%v' for struct tag '%v': unrecognized type", value, key, string(f.tag))
		}
	}
}

get_enum_based_on_string :: proc "contextless" (value: string, enumerated_array: [$T]string) -> T where intrinsics.type_is_enum(T) {
	for s, e in enumerated_array {
		if s == value do return e
	}
	return nil
}
