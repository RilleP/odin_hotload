#+private
package hotloader

import "core:sys/windows"
import "core:os"
import "core:unicode/utf16"
import "core:slice"
import "core:fmt"
import "core:sync"

string_to_wcstr :: proc(s: string) -> []windows.WCHAR {
	result := make([]windows.WCHAR, len(s)+1);
	for c, index in s {
		result[index] = cast(windows.WCHAR)c;
	}
	result[len(s)] = 0;
	return result;
}

run_process :: proc(command: string) -> int {
	compile_cmd := raw_data(string_to_wcstr(command));
	si: windows.STARTUPINFOW;
	si.cb = size_of(si);
	pi: windows.PROCESS_INFORMATION;

	success := windows.CreateProcessW(
		nil,
		compile_cmd,
		nil, //lpProcessAttributes: LPSECURITY_ATTRIBUTES,
		nil, //lpThreadAttributes: LPSECURITY_ATTRIBUTES,
		false, //bInheritHandles: BOOL,
		0, //dwCreationFlags: DWORD,
		nil, //lpEnvironment: LPVOID,
		nil, //lpCurrentDirectory: LPCWSTR,
		&si,
		&pi,
	);
	if !success {
		 error := windows.GetLastError();
		 fmt.printf("Failed to create process '%s' with error = %v\n", command, error);
	}
	
	// Wait until child process exits.
    windows.WaitForSingleObject( pi.hProcess, windows.INFINITE );
    exit_code: windows.DWORD;
    if !windows.GetExitCodeProcess(pi.hProcess, &exit_code) {
    	fmt.printf("Failed to get exit code for process.\n");
    }

    // Close process and thread handles. 
    windows.CloseHandle( pi.hProcess );
    windows.CloseHandle( pi.hThread );

    return cast(int)exit_code;
}

reload_lib_thread_proc :: proc() {
	dir_path := target_package_path;
	dir_handle := windows.CreateFileW(
		raw_data(string_to_wcstr(dir_path)),
		windows.GENERIC_READ,
        windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
        nil,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS,
        nil
	);
	if dir_handle == nil {
		fmt.printf("Failed to open reload lib directory for change watching\n");
		return;
	}

	for {
		buffer: [size_of(windows.FILE_NOTIFY_INFORMATION)*128]u8;
	    bytes_returned: windows.DWORD;
	    if !windows.ReadDirectoryChangesW(
	      dir_handle,
	      raw_data(buffer[:]),
	      size_of(buffer),
	      true,
	      windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
	      &bytes_returned,
	      nil,
	      nil,
	    ) {
	    	fmt.printf("Failed to ReadDirectoryChanges. Error: %d\n", windows.GetLastError());
	    	break;
	    }
    	sync.mutex_lock(&mutex);
    	defer sync.mutex_unlock(&mutex);
	    for byte_offset :u32= 0; byte_offset < bytes_returned; {
	    	fni := cast(^windows.FILE_NOTIFY_INFORMATION)&buffer[byte_offset];
	    	utf8_buffer: [512]u8;
	    	utf8_length := utf16.decode_to_utf8(utf8_buffer[:], slice.from_ptr(&fni.file_name[0], cast(int)fni.file_name_length/2));
	    	file_name := transmute(string)utf8_buffer[:utf8_length];

	    	for &hotload_file in hotload_files {
		    	if file_name == hotload_file.file_name {
			    	new_last_write_time, write_time_error := os.last_write_time_by_name(fmt.tprintf("%s\\%s", dir_path, file_name));
			    	if write_time_error != os.ERROR_NONE {
			    		fmt.printf("Failed to get write time for %s. Error = %d\n", file_name, write_time_error);
			    	}
			    	else {
				    	//fmt.printf("File: %s, changed %v\n", file_name, new_last_write_time);
				    	if new_last_write_time > hotload_file.last_change_time {
				    		hotload_file.last_change_time = new_last_write_time;
				    		hotload_file.has_changed = true;
				    		//fmt.printf("File: %s, changed %v\n", file_name, new_last_write_time);
				    		lib_src_has_changed = true;
				    	}
			    	}
			    	break;
		    	}
	    	}

	    	
	    	byte_offset += fni.next_entry_offset;
	    	if fni.next_entry_offset == 0 {
	    		break;
	    	}
	    }
	}
}