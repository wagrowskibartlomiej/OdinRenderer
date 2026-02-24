package engine

import "core:os"
import "core:log"
import "core:fmt"
import "core:slice"
import "core:reflect"

import "base:intrinsics"

@rodata
ENGINE_CONFIGURATION_FILE_NAME := "configuration.engine"

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
	1. Each line defines a one key value pair
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
	// Set default in case
	engine_configuration.settings.Frames_In_Flight = 2

	// Just to group all configuration in one place
	engine_configuration.configs.target = get_enum_based_on_string(CONFIG_BUILD_TARGET, Build_Targets)
	engine_configuration.configs.variant = get_enum_based_on_string(CONFIG_BUILD_VARIANT, Build_Variants)
	engine_configuration.configs.verbose_logging = CONFIG_VERBOSE_LOG
	engine_configuration.configs.tracking_allocator = CONFIG_TRACKING_ALLOCATOR

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
		when CONFIG_BUILD_VARIANT != Build_Variants[.Release] do fmt.printfln("Failed to open %v file to read options: %v", file, err)
		return
	}
	defer os.close(h)

	m := parse_engine_configuration_file(h)
	defer delete(m)

	for k, v in m do handle_values(k, v)


	when CONFIG_VERBOSE_LOG do log.debugf("Loading of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)

}

save_configuration :: proc() -> (success: bool) {
	h, err := os.open(ENGINE_CONFIGURATION_FILE_NAME, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, 0o755)
	if err != nil {
		log.errorf("Engine configuration save attempt failed: %v", err)
		return false
	}

	current_offset: i64
	conf := get_engine_configuration()
	separator := [?]byte{':', ' '}

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
			flag_false := transmute([]byte)OPTION_FLAG_TRUE_STRING
			os.write_at(h, flag_false[:], current_offset)
			current_offset += i64(len(flag_false))
		}
	}
	// Handle settings
	fields := reflect.struct_fields_zipped(type_of(conf.settings))

	for f in fields {
		tag := string(f.tag)
		tag_b := transmute([]byte)tag

		os.write_at(h, tag_b[:], current_offset)
		current_offset += i64(len(tag_b))

		os.write_at(h, separator[:], current_offset)
		current_offset += i64(len(separator))

		UNDEFINED_VALUE := [?]byte{'-', '-', '-'}

		val := transmute([]byte)reflect.struct_tag_get(f.tag, f.name)
		if len(val) == 0 do val = UNDEFINED_VALUE[:]

		os.write_at(h, val[:], current_offset)
		current_offset += i64(len(val))
	}

	when CONFIG_VERBOSE_LOG do log.debugf("Saving of file '%v' successful", ENGINE_CONFIGURATION_FILE_NAME)
	success = true
	return
}

parse_engine_configuration_file :: proc(h: os.Handle) -> map[string]any {
	data, success := os.read_entire_file_from_handle(h)
	if !success do return nil
	defer delete(data)

	// 128 characters should be more than enough
	key_buff := make([dynamic]byte, 0, 128) 
	defer delete(key_buff)

	val_buff := make([dynamic]byte, 0, 128)
	defer delete(val_buff)

	values := make(map[string]any)
	
	reading_key := true
	for char in data {
		switch char {
		case ' ':
			continue
		case '\n':
			reading_key = true
			key := string(key_buff[:])
			value := string(val_buff[:])

			_, exists := values[key]
			if !exists do handle_values(key, value)

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
	value := string(val_buff[:])
	_, exists := values[key]
	if key != "" && value != "" && !exists do handle_values(key, value)

	return values
}

@(private="file")
handle_values :: proc(key: string, value: any) {
	switch key {
		case Vulkan_Option_Flags_Names[.Debug_Layers]:
			handle_option_value(value, .Debug_Layers)
		case:
			handle_settings_values(key, value)
	}
}

@(private="file")
handle_option_value :: proc(value: any, option: Option_Flag) {
	v, ok := value.(string)
	if !ok do log.errorf("Unexpected error when handling option value '%v'", value)

	if v == OPTION_FLAG_TRUE_STRING do options_enable(option)
	else if v == OPTION_FLAG_FALSE_STRING do options_disable(option)
	else do log.errorf("Value for option '%v' is not valid: %v", option, v)
}

@(private="file")
handle_settings_values :: proc(key: string, value: any) {
	// TODO: Make use of reflect to maybe use struct tags as a way to parse everything
	when CONFIG_BUILD_VARIANT != Build_Variants[.Release] do fmt.eprintln("Settings are not supported yet")
}

get_enum_based_on_string :: proc "contextless" (value: string, enumerated_array: [$T]string) -> T where intrinsics.type_is_enum(T) {
	for s, e in enumerated_array {
		if s == value do return e
	}
	return nil
}
