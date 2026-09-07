package zsearch

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/windows"
import "core:time"
import r "vendor:raylib"

HEIGHT :: 300
WIDTH :: 1200
MAX_CHARS :: 20
FONT_SIZE_STEP :: 4
DRAW_WINDOW :: false

WindowState :: struct {
	font_size:            c.int,
	input_string_builder: strings.Builder,
	cursor_index:         u32,
}

// The record returned by FSCTL_ENUM_USN_DATA
USN_RECORD_V2 :: struct {
	RecordLength:              u32,
	MajorVersion:              u16,
	MinorVersion:              u16,
	FileReferenceNumber:       u64, // The MFT ID of this file
	ParentFileReferenceNumber: u64, // The MFT ID of the folder containing this
	Usn:                       i64,
	TimeStamp:                 i64,
	Reason:                    u32,
	SourceInfo:                u32,
	SecurityId:                u32,
	FileAttributes:            u32,
	FileNameLength:            u16,
	FileNameOffset:            u16,
	FileName:                  [1]u16, // Start of the UTF-16 string
}

// The input buffer for FSCTL_ENUM_USN_DATA
MFT_ENUM_DATA_V0 :: struct {
	StartFileReferenceNumber: u64,
	LowUsn:                   i64,
	HighUsn:                  i64,
}

File_Entry :: struct {
	file_id:   u64,
	parent_id: u64,
	name:      String_H, // points to a place in the string pool
}

Search_Index :: struct {
	files: [dynamic]File_Entry,
	names: [dynamic]u8,
}

String_H :: struct {
	offset: int,
	len:    int,
}

string_from_handle :: proc(handle: String_H, buffer: []u8) -> string {
	return string(buffer[handle.offset:handle.offset + handle.len])
}

/*
return true if the whole query found
in the exact order in the target.
*/
fuzzy_search :: proc(target: string, query: string) -> bool {
	if len(query) == 0 do return false
	if len(target) < len(query) do return false

	t_ind := 0
	q_ind := 0

	for t_ind < len(target) && q_ind < len(query) {
		t_char: u8 = target[t_ind]
		q_char: u8 = query[q_ind]

		if t_char == q_char {
			q_ind += 1
		}

		t_ind += 1
	}

	return len(query) == q_ind
}

control_keys :: proc(ws: ^WindowState) {
	if r.IsKeyDown(.LEFT_CONTROL) {
		if r.IsKeyPressed(.EQUAL) {
			ws.font_size += FONT_SIZE_STEP
		}
		if r.IsKeyPressed(.MINUS) {
			ws.font_size -= FONT_SIZE_STEP
		}
	}

	if (r.IsKeyPressed(.BACKSPACE) || r.IsKeyPressedRepeat(.BACKSPACE)) && ws.cursor_index > 0 {
		ordered_remove(&ws.input_string_builder.buf, ws.cursor_index - 1)
		ws.cursor_index -= 1
		fmt.printfln("Cursor index: %d", ws.cursor_index)
	}

	if (r.IsKeyPressed(.LEFT) || r.IsKeyPressedRepeat(.LEFT)) && ws.cursor_index > 0 {
		ws.cursor_index -= 1
		fmt.printfln("Cursor index: %d", ws.cursor_index)
	}

	if (r.IsKeyPressed(.RIGHT) || r.IsKeyPressedRepeat(.RIGHT)) &&
	   int(ws.cursor_index) < len(ws.input_string_builder.buf) {
		ws.cursor_index += 1
		fmt.printfln("Cursor index: %d", ws.cursor_index)
	}
}

init_window_state :: proc() -> WindowState {
	return WindowState{48, strings.builder_make(), 0}
}

