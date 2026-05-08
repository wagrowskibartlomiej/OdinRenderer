#+feature using-stmt
package engine

import "base:runtime"

import "core:log"
import "core:slice"
import "core:dynlib"
import "core:strings"

import "vendor:glfw"
import vk "vendor:vulkan"

//TODO: Change debug layers to be feature option, detected at runtime

when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] {
	when ODIN_PLATFORM_SUBTARGET == .Android do VK_ANDROID_SURFACE_EXT_NAME :: "VK_KHR_android_surface"
	else do #panic("Platform subtraget '" + ODIN_PLATFORM_SUBTARGET + "' does not have Vulkan surface extension name supplied")
}

// Should not be used in 99% of times, but maybe sometimes it'll be needed to set custom ones
VULKAN_GLOBAL_ALLOCATION_CALLBACKS : ^vk.AllocationCallbacks = nil

VALIDATION_LAYERS_NAME :: "VK_LAYER_KHRONOS_validation"

Renderer_State :: struct {
	core: Core_Vk_State,
	dyn: Dynamic_Vk_State,
	memory: GPU_Memory_State,
	resources: GPU_Resources_State,
	current_frame_index: int,
}

Core_Vk_State :: struct {
	data: rawptr,
	vklib: dynlib.Library,
	resource_flags: Vulkan_Static_State_Resource_Flags,
	instance: Instance_State,
	debug: Debug_State,
	physical_devices: Physical_Devices_State,
	device: Device_State,
	surface: Surface_State,
	swapchain: Swapchain_State,
	render_passes: Render_Passes_State,
	pipelines: Pipelines_State,
	framebuffers: Framebuffers_State,
}

Instance_State :: struct {
	handle: vk.Instance,
	using _: Layers_Extensions_Properties,
}

Debug_State :: struct {
	messenger: vk.DebugUtilsMessengerEXT,
	callbacks_data: vk.AllocationCallbacks,
	callbacks: ^vk.AllocationCallbacks,
}

Physical_Devices_State :: struct {
	supported: [dynamic]Supported_Physical_Device,
	active: ^Supported_Physical_Device,
}

Supported_Physical_Device :: struct {
	using _: Physical_Device,
	score: int,
	features: vk.PhysicalDeviceFeatures,
	properties: vk.PhysicalDeviceProperties,
	memory_properties: vk.PhysicalDeviceMemoryProperties,
	formats: []vk.SurfaceFormatKHR,
	queues_properties: []vk.QueueFamilyProperties,
	queue_indexes: Queue_Indexes,
	capabilites: vk.SurfaceCapabilitiesKHR,
	present_modes: []vk.PresentModeKHR,
	using _: Layers_Extensions_Properties,
}

Device_State :: struct {
	handle: vk.Device,
	graphics, transfer, compute: vk.Queue,
}

Physical_Device :: struct {
	handle: vk.PhysicalDevice,
	name: cstring,
}

Layers_Extensions_Properties :: struct {
	available_extensions: []vk.ExtensionProperties,
	available_layers: []vk.LayerProperties,
	enabled_extensions_names: [dynamic]cstring,
	enabled_layers_names: [dynamic]cstring,
}

//NOTE: Usually it'll be one queue for all, so it's not needed to implement usage of async ones for current state
Queue_Indexes :: struct {
	graphics, transfer, compute: int
}

// Flags that are used to check which initalization resource were created, so when it's cleanup time,
// or when resources need to be recreated it can be check using these flags
Vulkan_Static_State_Resource_Flag :: enum {
	Library,
	Instance,
	Debug,
	Physical_Device,
	Device,
	Surface,
	Swapchain,
	Render_Passes,
	Pipelines,
	Framebuffers,
}
Vulkan_Static_State_Resource_Flags :: bit_set[Vulkan_Static_State_Resource_Flag]

initialize_vulkan :: proc(renderer: ^Renderer_State, engine_state: ^Engine_Global_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	load_vklib(renderer)

	success := create_instance(&renderer.core, allocator, temp_allocator, callbacks)
	if !success {
		log.fatal("Cannot create Vulkan instance")
		return
	}

	if options_get_unsafe(.Debug_Layers) {
		success = create_debug_utils(&renderer.core, &engine_state.app_context, callbacks)
		if !success {
			log.fatal("Cannot create debug utils messenger")
			return
		}
	}

	success = create_surface(&renderer.core, &engine_state.window, allocator, callbacks)
	if !success {
		log.fatal("Failed to create surface")
		return
	}

	success = pick_physical_device(&renderer.core, allocator, temp_allocator)
	if !success {
		log.fatal("Failed to pick physical device ")
		return
	}

	success = create_device(&renderer.core, allocator, callbacks)
	if !success {
		log.fatal("Failed to create device")
		return
	}

	NO_OLD_SWAPCHAIN: vk.SwapchainKHR : {}

	success = create_swapchain(&renderer.core, engine_state.window.handle, NO_OLD_SWAPCHAIN, allocator, callbacks)
	if !success {
		log.fatal("Failed to create swapchain")
		return
	}

	success = create_render_passes(&renderer.core, callbacks)
	if !success {
		log.fatal("Failed to create render passes")
		return
	}

	success = create_graphics_pipelines(&renderer.core, &engine_state.assets, allocator, temp_allocator, callbacks)
	if !success {
		log.fatal("Failed to create graphics pipelines")
		return
	}

	success = build_framebuffers(&renderer.core, allocator, callbacks)
	if !success {
		log.fatal("Failed to build framebuffers")
		return
	}

	when CONFIG_VERBOSE_LOG do log.debug("Vulkan's initialization successful")
	return
}

