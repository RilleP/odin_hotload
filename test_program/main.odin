package small

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

COWABUNGA :: true;


Otherthing :: struct {
	y: f32,
}
Something :: struct {
	x: int,
}

x: Something;
when COWABUNGA {
	A :: true;
	s_in_when: Something;
}
else {
	when A {
		s_in_when: int;
	}
}


@hotload run := proc() {
	x.x = 5;
	when COWABUNGA {
		s_in_when.x = 3;
		fmt.printf("X = %d\n", s_in_when.x);
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