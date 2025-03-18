package small

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

COWABUNGA :: true;

Something :: struct {
	x: int,
}

Otherthing :: struct {
	y: f32,
}

when COWABUNGA {
	s: Something;
}
else {
	s: Something;
}


@hotload run := proc() {
	when COWABUNGA {
		s.x = 3;
	}
	else {
		s.y = 3.0;
	}
}

main :: proc() {
	DO_HOTLOADING :: true;
	when DO_HOTLOADING {
		did_reload_file :: proc(filepath: string, userdata: rawptr) {
			fmt.printf("Did reload file %s\n", filepath);
		}

		hotloader.start(hotload_procs, hotload_files, "../generator.exe", 
			additional_cmd_line_args=hotload_create_defines_command_line_arguments(context.temp_allocator));

		run();
		for {
			time.sleep(100 * time.Millisecond);
			if reload_result := hotloader.reload_if_changed(did_reload_file, nil); reload_result == .Failed_To_Reload {
				fmt.printf("Failed to reload\n");
				//os.exit(1);
			}
			else if reload_result == .Did_Reload {
				run();		
			}
		}

		hotloader.stop();
	}
	else {
		run();
	}
}