cleanup_vulkan :: proc(renderer: ^Renderer_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	// Flags checks are here to not print warning when exiting early,
	// it probably won't be a bottleneck anyway
	if .Framebuffers in renderer.core.resource_flags do cleanup_framebuffers(&renderer.core)
	if .Pipelines in renderer.core.resource_flags do cleanup_graphics_pipelines(&renderer.core, allocator, callbacks)
	if .Render_Passes in renderer.core.resource_flags do cleanup_renderer_passes(&renderer.core, callbacks)
	if .Swapchain in renderer.core.resource_flags do cleanup_swapchain(&renderer.core, allocator, callbacks)
	if .Surface in renderer.core.resource_flags do cleanup_surface(&renderer.core, callbacks)
	if .Device in renderer.core.resource_flags do cleanup_device(&renderer.core, callbacks)
	if .Physical_Device in renderer.core.resource_flags do cleanup_physical_devices(&renderer.core, allocator)
	if options_get_unsafe(.Debug_Layers) && .Debug in renderer.core.resource_flags do cleanup_debug_utils(&renderer.core, callbacks)
	if .Instance in renderer.core.resource_flags do cleanup_instance(&renderer.core, allocator, callbacks)
	if .Library in renderer.core.resource_flags do unload_vklib(renderer)
}

load_vklib :: proc(state: ^Renderer_State) {
	if .Library in state.core.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Library)

	when ODIN_OS == .Linux do vk_lib_name :: "libvulkan.so"
	else when ODIN_OS == .Windows do vk_lib_name :: "vulkan-1.dll"
	else do #panic("Vulkan lib name file not specified for " + ODIN_OS + " OS")

	loaded: bool
	state.core.vklib, loaded = dynlib.load_library(vk_lib_name)
	if !loaded do log.panic("Cannot load Vulkan dynamic library")
	when CONFIG_VERBOSE_LOG do log.debug("Vulkan dynamic library loaded")

	set_resource_flag(&state.core.resource_flags, Vulkan_Static_State_Resource_Flag.Library)

	vk_get_instance_proc_addr_name, found := dynlib.symbol_address(state.core.vklib, "vkGetInstanceProcAddr")
	if !found do log.panic("Cannot found addres of 'vkGetInstanceProcAddr'")
	when CONFIG_VERBOSE_LOG do log.debug("Address of 'vkGetInstanceProcAddr' found")

	vk.load_proc_addresses_global(vk_get_instance_proc_addr_name)
	when CONFIG_VERBOSE_LOG do log.debug("Global procedure addresses loaded")
}

unload_vklib :: proc(state: ^Renderer_State) {
	if .Library not_in state.core.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Library)
		return
	}
	unloaded := dynlib.unload_library(state.core.vklib)
	if !unloaded do log.errorf("Failed to unload Vulkan library: %v", dynlib.last_error())
	when CONFIG_VERBOSE_LOG do log.debug("Unloaded Vulkan library")

	unset_resource_flag(&state.core.resource_flags, Vulkan_Static_State_Resource_Flag.Library)
}

