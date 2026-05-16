#+build linux
package engine

when ODIN_OS != .Linux do #panic("Cannot build android APKs on " + ODIN_OS + ". If you want to build Android APK using Windows, please try using WSL.")

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:os"
import fp "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

import android "androidglue/ndkbindings"

File_Impl :: struct {
	name:      string,
	fd:        linux.Fd,
	file:      os.File,
	allocator: runtime.Allocator,
	buffer:    []byte,
	rw_mutex:  sync.RW_Mutex, // read write calls
	p_mutex:   sync.Mutex, // pread pwrite calls
}
Android_File_Impl :: struct {
	using _:    File_Impl,
	asset_data: ^Android_Asset_File_Data,
}

Android_Asset_File_Data :: struct {
	handle:                                    ^android.AAsset,
	flags:                                     Android_File_Impl_Flags,
	internal_offset, start_offset, end_offset: i64, // Used for using linux.read to prevent destroying AAsset global offset when ommiting AAsset Manager
}

// TODO: Fix writing to external and internal storage on Android
// Thread safe flag is only used for APK, app pointer needs to be passed
android_open :: proc(
	name: string,
	flags := os.File_Flags{.Read},
	perm := os.Permissions_Default,
	open_options := Android_Search_Everywhere_Not_Thread_Safe_Flags,
) -> (
	f: ^os.File,
	err: os.Error,
) {
	// Maybe if unsuporrted flags && only search asset return early? idk maybe let open it cause android proc will just return unsupported and let use the file in other ways?
	//if (.Write in flags || .Create in flags || .Trunc in flags || .Excl in flags || .Append in flags)\
	//&& Android_File_Impl_Flags{.Search_Assets} & open_options == Android_File_Impl_Flags{.Serach_Assets} {}

	state := get_android_global_state()
	if state == nil || state.app_ptr == nil do return nil, .ENXIO // I do not really now what error to return without extending os.Error and I'd want to avoid that
	app := state.app_ptr

	arena, _ := runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temp_alloc := runtime.arena_allocator(arena.arena)
	cname := strings.clone_to_cstring(name, temp_alloc)

	if .Search_Assets in open_options {
		asset := android.AAssetManager_open(app.activity.assetManager, cname, .RANDOM)
		if asset != nil {
			start, length: i64
			fd := android.AAsset_openFileDescriptor64(asset, &start, &length)
			if fd > 0 do android.AAsset_close(asset)
			return android_new_file_asset(
				linux.Fd(fd),
				name,
				start,
				length,
				app,
				asset,
				open_options,
				runtime.heap_allocator(),
			)
		}
	}

	// Just default to using O_NOCTTY because needing to open a controlling
	// terminal would be incredibly rare. This has no effect on files while
	// allowing us to open serial devices.
	sys_flags: linux.Open_Flags = {.NOCTTY, .CLOEXEC}
	when size_of(rawptr) == 4 {
		sys_flags += {.LARGEFILE}
	}
	switch flags & (os.O_RDONLY | os.O_WRONLY | os.O_RDWR) {
	case os.O_RDONLY:
	case os.O_WRONLY: sys_flags += {.WRONLY}
	case os.O_RDWR:   sys_flags += {.RDWR}
	}

	if .Append in flags        { sys_flags += {.APPEND} }
	if .Create in flags        { sys_flags += {.CREAT} }
	if .Excl in flags          { sys_flags += {.EXCL} }
	if .Sync in flags          { sys_flags += {.DSYNC} }
	if .Trunc in flags         { sys_flags += {.TRUNC} }
	if .Non_Blocking in flags  { sys_flags += {.NONBLOCK} }
	if .Inheritable in flags   { sys_flags -= {.CLOEXEC} }

	builder := strings.builder_make(temp_alloc)
	defer strings.builder_destroy(&builder) // if any other temp allocator would be used then maybe?

	if .Search_Internal_Storage in open_options {
		p := app.activity.internalDataPath
		f, err := _handle_storage_file_opening_internal(name, p, &builder, sys_flags, perm, open_options, app)
		if err == nil do return f, err
	}

	if .Search_External_Storage in open_options {
		p := app.activity.externalDataPath
		return _handle_storage_file_opening_internal(name, p, &builder, sys_flags, perm, open_options, app)
	}

	return nil, .Not_Exist
}

