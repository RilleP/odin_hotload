package test2

import "core:time"
import "core:fmt"
import "core:strings"
import "core:c"
import "../../hotloader"
import "vendor:raylib"

@hotload foo := proc() -> (a, b: i32) {
	a = 100;
	b = 130;
	return;
}

@hotload draw_frame := proc() {
	raylib_DrawCircle(240, 140, 170, raylib.YELLOW);
	x, y := foo();
	raylib_DrawRectangle(x, y, 300, 100, raylib.GREEN);
	x += 130;
	y += 40;
	raylib_DrawRectangle(x, y, 100, 100, raylib.RED);
	x += 120;
	y += 120;
	raylib_DrawRectangle(x, y, 100, 1002, raylib.GREEN);
}


// Need to create wrappers, since raylib has global state. 
raylib_DrawRectangle :: proc(x, y, w, h: c.int, color: raylib.Color) {
	raylib.DrawRectangle(x, y, w, h, color);
}

raylib_DrawCircle :: proc(centerX, centerY: c.int, radius: f32, color: raylib.Color) {
	raylib.DrawCircle(centerX, centerY, radius, color);
}

main :: proc() {
	hotloader.start(hotload_procs, hotload_files, "../../generator.exe");
	defer hotloader.stop();

	raylib.InitWindow(640, 360, strings.clone_to_cstring("Hotloadeeed"));

	for !raylib.WindowShouldClose() {
		if reload_result := hotloader.reload_if_changed(nil, nil); reload_result == .Did_Reload {
			fmt.printf("Reloaded!\n");
		}
		raylib.ClearBackground(raylib.BLUE);
		raylib.BeginDrawing();
		draw_frame();
		
		raylib.EndDrawing();
	}
}