create_instance :: proc(state: ^Core_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Instance in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Instance)
	// Check for 1.0 implementation
	_, found := dynlib.symbol_address(state.vklib, "vkEnumerateInstanceVersion")
	if !found do log.info("Vulkan instance version: 1.0.0")
	else {
		ver: u32
		vk.EnumerateInstanceVersion(&ver)
		decoded := decode_vk_version(ver)
		log.infof("Vulkan instance version: %v.%v.%v", decoded.x, decoded.y, decoded.z)
	}

	enumerated: bool

	state.instance.available_layers, enumerated = query_instance_layers(allocator)
	if !enumerated do return
	defer if !success do delete(state.instance.available_layers, allocator)

	for &l, i in state.instance.available_layers {
		if i == 0 do log.info("Available instance layers:")
		log.infof("%v. %v", i+1, cstring(raw_data(&l.layerName)))
	}

	requested_layers := get_requested_instance_layers(allocator)
	defer delete(requested_layers)

	for l, i in requested_layers{
		if i == 0 do log.info("Requested instance layers:")
		log.infof("%v. %v", i+1, l)
	}


	state.instance.available_extensions, enumerated = query_instance_extensions(allocator = allocator)
	if !enumerated do return
	defer if !success do delete(state.instance.available_extensions, allocator)

	for &e, i in state.instance.available_extensions {
		if i == 0 do log.info("Available instance extensions:")
		log.infof("%v. %v", i+1, cstring(raw_data(&e.extensionName)))
	}

	requested_extensions := get_requested_instance_extensions(allocator)
	defer delete(requested_extensions)

	for e, i in requested_extensions {
		if i == 0 do log.info("Requested instance extensions:")
		log.infof("%v. %v", i+1, e)
	}

	missing_layers: [dynamic]cstring
	defer delete(missing_layers)

	state.instance.enabled_layers_names, missing_layers = check_layers(requested_layers[:], state.instance.available_layers, allocator)
	defer if !success do delete(state.instance.enabled_layers_names)

	missing_extensions: [dynamic]cstring
	defer delete(missing_extensions)


	state.instance.enabled_extensions_names, missing_extensions = check_extensions(requested_extensions[:], state.instance.available_extensions, allocator)

	defer if !success do delete(state.instance.enabled_extensions_names)

	for l, i in missing_layers {
		if i == 0 do log.error("Requested instance layers missing:")
		log.errorf("%v. %v", i, l)
	}

	for e, i in missing_extensions {
		if i == 0 do log.error("Requested instance extensions missing:")
		log.errorf("%v. %v", i, e)
	}

	if len(missing_layers) > 0 || len(missing_extensions) > 0 do return

	application_info := vk.ApplicationInfo{
		sType = .APPLICATION_INFO,
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_0,
		pApplicationName = APPLICATION_NAME,
		pEngineName = ENGINE_NAME,
	}

	create_info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &application_info,
		enabledExtensionCount = u32(len(state.instance.enabled_extensions_names)),
		ppEnabledExtensionNames = raw_data(state.instance.enabled_extensions_names),
		enabledLayerCount = u32(len(state.instance.enabled_layers_names)),
		ppEnabledLayerNames = raw_data(state.instance.enabled_layers_names),
	}

	result := vk.CreateInstance(&create_info, callbacks, &state.instance.handle)
	if result != .SUCCESS {
		log.errorf("Instance creation error: %v", result)
		return
	}

	when CONFIG_VERBOSE_LOG do log.debug("Instance created")
	vk.load_proc_addresses_instance(state.instance.handle)
	when CONFIG_VERBOSE_LOG do log.debug("Instance procedure addresses loaded")

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Instance)

	success = true
	return
}

cleanup_instance :: proc(state: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Instance not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Instance)
		return
	}
	vk.DestroyInstance(state.instance.handle, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Instance destroyed")

	delete(state.instance.enabled_extensions_names)
	delete(state.instance.enabled_layers_names)

	delete(state.instance.available_extensions, allocator)
	delete(state.instance.available_layers, allocator)
	when CONFIG_VERBOSE_LOG do log.debug("Instance resources released")

	unset_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Instance)
}


// If no flags are passed, the ones from logger that is set in context are used to determine closest options possible
// If no callback and user data pointer is passed, the default ones from engine are used
create_debug_utils :: proc(state: ^Core_Vk_State, context_state: ^Context_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS, severity: vk.DebugUtilsMessageSeverityFlagsEXT = {}, callback := debug_utils_default_engine_callback) -> (success: bool) {
	assert(state != nil && context_state != nil, "State and context state pointers must not be nil")
	severity := severity // compiler hint

	if .Debug in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Debug)
	message_types := vk.DebugUtilsMessageTypeFlagsEXT{.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING} // if we are enabling debug layers I don't see a point to not want all messages
	// get severity if it is not given as parameter
	if severity == {} {
		lvl := context.logger.lowest_level

		switch lvl {
		case .Debug:
			severity |= {.VERBOSE}
			fallthrough
		case .Info:
			severity |= {.INFO}
			fallthrough
		case .Warning:
			severity |= {.WARNING}
			fallthrough
		case .Error:
			severity |= {.ERROR}
			fallthrough
		case .Fatal:
		case:
			log.warnf("Error may occured when level detection for Vulkan's debug utils messenger was set")
		}
	}

	// We need context state
	if context_state == nil do return false

	create_info := vk.DebugUtilsMessengerCreateInfoEXT{
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = severity,
		messageType = message_types,
		pfnUserCallback = callback,
		pUserData = context_state,
	}

	result := vk.CreateDebugUtilsMessengerEXT(state.instance.handle, &create_info, callbacks, &state.debug.messenger)
	if result != .SUCCESS {
		log.fatalf("Creation of debug utils messenger failed: %v")
		return
	}
	when CONFIG_VERBOSE_LOG do log.debug("Debug utils messenger created successfuly")

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Debug)

	success = true
	return
}

cleanup_debug_utils :: proc(state: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Debug not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Debug)
		return
	}

	vk.DestroyDebugUtilsMessengerEXT(state.instance.handle, state.debug.messenger, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Debug utils messenger destroyed")

	unset_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Debug)
}

debug_utils_default_engine_callback : vk.ProcDebugUtilsMessengerCallbackEXT : proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, message_types: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32 {
	ptr := cast(^Context_State)user_data
	context = ptr.ctx

	IDENT :: "VULKAN VALIDATION LAYERS"
	old_ident: string

	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do old_ident = (cast(^log.File_Console_Logger_Data)ptr.ctx.logger.data).ident
	else do old_ident = string((cast(^Android_Logger_Data)ptr.ctx.logger.data).ident)

	change_logger_ident(IDENT, ptr)
	defer change_logger_ident(old_ident, ptr)


	if .ERROR in severity do log.errorf("%v", callback_data.pMessage)
	else if .WARNING in severity do log.warnf("%v", callback_data.pMessage)
	else if .INFO in severity do log.infof("%v", callback_data.pMessage)
	else do log.debugf("%v", callback_data.pMessage)

	// "application should always return VK_FALSE"
	return false
}

