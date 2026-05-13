package obj

/*********************************************

IMPORTANT INFO:

OBJ parser, for now, is restricted to TRIANGULATED MESHES ONLY
I'll probably add triangulation in future, if I won't implement parsing gltf, but for now I'm sticking to this.

**********************************************/

import "base:runtime"

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Only compatabile for triangles
Triangle_Face :: struct {
	vertices_indexes: [3]int,
	normals_indexes:  [3]int,
	uvs_indexes:      [3]int,
}

vec2 :: [2]f32
vec3 :: [3]f32

Mesh :: struct {
	faces:    [dynamic]Triangle_Face,
	vertices: [dynamic]vec3,
	normals:  [dynamic]vec3,
	uvs:      [dynamic]vec2,
}

Vertex :: struct {
	position: vec3,
	normals:  vec3,
	uv:       vec2,
}

Error :: enum {
	FAILED_TO_READ_FILE,
	FAILED_TO_PARSE_DATA,
	UNEXPECTED_FILE_FORMATTING,
	PARSING_FLOW_ERROR,
}

/*
For now there is support ONLY for already triangulated meshes.
*/
load_mesh :: proc(
	file: ^os.File,
	allocator: runtime.Allocator = context.allocator,
) -> (
	Mesh,
	Error,
) {
	faces := make([dynamic]Triangle_Face, allocator)
	vertices := make([dynamic]vec3, allocator)
	normals := make([dynamic]vec3, allocator)
	uvs := make([dynamic]vec2, allocator)

	file_data, err := os.read_entire_file_from_file(file, allocator)
	if err != nil do return {}, .FAILED_TO_READ_FILE
	defer delete(file_data, allocator)

	// it's an alias, so no need to delete memory
	data := string(file_data)

	string_available := true
	line: string
	for string_available {
		line, string_available = strings.split_lines_iterator(&data)
		if !string_available do break
		if line == "" || len(line) <= 0 do continue

		switch line[0] {
		case '#':
			continue
		case 'v':
			// I assume that there will be no empty values, and spaces are exactly one lenght
			if len(line) <= 1 do return {}, .UNEXPECTED_FILE_FORMATTING
			if line[1] == 't' {
				vec, err := read_vertices_from_line_vec2(line)
				if err != nil do return {}, err

				append(&uvs, vec)
			} else if line[1] == 'n' {
				vec, err := read_vertices_from_line_vec3(line, 2)
				if err != nil do return {}, err

				append(&normals, vec)
			} else if line[1] == ' ' {
				vec, err := read_vertices_from_line_vec3(line, 1)
				if err != nil do return {}, err

				append(&vertices, vec)
			} else do return {}, .UNEXPECTED_FILE_FORMATTING
		case 'f':
			face, err := read_face(line)
			if err != nil do return {}, err

			append(&faces, face)
		case:
			continue
		}
	}
	return {faces = faces, normals = normals, vertices = vertices, uvs = uvs}, nil
}

/*
You can clean up mesh data manually, or use given procedure. Dynamic arrays do remember their allocators so you can go both ways.
*/
destroy_mesh :: proc(mesh: ^Mesh) {
	delete(mesh.faces)
	delete(mesh.vertices)
	delete(mesh.normals)
	delete(mesh.uvs)
}


/**********************************************

Since OBJ format stores vertices data as ASCII, operating on bytes instead of runes makes more sense.
However I'm not sure if there are cases when that is incorrect approach, if I'll get knowledge about that, the code will change.

**********************************************/


@(private)
read_vertices_from_line_vec2 :: proc(line: string) -> (vec2, Error) {
	vec: vec2
	vertex := make([dynamic]byte)
	counter := 0
	defer delete(vertex)
	// iteration as bytes, starting from second index assuming that line beggins with 'vt'
	// this assumption MIGHT be wrong, I'm not sure if all OBJs will work that way
	for index in 2 ..< len(line) {
		// I don't know if tabs are allowed in OBJ, but it won't hurt I guess
		if line[index] == ' ' ||
		   line[index] == '\t' ||
		   line[index] == '\n' ||
		   index == len(line) - 1 {
			if line[index] != ' ' && line[index] != '\t' && line[index] != '\n' do append(&vertex, line[index])
			if len(vertex) == 0 do continue
			v, success := strconv.parse_f32(string(vertex[:]))
			if !success do return vec, .FAILED_TO_PARSE_DATA
			if counter == 0 {
				vec[counter] = v
				clear(&vertex)
				counter += 1
			} else if counter == 1 {
				vec[counter] = v
				clear(&vertex)
				counter += 1
			} else do return vec, .PARSING_FLOW_ERROR
		} else if line[index] == '\n' do break
		else do append(&vertex, line[index])

		if counter >= 2 do break
	}
	return vec, nil
}


