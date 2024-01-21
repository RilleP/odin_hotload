package hotload_gen
/*
import "core:odin/ast"
import "core:strings"
import "core:fmt"

write_expression :: proc(sb: ^strings.Builder, expression: ^ast.Expr, is_type: bool = false, is_call: bool = false) {
	#partial switch derived in expression.derived_expr {
		case ^ast.Basic_Lit: {
			strings.write_string(sb, derived.tok.text);
		}
		case ^ast.Ident: {
			/*if (is_type || is_call) && !is_built_in(derived.name) {
				strings.write_string(sb, "MAIN.");
			}*/								
			strings.write_string(sb, derived.name);
		}
		case ^ast.Binary_Expr: {
			write_expression(sb, derived.left);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.op.text);
			strings.write_byte(sb, ' ');
			write_expression(sb, derived.right);
		}
		case ^ast.Selector_Expr: {
			write_expression(sb, derived.expr);
			strings.write_string(sb, derived.op.text);
			strings.write_string(sb, derived.field.name);
		}
		case ^ast.Call_Expr: {
			//strings.write_string(sb, "?()");								
			write_expression(sb, derived.expr, is_call=true);
			strings.write_byte(sb, '(');
			for arg, arg_index in derived.args {
				if arg_index > 0 do strings.write_string(sb, ", ");
				write_expression(sb, arg);
			}	
			strings.write_byte(sb, ')');
		}
		case ^ast.Type_Cast: {
			strings.write_string(sb, derived.tok.text);
			strings.write_byte(sb, '(');
			write_expression(sb, derived.type, is_type=true);
			strings.write_byte(sb, ')');
			write_expression(sb, derived.expr);
		}
		case ^ast.Paren_Expr: {
			strings.write_byte(sb, '(');
			write_expression(sb, derived.expr);
			strings.write_byte(sb, ')');
		}
		
		case ^ast.Bad_Expr: {
			assert(false);
		}
		case ^ast.Implicit: {
			assert(false);
		}
		case ^ast.Undef: {
			assert(false);
		}
		case ^ast.Basic_Directive: {
			assert(false);
		}
		case ^ast.Ellipsis: {
			assert(false);
		}
		case ^ast.Proc_Lit: {
			assert(false);
		}
		case ^ast.Comp_Lit: {
			if derived.type != nil {
				write_expression(sb, derived.type, is_type=true);
			}
			strings.write_string(sb, " { ");

			write_expression_array(sb, derived.elems);
			/*for elem, elem_index in derived.elems {
				if elem_index
				write_expression(sb, elem);
			}*/

			//write_indent(sb, indent);
			strings.write_string(sb, "}");
		}
		case ^ast.Tag_Expr: {
			assert(false);
		}
		case ^ast.Unary_Expr: {
			strings.write_string(sb, derived.op.text);
			write_expression(sb, derived.expr);
		}
		case ^ast.Implicit_Selector_Expr: {
			strings.write_byte(sb, '.');
			strings.write_string(sb, derived.field.name);
		}
		case ^ast.Selector_Call_Expr: {
			assert(false);
		}
		case ^ast.Index_Expr: {
			assert(false);
		}
		case ^ast.Deref_Expr: {
			assert(false);
		}
		case ^ast.Slice_Expr: {
			write_expression(sb, derived.expr);
			strings.write_byte(sb, '[');
			if derived.low != nil {
				write_expression(sb, derived.low);
			}
			strings.write_string(sb, derived.interval.text);
			if derived.high != nil {
				write_expression(sb, derived.high);
			}
			strings.write_byte(sb, ']');
		}
		case ^ast.Matrix_Index_Expr: {
			assert(false);
		}
		case ^ast.Field_Value: {
			write_expression(sb, derived.field);
			strings.write_string(sb, " = ");
			write_expression(sb, derived.value);
		}
		case ^ast.Ternary_If_Expr: {
			assert(false);
		}
		case ^ast.Ternary_When_Expr: {
			assert(false);
		}
		case ^ast.Or_Else_Expr: {
			assert(false);
		}
		case ^ast.Or_Return_Expr: {
			assert(false);
		}
		case ^ast.Type_Assertion: {
			assert(false);
		}
		case ^ast.Auto_Cast: {
			assert(false);
		}
		case ^ast.Inline_Asm_Expr: {
			assert(false);
		}

		case ^ast.Proc_Group: {
			assert(false);
		}

		case ^ast.Typeid_Type: {
			assert(false);
		}
		case ^ast.Helper_Type: {
			assert(false);
		}
		case ^ast.Distinct_Type: {
			assert(false);
		}
		case ^ast.Poly_Type: {
			assert(false);
		}
		case ^ast.Proc_Type: {
			assert(false);
		}
		case ^ast.Pointer_Type: {
			strings.write_byte(sb, '^');
			write_expression(sb, derived.elem, is_type=true);
		}
		case ^ast.Multi_Pointer_Type: {
			assert(false);
		}
		case ^ast.Array_Type: {
			strings.write_byte(sb, '[');
			if derived.len != nil {
				write_expression(sb, derived.len);
			}
			strings.write_byte(sb, ']');
			write_expression(sb, derived.elem);
		}
		case ^ast.Dynamic_Array_Type: {			
			// TODO: tag
			strings.write_string(sb, "[dynamic]");
			write_expression(sb, derived.elem);
		}
		case ^ast.Struct_Type: {
			assert(false);
		}
		case ^ast.Union_Type: {
			assert(false);
		}
		case ^ast.Enum_Type: {
			assert(false);
		}
		case ^ast.Bit_Set_Type: {
			assert(false);
		}
		case ^ast.Map_Type: {
			assert(false);
		}
		case ^ast.Relative_Type: {
			assert(false);
		}
		case ^ast.Matrix_Type: {
			assert(false);
		}
		case: {
			fmt.sbprint(sb, derived);
			assert(false);
		}
	}
}