get_requested_instance_extensions :: proc(allocator := context.allocator) -> [dynamic]cstring {
	extensions := make([dynamic]cstring, allocator)

	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] {
		ext := glfw.GetRequiredInstanceExtensions()
		for e in ext do append(&extensions, e)
		if options_get_unsafe(.Debug_Layers) do append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	} when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] {
		when ODIN_PLATFORM_SUBTARGET == .Android {
			append(&extensions, vk.KHR_SURFACE_EXTENSION_NAME)
			append(&extensions, VK_ANDROID_SURFACE_EXT_NAME)
		} else do #panic("Platform subtraget '" + ODIN_PLATFORM_SUBTARGET + "' does not have implemented querying of instance extensions")
	}

	return extensions
}

get_requested_instance_layers :: proc(allocator := context.allocator) -> [dynamic]cstring {
	layers := make([dynamic]cstring, allocator)

	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] {
		if options_get_unsafe(.Debug_Layers) do append(&layers, VALIDATION_LAYERS_NAME)
	}

	return layers
}

query_instance_extensions :: proc(layer_name: cstring = nil, allocator := context.allocator) -> (ext: []vk.ExtensionProperties, success: bool) {
	count: u32
	result := vk.EnumerateInstanceExtensionProperties(layer_name, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Instance extensions enumeration succeded")
	case .INCOMPLETE:
		log.warn("(1) Instance extensions enumeration was incomplete")
	case:
		log.errorf("(1) Error occured when enumerating instance extensions: %v", result)
		return
	}

	log.assert(count > 0, "(1) Queried instance extensions count is zero")

	ext = make([]vk.ExtensionProperties, count, allocator)
	defer if !success do delete(ext, allocator)

	result = vk.EnumerateInstanceExtensionProperties(layer_name, &count, raw_data(ext))
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Instance extensions enumeration succeded")
	case .INCOMPLETE:
		log.warn("(2) Instance extensions enumeration was incomplete")
	case:
		log.errorf("(2) Error occured when enumerating instance extensions: %v", result)
		return
	}

	log.assert(count > 0, "(2) Queried instance extensions count is zero")

	success = true
	return
}

query_instance_layers :: proc(allocator := context.allocator) -> (lay: []vk.LayerProperties, success: bool) {
	count: u32
	result := vk.EnumerateInstanceLayerProperties(&count, nil)
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Instance layers enumeration succeded")
	case .INCOMPLETE:
		log.warn("(1) Instance layers enumeration was incomplete")
	case:
		log.errorf("(1) Error occured when enumerating instance layers: %v", result)
		return
	}

	if count == 0 do log.warn("(1) Unexpected behaviour: queried count of instance layers is zero")

	lay = make([]vk.LayerProperties, count, allocator)
	defer if !success do delete(lay, allocator)

	result = vk.EnumerateInstanceLayerProperties(&count, raw_data(lay))
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Instance layers enumeration succeded")
	case .INCOMPLETE:
		log.warn("(2) Instance layers enumeration was incomplete")
	case:
		log.errorf("(2) Error occured when enumerating instance layers: %v", result)
		return
	}

	if count == 0 do log.warn("(2) Unexpected behaviour: queried count of instance layers is zero")

	success = true
	return
}

//NOTE: Device layers are deprecated, but in theory for compatibility reasons it should be used
query_device_layers :: proc(device: vk.PhysicalDevice, allocator := context.allocator) -> (lay: []vk.LayerProperties, success: bool) {
	count: u32
	result := vk.EnumerateDeviceLayerProperties(device, &count, nil)

	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Device layers enumeration succeded")
	case .INCOMPLETE:
		log.warn("(1) Device layers enumeration was incomplete")
	case:
		log.errorf("(1) Error occured when enumerating device layers: %v", result)
		return
	}

	if count == 0 do log.warn("(1) Unexpected behaviour: queried count of device layers is zero")

	lay = make([]vk.LayerProperties, count, allocator)
	defer if !success do delete(lay, allocator)

	result = vk.EnumerateDeviceLayerProperties(device, &count, raw_data(lay))
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Device layers enumeration succeded")
	case .INCOMPLETE:
		log.warn("(2) Device layers enumeration was incomplete")
	case:
		log.errorf("(2) Error occured when enumerating device layers: %v", result)
		return
	}

	if count == 0 do log.warn("(2) Unexpected behaviour: queried count of device layers is zero")

	success = true
	return
}

