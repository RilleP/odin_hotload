package hotload_gen

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:log"
import "core:fmt"

write_expression :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, expression: ^ast.Expr, indent: int, is_type: bool = false, is_call: bool = false) {
	#partial switch derived in expression.derived_expr {
		case ^ast.Basic_Lit: {
			strings.write_string(sb, derived.tok.text);
		}
		case ^ast.Ident: {
			/*if (is_type || is_call) && !is_built_in(derived.name) {
				strings.write_string(sb, "MAIN.");
			}*/	
			//is_declared_locally := name_is_declared_locally(visit_data, derived.name);
			local_declaration := maybe_get_local_declaration(visit_data, derived.name);
			if local_declaration != nil && 
			   .IN_SOME_WHEN_BLOCKS in local_declaration.flags && 
			   derived.name in visit_data.global_variables {
			   	log.errorf("Referenced variable '%s' is declared in some when branches, but not all; it is also a global variable and used after the when blocks. This is not supported.\n\t -> %s(%d:%d)", derived.name, expression.pos.file, expression.pos.line, expression.pos.column);
			   	visit_data.failed = true;
			}
			is_global := local_declaration == nil && derived.name in visit_data.global_variables;
			if is_global {
				strings.write_string(sb, "(");
			}							
			strings.write_string(sb, derived.name);
			if is_global {
				strings.write_string(sb, "^)");
			}
		}
		case ^ast.Binary_Expr: {
			write_expression(visit_data, sb, derived.left, indent);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.op.text);
			strings.write_byte(sb, ' ');
			write_expression(visit_data, sb, derived.right, indent);
		}
		case ^ast.Selector_Expr: {
			write_expression(visit_data, sb, derived.expr, indent);
			strings.write_string(sb, derived.op.text);
			strings.write_string(sb, derived.field.name);
		}
		case ^ast.Call_Expr: {
			//strings.write_string(sb, "?()");								
			write_expression(visit_data, sb, derived.expr, indent, is_call=true);
			strings.write_byte(sb, '(');
			has_written_ellipsis := false;
			for arg, arg_index in derived.args {
				if arg_index > 0 do strings.write_string(sb, ", ");				

				if !has_written_ellipsis && derived.ellipsis.pos.offset < arg.pos.offset {
					strings.write_string(sb, derived.ellipsis.text);
					has_written_ellipsis = true;
				}
				write_expression(visit_data, sb, arg, indent);
			}	
			strings.write_byte(sb, ')');
		}
		case ^ast.Type_Cast: {
			strings.write_string(sb, derived.tok.text);
			strings.write_byte(sb, '(');
			write_expression(visit_data, sb, derived.type, indent, is_type=true);
			strings.write_byte(sb, ')');
			write_expression(visit_data, sb, derived.expr, indent);
		}
		case ^ast.Paren_Expr: {
			strings.write_byte(sb, '(');
			write_expression(visit_data, sb, derived.expr, indent);
			strings.write_byte(sb, ')');
		}
		
		case ^ast.Bad_Expr: {
			strings.write_string(sb, "[BAD EXPR!]'");
			// NOTE: This is not writing the correct text for some reason. Maybe a bug in the parser. But whatever?
			strings.write_string(sb, visit_data.current_file_src[expression.pos.offset:expression.end.offset])
			strings.write_string(sb, "'");
		}
		case ^ast.Implicit: {
			strings.write_string(sb, tokenizer.tokens[derived.tok.kind]);
		}
		case ^ast.Undef: {
			strings.write_string(sb, tokenizer.tokens[derived.tok]);
		}
		case ^ast.Basic_Directive: {
			strings.write_string(sb, tokenizer.tokens[derived.tok.kind]);
			strings.write_string(sb, derived.name);
		}
		case ^ast.Ellipsis: {
			strings.write_string(sb, tokenizer.tokens[derived.tok]);
			write_expression(visit_data, sb, derived.expr, indent);
		}
		case ^ast.Proc_Lit: {
			write_proc_literal(visit_data, sb, derived, indent);
		}
		case ^ast.Comp_Lit: {
			if derived.type != nil {
				write_expression(visit_data, sb, derived.type, indent, is_type=true);
			}
			strings.write_string(sb, " { ");

			write_expression_array(visit_data, sb, derived.elems, indent);
			strings.write_string(sb, "}");
		}
		case ^ast.Tag_Expr: {
			panic("Not implemented");
		}
		case ^ast.Unary_Expr: {
			strings.write_string(sb, derived.op.text);
			write_expression(visit_data, sb, derived.expr, indent);
		}
		case ^ast.Implicit_Selector_Expr: {
			strings.write_byte(sb, '.');
			strings.write_string(sb, derived.field.name);
		}
		case ^ast.Selector_Call_Expr: {
			write_expression(visit_data, sb, derived.call, indent);
			//write_expression(visit_data, sb, derived.call, indent);
		}
		case ^ast.Index_Expr: {
			write_expression(visit_data, sb, derived.expr, indent);
			strings.write_byte(sb, '[');
			write_expression(visit_data, sb, derived.index, indent);
			strings.write_byte(sb, ']');
		}
		case ^ast.Deref_Expr: {
			write_expression(visit_data, sb, derived.expr, indent);
			strings.write_byte(sb, '^');
		}
		case ^ast.Slice_Expr: {
			write_expression(visit_data, sb, derived.expr, indent);
			strings.write_byte(sb, '[');
			if derived.low != nil {
				write_expression(visit_data, sb, derived.low, indent);
			}
			strings.write_string(sb, derived.interval.text);
			if derived.high != nil {
				write_expression(visit_data, sb, derived.high, indent);
			}
			strings.write_byte(sb, ']');
		}
		case ^ast.Matrix_Index_Expr: {
			write_expression(visit_data, sb, derived.expr, 0);
			strings.write_byte(sb, '[');
			write_expression(visit_data, sb, derived.row_index, 0);
			strings.write_byte(sb, ',');
			write_expression(visit_data, sb, derived.column_index, 0);
			strings.write_byte(sb, ']');
		}
		case ^ast.Field_Value: {
			write_expression(visit_data, sb, derived.field, indent);
			strings.write_string(sb, " = ");
			write_expression(visit_data, sb, derived.value, indent);
		}
		case ^ast.Ternary_If_Expr: {
			tif := derived;
			if tif.op1.kind == .Question {
				assert(tif.op2.kind == .Colon);

				write_expression(visit_data, sb, tif.cond, 0);
				strings.write_byte(sb, ' ');
				strings.write_string(sb, tif.op1.text);
				strings.write_byte(sb, ' ');
				write_expression(visit_data, sb, tif.x, 0);
				strings.write_byte(sb, ' ');
				strings.write_string(sb, tif.op2.text);
				strings.write_byte(sb, ' ');
				write_expression(visit_data, sb, tif.y, 0);
			}
			else {
				assert(tif.op1.kind == .If);
				assert(tif.op2.kind == .Else);
				
				write_expression(visit_data, sb, tif.x, 0);
				strings.write_byte(sb, ' ');
				strings.write_string(sb, tif.op1.text);
				strings.write_byte(sb, ' ');
				write_expression(visit_data, sb, tif.cond, 0);
				strings.write_byte(sb, ' ');
				strings.write_string(sb, tif.op2.text);
				strings.write_byte(sb, ' ');
				write_expression(visit_data, sb, tif.y, 0);
			}
		}
		case ^ast.Ternary_When_Expr: {
			twhen := derived;
			write_expression(visit_data, sb, twhen.x, 0);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, twhen.op1.text);
			strings.write_byte(sb, ' ');
			write_expression(visit_data, sb, twhen.cond, 0);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, twhen.op2.text);
			strings.write_byte(sb, ' ');
			write_expression(visit_data, sb, twhen.y, 0);
		}
		case ^ast.Or_Else_Expr: {
			write_expression(visit_data, sb, derived.x, 0);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.token.text);
			strings.write_byte(sb, ' ');
			write_expression(visit_data, sb, derived.y, 0);
		}
		case ^ast.Or_Return_Expr: {
			write_expression(visit_data, sb, derived.expr, 0);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.token.text);
		}
		case ^ast.Or_Branch_Expr: {
			write_expression(visit_data, sb, derived.expr, 0);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.token.text);
		}
		case ^ast.Type_Assertion: {
			write_expression(visit_data, sb, derived.expr, 0);
			strings.write_string(sb, ".(");
			write_expression(visit_data, sb, derived.type, 0);
			strings.write_string(sb, ")");
		}
		case ^ast.Auto_Cast: {
			strings.write_string(sb, derived.op.text);
			strings.write_byte(sb, ' ');
			write_expression(visit_data, sb, derived.expr, 0);
		}
		case ^ast.Inline_Asm_Expr: {
			panic("Not implemented");
		}

		case ^ast.Proc_Group: {
			panic("Not implemented");
		}

		case ^ast.Typeid_Type: {
			strings.write_string(sb, tokenizer.tokens[derived.tok]);
			if derived.specialization != nil {
				strings.write_string(sb, "/");
				write_expression(visit_data, sb, derived.specialization, indent);
			}
		}
		case ^ast.Helper_Type: {
			panic("Not implemented");
		}
		case ^ast.Distinct_Type: {
			panic("Not implemented");
		}
		case ^ast.Poly_Type: {
			strings.write_string(sb, tokenizer.tokens[tokenizer.Token_Kind.Dollar]);
			strings.write_string(sb, derived.type.name);
			if derived.specialization != nil {
				strings.write_byte(sb, '/');
				write_expression(visit_data, sb, derived.specialization, indent); // is type?
			}
		}
		case ^ast.Proc_Type: {
			write_proc_header(visit_data, sb, derived, indent);
		}
		case ^ast.Pointer_Type: {
			if derived.tag != nil {
				write_expression(visit_data, sb, derived.tag, indent);
			}
			strings.write_byte(sb, '^');
			write_expression(visit_data, sb, derived.elem, indent, is_type=true);
		}
		case ^ast.Multi_Pointer_Type: {
			assert(false);
		}
		case ^ast.Array_Type: {
			if derived.tag != nil {
				write_expression(visit_data, sb, derived.tag, indent);
			}
			strings.write_byte(sb, '[');
			if derived.len != nil {
				write_expression(visit_data, sb, derived.len, indent);
			}
			strings.write_byte(sb, ']');
			write_expression(visit_data, sb, derived.elem, indent);
		}
		case ^ast.Dynamic_Array_Type: {			
			if derived.tag != nil {
				write_expression(visit_data, sb, derived.tag, indent);
			}
			strings.write_string(sb, "[dynamic]");
			write_expression(visit_data, sb, derived.elem, indent);
		}
		case ^ast.Struct_Type: {
			strings.write_string(sb, "struct ");
			if derived.poly_params != nil {
				strings.write_string(sb, "(");
				write_field_list(visit_data, sb, derived.poly_params, ", ", 0);
				strings.write_string(sb, ") ");
			}

			if derived.align != nil {
				strings.write_string(sb, "#align");
				write_expression(visit_data, sb, derived.align, 0);
				strings.write_string(sb, " ");
			}
			if derived.field_align != nil {
				strings.write_string(sb, "#field_align");
				write_expression(visit_data, sb, derived.field_align, 0);
				strings.write_string(sb, " ");
			}

			if len(derived.where_clauses) > 0 {
				strings.write_string(sb, "where ");
				for e, ei in derived.where_clauses {
					if ei > 0 {
						strings.write_string(sb, ", ");
					}
					write_expression(visit_data, sb, e, 0);
				}
			}

			if derived.is_packed {
				strings.write_string(sb, "#packed ");
			}
			if derived.is_raw_union {
				strings.write_string(sb, "#raw_union ");
			}
			if derived.is_no_copy {
				strings.write_string(sb, "#no_copy ");
			}

			strings.write_string(sb, "{\n");
			write_field_list(visit_data, sb, derived.fields, ",\n", indent+1);	
			strings.write_string(sb, "\n");
			write_indent(sb, indent);
			strings.write_string(sb, "}");
		}
		case ^ast.Union_Type: {
			strings.write_string(sb, "union ");
			if derived.poly_params != nil {
				strings.write_string(sb, "(");
				write_field_list(visit_data, sb, derived.poly_params, ", ", 0);
				strings.write_string(sb, ") ");
			}

			if derived.align != nil {
				strings.write_string(sb, "#align");
				write_expression(visit_data, sb, derived.align, 0);
				strings.write_string(sb, " ");
			}			

			switch derived.kind {
				case .Normal, .maybe:
				case .no_nil: strings.write_string(sb, "#no_nil ");
				case .shared_nil: strings.write_string(sb, "#shared_nil ");
			}

			if len(derived.where_clauses) > 0 {
				strings.write_string(sb, "where ");
				for e, ei in derived.where_clauses {
					if ei > 0 {
						strings.write_string(sb, ", ");
					}
					write_expression(visit_data, sb, e, 0);
				}
			}

			strings.write_string(sb, "{\n");
			for variant, index in derived.variants {
				if index > 0 {
					strings.write_string(sb, ",\n");
				}
				write_indent(sb, indent+1);
				write_expression(visit_data, sb, variant, indent);
			}
			strings.write_string(sb, "\n");
			write_indent(sb, indent);
			strings.write_string(sb, "}");
		}
		case ^ast.Enum_Type: {
			strings.write_string(sb, "enum ");
			if derived.base_type != nil {
				write_expression(visit_data, sb, derived.base_type, indent);
			}
			strings.write_string(sb, "{\n");

			for field, index in derived.fields {
				if index > 0 {
					strings.write_string(sb, ",\n");
				}
				write_indent(sb, indent+1);
				write_expression(visit_data, sb, field, indent+1);
			}

			strings.write_string(sb, "\n");
			write_indent(sb, indent);
			strings.write_string(sb, "}");
		}
		case ^ast.Bit_Set_Type: {
			panic("Not implemented");
		}
		case ^ast.Map_Type: {
			panic("Not implemented");
		}
		case ^ast.Relative_Type: {
			panic("Not implemented");
		}
		case ^ast.Matrix_Type: {
			strings.write_string(sb, "matrix[");
			write_expression(visit_data, sb, derived.row_count, 0);
			strings.write_string(sb, ", ");
			write_expression(visit_data, sb, derived.column_count, 0);
			strings.write_string(sb, "]");
			write_expression(visit_data, sb, derived.elem, 0);
		}
		case: {
			fmt.sbprint(sb, derived);
			assert(false);
		}
	}
}