@(private="file")
_handle_storage_file_opening_internal :: proc(name: string, path: cstring, builder: ^strings.Builder, sys_flags: linux.Open_Flags, perm: os.Permissions, open_options: Android_File_Impl_Flags, app: ^android.android_app) -> (f: ^os.File, err: os.Error) {
	base := fp.base(name)
	final_path := fmt.sbprintf(builder, "%v/%v", path, base)
	cpath := strings.unsafe_to_cstring(builder)
	fd, open_err := linux.open(cpath, sys_flags, transmute(linux.Mode)transmute(u32)perm)
	// if we found file
	if open_err == nil {
		f, err = android_new_file_storage(fd, name, 0, 0, app, nil, open_options, runtime.heap_allocator())
		if err == nil do return
	} else do err = _get_platform_error(open_err) // assign error to return if we won't be searching in external storage
	strings.builder_reset(builder)

	return
}

@(private="file")
android_file_proc : os.File_Stream_Proc : proc(stream_data: rawptr, mode: os.File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: os.Error) {
	file := cast(^os.File)stream_data
	data := cast(^Android_File_Impl)file.impl

	// If in APK there will be asset_data (it can be either asset opened with manager or descriptor)
	if data.asset_data != nil do return android_handle_assets_proc(data, mode, p, offset, whence, allocator)
	else do return android_handle_file_proc(data, mode, p, offset, whence, allocator) // if external/internal storage just handle it like a linux one

	return
}

@(private="file")
android_handle_assets_proc :: proc(data: ^Android_File_Impl, mode: os.File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: os.Error) {
	switch mode {
	case .Read: return _android_read(data, p)
	case .Read_At: return _android_read_at(data, p, offset)
	case .Seek: return _android_seek(data, offset, whence)
	case .Size: return android_size(data)
	case .Close, .Destroy:
		android_close(data)
		return
	case .Fstat, .Flush, .Write, .Write_At: return 0, .Unsupported
	case .Query: return io.query_utility({.Read, .Read_At, .Close, .Seek, .Size, .Destroy})
	}
	return
}

@(private="file")
android_new_file_asset :: proc(fd: linux.Fd, name: string, start, length: i64, app: ^android.android_app, asset: ^android.AAsset, flags: Android_File_Impl_Flags, allocator: runtime.Allocator) -> (f: ^os.File, err: os.Error) {
	// Firstly we need to allocate everything and if it goes wrong return and cleanup
	impl := new(Android_File_Impl, allocator) or_return
	defer if err != nil do free(impl, allocator)

	impl.asset_data = new(Android_Asset_File_Data, allocator) or_return // allocating this indicates that it's an APK asset (either opened with AAsset manager or normal file descriptor)
	defer if err != nil do free(impl.asset_data, allocator)

	impl.name = strings.clone(name, allocator) or_return

	impl.allocator = allocator
	impl.file.impl = impl
	impl.file.stream.procedure = android_file_proc
	impl.file.stream.data = app
	impl.asset_data.start_offset = start
	impl.asset_data.end_offset = start + length
	impl.asset_data.flags = flags
	impl.asset_data.handle = asset

	// Compressed asset or opened with descriptor
	if fd < 0 do impl.fd = -1
	else do impl.fd = fd

	return &impl.file, nil
}

@(private="file")
android_new_file_storage :: proc(fd: linux.Fd, name: string, start, length: i64, app: ^android.android_app, asset: ^android.AAsset, flags: Android_File_Impl_Flags, allocator: runtime.Allocator) -> (f: ^os.File, err: os.Error) {
	if fd < 0 do return nil, .ENOENT

	// Firstly we need to allocate everything and if it goes wrong return and cleanup
	impl := new(Android_File_Impl, allocator) or_return
	defer if err != nil do free(impl, allocator)

	impl.name = strings.clone(name, allocator) or_return

	impl.allocator = allocator
	impl.fd = fd
	impl.file.impl = impl
	impl.file.stream.procedure = android_file_proc
	impl.file.stream.data = app
	impl.asset_data = nil // this indicates that it is not an APK Asset

	return &impl.file, nil
}