query_device_extensions :: proc(device: vk.PhysicalDevice, layer_name: cstring = nil, allocator := context.allocator) -> (ext: []vk.ExtensionProperties, success: bool) {
	count: u32
	result := vk.EnumerateDeviceExtensionProperties(device, layer_name, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Device extensions enumeration succeded")
	case .INCOMPLETE:
		log.warn("(1) Device extensions enumeration was incomplete")
	case:
		log.errorf("(1) Error occured when enumerating device extensions: %v", result)
		return
	}

	if count == 0 do log.warn("(1) Unexpected behaviour: queried count of device extensions is zero")

	ext = make([]vk.ExtensionProperties, count, allocator)
	defer if !success do delete(ext, allocator)

	result = vk.EnumerateDeviceExtensionProperties(device, layer_name, &count, raw_data(ext))
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Device extensions enumeration succeded")
	case .INCOMPLETE:
		log.warn("(2) Device extensions enumeration was incomplete")
	case:
		log.errorf("(2) Error occured when enumerating device extensions: %v", result)
		return
	}

	if count == 0 do log.warn("(2) Unexpected behaviour: queried count of device extensions is zero")

	success = true
	return
}

check_extensions :: proc(requested_ext_names: []cstring, extensions: []vk.ExtensionProperties, allocator := context.allocator) -> (extensions_names: [dynamic]cstring, missing_ext_names: [dynamic]cstring) {
	if len(requested_ext_names) <= 0 do log.warn("Unexpected behaviour: no requested extensions given, this may not be an error, but probably is")

	extensions_names = make([dynamic]cstring, 0, len(requested_ext_names), allocator)
	missing_ext_names = make([dynamic]cstring, 0, len(requested_ext_names), allocator)

	outer_loop:
	for req_ext in requested_ext_names {
		for &ext in extensions {
			ext_name := cstring(raw_data(&ext.extensionName))

			if ext_name == req_ext {
				append(&extensions_names, ext_name)
				continue outer_loop
			}
		}
		append(&missing_ext_names, req_ext)
	}

	return
}

check_layers :: proc(requested_lay_names: []cstring, layers: []vk.LayerProperties, allocator := context.allocator) -> (layers_names:[dynamic]cstring, missing_lay_names: [dynamic]cstring) {
	layers_names = make([dynamic]cstring, 0, len(requested_lay_names), allocator)
	missing_lay_names = make([dynamic]cstring, 0, len(requested_lay_names), allocator)

	outer_loop:
	for req_lay in requested_lay_names {
		for &lay in layers {
			lay_name := cstring(raw_data(&lay.layerName))

			if lay_name == req_lay {
				append(&layers_names, lay_name)
				continue outer_loop
			}
		}
		append(&missing_lay_names, req_lay)
	}

	return
}

/************************************************************************
Implementing the functionality to change physical device could be useful,
but since the priority is to develop renderer on Android,
I do not see it that important as when targeting PCs
************************************************************************/

pick_physical_device :: proc(state: ^Core_Vk_State, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (success: bool) {
	if .Physical_Device in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Physical_Device)
	count: u32

	result := vk.EnumeratePhysicalDevices(state.instance.handle, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(1) Physical devices enumerated")
	case .INCOMPLETE:
		log.warn("(1) Not all physical devices were enumerated")
	case:
		log.errorf("(1) Error occured when enumerating physical devices: %v", result)
		return
	}

	log.assert(count > 0, "(1) Queried physical device count is zero")

	devices := make([]vk.PhysicalDevice, count, temp_allocator)
	defer delete(devices, temp_allocator)

	result = vk.EnumeratePhysicalDevices(state.instance.handle, &count, raw_data(devices))
	#partial switch result {
	case .SUCCESS:
		when CONFIG_VERBOSE_LOG do log.debug("(2) Physical devices enumerated")
	case .INCOMPLETE:
		log.warn("(2) Not all physical devices were enumerated")
	case:
		log.errorf("(2) Error occured when enumerating physical devices: %v", result)
		return
	}

	unsupported := evaluate_physical_devices(devices, state.surface.handle, &state.physical_devices, allocator, temp_allocator)
	defer delete(unsupported)

	for dev, i in unsupported {
		if i == 0 do log.info("Unsupported device(s):")
		log.infof("%v. %v", i+1, dev.name)
	}

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Physical_Device)

	success = true
	return
}

cleanup_physical_devices :: proc(state: ^Core_Vk_State, allocator := context.allocator) {
	if .Physical_Device not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Physical_Device)
		return
	}

	for d in state.physical_devices.supported {
		delete (d.queues_properties, allocator)
		delete (d.available_extensions, allocator)
		delete (d.available_layers, allocator)
		delete (d.present_modes, allocator)
		delete (d.formats, allocator)
		delete (d.enabled_extensions_names)
		delete (d.enabled_layers_names)
	}
	delete (state.physical_devices.supported)

	state.physical_devices.active = nil

	unset_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Physical_Device)
}

