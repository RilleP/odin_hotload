package small

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

color_srgb :: proc(r, g, b, a: f32) -> [4]f32 {
	return {r, g, b, a};
}

blue : [4]f32 = color_srgb(0.1, 0.12, 0.94, 1.0);

red := color_srgb(1.0, 0.1, 0.1, 1.0); // Not used so its ok to not specify type

@hotload run := proc() {
	fmt.printf("Blued is %v\n", blue);
	fmt.printf("Red is %v\n", red);
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