package render

import "core:log"
import "core:slice"
import "core:dynlib"
import "core:strings"

import "vendor:glfw"
import vk "vendor:vulkan"

when DESKTOP_BUILD {
	REQUESTED_INSTANCE_EXTENSIONS := []cstring{

	}
	REQUESTED_INSTANCE_LAYERS := []cstring{

	}
} else {
	REQUESTED_INSTANCE_EXTENSIONS := []cstring{
		"VK_KHR_surface",
		"VK_KHR_android_surface",
	}
	REQUESTED_INSTANCE_LAYERS := []cstring{

	}
}

when DESKTOP_BUILD {
	REQUESTED_DEVICE_EXTENSIONS := []cstring{

	}
	REQUESTED_DEVICE_LAYERS := []cstring{

	}
} else {
	REQUESTED_DEVICE_EXTENSIONS := []cstring{

	}
	REQUESTED_DEVICE_LAYERS := []cstring{

	}
}

// Flags that are used to check which initalization resource were created, so when it's cleanup time,
// or when resources need to be recreated it can be check using these flags
Init_Resources_Created_Flag :: enum {
	Library,
	Instance,
	Physical_Device,
	Device,
	Surface,
}
Init_Resources_Created_Flags :: bit_set[Init_Resources_Created_Flag]

Renderer_State :: struct {
	init: Vulkan_Init_State,
}

Vulkan_Init_State :: struct {
	data: rawptr,
	vklib: dynlib.Library,
	resource_flags: Init_Resources_Created_Flags,
	instance: Instance_State,
	physical_devices: Physical_Devices,
	device: Device_State,
	surface: Surface_State,
}

Layers_Extensions_Properties :: struct {
	available_extensions: []vk.ExtensionProperties,
	available_layers: []vk.LayerProperties,
	enabled_extensions_names: [dynamic]cstring,
	enabled_layers_names: [dynamic]cstring,
}

Instance_State :: struct {
	handle: vk.Instance,
	using _: Layers_Extensions_Properties,
}

Physical_Devices :: struct {
	detected: #soa []Physical_Device,
	active: Active_Physical_Device,
}

Physical_Device :: struct {
	handle: vk.PhysicalDevice,
	name: string,
	score: int,
}

Active_Physical_Device :: struct {
	device: #soa^#soa[]Physical_Device,
	features: vk.PhysicalDeviceFeatures,
	properties: vk.PhysicalDeviceProperties,
	memory_properties: vk.PhysicalDeviceMemoryProperties,
	queues_properites: []vk.QueueFamilyProperties,
	queue_indexes: Queue_Indexes,
	using _: Layers_Extensions_Properties,
}

//NOTE: Usually it'll be one queue for all, so it's not needed to implement usage of async ones for current state
Queue_Indexes :: struct {
	graphics, transfer, compute: int
}

Device_State :: struct {
	handle: vk.Device,
	graphics, transfer, compute: vk.Queue,
}