@(private = "file")
android_close :: proc(impl: ^Android_File_Impl) -> (err: os.Error) {
	// So we have 3 options that we need to consider when clearing up (thread synchronization of closing file is responsibility of a caller, we only synchronize APKs reads and seek etc.):
	// - either we have normal file with valid fd and nil in asset_data
	// - or we can have asset with descriptor, which means valid fd and asset_data allocated (but asset handle is nil)
	// - and the last option is compressed asset that we cannot open with file descriptor which will have fd field set at -1 (or any non valid, but If I don't forget to set it, it should be -1)

	if impl.fd < 0 {
		if impl.asset_data != nil do android.AAsset_close(impl.asset_data.handle)
		else do return .EBADF
	} else {
		close_err := linux.close(impl.fd)
		err = _get_platform_error(close_err)
	}

	if impl.asset_data != nil do free(impl.asset_data, impl.allocator)

	delete(impl.name, impl.allocator)
	free(impl, impl.allocator)

	return
}

@(private = "file")
android_size :: proc(impl: ^Android_File_Impl) -> (size: i64, err: os.Error) {
	if impl.fd < 0 do return android.AAsset_getLength64(impl.asset_data.handle), nil
	else {
		s: linux.Stat
		err := linux.fstat(impl.fd, &s)
		return i64(s.size), _get_platform_error(err)
	}
}


@(private="file")
_get_absolute_offset :: proc(data: ^Android_Asset_File_Data, offset: i64, whence: io.Seek_From) -> (abs_offset: i64, err: os.Error) {
	curr_rel := data.internal_offset - data.start_offset
	new_rel: i64

	asset_length := data.end_offset - data.start_offset

	switch whence {
	case .Start: new_rel = offset
	case .Current: new_rel = curr_rel + offset
	case .End: new_rel = asset_length + offset
	}

	if new_rel < 0 || new_rel > asset_length do return data.internal_offset, .Invalid_Offset

	return data.start_offset + new_rel, nil
}

@(private = "file")
_android_read :: proc(data: ^Android_File_Impl, p: []byte) -> (n: i64, err: os.Error) {
	if len(p) <= 0 do return 0, nil
	p := p[:min(len(p), MAX_RW)]

	if .Thread_Safe_APK in data.asset_data.flags {
		sync.lock(&data.p_mutex)
		defer sync.unlock(&data.p_mutex)

		return _android_read_internal(data, p)
	} else do return _android_read_internal(data, p)
}

@(private = "file")
_android_read_internal :: proc(data: ^Android_File_Impl, p: []byte) -> (n: i64, err: os.Error) {
	if data.fd < 0 {
		read := android.AAsset_read(data.asset_data.handle, raw_data(p), len(p))

		if read == 0 do return 0, .EOF
		else if read < 0 do return i64(read), .Unknown
		else do return i64(read), nil
	}

	remaining := data.asset_data.end_offset - data.asset_data.internal_offset
	if remaining <= 0 do return 0, .EOF

	to_read := min(min(i64(len(p)), remaining), MAX_RW)

	read, read_err := linux.pread(data.fd, p[:to_read], data.asset_data.internal_offset)
	if read_err != nil do return 0, _get_platform_error(read_err)

	data.asset_data.internal_offset += i64(read)
	return i64(read), io.Error.EOF if read == 0 else nil
}

@(private="file")
_android_read_at :: proc(data: ^Android_File_Impl, p: []byte, offset: i64) -> (n: i64, err: os.Error) {
	if len(p) <= 0 do return 0, nil

	if data.fd < 0 {
		if .Thread_Safe_APK in data.asset_data.flags {
			sync.lock(&data.p_mutex)
			defer sync.unlock(&data.p_mutex)

			return _android_read_at_compressed(data, p, offset)
		} else do return _android_read_at_compressed(data, p, offset)
	}

	abs_off, off_err := _get_absolute_offset(data.asset_data, offset, .Start)
	if off_err != nil do return 0, off_err

	remaining := data.asset_data.end_offset - abs_off
	to_read := min(min(i64(len(p)), remaining), MAX_RW)

	read, read_err := linux.pread(data.fd, p[:to_read], abs_off)
	if read_err != nil do return 0, _get_platform_error(read_err)

	return i64(read), .EOF if read == 0 && to_read > 0 else nil
}

