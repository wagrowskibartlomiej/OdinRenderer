package engine


import "base:runtime"

import "core:os"
import "core:log"
import "core:time"
import "core:slice"
import "core:strconv"

import vk "vendor:vulkan"

engine_init :: proc "contextless" (
	state: ^Engine_Global_State,
	procs := Engine_State_Create_Procs{},
) -> (
	ctx: runtime.Context,
) {
	context = setup_engine_state(state, procs)

	state.mesh.position = {1, 1, 1}
	state.mesh.scale = {1, 1, 1}
	initialize_engine_configuration()
	load_configuration(get_engine_configuration()._settings_strings_arena.allocator)

	initialize_asset_manager(&state.assets)

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success := read_assets_dir_recursive(&state.assets, load_assets_mem = true)
		if !success do log.panicf("Unable to continue without assets")
	} else do read_assets_packed(state.assets.assets_file, &state.assets, true)

	return context
}

engine_cleanup :: proc(state: ^Engine_Global_State, procs := Engine_State_Cleanup_Procs{}) {
	saved := save_configuration()
	if !saved do log.error("Engine configuration not saved")

	when CONFIG_BUILD_VARIANT == Build_Variants[.Editor] {
		success := build_asset_packed(&state.assets)
		if !success do log.error("Building assets file failed")
	}
	cleanup_asset_manager(&state.assets)
	cleanup_engine_configuration()
	cleanup_engine_state(state, procs)
	//free_all(context.temp_allocator)
}

engine_renderer_init :: proc(state: ^Engine_Global_State) -> (success: bool) {
	success = create_window(&state.window)
	success or_return

	initialize_vulkan(&state.renderer, state)
	if !check_all_flags(state.renderer.core.resource_flags) {
		log.fatal("Initalization not completed successfuly")
		cleanup_vulkan(&state.renderer)
		return
	}

	success = init_frame_resources(&state.renderer.dyn, &state.renderer.core)
	success or_return

	return true
}
engine_renderer_cleanup :: proc(state: ^Engine_Global_State) {
	log.infof("Engine was running for %v", time.diff(state.time.engine_start, time.now()))
	avg_frame_time_s := state.time.stats.total_frame_time / f64(state.time.stats.frame_count)
	avg_fps := 1.0 / avg_frame_time_s
	avg_frame_time_ms := avg_frame_time_s * 1000
	log.infof("Avg frame time: %.4f ms (%.2f FPS)", avg_frame_time_ms, avg_fps)
	engine_write_performance_stats(avg_fps, avg_frame_time_ms)
	cleanup_frame_resources(&state.renderer.core, &state.renderer.dyn)
	cleanup_vulkan(&state.renderer)
	cleanup_window(&state.window)
}

engine_write_performance_stats :: proc(avg_fps: f64, avg_frame_time_ms: f64) {
	f, err := engine_open("performance.txt", {.Create, .Trunc, .Write})
	if err != nil {
		log.errorf("Failed to save performance stats into file: %v", err)
		return
	}
	defer os.close(f)
	counter : i64 = 0

	// Bigger just in case
	float_buffer: [128]byte

	first := "Average frame time:"
	os.write_at(f, transmute([]byte)first, counter)
	counter += i64(slice.size(transmute([]byte)first))

	avg_time_str := strconv.write_float(float_buffer[:], avg_frame_time_ms, 'f', 4, 64)
	// it adds sign, so we're just gonna change it into space (we can safely do this since backing buffer is on stack, not in rodata)
	(transmute([]byte)avg_time_str)[0] = ' '
	os.write_at(f, transmute([]byte)avg_time_str, counter)
	counter += i64(slice.size(transmute([]byte)avg_time_str))

	first_sep := " ms\n"
	os.write_at(f, transmute([]byte)first_sep, counter)
	counter += i64(slice.size(transmute([]byte)first_sep))

	second := "Average FPS:"
	os.write_at(f, transmute([]byte)second, counter)
	counter += i64(slice.size(transmute([]byte)second))

	avg_fps_str := strconv.write_float(float_buffer[:], avg_fps, 'f', 4, 64)
	// same as above
	(transmute([]byte)avg_fps_str)[0] = ' '
	os.write_at(f, transmute([]byte)avg_fps_str, counter)
	counter += i64(slice.size(transmute([]byte)avg_fps_str))

	os.write_at(f, []byte{'\n'}, counter)
	counter += 1
}

