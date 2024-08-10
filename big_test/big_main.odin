package big

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

@hotload run := proc() {	
	run_bit_fields();
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