//WARN: Procedure allocates string names with given allocator, names then need to be freed accordingly
evaluate_physical_devices :: proc(devices: []vk.PhysicalDevice, surface: vk.SurfaceKHR, devices_state: ^Physical_Devices_State, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (unsupported: [dynamic]Physical_Device) {
	log.assert(len(devices)>0, "Length of devices is zero")

	unsupported = make([dynamic]Physical_Device, allocator)
	devices_state.supported = make([dynamic]Supported_Physical_Device, allocator)

	// Check devices properties, append to supproted list if it's suitable for use and meets the requirements,
	// if not, add to unsupported list and delete all details that will not be in use
	for &d, i in devices {
		log.assert(d != nil, "Physical device handle is nil, when expected to be a valid VkPhysicalDevice")

		success: bool
		supported_state: Supported_Physical_Device

		// Get the minimal properties to make sure the device meets the requirements
		using supported_state
		handle = d

		// Get name for every device, to make it identifiable
		vk.GetPhysicalDeviceProperties(handle, &properties)
		name = strings.unsafe_string_to_cstring(string(properties.deviceName[:]))
		defer if !success do append(&unsupported, Physical_Device{handle, strings.clone_to_cstring(string(name), allocator)})

		available_extensions, success = query_device_extensions(handle, nil, allocator)
		if !success {
			log.warnf("[%v] Cannot determine available device extensions", name)
			continue
		}
		defer if !success do delete(available_extensions, allocator)

		available_layers, success = query_device_layers(handle, allocator)
		if !success {
			log.warnf("[%v] Cannot determine available device layers", name)
			continue
		}
		defer if !success do delete(available_layers, allocator)

		counter: u32

		vk.GetPhysicalDeviceQueueFamilyProperties(handle, &counter, nil)

		queues_properties = make([]vk.QueueFamilyProperties, counter, allocator)
		defer if !success do delete(queues_properties, allocator)

		vk.GetPhysicalDeviceQueueFamilyProperties(handle, &counter, raw_data(queues_properties))


		// It device does not meet requirements add it to unsupported list, then continue to evaluate rest
		success = physical_device_evaluation(&supported_state, surface, allocator)
		if !success do continue

		// Get the rest of the properties NOTE: SET DEVICE AS NOT SUPPORTED WHEN ERROR OCCURS
		vk.GetPhysicalDeviceFeatures(handle, &features)
		vk.GetPhysicalDeviceMemoryProperties(handle, &memory_properties)
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(handle, surface, &capabilites)


		// Surface formats
		result := vk.GetPhysicalDeviceSurfaceFormatsKHR(handle, surface, &counter, nil)
		#partial switch result {
		case .SUCCESS:
			when CONFIG_VERBOSE_LOG do log.debugf("(1)[%v] Querying of surface formats succeeded", name)
		case .INCOMPLETE:
			log.warnf("(1)[%v] Not all surface formats were queried, some functionality may not work")
		case:
			log.errorf("(1)[%v] Surface format query failed (device counts as not supported): %v", name, result)
			success = false
			continue
		}

		formats = make([]vk.SurfaceFormatKHR, counter, allocator)
		defer if !success do delete(formats, allocator)

		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(handle, surface, &counter, raw_data(formats))
		#partial switch result {
		case .SUCCESS:
			when CONFIG_VERBOSE_LOG do log.debugf("(2)[%v] Querying of surface formats succeeded", name)
		case .INCOMPLETE:
			log.warnf("(2)[%v] Not all surface formats were queried, some functionality may not work", name)
		case:
			log.errorf("(2)[%v] Surface format query failed (device counts as not supported): %v", name, result)
			success = false
			continue
		}

		// Presentation modes
		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(handle, surface, &counter, nil)
		#partial switch result {
		case .SUCCESS:
			when CONFIG_VERBOSE_LOG do log.debugf("(1)[%v] Querying of surface presentation modes succeeded", name)
		case .INCOMPLETE:
			log.warnf("(1)[%v] Not all surface presentation modes were queried, some functionality may not work")
		case:
			log.errorf("(1)[%v] Surface presentation modes query failed (device counts as not supported): %v", name, result)
			success = false
			continue
		}

		present_modes = make([]vk.PresentModeKHR, counter, allocator)
		defer if !success do delete(present_modes, allocator)

		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(handle, surface, &counter, raw_data(present_modes))
		#partial switch result {
		case .SUCCESS:
			when CONFIG_VERBOSE_LOG do log.debugf("(2)[%v] Querying of surface presentation modes succeeded", name)
		case .INCOMPLETE:
			log.warnf("(2)[%v] Not all surface presentation modes were queried, some functionality may not work")
		case:
			log.errorf("(2)[%v] Surface presentation modes query failed (device counts as not supported): %v", name, result)
			success = false
			continue
		}

		score = physical_device_score_rating(&supported_state)

		append(&devices_state.supported, supported_state)
		success = true // set true to not delete the recources with defered statements
	}

	log.ensuref(len(devices_state.supported) >= 1, "No supported physical devices detected, cannot continue")

	slice.sort_by_cmp(devices_state.supported[:], sort_by_score)

	// Get the one active with the best score
	devices_state.active = &devices_state.supported[0]
	log.infof("Picked device: %v (score: %v)", devices_state.active.name, devices_state.active.score)

	return
}

get_requested_device_extensions :: proc(allocator := context.allocator) -> [dynamic]cstring {
	extensions := make([dynamic]cstring, allocator)

	append(&extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)

	return extensions
}

get_requested_device_layers :: proc(allocator := context.allocator) -> [dynamic]cstring {
	return nil
}