@(private="file")
_android_read_at_compressed :: proc(data: ^Android_File_Impl, p: []byte, offset: i64) -> (n: i64, err: os.Error) {
	curr := android.AAsset_seek(data.asset_data.handle, 0, .CUR)
	if curr < 0 do return 0, .Unknown
	defer android.AAsset_seek(data.asset_data.handle, curr, .SET)

	requested := android.AAsset_seek(data.asset_data.handle, offset, .SET)
	if requested < 0 do return 0, .Invalid_Offset

	read := android.AAsset_read(data.asset_data.handle, raw_data(p), len(p))

	if read == 0 do return 0, .EOF
	else if read < 0 do return i64(read), .Unknown
	else do return i64(read), nil
}

@(private="file")
_android_seek :: proc(data: ^Android_File_Impl, offset: i64, whence: io.Seek_From) -> (i64, os.Error) {
	if .Thread_Safe_APK in data.asset_data.flags {
		sync.lock(&data.p_mutex)
		defer sync.unlock(&data.p_mutex)
		return _android_seek_internal(data, offset, whence)
	}
	return _android_seek_internal(data, offset, whence)
}

@(private="file")
_android_seek_internal :: proc(data: ^Android_File_Impl, offset: i64, whence: io.Seek_From) -> (i64, os.Error) {
	if data.fd < 0 {
		off := android.AAsset_seek64(data.asset_data.handle, offset, android.Seek_Whence(whence))
		if off < 0 do return 0, .Unknown
		data.asset_data.internal_offset = off
		return off, nil
	}

	abs_off, off_err := _get_absolute_offset(data.asset_data, offset, io.Seek_From(whence))
	if off_err != nil do return (data.asset_data.internal_offset - data.asset_data.start_offset), off_err

	data.asset_data.internal_offset = abs_off

	return (abs_off - data.asset_data.start_offset), nil
}

// Rationale behind reuse of linux core:os file proc:
// 1. Accessibility: The original procedure is private within `core:os`, preventing direct reuse.
// 2. Extended Functionality: We need to mimic libc behavior while extending it to support
//    Android AAsset handling seamlessly.
// 3. Cross-Compilation: Dynamically extracting the procedure from a dummy file at runtime
//    is unreliable. For instance, building on Windows for an Android target would yield
//    the wrong host procedure. Copying the Linux/Posix implementation ensures the
//    correct logic is baked in regardless of the build host.


// Most implementations will EINVAL at some point when doing big writes.
// In practice a read/write call would probably never read/write these big buffers all at once,
// which is why the number of bytes is returned and why there are procs that will call this in a
// loop for you.
// We set a max of 1GB to keep alignment and to be safe.
@(private = "file")
MAX_RW :: 1 << 30

// Mostly like linux file proc, but closing is different to handle additonal Android data
@(private="file")
android_handle_file_proc :: proc(stream_data: rawptr, mode: os.File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: os.Error) {
	f := (^File_Impl)(stream_data)
	switch mode {
	case .Read:
		n, err = _read(f, p)
		return
	case .Read_At:
		n, err = _read_at(f, p, offset)
		return
	case .Write:
		n, err = _write(f, p)
		return
	case .Write_At:
		n, err = _write_at(f, p, offset)
		return
	case .Seek:
		n, err = _seek(f, offset, whence)
		return
	case .Size:
		n, err = _file_size(f)
		return
	case .Flush:
		err = _flush(f)
		return
	case .Close, .Destroy:
		err = android_close(cast(^Android_File_Impl)f)
		return
	case .Query:
		return io.query_utility({.Read, .Read_At, .Write, .Write_At, .Seek, .Size, .Flush, .Close, .Destroy, .Query})
	case .Fstat:
		err = file_stream_fstat_utility(f, p, allocator)
		return
	}
	return 0, .Unsupported
}