write_expression_array :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, expressions: []^ast.Expr, indent: int) {
	for expression, index in expressions {
		if index > 0 do strings.write_string(sb, ", ");
		write_expression(visit_data, sb, expression, indent);
	}
}

write_statement :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, statement: ^ast.Stmt, indent: int) {	
	if len(sb.buf) == 0 || sb.buf[len(sb.buf)-1] == '\n' {
		write_indent(sb, indent);
	}
	#partial switch derived in statement.derived_stmt {
		case ^ast.Return_Stmt: {
			strings.write_string(sb, "return ");
			for result, result_index in derived.results {
				if result_index > 0 do strings.write_string(sb, ", ");
				write_expression(visit_data, sb, result, indent);
			}
		}
		case ^ast.Expr_Stmt: {
			write_expression(visit_data, sb, derived.expr, indent);
		}
		case ^ast.Value_Decl: {
			add_declaration_names(&visit_data.scopes, derived.names);

			for name, name_index in derived.names {
				if name_index > 0 do strings.write_string(sb, ", ");
				write_expression(visit_data, sb, name, indent);
			}
			strings.write_string(sb, ":");
			if derived.type != nil {
				write_expression(visit_data, sb, derived.type, indent);
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
					write_expression(visit_data, sb, value, indent);
				}
			}
		}
		case ^ast.Assign_Stmt: {

			write_expression_array(visit_data, sb, derived.lhs, indent);
			strings.write_byte(sb, ' ');
			strings.write_string(sb, derived.op.text);
			strings.write_byte(sb, ' ');
			write_expression_array(visit_data, sb, derived.rhs, indent);
		}		
		case ^ast.If_Stmt: {
			maybe_write_label(visit_data, sb, derived.label, indent);

			strings.write_string(sb, "if ");

			if derived.init != nil {
				write_statement(visit_data, sb, derived.init, 0);
				strings.write_string(sb, "; ");
			}
			write_expression(visit_data, sb, derived.cond, indent);

			write_statement(visit_data, sb, derived.body, indent);

			if derived.else_stmt != nil {
				write_indent(sb, indent);
				strings.write_string(sb, "else ");
				write_statement(visit_data, sb, derived.else_stmt, indent);
			}
		}
		case ^ast.When_Stmt: {
			scopes := &visit_data.scopes;
			when_blocks_index := scopes.current_when_blocks_count;
			scopes.current_when_blocks_count += 1;

			strings.write_string(sb, "when ");
			write_expression(visit_data, sb, derived.cond, indent);

			write_statement(visit_data, sb, derived.body, indent);

			if derived.else_stmt != nil {
				write_indent(sb, indent);
				strings.write_string(sb, "else ");

				if else_block, ok := derived.else_stmt.derived_stmt.(^ast.Block_Stmt); ok {
					scopes.current_when_blocks_count += 1;
					enter_block(scopes);
					write_statement(visit_data, sb, else_block, indent);
					exit_block(scopes);
				}
				else {
					write_statement(visit_data, sb, derived.else_stmt, indent);
				}
			}

			if when_blocks_index == 0 {
				for decl, count in scopes.declarations_in_current_when_blocks {
					//fmt.printf("\tWHEN: %s was declared in %d/%d blocks\n", decl, count, scopes.current_when_blocks_count)
					if count < scopes.current_when_blocks_count { 
						// Not declared in all blocks, so add as potential global
						// add_global_reference(visit_data, decl);
						/*if decl in visit_data.global_variables {
							log.errorf("%s is declared as a local variable in some branches of a when statement. %s is also a global variable. So this will not work!\n", decl, decl);
						}
						fmt.printf("Declaration '%v' in when block is NOT declared in all %v blocks, only in %d of them.\n", decl, scopes.current_when_blocks_count, count);*/
						append(&scopes.current.declaration_stack, Local_Declaration{decl, {.IN_SOME_WHEN_BLOCKS}});
					}
					else {
						// Declared in all blocks
						append(&scopes.current.declaration_stack, Local_Declaration{decl, {}});
						/*fmt.printf("Declaration '%v' in when block is declared in all %d blocks.\n", decl, scopes.current_when_blocks_count);*/
					}
				}

				clear(&scopes.declarations_in_current_when_blocks);
				scopes.current_when_blocks_count = 0;
			}
		}
		case ^ast.For_Stmt: {
			maybe_write_label(visit_data, sb, derived.label, indent);
			strings.write_string(sb, "for ");
			if derived.init != nil {
				write_statement(visit_data, sb, derived.init, 0);
				strings.write_string(sb, "; ");
			}
			write_expression(visit_data, sb, derived.cond, indent);

			if derived.post != nil {
				strings.write_string(sb, "; ");
				write_statement(visit_data, sb, derived.post, 0);
			}

			write_statement(visit_data, sb, derived.body, indent);
		}
		case ^ast.Range_Stmt: {
			if derived.reverse {
				strings.write_string(sb, "#reverse ");
			}
			maybe_write_label(visit_data, sb, derived.label, indent);
			strings.write_string(sb, "for ");
			write_expression_array(visit_data, sb, derived.vals, indent);

			strings.write_string(sb, " in ");
			write_expression(visit_data, sb, derived.expr, indent);


			write_statement(visit_data, sb, derived.body, indent);
		}
		case ^ast.Defer_Stmt: {
			strings.write_string(sb, "defer ");
			write_statement(visit_data, sb, derived.stmt, indent);
		}
		case ^ast.Block_Stmt: {
			write_block(visit_data, sb, derived, indent);
		}
		case ^ast.Branch_Stmt: {
			strings.write_string(sb, derived.tok.text);
			if derived.label != nil {
				strings.write_byte(sb, ' ');
				write_expression(visit_data, sb, derived.label, indent);
			}
		}
		case ^ast.Switch_Stmt: {
			maybe_write_label(visit_data, sb, derived.label, indent);
			if derived.partial {
				strings.write_string(sb, "#partial ");
			}
			strings.write_string(sb, "switch ");
			write_expression(visit_data, sb, derived.cond, indent);
			write_statement(visit_data, sb, derived.body, indent);
		}
		case ^ast.Case_Clause: {
			strings.write_string(sb, "case ");
			write_expression_array(visit_data, sb, derived.list, indent);
			strings.write_byte(sb, ':');
			for statement in derived.body {
				if block, is_block := statement.derived.(^ast.Block_Stmt); is_block {
					write_statement(visit_data, sb, statement, indent);
				}
				else {
					strings.write_byte(sb, '\n');
					write_statement(visit_data, sb, statement, indent+1);
				}
			}
		}
		case: {
			fmt.printf("\n%v\n", derived);
			assert(false);
		}
	}
}