@(private)
read_vertices_from_line_vec3 :: proc(line: string, start_index: int) -> (vec3, Error) {
	vec: vec3
	counter := 0
	vertex := make([dynamic]byte)
	defer delete(vertex)
	// iteration as bytes, starting from passed index assuming that line beggins with 'vn' or 'v' is checked before function is called
	for index in start_index ..< len(line) {
		// I don't know if tabs are allowed in OBJ, but it won't hurt I guess
		if line[index] == ' ' ||
		   line[index] == '\t' ||
		   line[index] == '\n' ||
		   index == len(line) - 1 {
			if line[index] != '\n' && line[index] != ' ' && line[index] == '\t' do append(&vertex, line[index])
			if len(vertex) == 0 do continue
			v, success := strconv.parse_f32(string(vertex[:]))
			if !success do return vec, .FAILED_TO_PARSE_DATA
			if counter == 0 {
				vec[counter] = v
				clear(&vertex)
				counter += 1
			} else if counter == 1 {
				vec[counter] = v
				clear(&vertex)
				counter += 1
			} else if counter == 2 {
				vec[counter] = v
				clear(&vertex)
				counter += 1
			} else do return vec, .PARSING_FLOW_ERROR
		} else do append(&vertex, line[index])

		if counter >= 3 do break
	}
	return vec, nil
}

@(private)
read_face :: proc(line: string) -> (Triangle_Face, Error) {
	face: Triangle_Face
	face_indexes := make([dynamic]byte)
	defer delete(face_indexes)
	indexes: [3]int
	vertex_counter := 0
	value_counter := 0

	// iteration as bytes, starting from index 1 assuming that line beggins with 'f'
	for index in 1 ..< len(line) {
		// I don't know if tabs are allowed in OBJ, but it won't hurt I guess
		if line[index] == ' ' ||
		   line[index] == '\t' ||
		   line[index] == '\n' ||
		   index == len(line) - 1 {
			if line[index] != '\n' && line[index] != '\t' && line[index] != ' ' do append(&face_indexes, line[index])
			if len(face_indexes) <= 0 do continue
			else {
				value, success := strconv.parse_int(string(face_indexes[:]))
				if !success do return face, .FAILED_TO_PARSE_DATA

				if value_counter == 0 {
					indexes[value_counter] = value - 1
					value_counter += 1
				} else if value_counter == 1 {
					indexes[value_counter] = value - 1
					value_counter += 1
				} else if value_counter == 2 {
					indexes[value_counter] = value - 1
					value_counter += 1
				} else do return face, .PARSING_FLOW_ERROR
				clear(&face_indexes)
			}
		} else if line[index] == '/' {
			// This shouldn't happen, because I'm assuming that in a correctly formatted file there is no '/' after third number
			if value_counter >= 3 do return face, .UNEXPECTED_FILE_FORMATTING
			// This shouldn't happen either, I'm assuming that no face will beign with '/'
			if len(face_indexes) <= 0 do return face, .UNEXPECTED_FILE_FORMATTING

			value, success := strconv.parse_int(string(face_indexes[:]))
			if !success do return face, .FAILED_TO_PARSE_DATA

			// OBJ indexes begin at 1, AFAIK, so decrementing them is what is needed
			if value_counter == 0 {
				indexes[value_counter] = value - 1
				value_counter += 1
			} else if value_counter == 1 {
				indexes[value_counter] = value - 1
				value_counter += 1
			} else if value_counter == 2 {
				indexes[value_counter] = value - 1
				value_counter += 1
			} else do return face, .PARSING_FLOW_ERROR
			clear(&face_indexes)
		} else do append(&face_indexes, line[index])

		if value_counter == 3 {
			if vertex_counter == 0 {
				face.vertices_indexes[vertex_counter] = indexes[0]
				face.uvs_indexes[vertex_counter] = indexes[1]
				face.normals_indexes[vertex_counter] = indexes[2]
				vertex_counter += 1
			} else if vertex_counter == 1 {
				face.vertices_indexes[vertex_counter] = indexes[0]
				face.uvs_indexes[vertex_counter] = indexes[1]
				face.normals_indexes[vertex_counter] = indexes[2]
				vertex_counter += 1
			} else if vertex_counter == 2 {
				face.vertices_indexes[vertex_counter] = indexes[0]
				face.uvs_indexes[vertex_counter] = indexes[1]
				face.normals_indexes[vertex_counter] = indexes[2]
				vertex_counter += 1
			} else do return face, .PARSING_FLOW_ERROR
			value_counter = 0
		}

		if vertex_counter >= 3 do break
	}
	return face, nil
}

//TODO: For smaller meshes it works, but If we're going to load larger we're going to need something other than temp_allocator
bake_mesh :: proc(
	mesh: Mesh,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	vertices: []Vertex,
	indices: []u32,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	unique_vertices := make(map[Vertex]u32, temp_allocator)
	dyn_vertices := make([dynamic]Vertex, temp_allocator)
	dyn_indices := make([dynamic]u32, temp_allocator)


	for face in mesh.faces {
		for i in 0 ..< 3 {
			v := Vertex {
				position = mesh.vertices[face.vertices_indexes[i]],
				normals  = mesh.normals[face.normals_indexes[i]],
				// for translation to top to bottom
				uv       = {
					mesh.uvs[face.uvs_indexes[i]][0],
					1 - mesh.uvs[face.uvs_indexes[i]][1],
				},
			}

			idx, ok := unique_vertices[v]
			if !ok {
				idx = cast(u32)len(dyn_vertices)
				append(&dyn_vertices, v)
				unique_vertices[v] = idx
			}

			append(&dyn_indices, idx)
		}
	}

	vertices = slice.clone(dyn_vertices[:], allocator)
	indices = slice.clone(dyn_indices[:], allocator)
	return
}
