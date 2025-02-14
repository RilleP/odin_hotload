package hotload_gen


is_built_in :: proc(name: string) -> bool {
	switch name {
		case "true": return true;
		case "false": return true;
		case "nil": return true;

		case "ODIN_OS": return true;
		case "ODIN_ARCH": return true;
		case "ODIN_ENDIAN": return true;
		case "ODIN_VENDOR": return true;
		case "ODIN_VERSION": return true;
		case "ODIN_ROOT": return true;
		case "ODIN_DEBUG": return true;
		
		case "byte": return true;

		case "bool": return true;
		case "b8": return true;
		case "b16": return true;
		case "b32": return true;
		case "b64": return true;

		case "i8": return true;
		case "u8": return true;
		case "i16": return true;
		case "u16": return true;
		case "i32": return true;
		case "u32": return true;
		case "i64": return true;
		case "u64": return true;

		case "i128": return true;
		case "u128": return true;

		case "rune": return true;

		case "f16": return true;
		case "f32": return true;
		case "f64": return true;

		case "complex32": return true;
		case "complex64": return true;
		case "complex128": return true;

		case "quaternion64": return true;
		case "quaternion128": return true;
		case "quaternion256": return true;

		case "int": return true;
		case "uint": return true;
		case "uintptr": return true;

		case "rawptr": return true;
		case "string": return true;
		case "cstring": return true;
		case "any": return true;

		case "typeid": return true;

		// Endian Specific Types
		case "i16le": return true;
		case "u16le": return true;
		case "i32le": return true;
		case "u32le": return true;
		case "i64le": return true;
		case "u64le": return true;
		case "i128le": return true;
		case "u128le": return true;

		case "i16be": return true;
		case "u16be": return true;
		case "i32be": return true;
		case "u32be": return true;
		case "i64be": return true;
		case "u64be": return true;
		case "i128be": return true;
		case "u128be": return true;


		case "f16le": return true;
		case "f32le": return true;
		case "f64le": return true;

		case "f16be": return true;
		case "f32be": return true;
		case "f64be": return true;

		// Procs
		case "len": return true; 
		case "cap": return true; 

		case "size_of": return true;      
		case "align_of": return true;     

		case "offset_of_selector": return true; 
		case "offset_of_member": return true;   
		case "offset_of": return true; 
		case "offset_of_by_string": return true; 

		case "type_of": return true;      
		case "type_info_of": return true; 
		case "typeid_of": return true;    

		case "swizzle": return true; 

		case "complex": return true;    
		case "quaternion": return true; 
		case "real": return true;       
		case "imag": return true;       
		case "jmag": return true;       
		case "kmag": return true;       
		case "conj": return true;       

		case "expand_values": return true; 

		case "min": return true;   
		case "max": return true;   
		case "abs": return true;   
		case "clamp": return true; 

		case "soa_zip": return true; 
		case "soa_unzip": return true; 


		case "determinant": return true;
		case "adjugate": return true;
		case "inverse_transpose": return true;
		case "inverse": return true;
		case "hermitian_adjoint": return true;
		case "matrix_trace": return true;
		case "matrix_minor": return true;
		case "matrix1x1_determinant": return true;
		case "matrix2x2_determinant": return true;
		case "matrix3x3_determinant": return true;
		case "matrix4x4_determinant": return true;
		case "matrix1x1_adjugate": return true;
		case "matrix2x2_adjugate": return true;
		case "matrix3x3_adjugate": return true;
		case "matrix4x4_adjugate": return true;
		case "matrix1x1_inverse_transpose": return true;
		case "matrix2x2_inverse_transpose": return true;
		case "matrix3x3_inverse_transpose": return true;
		case "matrix4x4_inverse_transpose": return true;
		case "matrix1x1_inverse": return true;
		case "matrix2x2_inverse": return true;
		case "matrix3x3_inverse": return true;
		case "matrix4x4_inverse": return true;
		case "raw_soa_footer_slice": return true;
		case "raw_soa_footer_dynamic_array": return true;
		case "make_soa_aligned": return true;
		case "make_soa_slice": return true;
		case "make_soa_dynamic_array": return true;
		case "make_soa_dynamic_array_len": return true;
		case "make_soa_dynamic_array_len_cap": return true;
		case "make_soa": return true;
		case "resize_soa": return true;
		case "reserve_soa": return true;
		case "append_soa_elem": return true;
		case "append_soa_elems": return true;
		case "append_soa": return true;
		case "delete_soa": return true;
		case "Maybe": return true;
		case "container_of": return true;
		case "init_global_temporary_allocator": return true;
		case "copy_slice": return true;
		case "copy_from_string": return true;
		case "copy": return true;
		case "unordered_remove": return true;
		case "ordered_remove": return true;
		case "remove_range": return true;
		case "pop": return true;
		case "pop_safe": return true;
		case "pop_front": return true;
		case "pop_front_safe": return true;
		case "clear": return true;
		case "reserve": return true;
		case "resize": return true;
		case "shrink": return true;
		case "free": return true;
		case "free_all": return true;
		case "delete_string": return true;
		case "delete_cstring": return true;
		case "delete_dynamic_array": return true;
		case "delete_slice": return true;
		case "delete_map": return true;
		case "delete": return true;
		case "new": return true;
		case "new_clone": return true;
		case "make_slice": return true;
		case "make_dynamic_array": return true;
		case "make_dynamic_array_len": return true;
		case "make_dynamic_array_len_cap": return true;
		case "make_map": return true;
		case "make_multi_pointer": return true;
		case "make": return true;
		case "raw_data": return true;
		case "clear_map": return true;
		case "reserve_map": return true;
		case "shrink_map": return true;
		case "delete_key": return true;
		case "append_elem": return true;
		case "append_elems": return true;
		case "append_elem_string": return true;
		case "append_string": return true;
		case "append": return true;
		case "append_nothing": return true;
		case "inject_at_elem": return true;
		case "inject_at_elems": return true;
		case "inject_at_elem_string": return true;
		case "inject_at": return true;
		case "assign_at_elem": return true;
		case "assign_at_elems": return true;
		case "assign_at_elem_string": return true;
		case "assign_at": return true;
		case "clear_dynamic_array": return true;
		case "reserve_dynamic_array": return true;
		case "resize_dynamic_array": return true;
		case "map_insert": return true;
		case "incl_elem": return true;
		case "incl_elems": return true;
		case "incl_bit_set": return true;
		case "excl_elem": return true;
		case "excl_elems": return true;
		case "excl_bit_set": return true;
		case "incl": return true;
		case "excl": return true;
		case "card": return true;
		case "assert": return true;
		case "panic": return true;
		case "unimplemented": return true;


		case: return false;
	}
}