load_disk :: proc(index: ^Search_Index) {
	hd := windows.CreateFileW(
		windows.L("\\\\.\\C:"),
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		nil,
	)
	if hd == windows.INVALID_HANDLE_VALUE {
		err := windows.GetLastError()
		fmt.printfln("Failed to open a file: %d", err)
		return
	}

	fmt.printfln("Opened a file: %p", hd)

	med: MFT_ENUM_DATA_V0
	med.StartFileReferenceNumber = 0
	med.LowUsn = 0
	med.HighUsn = 9223372036854775807 // Max i64

	//buffer: [65536]u8 // 64kb
	buffer: []u8 = make([]u8, 1024 * 1024) // 1mb
	bytes_returned: u32
	bytes_total: u32
	record_count: u32 = 0
	first_tick := time.tick_now()
	//index_names_offset := 0

	//reserve(&index.names, 64 * 1024 * 1024)
	//reserve(&index.files, 1000000)

	for {
		ok := windows.DeviceIoControl(
			hd,
			0x000900b3, // FSCTL_ENUM_USN_DATA
			&med,
			size_of(med),
			&buffer[0],
			u32(len(buffer)),
			&bytes_returned,
			nil,
		)

		if !ok || bytes_returned < 8 do break
		//fmt.printfln("USN DATA BYTES RETURNED: %d", bytes_returned)
		bytes_total += bytes_returned

		next_id := (^u64)(&buffer[0])^
		//fmt.printfln("NEXT ID: %p", next_id)

		offset := u32(8)
		for offset < bytes_returned {
			record := (^USN_RECORD_V2)(&buffer[offset])

			name_ptr := ([^]u16)(&buffer[offset + u32(record.FileNameOffset)])
			name_len := record.FileNameLength / 2

			name_odin, err := windows.utf16_to_utf8(name_ptr[:name_len], context.temp_allocator)

			file_entry := File_Entry{}
			file_entry.file_id = record.FileReferenceNumber
			file_entry.parent_id = record.ParentFileReferenceNumber

			start_idx := len(index.names)

			append(&index.names, ..transmute([]u8)name_odin)

			end_idx := len(index.names)

			file_entry.name = String_H {
				offset = start_idx,
				len    = end_idx - start_idx,
			}

			append(&index.files, file_entry)

			offset += record.RecordLength
			record_count += 1
		}

		med.StartFileReferenceNumber = next_id
	}

	delete(buffer)

	elapsed := time.tick_diff(first_tick, time.tick_now())
	seconds := time.duration_seconds(elapsed)

	fmt.printfln("Total Time: %2f", seconds)
	fmt.printfln("Record Count: %d", record_count)
	fmt.printfln("Records/Per Second: %2f", f64(record_count) / seconds)
	fmt.printfln("Total MB: %d", bytes_total / 1000000)
	fmt.printfln("File Entries Size: %d", len(index.files))
	fmt.printfln("File Names Size: %d", len(index.names))
	fmt.printfln("Random File ID: %d", index.files[26412].file_id)
	fmt.printfln("Random File Name: %s", index.files[26412].name)
}

main :: proc() {

	index := Search_Index{}
	index.files = make([dynamic]File_Entry)
	defer delete(index.files)
	index.names = make([dynamic]u8)
	defer delete(index.names)
	load_disk(&index)

	for i in 0 ..< len(index.files) {
		file_entry := index.files[i]
		if fuzzy_search(string_from_handle(file_entry.name, index.names[:]), "bashrc") {
			fmt.printfln("file id: %d", file_entry.file_id)
			fmt.printfln("file name: %s", index.names[file_entry.name.offset])
		}
	}
	fmt.printfln("GOT HERE!")

	if DRAW_WINDOW {
		ws := init_window_state()


		r.SetConfigFlags({.WINDOW_UNDECORATED})
		r.InitWindow(WIDTH, HEIGHT, "Search")

		font := r.GetFontDefault()
		spacing := f32(2)

		for !r.WindowShouldClose() {
			control_keys(&ws)

			key: rune = r.GetCharPressed()

			for key > 0 {
				if len(ws.input_string_builder.buf) < MAX_CHARS {
					strings.write_rune(&ws.input_string_builder, key)
					ws.cursor_index += 1
				}
				key = r.GetCharPressed()
			}


			r.BeginDrawing()

			r.ClearBackground(r.Color{0x2b, 0x36, 0x3a, 0xFF})

			current_str: string = strings.to_string(ws.input_string_builder)
			current_cstr: cstring = strings.clone_to_cstring(current_str, context.temp_allocator)
			r.DrawTextEx(font, current_cstr, {50, 50}, f32(ws.font_size), spacing, r.WHITE)

			text_size: r.Vector2 = r.MeasureTextEx(
				font,
				strings.clone_to_cstring(current_str[:ws.cursor_index]),
				f32(ws.font_size),
				spacing,
			)
			r.DrawLineEx(
				{50 + text_size.x + 4, 50},
				{50 + text_size.x + 4, 50 + text_size.y},
				f32(4),
				r.BLACK,
			)


			r.EndDrawing()

			free_all(context.temp_allocator)
		}

		r.CloseWindow()
	}

}
