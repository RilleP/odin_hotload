package small

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

add :: proc {
	add_int,
	add_float,
}

add_int :: proc(a,b: int) -> int {
	return a+b;
}

add_float :: proc(a, b: f32) -> f32 {
	return a+b;
}

foo :: proc(x: int) -> int {
	return x*x;
}

@hotload run := proc(x: int = 13) {	
	fmt.println(add(x, 3));
}

main :: proc() {
	DO_HOTLOADING :: true;
	when DO_HOTLOADING {
		did_reload_file :: proc(filepath: string, userdata: rawptr) {
			fmt.printf("Did reload file %s\n", filepath);
		}

		hotloader.start(hotload_procs, hotload_files, "../generator.exe");
		run();
		for {
			time.sleep(100 * time.Millisecond);
			if reload_result := hotloader.reload_if_changed(did_reload_file, nil); reload_result == .Failed_To_Reload {
				os.exit(1);
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