initialize_vulkan :: proc(window_state: ^Window_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (state: Renderer_State) {
	load_vklib(&state)

	success := create_instance(&state.init, allocator, temp_allocator, callbacks)
	if !success {
		log.fatal("Cannot create Vulkan instance")
		return 
	}

	success = pick_physical_device(&state.init, allocator, temp_allocator)
	if !success {
		log.fatal("Failed to pick physical device ")
		return
	}

	success = create_device(&state.init, allocator, callbacks)
	if !success {
		log.fatal("Failed to create device")
		return
	}

	success = create_surface(&state.init, window_state, callbacks)
	if !success {
		log.fatal("FAiled to create surface")
		return
	}
	

	when VERBOSE_LOG do log.debug("Initialization successful")
	return
}

cleanup_vulkan :: proc(state: ^Renderer_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) {
	if .Surface in state.init.resource_flags do cleanup_surface(&state.init, callbacks)
	if .Device in state.init.resource_flags do cleanup_device(&state.init, allocator, callbacks)
	if .Physical_Device in state.init.resource_flags do cleanup_physical_devices(&state.init, allocator)
	if .Instance in state.init.resource_flags do cleanup_instance(&state.init, allocator, callbacks)
	if .Library in state.init.resource_flags do unload_vklib(state)
}

load_vklib :: proc(state: ^Renderer_State) {
	when ODIN_OS == .Linux do vk_lib_name :: "libvulkan.so"
	else when ODIN_OS == .Windows do vk_lib_name :: "1-vulkan.dll"
	else do #panic("Vulkan lib name file not specified for " + ODIN_OS + " OS")

	loaded: bool
	state.init.vklib, loaded = dynlib.load_library(vk_lib_name)
	if !loaded do log.panic("Cannot load Vulkan dynamic library")
	when VERBOSE_LOG do log.debug("Vulkan dynamic library loaded")
	state.init.resource_flags |= {.Library}
	when VERBOSE_LOG do log.debug("Vulkan dynamic library resource flag set")

	vk_get_instance_proc_addr_name, found := dynlib.symbol_address(state.init.vklib, "vkGetInstanceProcAddr")
	if !found do log.panic("Cannot found addres of 'vkGetInstanceProcAddr'")
	when VERBOSE_LOG do log.debug("Address of 'vkGetInstanceProcAddr' found")

	vk.load_proc_addresses_global(vk_get_instance_proc_addr_name)
	when VERBOSE_LOG do log.debug("Global procedure addresses loaded")
	log.debug("Vulkan initalization start")
}

unload_vklib :: proc(state: ^Renderer_State) {
	unloaded := dynlib.unload_library(state.init.vklib)
	if !unloaded do log.errorf("Failed to unload Vulkan library: %v", dynlib.last_error())
	when VERBOSE_LOG do log.debug("Unloaded Vulkan library")

	state.init.resource_flags &~= {.Library}
	when VERBOSE_LOG do log.debug("Vulkan library resource flag unset")
}

create_instance :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, temp_allocator := context.temp_allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
	enumerated: bool 

	state.instance.available_layers, enumerated = query_instance_layers(allocator)
	if !enumerated do return
	defer if !success do delete(state.instance.available_layers, allocator)

	for &l, i in state.instance.available_layers {
		if i == 0 do log.info("Available instance layers:")
		log.infof("%v. %v", i+1, cstring(raw_data(&l.layerName)))
	}

	for l, i in REQUESTED_INSTANCE_LAYERS {
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

	missing_layers: [dynamic]cstring
	defer delete(missing_layers)

	state.instance.enabled_layers_names, missing_layers = check_layers(REQUESTED_INSTANCE_LAYERS, state.instance.available_layers, allocator)
	defer if !success do delete(state.instance.enabled_layers_names)

	missing_extensions: [dynamic]cstring
	defer delete(missing_extensions)

	when DESKTOP_BUILD {
		ext := slice.clone_to_dynamic(REQUESTED_INSTANCE_EXTENSIONS, temp_allocator)
		defer delete(ext)
		glfw_ext := glfw.GetRequiredInstanceExtensions()

		for e in glfw_ext do append(&ext, e)
			
		for e, i in ext {
			if i == 0 do log.info("Requested instance extensions:")
			log.infof("%v. %v", i+1, e)
		}

		state.instance.enabled_extensions_names, missing_extensions = check_extensions(ext[:], state.instance.available_extensions, allocator)
	} else {
		for e, i in REQUESTED_INSTANCE_EXTENSIONS {
			if i == 0 do log.info("Requested instance extensions:")
			log.infof("%v. %v", i+1, e)
		}

		state.instance.enabled_extensions_names, missing_extensions = check_extensions(REQUESTED_INSTANCE_EXTENSIONS, state.instance.available_extensions, allocator)
	}

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
		pApplicationName = "ODIN_ANDROID_RENDERER",
		pEngineName = "ODIN_ANDROID_RENDERER",
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

	when VERBOSE_LOG do log.debug("Instance created")
	vk.load_proc_addresses_instance(state.instance.handle)
	when VERBOSE_LOG do log.debug("Instance procedure addresses loaded")

	state.resource_flags |= {.Instance}
	when VERBOSE_LOG do log.debug("Instance resource flag set")

	success = true
	return
}

cleanup_instance :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) {
	vk.DestroyInstance(state.instance.handle, callbacks)
	when VERBOSE_LOG do log.debug("Instance destroyed")

	delete(state.instance.enabled_extensions_names)
	delete(state.instance.enabled_layers_names)

	delete(state.instance.available_extensions, allocator)
	delete(state.instance.available_layers, allocator)
	when VERBOSE_LOG do log.debug("Instance resources released")

	state.resource_flags &~= {.Instance}
	when VERBOSE_LOG do log.debug("Instance resource flag unset")
}