write_expression_array :: proc(sb: ^strings.Builder, expressions: []^ast.Expr) {
	for expression, index in expressions {
		if index > 0 do strings.write_string(sb, ", ");
		write_expression(sb, expression);
	}
}

write_statement :: proc(sb: ^strings.Builder, statement: ^ast.Stmt, indent: int) {	
	#partial switch derived in statement.derived_stmt {
		case ^ast.Return_Stmt: {
			strings.write_string(sb, "return ");
			for result, result_index in derived.results {
				if result_index > 0 do strings.write_string(sb, ", ");
				write_expression(sb, result);
			}
		}
		case ^ast.Expr_Stmt: {
			write_expression(sb, derived.expr);
		}
		case ^ast.Value_Decl: {
			for name, name_index in derived.names {
				if name_index > 0 do strings.write_string(sb, ", ");
				write_expression(sb, name);
			}
			strings.write_string(sb, ":");
			if derived.type != nil {
				write_expression(sb, derived.type);
			}

			if len(derived.values) > 0 {
				if derived.is_mutable {
					strings.write_string(sb, "=");
				}
				else {
					strings.write_string(sb, ":");
				}
				for value, value_index in derived.values {
					if value_index > 0 do strings.write_string(sb, ", ");
					write_expression(sb, value);
				}
			}
		}
		case ^ast.Assign_Stmt: {

			write_expression_array(sb, derived.lhs);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.op.text);
			strings.write_byte(sb, ' ');
			write_expression_array(sb, derived.rhs);
		}		
		case ^ast.If_Stmt: {
			maybe_write_label(sb, derived.label);

			strings.write_string(sb, "if ");

			if derived.init != nil {
				write_statement(sb, derived.init, 0);
				strings.write_string(sb, "; ");
			}
			write_expression(sb, derived.cond);

			write_statement(sb, derived.body, indent);

			if derived.else_stmt != nil {
				write_indent(sb, indent);
				strings.write_string(sb, "else ");
				write_statement(sb, derived.else_stmt, indent);
			}
		}
		case ^ast.When_Stmt: {
			strings.write_string(sb, "when ");
			write_expression(sb, derived.cond);

			write_statement(sb, derived.body, indent);

			if derived.else_stmt != nil {
				write_indent(sb, indent);
				strings.write_string(sb, "else ");
				write_statement(sb, derived.else_stmt, indent);
			}
		}
		case ^ast.For_Stmt: {
			maybe_write_label(sb, derived.label);
			strings.write_string(sb, "for ");
			if derived.init != nil {
				write_statement(sb, derived.init, 0);
				strings.write_string(sb, "; ");
			}
			write_expression(sb, derived.cond);

			if derived.post != nil {
				strings.write_string(sb, "; ");
				write_statement(sb, derived.post, 0);
			}

			write_statement(sb, derived.body, indent);
		}
		case ^ast.Range_Stmt: {
			if derived.reverse {
				strings.write_string(sb, "#reverse ");
			}
			maybe_write_label(sb, derived.label);
			strings.write_string(sb, "for ");
			write_expression_array(sb, derived.vals);

			strings.write_string(sb, " in ");
			write_expression(sb, derived.expr);


			write_statement(sb, derived.body, indent);
		}
		case ^ast.Block_Stmt: {
			write_block(sb, derived, indent);
		}
		case ^ast.Branch_Stmt: {
			strings.write_string(sb, derived.tok.text);
			if derived.label != nil {
				strings.write_byte(sb, ' ');
				write_expression(sb, derived.label);
			}
		}
		case: {
			fmt.printf("\n%s\n", derived);
			assert(false);
		}
	}
}

