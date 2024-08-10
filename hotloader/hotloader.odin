package hotloader

import "core:time"
import "core:thread"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:strings"

hot_lib: dynlib.Library;
Proc_Type :: #type proc() -> int;
the_proc: Proc_Type;

Loader_Proc :: #type proc(dynlib.Library) -> bool;
the_loader_proc: Loader_Proc;

Reloaded_File_Proc :: #type proc(filepath: string, userdata: rawptr);

DLL_OUTPUT_PATH :: "hotload_generated_code/generated.dll";
LOADED_DLL_PATH :: "hotload_generated_code/loaded.dll"


Reload_Result :: enum {
	Did_Not_Need_To,
	Did_Reload,
	Failed_To_Reload,
}

reload_hot_lib :: proc() -> bool {
	if !regenerate_code() {
		fmt.printf("Reload failed. Failed to regenerate.\n");
		return false;
	}
	if !recompile_hot_lib() {
		fmt.printf("Reload failed. Failed to compile.\n");
		return false;
	}
	
	if hot_lib != nil {
		dynlib.unload_library(hot_lib);
		hot_lib = nil;
	}
	if os.exists(DLL_OUTPUT_PATH) {
		if os.rename(DLL_OUTPUT_PATH, LOADED_DLL_PATH) != os.ERROR_NONE {
			fmt.printf("Failed to rename dll file\n");
			return false;
		}
	}
	hot, did_load := dynlib.load_library(LOADED_DLL_PATH);
	if !did_load {
		fmt.printf("Failed to load hot\n");
		return false;
	}
	if !the_loader_proc(hot) {
		return false;
	}
	
	hot_lib = hot;
	return true;
}

regenerate_code :: proc() -> bool {
	command := fmt.tprintf("%s %s -lib", lib_generator_exe_path, target_package_path);
	exit_code := run_process(command);
	fmt.printf("Regenerate Process finished with exit_code %d\n", exit_code);
    return exit_code == 0;
}

recompile_hot_lib :: proc() -> bool {
	show_timings := .SHOW_LIB_COMPILE_TIMINGS in flags;
	command := fmt.tprintf("odin build hotload_generated_code/code.odin -file -out:%s -build-mode:shared -ignore-unknown-attributes %s %s %s", 
		DLL_OUTPUT_PATH, 
		"-show-timings" if show_timings else "", 
		"-debug"        when ODIN_DEBUG else "",
		lib_generator_additional_cmd_line_args);

	exit_code := run_process(command);
	fmt.printf("Recompile finished with exit_code %d\n", exit_code);
    return exit_code == 0;
}

lib_src_has_changed: b8;
reload_lib_thread: ^thread.Thread;
target_package_path: string;
hotload_files: []Hotload_File;
mutex: sync.Mutex;
is_running := false;

Flag :: enum {
	SHOW_LIB_COMPILE_TIMINGS,
}
flags: bit_set[Flag];

Hotload_File :: struct {
	file_name: string,
	has_changed: bool,
	last_change_time: os.File_Time,
}

lib_generator_exe_path: string;
lib_generator_additional_cmd_line_args: string;
start :: proc(loader_proc: Loader_Proc, file_names: []string, generator_exe_path: string, additional_cmd_line_args: string = "", location := #caller_location) {
	assert(!is_running);
	is_running = true;
	dir, file := filepath.split(location.file_path);
	working_dir := os.get_current_directory(context.temp_allocator);
	target_path, relative_error := filepath.rel(working_dir, dir);
	if relative_error != .None {
		target_package_path = strings.clone(dir); 
	}
	else {
		target_package_path = strings.clone(target_path);
	}
	//fmt.printf("Working dir: %s\n", working_dir);
	//fmt.printf("Target package path: %s, dir: %s\n", target_package_path, dir);
	lib_generator_exe_path = fmt.aprint(target_package_path, generator_exe_path, sep=filepath.SEPARATOR_STRING);
	lib_generator_additional_cmd_line_args = strings.clone(additional_cmd_line_args);
	hotload_files = make([]Hotload_File, len(file_names));
	for file_name, index in file_names {
		hotload_files[index] = {
			file_name,
			false,
			0,
		};
	}
	the_loader_proc = loader_proc;
	when false {
		// Reload on startup, just for testing
		if !reload_hot_lib() {
			os.exit(1);
		}
	}
	reload_lib_thread = thread.create_and_start(reload_lib_thread_proc);
}

reload_if_changed :: proc(reloaded_file_proc: Reloaded_File_Proc, reloaded_file_proc_userdata: rawptr) -> (result: Reload_Result) {
	if lib_src_has_changed {
		sync.mutex_lock(&mutex);
		defer sync.mutex_unlock(&mutex);

		success := reload_hot_lib();
		if success {
			if reloaded_file_proc != nil {
				for &hotload_file in hotload_files {
					if hotload_file.has_changed {
						reloaded_file_proc(hotload_file.file_name, reloaded_file_proc_userdata);
						hotload_file.has_changed = false;
					}
				}
			}
			result = .Did_Reload;
		}
		else {
			result = .Failed_To_Reload;
		}

		lib_src_has_changed = false;
	}
	else {
		result = .Did_Not_Need_To;
	}
	return;
}

stop :: proc(do_unload_library := false) {
	assert(is_running);
	is_running = false;
	if do_unload_library && hot_lib != nil {
		dynlib.unload_library(hot_lib)
	}

	free(raw_data(target_package_path));
	free(raw_data(lib_generator_exe_path));
	delete(hotload_files);

	thread.terminate(reload_lib_thread, 0);
}