package global_variables

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"


Fruit :: enum {
	BANANA,
	APPLE,
}

Foo :: struct {
	x: Fruit,
	y: int,
	bar: Bar,
}

Bar :: struct {
	z: int,
}


SHOULD_NOT_BE_REFERENCED :: 1337;
foo := Foo {
	x = .BANANA,
	y = SHOULD_NOT_BE_REFERENCED,
}

Array_Element_Type :: int;

Global_Enum :: enum {
	A,
	B,
}

global_enum := Global_Enum.B;
global_array := [10]Array_Element_Type {
	3 = SHOULD_NOT_BE_REFERENCED
}


SHOULD_NOT_BE_REFERENCED_1 :: 1337;
SHOULD_NOT_BE_REFERENCED_2 :: 1337;

INT_1 :: int;
INT_2 :: int;

global_int: INT_1 = SHOULD_NOT_BE_REFERENCED_1;
global_int2 := INT_2(SHOULD_NOT_BE_REFERENCED_2);


MY_INT :: int;

a := MY_INT(3);

SHOULD_BE_REFFED :: 420;

@hotload run := proc() {
	foo.x = .APPLE//BAR.x;
	a = 3;
	global_array[2] = 2;
	fmt.printf("index 3 = %d\n", global_array[3]);
	fmt.printf("global enum = %v\n", global_enum);

	local_foo := Foo {
		x = .APPLE,
		bar = {
			z = global_int,
		},
	}

	global_int2 = 7;
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
				fmt.printf("CHEESE\n");
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