maybe_write_label :: proc(sb: ^strings.Builder, label: ^ast.Expr) {
	if label == nil do return;
	write_expression(sb, label);
	strings.write_string(sb, ": ");
}

write_indent :: proc(sb: ^strings.Builder, depth: int) {
	for ii in 0..<depth do strings.write_byte(sb, '\t');
}
write_block :: proc(sb: ^strings.Builder, block: ^ast.Block_Stmt, indent: int) {
	maybe_write_label(sb, block.label);
	if !block.uses_do do strings.write_string(sb, "{\n");
	else              do strings.write_string(sb, " do ");
	for statement in block.stmts {
		if !block.uses_do do write_indent(sb, indent+1);
		write_statement(sb, statement, indent+1);
		if !block.uses_do do strings.write_string(sb, "\n");
	}
	if !block.uses_do do write_indent(sb, indent);
	if !block.uses_do do strings.write_byte(sb, '}');
	strings.write_byte(sb, '\n');
}

write_proc_literal :: proc(sb: ^strings.Builder, proc_lit: ^ast.Proc_Lit) {
	switch proc_lit.inlining {
		case .None: 
		case .Inline: strings.write_string(sb, "#force_inline ");
		case .No_Inline: strings.write_string(sb, "#force_no_inline ");
	}

	strings.write_string(sb, "proc(");
	for field, field_index in proc_lit.type.params.list {
		// TODO: default_value
		// TODO: test polymorphic
		// TODO: flags 
		if field_index > 0 do strings.write_string(sb, ", ");
		for field_name, field_name_index in field.names {
			if field_name_index > 0 do strings.write_string(sb, ", ");
			#partial switch derived in field_name.derived_expr {
				case ^ast.Ident: {									
					strings.write_string(sb, derived.name);
				}
			}
		}
		strings.write_string(sb, ": ");
		write_expression(sb, field.type, is_type=true);						
	}
	strings.write_string(sb, ") ");
	if proc_lit.type.results != nil {
		strings.write_string(sb, "-> ");
		strings.write_byte(sb, '(');
		for field, field_index in proc_lit.type.results.list {
			// TODO: default_value
			// TODO: test polymorphic with multiple names
			// TODO: flags 
			if field_index > 0 do strings.write_string(sb, ", ");
			if len(field.names) > 0 {
				did_write_name := false;
				for field_name, field_name_index in field.names {
					if field_name_index > 0 && did_write_name do strings.write_string(sb, ", ");
					#partial switch derived in field_name.derived_expr {
						case ^ast.Ident: {
							if derived.name != "_" {
								strings.write_string(sb, derived.name);
								did_write_name = true;
							}
						}
					}
				}
				if did_write_name {
					strings.write_string(sb, ": ");
				}
			}
			write_expression(sb, field.type, is_type=true);							
		}	
		strings.write_byte(sb, ')');
	}

	tag_strings := [ast.Proc_Tag]string {
		.Bounds_Check = "#bounds_Check",
		.No_Bounds_Check = "#no_bounds_check",
		.Optional_Ok = "#optional_ok",
		.Optional_Allocator_Error = "#optional_allocator_error",
	};
	written_tag_count := 0;
	for tag in ast.Proc_Tag {
		if tag in proc_lit.tags {
			if written_tag_count > 0 do strings.write_string(sb, ", ");
			strings.write_string(sb, tag_strings[tag]);				
			written_tag_count += 1;
		}
	}
	
	body := proc_lit.body;
	block := body.derived_stmt.(^ast.Block_Stmt);
	write_block(sb, block, 0);

	strings.write_string(sb, "\n");
}*/