engine_poll_events :: proc(state: ^Engine_Global_State) {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do glfw_poll_events()
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET != .Android do #panic(#procedure + " is not implemented for " + CONFIG_BUILD_TARGET + "target (" + ODIN_PLATFORM_SUBTARGET + ") subtarget")
	else do android_poll_events(cast(^Engine_Android_Global_State)state.platform_context)
}

engine_is_running :: proc(state: ^Engine_Global_State) -> bool {
	when CONFIG_BUILD_TARGET == Build_Targets[.Pc] do return glfw_is_running(state)
	else when CONFIG_BUILD_TARGET == Build_Targets[.Mobile] && ODIN_PLATFORM_SUBTARGET == .Android do return android_is_running(cast(^Engine_Android_Global_State)state)
	else do #panic(#procdure +" is not implemented for " + CONFIG_BUILD_TARGET + " target (subtarget " + ODIN_PLATFORM_SUBTARGET + ")")
}

engine_process_input :: proc() {}

engine_update_logic :: proc() {
	m := &get_global_state().mesh
	m.rotation.y += (5 * f32(get_delta()))
	if m.rotation.y >= 360 do m.rotation.y -= 360
}

engine_upload_gpu :: proc(update: bool) {
	if !update {
		return
	}
	r := &get_global_state().renderer

	//TODO: Bake fallback cube mesh and fallback one color texture into executable with #load

	texture, text_exists := get_asset(
		"example_texture.png",
		DEFAULT_ASSETS_PKG_NAME,
		.PNG,
		&get_global_state().assets,
	)
	if !text_exists do log.panic("Cannot continue without texture")

	mesh, mesh_exists := get_asset(
		"example_mesh.obj",
		DEFAULT_ASSETS_PKG_NAME,
		.OBJ,
		&get_global_state().assets,
	)
	if !mesh_exists do log.panic("Cannot continue without mesh")

	success := engine_handle_buffer_upload(
		raw_data(mesh.memory.mesh.verticies),
		slice.size(mesh.memory.mesh.verticies),
		r.dyn.vertex,
		&r.dyn.staging,
	)
	if !success do log.panicf("Cannot continue without sucecssfull mesh vertices transfer")

	success = engine_handle_buffer_upload(
		raw_data(mesh.memory.mesh.indicies),
		slice.size(mesh.memory.mesh.indicies),
		r.dyn.index,
		&r.dyn.staging,
	)
	if !success do log.panicf("Cannot continue without sucecssfull mesh indices transfer")

	ext := get_vulkan_extent_from_texture_data(texture.data.texture)

	region := vk.BufferImageCopy {
		imageExtent = ext,
		imageSubresource = {
			aspectMask = {.COLOR},
			baseArrayLayer = 0,
			layerCount = 1,
			mipLevel = 0,
		},
	}

	success = engine_handle_image_upload(
		raw_data(texture.memory.regular),
		len(texture.memory.regular),
		r.core.images.example_texture.handle,
		.SHADER_READ_ONLY_OPTIMAL,
		region,
		&r.dyn.staging,
	)
	if !success do log.panic("Cannot continue without successfull texture transfer")
}

engine_draw_frame :: proc(
	state: ^Engine_Global_State,
	frame_index: int,
	allocator := context.allocator,
	callbacks := VULKAN_GLOBAL_ALLOCATION_CALLBACKS,
) -> vk.Result {
	res := draw_frame(
		&state.renderer.core,
		&state.renderer.dyn,
		state.window.handle,
		frame_index,
		allocator,
		callbacks,
	)
	#partial switch res {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR:
		recreate_swapchain(.Default_Mesh, allocator, callbacks)
	case:
		log.panicf("Drawing failure: %v", res)
	}

	return res
}