maybe_write_label :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, label: ^ast.Expr, indent: int) {
	if label == nil do return;
	write_expression(visit_data, sb, label, indent);
	strings.write_string(sb, ": ");
}

/*write_indent :: proc(sb: ^strings.Builder, depth: int) {
	for ii in 0..<depth do strings.write_byte(sb, '\t');
}*/
write_block :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, block: ^ast.Block_Stmt, indent: int) {
	enter_block(&visit_data.scopes);
	maybe_write_label(visit_data, sb, block.label, indent);

	add_all_constant_declarations_in_block(visit_data, block);

	if !block.uses_do do strings.write_string(sb, "{\n");
	else              do strings.write_string(sb, " do ");

	for statement in block.stmts {
		if !block.uses_do do write_indent(sb, indent+1);
		write_statement(visit_data, sb, statement, indent+1);
		/*if !block.uses_do do */strings.write_string(sb, "\n");
	}
	if !block.uses_do {
		write_indent(sb, indent);	
		strings.write_byte(sb, '}');
	} 
	/*else {
		strings.write_string(sb, "\n");
	}*/
	exit_block(&visit_data.scopes);
}

write_field_list :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, field_list: ^ast.Field_List, separator: string, indent: int) {

	// Indent if separator ends with new line
	should_indent := len(separator) > 0 && separator[len(separator)-1] == '\n'; 

	for field, field_index in field_list.list {
		if field_index > 0 do strings.write_string(sb, separator);
		if should_indent do write_indent(sb, indent);

		for flag in ast.Field_Flag {
			if flag in field.flags {
				strings.write_string(sb, ast.field_flag_strings[flag]);
				strings.write_byte(sb, ' ');
			}
		}
		for field_name, field_name_index in field.names {
			if field_name_index > 0 do strings.write_string(sb, ", ");
			write_expression(visit_data, sb, field_name, indent);
		}
		if field.type != nil {
			strings.write_string(sb, ": ");
			write_expression(visit_data, sb, field.type, indent, is_type=true);
		}

		if field.default_value != nil {
			strings.write_string(sb, field.type != nil ? " = " : " := ");
			write_expression(visit_data, sb, field.default_value, indent);
		}

		if len(field.tag.text) > 0 {
			strings.write_byte(sb, ' ');
			strings.write_string(sb, field.tag.text);
		}
	}
}