@(private = "file")
_read :: proc(f: ^File_Impl, p: []byte) -> (i64, os.Error) {
	if len(p) <= 0 {
		return 0, nil
	}

	n, errno := linux.read(f.fd, p[:min(len(p), MAX_RW)])
	if errno != .NONE {
		return 0, _get_platform_error(errno)
	}
	return i64(n), io.Error.EOF if n == 0 else nil
}
@(private = "file")
_read_at :: proc(f: ^File_Impl, p: []byte, offset: i64) -> (i64, os.Error) {
	if len(p) <= 0 {
		return 0, nil
	}
	if offset < 0 {
		return 0, .Invalid_Offset
	}
	n, errno := linux.pread(f.fd, p[:min(len(p), MAX_RW)], offset)
	if errno != .NONE {
		return 0, _get_platform_error(errno)
	}
	if n == 0 {
		return 0, .EOF
	}
	return i64(n), nil
}

@(private = "file")
_write :: proc(f: ^File_Impl, p: []byte) -> (nt: i64, err: os.Error) {
	p := p
	for len(p) > 0 {
		n, errno := linux.write(f.fd, p[:min(len(p), MAX_RW)])
		if errno != .NONE {
			err = _get_platform_error(errno)
			return
		}

		p = p[n:]
		nt += i64(n)
	}

	/*
	I guess that's not really needed anymore?
	sync_errno := linux.fsync(f.fd)
	if sync_errno != .NONE {
		log.errorf("[FILE INSPECT] _write: error writing on fd %v: %v", f.fd, sync_errno)
	} else {
		log.info("[FILE INSPECT] _write: Fsync succeded.")
	}
	*/

	return
}

@(private = "file")
_write_at :: proc(f: ^File_Impl, p: []byte, offset: i64) -> (nt: i64, err: os.Error) {
	if offset < 0 {
		return 0, .Invalid_Offset
	}

	p := p
	offset := offset
	for len(p) > 0 {
		n, errno := linux.pwrite(f.fd, p[:min(len(p), MAX_RW)], offset)
		if errno != .NONE {
			err = _get_platform_error(errno)
			return
		}

		p = p[n:]
		nt += i64(n)
		offset += i64(n)
	}

	return
}

@(no_sanitize_memory, private = "file")
_file_size :: proc(f: ^File_Impl) -> (n: i64, err: os.Error) {
	// TODO: Identify 0-sized "pseudo" files and return No_Size. This would
	//       eliminate the need for the _read_entire_pseudo_file procs.
	s: linux.Stat = ---
	errno := linux.fstat(f.fd, &s)
	if errno != .NONE {
		return 0, _get_platform_error(errno)
	}

	if s.mode & linux.S_IFMT == linux.S_IFREG {
		return i64(s.size), nil
	}
	return 0, .No_Size
}

@(private = "file")
_flush :: proc(f: ^File_Impl) -> os.Error {
	return _get_platform_error(linux.fsync(f.fd))
}

@(private="file")
file_stream_fstat_utility :: proc(f: ^File_Impl, p: []byte, allocator: runtime.Allocator) -> (err: os.Error) {
	fi: os.File_Info
	if len(p) >= size_of(fi) {
		fi, err = _fstat(&f.file, allocator)
		runtime.mem_copy_non_overlapping(raw_data(p), &fi, size_of(fi))
	} else {
		err = .Short_Buffer
	}
	return
}

@(private = "file")
_seek :: proc(f: ^File_Impl, offset: i64, whence: io.Seek_From) -> (ret: i64, err: os.Error) {
	// We have to handle this here, because Linux returns EINVAL for both
	// invalid offsets and invalid whences.
	switch whence {
	case .Start, .Current, .End:
		break
	case:
		return 0, .Invalid_Whence
	}
	n, errno := linux.lseek(f.fd, offset, linux.Seek_Whence(whence))
	#partial switch errno {
	case .EINVAL:
		return 0, .Invalid_Offset
	case .NONE:
		return n, nil
	case:
		return 0, _get_platform_error(errno)
	}
}
@(private = "file")
_get_platform_error :: proc(errno: linux.Errno) -> os.Error {
	#partial switch errno {
	case .NONE:
		return nil
	case .EPERM, .EACCES:
		return .Permission_Denied
	case .EEXIST:
		return .Exist
	case .ENOENT:
		return .Not_Exist
	case .ETIMEDOUT:
		return .Timeout
	case .EPIPE:
		return .Broken_Pipe
	case .EBADF:
		return .Invalid_File
	case .ENOMEM:
		return .Out_Of_Memory
	case .ENOSYS:
		return .Unsupported
	}

	return os.Platform_Error(i32(errno))
}

