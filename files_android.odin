#+build linux
package engine

when ODIN_OS != .Linux do #panic("Cannot build android APKs on " + ODIN_OS + ". If you want to build Android APK using Windows, please try using WSL.")

import "base:runtime"

import "core:os"
import "core:io"
import "core:sync"
import "core:sys/linux"
import "core:time"
import "core:strconv"

import android "androidglue/ndkbindings"

open_android :: proc() {}

File_Impl :: struct {
	name: string,
	fd: linux.Fd,
	file: os.File,
	allocator: runtime.Allocator,

	buffer:   []byte,
	rw_mutex: sync.RW_Mutex, // read write calls
	p_mutex:  sync.Mutex, // pread pwrite calls
}
Android_File_Impl :: struct {
	using _: File_Impl,
	asset: 	^android.AAsset,
}

android_file_stream_proc : os.File_Stream_Proc : proc(stream_data: rawptr, mode: os.File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: os.Error) {
	data := cast(^Android_File_Impl)stream_data

	// Handle here like normal file
	return
}



























// NOTE:
// This is a local copy of the `_file_stream_buffered_proc` implementation and all needed linux procedures from `core:os`.
//
// RATIONALE:
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
@(private="file")
MAX_RW :: 1 << 30

@(private="file")
_file_stream_buffered_proc :: proc(stream_data: rawptr, mode: os.File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: os.Error) {
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
		err = _close(f)
		return
	case .Query:
		return io.query_utility({.Read, .Read_At, .Write, .Write_At, .Seek, .Size, .Flush, .Close, .Destroy, .Query})
	case .Fstat:
		err = file_stream_fstat_utility(f, p, allocator)
		return
	}
	return 0, .Unsupported
}

@(private="file")
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
@(private="file")
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

@(private="file")
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

	return
}

@(private="file")
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

@(no_sanitize_memory, private="file")
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

@(private="file")
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

@(private="file")
_close :: proc(f: ^File_Impl) -> os.Error {
	if f == nil{
		return nil
	}
	errno := linux.close(f.fd)
	if errno == .EBADF { // avoid possible double free
		return _get_platform_error(errno)
	}
	_destroy(f)
	return _get_platform_error(errno)
}
@(private="file")
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
@(private="file")
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

@(private="file")
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

@(private="file")
_read_link_cstr :: proc(name_cstr: cstring, allocator: runtime.Allocator) -> (string, os.Error) {
	bufsz : uint = 256
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

@(private="file")
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

@(private="file")
_Path_Separator        :: '/'
@(private="file")
_is_path_separator :: proc(c: byte) -> bool {
	return c == _Path_Separator
}

@(private="file")
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