write_proc_header :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, proc_type: ^ast.Proc_Type, indent: int) {
	strings.write_string(sb, "proc(");
	write_field_list(visit_data, sb, proc_type.params, ", ", 0);

	strings.write_string(sb, ") ");
	if proc_type.results != nil {
		strings.write_string(sb, "-> ");
		strings.write_byte(sb, '(');
		for field, field_index in proc_type.results.list {
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
			write_expression(visit_data, sb, field.type, indent, is_type=true);	
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
		if tag in proc_type.tags {
			if written_tag_count > 0 do strings.write_string(sb, ", ");
			strings.write_string(sb, tag_strings[tag]);				
			written_tag_count += 1;
		}
	}
}

write_proc_literal :: proc(visit_data: ^Visit_Data, sb: ^strings.Builder, proc_lit: ^ast.Proc_Lit, indent: int) {
	
	scopes := &visit_data.scopes;
	push_local_declaration(scopes, .Proc);
	defer pop_local_declaration(scopes);

	switch proc_lit.inlining {
		case .None: 
		case .Inline: strings.write_string(sb, "#force_inline ");
		case .No_Inline: strings.write_string(sb, "#force_no_inline ");
	}

	write_proc_header(visit_data, sb, proc_lit.type, indent);
	
	enter_block(scopes);
	block := proc_lit.body.derived_stmt.(^ast.Block_Stmt);
	write_block(visit_data, sb, block, indent);
	exit_block(scopes);
}