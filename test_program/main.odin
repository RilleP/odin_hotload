package small

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"
 
CONST_INT :: 420;
global_typed_int: i16;
global_typed_float: f32;
global_typed_float_with_value: f32 = 1.2;
global_int := 1;
global_float := 69.420; 
global_string := "Hellope";
global_pointer: ^int;
global_array := []int {1, 2, 3};
//global_func := foo;

aa : int;
bb : int;


TYPE :: int;
T :: int;
N :: 4;

Fruit :: enum { 
	BANANA = 1,
	STRAIGHT_BANANA,
	APPLE,
	ORANGE,
}

CONSTANT :: 1337;

A :: 0;
B :: 0;
C :: 0;
D :: 0;

x := 2;
a := 3;
b := 4;
@hotload run := proc() {
	/*A :: 1;
	foo :: proc() {
		x := A;
	}*/
	/*fmt.println(A, B);
	A :: 1
	foo :: proc() {
		fmt.println(A, B, C, D);
		C :: 1;
		fmt.println(A, B, C, D);		
		D :: 1;
		fmt.println(A, B, C, D);
	}
	foo();
	fmt.println(A, B);
	B :: 1;
	fmt.println(A, B);*/
	when !true {
		b := 1;
	}	
	else {
		//b := 1;
		b += 1; 
	}

	b += 3;
	fmt.println("b = ", b);

	/*a := x;
	fmt.println("a = ", a);
	a += 2;
	fmt.println("a = ", a); 

	foo :: proc() {
		//a :: 109;

		y := x;
		z := a;

		fmt.printf("foo: y = %v, z = %v\n", y, z);
	}

	//x :: 10;
	foo();*/
}


big_run :: proc() {
	//things : []Object;
	hello :: proc(v: ..int) {

	}
	Object :: struct #packed {
		data: int "this is a tag",
		method: proc(this: ^Object, x: int) -> int,
	}

	Kack :: struct #field_align(4) #align(8) {
		b: u8,
	}

	Array :: struct($T: typeid, $N: int) where N > 1, N < 10 {
		data: [N]T,
		using kack: Kack,
	}

	Banana_Sandwich :: struct #raw_union {
		data: ^int,
	}

	bs := Banana_Sandwich{nil}; 
	/*global_int += 1000;
	x := global_int;
	y := CONST_INT;
	z := global_typed_int;
	fmt.println("the glodbal intttteger omgg is ", x, z, foo()); */

	/*for ii in 0..<2 {
		fmt.println("the global pointer value is", (global_pointer^));
	}
	*/
	/*array : [5]f32;
	array[2] = 4.4;*/
	//flots : [3]f32;
	//yoo("heyo", ..array[:], flot = 3);

	/*bar :: proc(before: $T/[]$E) /*-> (v: T, ok := true)*/ {
		fmt.println(before);
	}

	bar (array[:]);

	o: Object;
	o.method = foo;
	x := o->method(1337);
	fmt.println(x);*/
	

	fruit: Fruit = .ORANGE;
	fruter: #partial switch fruit {
		case .BANANA, .STRAIGHT_BANANA:{
			fmt.println("Banananana");
			maybe(3) or_break
			break fruter;
		}
		case: 
			x := 4;
			fmt.println("Not banana", fruit);

	}

	fmt.println("yoo" if fruit == .BANANA else "what");
	fmt.println("yoo" when CONST_INT > 69 else "what");
	ma : matrix[4, 4]f32;
	fmt.println(ma[int(global_typed_int), global_int]);

	fmt.println("or_else = ", maybe(3) or_else 1337);

	y: int;
	y = auto_cast global_typed_int;

	Thing :: union #no_nil {
		int,
		f32,
	}

	thing: Thing;
	thing = 1337;
	thing_int := thing.(int);
	fmt.println("thing_int ", thing_int)
}


maybe :: proc(x: int) -> (r: int, ok: bool) {
	if x > 5 do return r, true;
	else do return 0, false;
}

/*@hotload aboo := proc(x: string = "hello", f: f32, n := 4, allocator := context.allocator) {

}

foo :: proc(this: ^Object, x: int) -> int {
	this.data = x;
	return 4;
}

yoo :: proc(x: string, args: ..int, flot: f32 = 3) {
	fmt.println(x, args);
}
*/
main :: proc() {
	global_pointer = &aa;
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
				global_typed_int += 1;
				aa += 3;
				run();		
			}
		}

		hotloader.stop();
	}
	else {
		run();
	}
}