// WARN: Allocates the extensions and layers names, in passed state struct, using given allocator ONLY IF the device is supported
physical_device_evaluation :: proc(device: ^Supported_Physical_Device, surface: vk.SurfaceKHR, allocator := context.allocator) -> (supported: bool) {
	supported = true // set initally to true, so check can be made at the end to log everything that is incorrect
	device.queue_indexes = physical_device_evaluate_queues(device.queues_properties, surface, device.handle)
	if device.queue_indexes.graphics == -1 {
		log.warnf("[%v] No available graphics queue with presentation support", device.name)
		supported = false
	}

	requested_extensions := get_requested_device_extensions(allocator)
	defer delete(requested_extensions)

	missing_ext_names: [dynamic]cstring
	device.enabled_extensions_names, missing_ext_names = check_extensions(requested_extensions[:], device.available_extensions, allocator)
	defer if !supported do delete(device.enabled_extensions_names)
	defer delete(missing_ext_names)
	if len(missing_ext_names) > 0 {
		for ext, i in missing_ext_names {
			if i == 0 do log.warn("[%v] Missing requested extension(s):", len(missing_ext_names), device.name)
			log.warnf("\t%v. %v", i+1, ext)
		}
		supported = false
	}

	requested_layers := get_requested_device_layers(allocator)
	defer delete(requested_layers)

	missing_lay_names: [dynamic]cstring
	device.enabled_layers_names, missing_lay_names = check_layers(requested_layers[:], device.available_layers, allocator)
	defer if !supported do delete(device.enabled_layers_names)
	defer delete(missing_lay_names)
	if len(missing_lay_names) > 0 {
		for lay, i in missing_lay_names {
			if i == 0 do log.warn("[%v] Missing requested layer(s):", device.name)
			log.warnf("\t%v. %v", i+1, lay)
		}
		supported = false
	}

	return
}

physical_device_score_rating :: proc(device: ^Supported_Physical_Device) -> (score: int) {
	// Better score for async queues
	if device.queue_indexes.transfer != device.queue_indexes.graphics do score += 1000
	if device.queue_indexes.compute != device.queue_indexes.graphics do score += 500

	if device.properties.deviceType == .DISCRETE_GPU do score += 10000
	score += int(device.properties.limits.maxImageDimension2D)

	return
}

sort_by_score :: proc(i, j: Supported_Physical_Device) -> slice.Ordering {
	if i.score > j.score do return .Greater
	else if i.score < j.score do return .Less
	else do return .Equal
}

// TODO:
// There can be situation that presentation queue will be separate from graphics queue,
// (sometimes for small performance increase?) so that case needs to be handled,
// but it's really rare from what I understand, so it's low priority change
physical_device_evaluate_queues :: proc(queue_properties: []vk.QueueFamilyProperties, surface: vk.SurfaceKHR, device: vk.PhysicalDevice) -> (indexes: Queue_Indexes) {
	indexes.compute = -1
	indexes.graphics = -1
	indexes.transfer = -1

	dedicated_compute_index := -1
	dedicated_transfer_index := -1
	async_index := -1

	presentation_supported: b32

	// find dedicated and async queues first
	for q, i in queue_properties {
		flags := q.queueFlags

		if .GRAPHICS in flags && indexes.graphics == -1 {
			result := vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, &presentation_supported)
			if result != .SUCCESS do log.warnf("Physical device surface support error: %v", result)
			if presentation_supported do indexes.graphics = i
		}

		if .COMPUTE in flags && .GRAPHICS not_in flags && dedicated_compute_index == -1 do dedicated_compute_index = i

		if .TRANSFER in flags && .GRAPHICS not_in flags && dedicated_transfer_index == -1 do dedicated_transfer_index = i

		if (.COMPUTE in flags || .TRANSFER in flags) && .GRAPHICS not_in flags && async_index == -1 do async_index = i
	}

	// assign dedicated queues
	indexes.compute = dedicated_compute_index
	indexes.transfer = dedicated_transfer_index

	// use async queue if no dedicated compute/transfer
	if indexes.compute == -1 do indexes.compute = async_index
	if indexes.transfer == -1 do indexes.transfer = async_index

	// fallback
	if indexes.compute == -1 do indexes.compute = indexes.graphics
	if indexes.transfer == -1 do indexes.transfer = indexes.graphics

	return
}