@(private = "file")
_fstat :: proc(f: ^os.File, allocator: runtime.Allocator) -> (os.File_Info, os.Error) {
	impl := (^File_Impl)(f.impl)
	return _fstat_internal(impl.fd, allocator)
}

@(private="file")
_fstat_internal :: proc(fd: linux.Fd, allocator: runtime.Allocator) -> (fi: os.File_Info, err: os.Error) {
	s: linux.Stat
	errno := linux.fstat(fd, &s)
	if errno != .NONE {
		return {}, _get_platform_error(errno)
	}
	type := os.File_Type.Regular
	switch s.mode & linux.S_IFMT {
	case linux.S_IFBLK:  type = .Block_Device
	case linux.S_IFCHR:  type = .Character_Device
	case linux.S_IFDIR:  type = .Directory
	case linux.S_IFIFO:  type = .Named_Pipe
	case linux.S_IFLNK:  type = .Symlink
	case linux.S_IFREG:  type = .Regular
	case linux.S_IFSOCK: type = .Socket
	}
	mode := transmute(os.Permissions)(0o7777 & transmute(u32)s.mode)

	// TODO: As of Linux 4.11, the new statx syscall can retrieve creation_time
	fi = os.File_Info {
		fullpath          = _get_full_path(fd, allocator) or_return,
		name              = "",
		inode             = u128(u64(s.ino)),
		size              = i64(s.size),
		mode              = mode,
		type              = type,
		modification_time = time.Time {i64(s.mtime.time_sec) * i64(time.Second) + i64(s.mtime.time_nsec)},
		access_time       = time.Time {i64(s.atime.time_sec) * i64(time.Second) + i64(s.atime.time_nsec)},
		creation_time     = time.Time{i64(s.ctime.time_sec) * i64(time.Second) + i64(s.ctime.time_nsec)}, // regular stat does not provide this
	}
	fi.creation_time = fi.modification_time
	_, fi.name = split_path(fi.fullpath)
	return
}

@(private="file")
_get_full_path :: proc(fd: linux.Fd, allocator: runtime.Allocator) -> (fullpath: string, err: os.Error) {
	PROC_FD_PATH :: "/proc/self/fd/"

	buf: [32]u8
	copy(buf[:], PROC_FD_PATH)

	strconv.write_int(buf[len(PROC_FD_PATH):], i64(fd), 10)

	if fullpath, err = _read_link_cstr(cstring(&buf[0]), allocator); err != nil || fullpath[0] != '/' {
		delete(fullpath, allocator)
		fullpath = ""
	}
	return
}

@(private = "file")
_read_link_cstr :: proc(name_cstr: cstring, allocator: runtime.Allocator) -> (string, os.Error) {
	bufsz: uint = 256
	buf := make([]byte, bufsz, allocator)
	for {
		sz, errno := linux.readlink(name_cstr, buf[:])
		if errno != .NONE {
			delete(buf, allocator)
			return "", _get_platform_error(errno)
		} else if sz == int(bufsz) {
			bufsz *= 2
			delete(buf, allocator)
			buf = make([]byte, bufsz, allocator)
		} else {
			return string(buf[:sz]), nil
		}
	}
}

@(private = "file")
split_path :: proc(path: string) -> (dir, file: string) {
	i := len(path) - 1
	for i >= 0 && !_is_path_separator(path[i]) {
		i -= 1
	}
	if i == 0 {
		return path[:i+1], path[i+1:]
	} else if i > 0 {
		return path[:i], path[i+1:]
	}
	return "", path
}

@(private = "file")
_Path_Separator :: '/'
@(private = "file")
_is_path_separator :: proc(c: byte) -> bool {
	return c == _Path_Separator
}

@(private = "file")
_destroy :: proc(f: ^File_Impl) -> os.Error {
	if f == nil {
		return nil
	}
	a := f.allocator
	err0 := delete(f.name, a)
	err1 := delete(f.buffer, a)
	err2 := free(f, a)
	err0 or_return
	err1 or_return
	err2 or_return
	return nil
}