engine_update_current_frame_idx :: proc(state: ^Engine_Global_State) {
	assert(state != nil)
	state.renderer.current_frame_index =
		(state.renderer.current_frame_index + 1) %
		get_engine_configuration().settings.Frames_In_Flight
}

engine_calculate_delta :: proc(state: ^Engine_Global_State) {
	assert(state != nil)

	n := time.now()

	state.time.frame_diff = time.diff(state.time.last_frame_start, n)
	state.time.delta = time.duration_seconds(state.time.frame_diff)
	state.time.last_frame_start = n

	state.time.stats.frame_count += 1
	state.time.stats.total_frame_time += state.time.delta
}

engine_handle_buffer_upload :: proc(
	data: rawptr,
	size: int,
	dst: GPU_Resource_Handle,
	staging: ^Staging_Buffer,
) -> (
	success: bool,
) {
	actions, ok := gpu_move_data_to_buffer(data, size, dst, staging)
	if !ok {
		log.errorf("Failed to update destination buffer")
		return
	}

	if .Flush_Destination in actions {
		success = gpu_flush_resource(dst)
		if !success {
			log.errorf("Failed to flush destination buffer")
			return
		}
	}

	if .Flush_Staging in actions {
		success = gpu_flush_resource(staging.handle)
		if !success {
			log.errorf("Failed to flush staging buffer")
			return
		}
	}

	if .Submit_Cmd_Buffer in actions {
		// TODO: Check for queue transfer ownership, right now it's ignored cause we use only graphics
		graphics := get_global_state().renderer.core.device.graphics
		submit_info := vk.SubmitInfo {
			sType              = .SUBMIT_INFO,
			commandBufferCount = 1,
			pCommandBuffers    = &staging.cmd_buff,
			/*
			Since we're not using separate transfer queue, we ignore these
			pSignalSemaphores = &s.sem,
			signalSemaphoreCount = 1,
			*/
		}
		result := vk.QueueSubmit(graphics, 1, &submit_info, staging.fence)
		if result != .SUCCESS {
			log.errorf("Queue submition for buffer copy failed: %v", result)
			return
		}

		#partial switch gpu_get_data(dst).type {
		case .Vertex_Buffer:
			staging.flags += {.Vertex_Updated}
		case .Index_Buffer:
			staging.flags += {.Index_Updated}
		}
	}

	return true
}

engine_handle_image_upload :: proc(
	data: rawptr,
	size: int,
	dst: GPU_Resource_Handle,
	dst_layout: vk.ImageLayout,
	region: vk.BufferImageCopy,
	staging: ^Staging_Buffer,
) -> (
	success: bool,
) {
	actions, ok := gpu_move_data_to_image(
		staging.cmd_buff,
		data,
		size,
		dst,
		dst_layout,
		region,
		staging,
	)
	if !ok do log.panic("Cannot continue without texture transfer")

	if .Flush_Destination in actions {
		log.panic(
			"Something went wrong, texture should be in optimal tiling which means we can't copy directly to image",
		)
	}

	if .Flush_Staging in actions {
		ok := gpu_flush_resource(staging.handle)
		if !ok do log.panicf("Flushing staging buffer failed, cannot continue")
	}

	if .Submit_Cmd_Buffer in actions {
		submit_info := vk.SubmitInfo {
			commandBufferCount = 1,
			pCommandBuffers    = &staging.cmd_buff,
			sType              = .SUBMIT_INFO,
		}
		result := vk.QueueSubmit(
			get_global_state().renderer.core.device.graphics,
			1,
			&submit_info,
			staging.fence,
		)
		if result != .SUCCESS {
			log.errorf("Queue submition for image copy failed: %v", result)
			return
		}
	}


	return true
}
