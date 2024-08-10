package big

import "core:fmt"
import "core:time"
import "core:os"
import "../hotloader"

BF_Backing :: u32;
BF_A_Type :: u8;
BF_A_N :: 4;

Bit_Field :: bit_field BF_Backing {
	a: BF_A_Type|BF_A_N,
	b: u32|20
}
@hotload run_bit_fields := proc() {	
	field: Bit_Field;
	field.a = 3;
	a := field.a;
	field.b = 19999;
	fmt.println("Bit Field", size_of(a), a, field.b);
}