create_device :: proc(state: ^Core_Vk_State, allocator := context.allocator, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) -> (success: bool) {
	if .Device in state.resource_flags do log_called_when_resource_set(#procedure, Vulkan_Static_State_Resource_Flag.Device)
	queue_priority_max: f32 = 1

	// using to make indexes easier to access
	using state.physical_devices.active.queue_indexes
	log.assert(graphics != -1, "Graphics queue inavlid index: missing, not detected or error")
	log.assert(transfer != -1,  "Transfer queue inavlid index: missing, not detected or error")
	log.assert(compute != -1,  "Compute queue inavlid index: missing, not detected or error")

	// Make static array and use separate counter like "length" and actual length as "capacity",
	// Could've used core:containter/small_array but I don't think it's neccessary
	// Order should always be: graphics, transfer, compute
	// If any of them are the same queue it should be ordered with this order in mind, so for example:
	// Dedicated transfer: 1. Graphics|Compute, 2. Transfer
	// Dedicated compute: 1. Graphics|Transfer, 2. Compute
	// Async transfer/compute: 1. Graphics, 2.Transfer|Compute
	// All dedicated: 1. Graphics, 2.Transfer, 3. Compute
	// Single queue: 1. Graphics|Transfer|Compute
	infos: [3]vk.DeviceQueueCreateInfo
	infos_count: u32 = 0

	graphics_create_info := vk.DeviceQueueCreateInfo{
		sType = .DEVICE_QUEUE_CREATE_INFO,
		pQueuePriorities = &queue_priority_max,
		queueCount = 1,
		queueFamilyIndex = u32(graphics)
	}

	transfer_create_info := vk.DeviceQueueCreateInfo{
		sType = .DEVICE_QUEUE_CREATE_INFO,
		pQueuePriorities = &queue_priority_max,
		queueCount = 1,
		queueFamilyIndex = u32(transfer)
	}

	compute_create_info := vk.DeviceQueueCreateInfo{
		sType = .DEVICE_QUEUE_CREATE_INFO,
		pQueuePriorities = &queue_priority_max,
		queueCount = 1,
		queueFamilyIndex = u32(compute)
	}

	// Graphics queue will always be present,
	// either with separate trasnfer and/or compute queues, or with all functionality as one queue
	infos[0] = graphics_create_info
	infos_count += 1

	if transfer != graphics { // Dedicated transfer or sperate transfer|compute queue
		infos[1] = transfer_create_info
		infos_count += 1

		if transfer != compute && compute != graphics { // Dedicated compute queue
			infos[2] = compute_create_info
			infos_count += 1
		}
	} else { // Graphics|transfer queue
		if transfer != compute { // Dedicated compute queue
			infos[1] = compute_create_info
			infos_count += 1
		}
	}


	create_info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO,
		pEnabledFeatures = nil, // Nothing I need now
		queueCreateInfoCount = infos_count,
		pQueueCreateInfos = raw_data(&infos),
		enabledExtensionCount = u32(len(state.physical_devices.active.enabled_extensions_names)),
		ppEnabledExtensionNames= raw_data(state.physical_devices.active.enabled_extensions_names),
		enabledLayerCount = u32(len(state.physical_devices.active.enabled_layers_names)),
		ppEnabledLayerNames= raw_data(state.physical_devices.active.enabled_layers_names),
	}

	result := vk.CreateDevice(state.physical_devices.active.handle, &create_info, callbacks, &state.device.handle)
	if result != .SUCCESS {
		log.errorf("Device creation error: %v", result)
		return
	}

	when CONFIG_VERBOSE_LOG do for q, i in state.physical_devices.active.queues_properties {
		if i == 0 do log.info("Available queue families:")
		log.infof("%v. Usage: %v, queue count: %v", i+1, q.queueFlags, q.queueCount)
	}

	// Get graphics queue
	vk.GetDeviceQueue(state.device.handle, u32(graphics), 0, &state.device.graphics)

	// Get other queues if they're present
	if transfer != graphics {
		// T|C & G or G & T & C or G|C & T
		vk.GetDeviceQueue(state.device.handle, u32(transfer), 0, &state.device.transfer)
		if transfer != compute && compute != graphics {
			vk.GetDeviceQueue(state.device.handle, u32(compute), 0, &state.device.compute) // G & T & C
			when CONFIG_VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated transfer and compute queue")
		}
		else if transfer == compute {
			state.device.compute = state.device.transfer // T|C & G
			when CONFIG_VERBOSE_LOG do log.debug("Queue combination detecetd: async transfer|compute queue")
		}
		else {
			state.device.compute = state.device.graphics // G|C & T
			when CONFIG_VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated transfer queue")
		}
	} else {
		// G|T & C or G|T|C
		state.device.transfer = state.device.graphics
		if transfer != compute {
			vk.GetDeviceQueue(state.device.handle, u32(compute), 0, &state.device.compute) // G|T & C
			when CONFIG_VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated compute queue")
		}
		else {
			state.device.compute = state.device.graphics // G|T|C
			when CONFIG_VERBOSE_LOG do log.debug("Queue combination detecetd: no dedicated or async queues")
		}
	}
	when CONFIG_VERBOSE_LOG do log.debugf("Chosen queue indexes: (G) %v, (T) %v, (C) %v", graphics, transfer, compute)

	set_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Device)

	success = true
	return
}

cleanup_device :: proc(state: ^Core_Vk_State, callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS) {
	if .Device not_in state.resource_flags {
		log_called_when_resource_unset(#procedure, Vulkan_Static_State_Resource_Flag.Device)
		return
	}

	vk.DestroyDevice(state.device.handle, callbacks)
	when CONFIG_VERBOSE_LOG do log.debug("Device destroyed")

	unset_resource_flag(&state.resource_flags, Vulkan_Static_State_Resource_Flag.Device)
}

check_all_flags :: proc(flags: bit_set[$T]) -> (all_present: bool){
	for flag in T do if flag not_in flags && (flag == .Debug && options_get_unsafe(.Debug_Layers) ) do return false

	return true
}