query_instance_extensions :: proc(layer_name: cstring = nil, allocator := context.allocator) -> (ext: []vk.ExtensionProperties, success: bool) {
	count: u32
	result := vk.EnumerateInstanceExtensionProperties(layer_name, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(1) Instance extensions enumeration succeded")
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
		when VERBOSE_LOG do log.debug("(2) Instance extensions enumeration succeded")
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
		when VERBOSE_LOG do log.debug("(1) Instance layers enumeration succeded")
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
		when VERBOSE_LOG do log.debug("(2) Instance layers enumeration succeded")
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
query_device_layers :: proc(device: ^vk.PhysicalDevice, allocator := context.allocator) -> (lay: []vk.LayerProperties, success: bool) {
	count: u32
	result := vk.EnumerateDeviceLayerProperties(device^, &count, nil)

	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(1) Device layers enumeration succeded")
	case .INCOMPLETE:
		log.warn("(1) Device layers enumeration was incomplete")
	case: 
		log.errorf("(1) Error occured when enumerating device layers: %v", result)
		return
	}

	if count == 0 do log.warn("(1) Unexpected behaviour: queried count of device layers is zero")

	lay = make([]vk.LayerProperties, count, allocator)
	defer if !success do delete(lay, allocator)

	result = vk.EnumerateDeviceLayerProperties(device^, &count, raw_data(lay))
	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(2) Device layers enumeration succeded")
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

query_device_extensions :: proc(device: vk.PhysicalDevice,layer_name: cstring = nil, allocator := context.allocator) -> (ext: []vk.ExtensionProperties, success: bool) {
	count: u32
	result := vk.EnumerateDeviceExtensionProperties(device, layer_name, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(1) Device extensions enumeration succeded")
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
		when VERBOSE_LOG do log.debug("(2) Device extensions enumeration succeded")
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

pick_physical_device :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (success: bool) {
	count: u32

	result := vk.EnumeratePhysicalDevices(state.instance.handle, &count, nil)
	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(1) Physical devices enumerated")
	case .INCOMPLETE:
		log.warn("(1) Not all physical devices were enumerated")
	case: 
		log.errorf("(1) Error occured when enumerating physical devices: %v", result)
		return
	}

	log.assert(count > 0, "(1) Queried physical device count is zero")

	devices := make([]vk.PhysicalDevice, count, temp_allocator)
	defer delete(devices, temp_allocator)

	state.physical_devices.detected = make(#soa[]Physical_Device, count, allocator)
	defer if !success do delete(state.physical_devices.detected, allocator)


	result = vk.EnumeratePhysicalDevices(state.instance.handle, &count, raw_data(devices))
	#partial switch result {
	case .SUCCESS:
		when VERBOSE_LOG do log.debug("(2) Physical devices enumerated")
	case .INCOMPLETE:
		log.warn("(2) Not all physical devices were enumerated")
	case: 
		log.errorf("(2) Error occured when enumerating physical devices: %v", result)
		return
	}

	log.assert(count > 0, "(2) Queried physical device count is zero")

	// Copy the handles for custom data structure
	for d, i in devices do state.physical_devices.detected[i].handle = d

	state.physical_devices.active = pick_best_device_based_on_score(&state.physical_devices.detected, allocator, temp_allocator)
	log.infof("Picked physical device: %v", state.physical_devices.active.device.name)

	enumerated: bool

	state.physical_devices.active.available_layers, enumerated = query_device_layers(&state.physical_devices.active.device.handle, allocator)
	if !enumerated do return
	defer if !success do delete(state.physical_devices.active.available_layers, allocator)

	for &l, i in state.physical_devices.active.available_layers {
		if i == 0 do log.infof("Available device layers (%v):", state.physical_devices.active.device.name)
		log.infof("%v. %v", i+1, cstring(raw_data(&l.layerName)))
	}

	for l, i in REQUESTED_DEVICE_LAYERS {
		if i == 0 do log.info("Requested device layers:")
		log.infof("%v. %v", i+1, l)
	}

	state.physical_devices.active.available_extensions, enumerated = query_device_extensions(state.physical_devices.active.device.handle, allocator = allocator)
	if !enumerated do return
	defer if !success do delete(state.physical_devices.active.available_extensions, allocator)

	for &e, i in state.physical_devices.active.available_extensions {
		if i == 0 do log.infof("Available device extensions (%v):", state.physical_devices.active.device.name)
		log.infof("%v. %v", i+1, cstring(raw_data(&e.extensionName)))
	}

	for e, i in REQUESTED_DEVICE_EXTENSIONS {
		if i == 0 do log.info("Requested device extensions:")
		log.infof("%v. %v", i+1, e)
	}

	missing_layers: [dynamic]cstring
	defer delete(missing_layers)
	state.physical_devices.active.enabled_layers_names, missing_layers = check_layers(REQUESTED_DEVICE_LAYERS, state.physical_devices.active.available_layers, allocator)

	missing_extensions: [dynamic]cstring
	defer delete(missing_extensions)
	state.physical_devices.active.enabled_extensions_names, missing_extensions = check_extensions(REQUESTED_DEVICE_EXTENSIONS, state.physical_devices.active.available_extensions, allocator)


	for l, i in missing_layers {
		if i == 0 do log.error("Requested layers missing:")
		log.errorf("%v. %v", i, l)
	}

	for e, i in missing_extensions {
		if i == 0 do log.error("Requested extensions missing:")
		log.errorf("%v. %v", i, e)
	}

	if len(missing_layers) > 0 || len(missing_extensions) > 0 do return

	state.resource_flags |= {.Physical_Device}
	when VERBOSE_LOG do log.debug("Physical device resources flag set")

	success = true
	return
}

cleanup_physical_devices :: proc(state: ^Vulkan_Init_State, allocator := context.allocator) {
	using state.physical_devices

	for d in detected do delete(d.name, allocator)
	when VERBOSE_LOG do log.debug("Deleted allocated physical devices names")

	delete(detected)
	when VERBOSE_LOG do log.debug("Deleted all detected physical devices")

	delete(active.queues_properites, allocator)
	when VERBOSE_LOG do log.debug("Deleted active physical device queue family properties")

	delete(active.enabled_extensions_names)
	delete(active.enabled_layers_names)

	delete(active.available_extensions, allocator)
	delete(active.available_layers, allocator)
	when VERBOSE_LOG do log.debug("Active device resources released")

	active = {}
	when VERBOSE_LOG do log.debug("Zeroed active physical device struct")

	state.resource_flags &~= {.Physical_Device}
	when VERBOSE_LOG do log.debug("Physical device resource flag unset")
}

//WARN: Procedure allocates string names with given allocator, names then need to be freed accordingly
pick_best_device_based_on_score :: proc(devices: ^#soa[]Physical_Device, allocator := context.allocator, temp_allocator := context.temp_allocator) -> (active: Active_Physical_Device) {
	log.assert(len(devices)>0, "Length of devices is zero")

	features: vk.PhysicalDeviceFeatures
	properties: vk.PhysicalDeviceProperties
	memory_properties: vk.PhysicalDeviceMemoryProperties
	queue_familiy_properties: []vk.QueueFamilyProperties

	last_highest_score: int


	for &d, i in devices {
		log.assert(d.handle != nil, "Physical device handle is nil, when expected to be a valid VkPhysicalDevice")

		queue_counter: u32

		vk.GetPhysicalDeviceFeatures(d.handle, &features)
		vk.GetPhysicalDeviceProperties(d.handle, &properties)
		vk.GetPhysicalDeviceMemoryProperties(d.handle, &memory_properties)

		//copy the name with allocator so that it can be stored without storing all other properties
		d.name = strings.clone_from_cstring(cstring(raw_data(&properties.deviceName)), allocator)

		vk.GetPhysicalDeviceQueueFamilyProperties(d.handle, &queue_counter, nil)
		log.assert(queue_counter > 0, "(1) Queue counter is less than one")

		//Query currents device queues, then check for results and then either discard or overwrite the current active one,
		//so delete the one that is set in active device
		queue_familiy_properties = make([]vk.QueueFamilyProperties, queue_counter, temp_allocator) 

		vk.GetPhysicalDeviceQueueFamilyProperties(d.handle, &queue_counter, raw_data(queue_familiy_properties))
		log.assert(queue_counter > 0, "(2) Queue counter is less than one")

		indexes := get_physical_device_queues_indexes(queue_familiy_properties)

		// Better score for async queues
		if indexes.transfer != indexes.graphics do d.score += 1000
		if indexes.compute != indexes.graphics do d.score += 500
	
		when DESKTOP_BUILD {
			// just to be sure for desktop that the better one will be picked
			if properties.deviceType == .DISCRETE_GPU do d.score += 10000
			d.score += int(properties.limits.maxImageDimension2D)
		}

		// Just in case always get the first one as the active device
		if d.score > last_highest_score || i == 0 {
			last_highest_score = d.score
			active.device = &devices[i]
			active.features = features
			active.properties = properties
			active.memory_properties = memory_properties
			active.queues_properites = slice.clone(queue_familiy_properties, allocator)
			active.queue_indexes = indexes
		}
	}

	return
}

get_physical_device_queues_indexes :: proc(queue_properties: []vk.QueueFamilyProperties) -> (indexes: Queue_Indexes) {
	indexes.compute = -1
	indexes.graphics = -1
	indexes.transfer = -1

	dedicated_compute_index := -1
	dedicated_transfer_index := -1
	async_index := -1

	// find dedicated and async queues first
	for q, i in queue_properties {
		flags := q.queueFlags

		if .GRAPHICS in flags && indexes.graphics == -1 do indexes.graphics = i

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

create_device :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) -> (success: bool) {
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

	result := vk.CreateDevice(state.physical_devices.active.device.handle, &create_info, callbacks, &state.device.handle)
	if result != .SUCCESS {
		log.errorf("Device creation error: %v", result)
		return
	}

	when VERBOSE_LOG do for q, i in state.physical_devices.active.queues_properites {
		if i == 0 do log.info("Available queue families:")
		log.infof("Usage: %v, queue count: %v", q.queueFlags, q.queueCount)
	}

	// Get graphics queue
	vk.GetDeviceQueue(state.device.handle, u32(graphics), 0, &state.device.graphics)

	// Get other queues if they're present
	if transfer != graphics {
		// T|C & G or G & T & C or G|C & T
		vk.GetDeviceQueue(state.device.handle, u32(transfer), 0, &state.device.transfer)
		if transfer != compute && compute != graphics {
			vk.GetDeviceQueue(state.device.handle, u32(compute), 0, &state.device.compute) // G & T & C
			when VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated transfer and copmute queue")
		}
		else if transfer == compute {
			state.device.compute = state.device.transfer // T|C & G
			when VERBOSE_LOG do log.debug("Queue combination detecetd: async transfer|compute queue")
		}
		else {
			state.device.compute = state.device.graphics // G|C & T
			when VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated transfer queue")
		}
	} else { 
		// G|T & C or G|T|C
		state.device.transfer = state.device.graphics
		if transfer != compute {
			vk.GetDeviceQueue(state.device.handle, u32(compute), 0, &state.device.compute) // G|T & C
			when VERBOSE_LOG do log.debug("Queue combination detecetd: dedicated compute queue")
		}
		else {
			state.device.compute = state.device.graphics // G|T|C
			when VERBOSE_LOG do log.debug("Queue combination detecetd: no dedicated or async queues")
		}
	}

	state.resource_flags |= {.Device}
	when VERBOSE_LOG do log.debug("Device resources flag set")

	success = true
	return 
}

cleanup_device :: proc(state: ^Vulkan_Init_State, allocator := context.allocator, callbacks: ^vk.AllocationCallbacks = nil) {
	vk.DestroyDevice(state.device.handle, callbacks)
	when VERBOSE_LOG do log.debug("Device destroyed")

	state.resource_flags &~= {.Device}
	when VERBOSE_LOG do log.debug("Device resource flag unset")
}

check_all_flags :: proc(flags: bit_set[$T]) -> (all_present: bool){
	for flag in T do if flag not_in flags do return false
	
	return true
}
