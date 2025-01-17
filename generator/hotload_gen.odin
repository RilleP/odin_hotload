package hotload_gen

import "core:fmt"
import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:os"
import "core:log"
import "core:time"
import "core:path/filepath"

import "base:runtime"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

Block :: struct {
	first_declaration_index: int,
	first_constant_value_declaration_index: int,
}

Local_Declarations_Type :: enum {
	Struct,
	Proc,
}

Local_Declaration_Flag :: enum {
	IN_SOME_WHEN_BLOCKS,
}

Local_Declaration :: struct {
	name: string,
	flags: bit_set[Local_Declaration_Flag],
}

Local_Declarations :: struct {
	// Things declared in a proc or struct definition
	type: Local_Declarations_Type,
	declaration_stack: [dynamic]Local_Declaration,
	constant_value_declaration_stack: [dynamic]Local_Declaration,
	block_stack: [dynamic]Block,
}

Scopes :: struct {	
	local_declaration_stack: [dynamic]Local_Declarations,
	current: ^Local_Declarations,

	declarations_in_current_when_blocks: map[string]int,
	current_when_blocks_count: int,
}

Proc_To_Write :: struct {
	name: string,
	lit: ^ast.Proc_Lit,
	file_src: string,
}

Hashtag_Config :: struct {
	name: string,
	expr: string,
}

Visit_Data :: struct {
	package_path: string,
	sb: ^strings.Builder,
	current_file_src: string,
	current_file_path: string,
	current_file_has_hotload_procs: bool,

	hotload_proc_names: [dynamic]string,
	hotload_procs_to_write: [dynamic]Proc_To_Write,
	other_proc_signatures:   map[string]Proc_Signature,
	all_type_declarations: map[string]Type_Declaration,
	global_variables: map[string]Global_Variable_Declaration,
	when_trees: [dynamic]When_Tree,
	hotload_files: [dynamic]string,
	hashtag_configs: [dynamic]Hashtag_Config,

	imports: map[string]Import,
	packages: map[string]Import,

	scopes: Scopes,
	
	referenced_identifiers : map[string]Referenced_Ident,

	do_add_procs_in_when_trees: bool,
	
	failed: bool,

	import_file_allocator: mem.Allocator,
}

Import :: struct {
	name: string,
	name_is_user_specified: bool, // Like import foo "core:fmt"
	fullpath: string,
	text: string,
	is_referenced: bool,
}

Referenced_Ident :: struct {
	count: int,
	found_and_handled: bool,
}

Proc_Signature :: struct {
	name: string,
	type_string: string,
	type: ^ast.Proc_Type,
	type_references_have_been_added: bool,
	is_generic: bool,
	wrapped: bool,
	attributes: []^ast.Attribute,
	file_src: string,
}

Type_Declaration :: struct {
	file_src: string,
	decl_string: string,
	value: ^ast.Expr,
	value_references_have_been_added: bool,
	inside_when: string,
}

Type_Declaration_State :: enum u8 {
	Defined,
	Referenced,
}

Global_Variable_Declaration :: struct {
	file_src: string,
	decl_string: string,
	type_string: string,
	value_references_have_been_added: bool,
	type_expr: ^ast.Expr,
	value_expr: ^ast.Expr,

}

When_Tree :: struct {
	any_referenced: bool,
	all_type_declarations: map[string]Type_Declaration_State,
	all_proc_declarations: map[string]Type_Declaration_State,
	node: ^ast.When_Stmt,
	file_src: string,
}

get_type_string :: proc(file_src: string, type_expr: ^ast.Expr) -> string {

	offset0 := type_expr.pos.offset;
	offset1 := type_expr.end.offset;
	#partial switch derived_type in type_expr.derived_expr {
		case ^ast.Array_Type: {
			if derived_type.tag != nil {
				offset0 = derived_type.tag.pos.offset;
			}
		}
	}
	return file_src[offset0:offset1];
}

add_expression_type_reference :: proc(visit_data: ^Visit_Data, expr: ^ast.Expr) {
	#partial switch derived in expr.derived_expr {
		case ^ast.Ident: {
			add_global_reference_if_not_declared_locally(visit_data, derived.name);
			//add_global_reference(visit_data, derived.name);
		}
		case ^ast.Basic_Lit: {
		}
		case ^ast.Pointer_Type: {
			add_expression_type_reference(visit_data, derived.elem);
		}
		case ^ast.Selector_Expr: {
			// Is this always an imported type?
			add_expression_type_reference(visit_data, derived.expr);
		}
		case ^ast.Proc_Type: {
			if derived.params != nil {
				add_field_list_type_references(visit_data, &visit_data.scopes, derived.params);
			}
			if derived.results != nil {
				add_field_list_type_references(visit_data, &visit_data.scopes, derived.results);
			}
		}
		case ^ast.Call_Expr: {
			add_expression_type_reference(visit_data, derived.expr);
			for arg in derived.args {
				add_expression_ident_references(visit_data, arg);
			}
		}
		case ^ast.Typeid_Type: {
			// TODO: Add specialization?
		}
		case ^ast.Array_Type: {
			if derived.len != nil {
				add_expression_ident_references(visit_data, derived.len);
			}
			add_expression_type_reference(visit_data, derived.elem);
		}
		case ^ast.Dynamic_Array_Type: {
			add_expression_type_reference(visit_data, derived.elem);
		}
		case ^ast.Ellipsis: {
			add_expression_type_reference(visit_data, derived.expr);
		}
		case ^ast.Implicit: {
			// Note: this is the context token. Don't need to do anything with that I don't think
		}
		case ^ast.Poly_Type: {
			if derived.specialization != nil {
				add_expression_type_reference(visit_data, derived.specialization);
			}
		}
		case ^ast.Matrix_Type: {
			add_expression_type_reference(visit_data, derived.row_count);
			add_expression_type_reference(visit_data, derived.column_count);
			add_expression_type_reference(visit_data, derived.elem);
		}
		case ^ast.Map_Type: {
			add_expression_type_reference(visit_data, derived.key);
			add_expression_type_reference(visit_data, derived.value);
		}
		case: {
			fmt.printf("Unhandled type %v in add_expression_type_reference.\n", expr.derived_expr);
			assert(false);
		}
	}
}

add_references_in_proc_attributes :: proc(visit_data: ^Visit_Data, proc_signature: ^Proc_Signature) {
	for attribute in proc_signature.attributes {
		for expression in attribute.elems {
			#partial switch e in expression.derived_expr {
				case ^ast.Ident: {
					// Dont care about these					
				}
				case ^ast.Field_Value: {
					name_ident, name_ok := e.field.derived.(^ast.Ident);
					if !name_ok do panic("Name of field value should be an ident!")

					switch name_ident.name {
						case "deferred_in", "deferred_out", "deferred_in_out", "deferred_none": {
							#partial switch value in e.value.derived {		
								case ^ast.Ident: {
									deferred_proc_signature, exists := &visit_data.other_proc_signatures[value.name];
									if exists {
										deferred_proc_signature.wrapped = true;
										add_global_reference(visit_data, value.name);
									}
								}
								case: {
									fmt.printf("deferred_in value is Unimplemented Type: %v\n", value);
								}
							}		
						}
					}
				}
				case: {
					fmt.printf("Unhandled attribute %v\n", e);
				}
			}
		}
	}
}

add_other_proc_signature :: proc(visit_data: ^Visit_Data, name: string, proc_lit: ^ast.Proc_Lit, attributes: [dynamic]^ast.Attribute) {
	type := proc_lit.type;
	type_string := visit_data.current_file_src[type.pos.offset:type.end.offset];
	//fmt.println(type_string);
	is_generic := type.generic;
	if !is_generic {
		for c in type_string {
			if c == '$' {
				is_generic = true;
				break;
			}
		}
	}
	/*if is_generic {
		fmt.printf("%s is generic\n", name);
	}*/
	if type.diverging {
		fmt.printf("%s is diverging\n", name);
	}

	visit_data.other_proc_signatures[name] = Proc_Signature{
		name = name, 
		type_string = type_string,
		type = type,	
		is_generic = is_generic,
		attributes = attributes[:],
		file_src = visit_data.current_file_src,
	};
}

add_reference_to_ident :: proc(referenced_identifiers: ^map[string]Referenced_Ident, name: string) {
	ref := referenced_identifiers[name];
	if ref.count == 0 {
		// First time
		log.infof("+ Add reference to global identifier %s\n", name);
	}
	ref.count += 1;
	referenced_identifiers[name] = ref;
}

add_global_reference :: proc(visit_data: ^Visit_Data, name: string) {
	add_reference_to_ident(&visit_data.referenced_identifiers, name);
}

visit_and_add_ident_references :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil;
	visit_data := cast(^Visit_Data)visitor.data;

	#partial switch derived in node.derived {
		case ^ast.Ident: {
			add_global_reference_if_not_declared_locally(visit_data, derived.name);			
		}
		case ^ast.Selector_Expr: {
			add_expression_ident_references(visit_data, derived.expr);
			return nil;
		}
		case ^ast.Implicit_Selector_Expr: {
			return nil;
		}
		case ^ast.Field_List: {
			//return nil;
		}
		case ^ast.Field: {
			add_declaration_names(&visit_data.scopes, derived.names);
			add_expression_ident_references(visit_data, derived.type);
			add_expression_ident_references(visit_data, derived.default_value);
			return nil;
		}
		case ^ast.Struct_Type: {
			return nil;
		}
		case ^ast.Field_Value: {
			add_expression_ident_references(visit_data, derived.value);
			return nil;
		}
		case ^ast.Proc_Lit: {
			add_proc_references(visit_data, derived);
			return nil;
		}
		case ^ast.Assign_Stmt: {			
			for expr in derived.rhs {				
				add_expression_ident_references(visit_data, expr);
			}
		}
	}
	return visitor;
} 

add_expression_ident_references :: proc(visit_data: ^Visit_Data, expr: ^ast.Expr) {
	visitor := ast.Visitor { visit_and_add_ident_references, visit_data }
	ast.walk(&visitor, &expr.expr_base);	
}

add_field_list_type_references :: proc(visit_data: ^Visit_Data, scopes: ^Scopes, field_list: ^ast.Field_List) {
	assert(field_list != nil);

	for field in field_list.list {
		add_declaration_names(scopes, field.names);
		if field.type != nil {
			add_expression_type_reference(visit_data, field.type);
		}
		if field.default_value != nil {
			add_expression_ident_references(visit_data, field.default_value);
		}
	}
}

add_constant_declaration_names :: proc(scopes: ^Scopes, names: []^ast.Expr) {
	for name_expr in names {
		name: string;
		#partial switch derived in name_expr.derived {
			case ^ast.Ident: {
				name = derived.name;
			}
			case: {
				fmt.printf("Unhandled constant declaration name type. %v\n", name_expr.derived);
				panic("Unhandled constant declaration name type.");
			}
		}
		assert(len(name) > 0);
		// TODO: Fix For When blocks
		/*if scopes.current_when_blocks_count > 0 {
			n := scopes.declarations_in_current_when_blocks[name];
			scopes.declarations_in_current_when_blocks[name] = n+1;
		}*/
		append(&scopes.current.constant_value_declaration_stack, Local_Declaration{name, {}});
	}
}

add_declaration_names :: proc(scopes: ^Scopes, names: []^ast.Expr) {
	for name_expr in names {
		name: string;
		#partial switch derived in name_expr.derived {
			case ^ast.Ident: {
				name = derived.name;
			}
			case ^ast.Poly_Type: {
				// Example: struct($T: typeid) or proc($T: typeid)
				if ident, ok := derived.type.derived.(^ast.Ident); ok {
					name = ident.name;
				}
				else {
					panic("Unhandled Poly_Type type not an ident.");
				}
			}
			case ^ast.Unary_Expr: {
				// Example: for &t in ts {}
				if ident, ok := derived.expr.derived.(^ast.Ident); ok {
					name = ident.name;
				}
				else {
					fmt.printf("Add??? unary expr declaration name %v\n", derived.expr);
					continue;
				}
			}
			case: {
				fmt.printf("Unhandled declaration name type. %v\n", name_expr.derived);
				panic("Unhandled declaration name type.");
			}
		}
		assert(len(name) > 0);
		if scopes.current_when_blocks_count > 0 {
			n := scopes.declarations_in_current_when_blocks[name];
			scopes.declarations_in_current_when_blocks[name] = n+1;
		}
		append(&scopes.current.declaration_stack, Local_Declaration{name, {}});
	}
}

enter_block :: proc(scopes: ^Scopes) {
	append(&scopes.current.block_stack, Block { 
		len(scopes.current.declaration_stack),
		len(scopes.current.constant_value_declaration_stack)
	});
}

exit_block :: proc(scopes: ^Scopes) {
	popped := pop(&scopes.current.block_stack);
	if len(scopes.current.declaration_stack) > popped.first_declaration_index {
		remove_range(
			&scopes.current.declaration_stack, 
			popped.first_declaration_index, 
			len(scopes.current.declaration_stack));
		remove_range(
			&scopes.current.constant_value_declaration_stack,
			popped.first_constant_value_declaration_index, 
			len(scopes.current.constant_value_declaration_stack));
	}
}

add_statement_references :: proc(visit_data: ^Visit_Data, statement: ^ast.Stmt) {
	#partial switch derived in statement.derived_stmt {
		case ^ast.Value_Decl: {
			// add name before so that the name can be used inside the value in the case that the value is a struct type. 
			add_declaration_names(&visit_data.scopes, derived.names);

			for value in derived.values {
				if enum_type, is_enum := value.derived_expr.(^ast.Enum_Type); is_enum {
					// Handle enum as separate case to not add references to the names of the enum values.
					if enum_type.base_type != nil {
						add_expression_ident_references(visit_data, enum_type.base_type);
					}
	
					for field in enum_type.fields {
						if field_value, ok := field.derived.(^ast.Field_Value); ok {
							add_expression_ident_references(visit_data, field_value.value);
						}
					}
				}
				else {
					add_expression_ident_references(visit_data, value);
				}
			}
			if derived.type != nil do add_expression_type_reference(visit_data, derived.type);
		}
		case ^ast.For_Stmt: {
			enter_block(&visit_data.scopes);

			if derived.init != nil {
				add_statement_references(visit_data, derived.init);
				/*if value_decl, ok := derived.init.derived_stmt.(^ast.Value_Decl); ok {
					for value in value_decl.values {
						add_expression_ident_references(visit_data, value);
					}
					if value_decl.type != nil do add_expression_type_reference(visit_data, value_decl.type);
					add_declaration_names(visit_data, value_decl.names);
				}*/
			}
			if derived.cond != nil {
				add_expression_ident_references(visit_data, derived.cond);	
			}
			if derived.post != nil {
				add_statement_references(visit_data, derived.post);
			}
			if derived.body != nil {
				if if_block, ok := derived.body.derived_stmt.(^ast.Block_Stmt); ok {
					add_block_references(visit_data, if_block);
				}
				else {
					assert(false, "Unhandled: for stmt body is not a block!");
				}
			}
			exit_block(&visit_data.scopes);
		}
		case ^ast.Range_Stmt: {
			scopes := &visit_data.scopes;
			enter_block(scopes);

			add_declaration_names(scopes, derived.vals);
			add_expression_ident_references(visit_data, derived.expr);

			if derived.body != nil {
				if if_block, ok := derived.body.derived_stmt.(^ast.Block_Stmt); ok {
					add_block_references(visit_data, if_block);
				}
				else {
					assert(false, "Unhandled: range stmt body is not a block!");
				}
			}

			exit_block(scopes);
		}
		case ^ast.Switch_Stmt: {
			enter_block(&visit_data.scopes);
			if derived.init != nil do add_statement_references(visit_data, derived.init);
			add_expression_ident_references(visit_data, derived.cond);

			add_statement_references(visit_data, derived.body);

			exit_block(&visit_data.scopes);
		}
		case ^ast.Case_Clause: {
			enter_block(&visit_data.scopes);
			for st in derived.body {
				add_statement_references(visit_data, st);
			}
			exit_block(&visit_data.scopes);
		}
		case ^ast.Type_Switch_Stmt: {
			enter_block(&visit_data.scopes);
			assign := derived.tag.derived.(^ast.Assign_Stmt)
			add_declaration_names(&visit_data.scopes, assign.lhs);
			for expr in assign.rhs {
				add_expression_ident_references(visit_data, expr);
			}
			
			add_statement_references(visit_data, derived.body);
			exit_block(&visit_data.scopes);
		}
		case ^ast.If_Stmt: {
			// Add a surrounding block around the if block with the init statement.
			enter_block(&visit_data.scopes);
			if derived.init != nil {
				add_statement_references(visit_data, derived.init);
			}

			if derived.cond != nil {
				add_expression_ident_references(visit_data, derived.cond);	
			}
			add_statement_references(visit_data, derived.body);

			if derived.else_stmt != nil {
				add_statement_references(visit_data, derived.else_stmt);
			}
			exit_block(&visit_data.scopes);
		}
		case ^ast.When_Stmt: {
			scopes := &visit_data.scopes;
			when_blocks_index := scopes.current_when_blocks_count;
			
			scopes.current_when_blocks_count += 1;
			if derived.cond != nil {
				add_expression_ident_references(visit_data, derived.cond);
			}

			if derived.body != nil {
				if when_block, ok := derived.body.derived_stmt.(^ast.Block_Stmt); ok {
					enter_block(scopes);
					add_block_references(visit_data, when_block);
					exit_block(scopes);
				}
			}
			if derived.else_stmt != nil {
				// Can be Block_Stmt or When_Stmt
				//fmt.printf("When else is %v\n", reflect.union_variant_typeid(derived.else_stmt.derived));
				if else_block, ok := derived.else_stmt.derived_stmt.(^ast.Block_Stmt); ok {
					scopes.current_when_blocks_count += 1;
					enter_block(scopes);
					add_block_references(visit_data, else_block);
					exit_block(scopes);
				}
				else {
					// This is to assert that it is actually a when stmt
					a := derived.else_stmt.derived_stmt.(^ast.When_Stmt);
					add_statement_references(visit_data, derived.else_stmt);
				}
			}
			if when_blocks_index == 0 {
				for decl, count in scopes.declarations_in_current_when_blocks {
					//fmt.printf("\tWHEN: %s was declared in %d/%d blocks\n", decl, count, scopes.current_when_blocks_count)
					if count < scopes.current_when_blocks_count { 
						// Not declared in all blocks, so add as potential global
						// add_global_reference(visit_data, decl);
					}
					else {
						// Declared in all blocks
						append(&scopes.current.declaration_stack, Local_Declaration{decl, {}});
					}
				}

				clear(&scopes.declarations_in_current_when_blocks);
				scopes.current_when_blocks_count = 0;
			}

		}
		case ^ast.Block_Stmt: {
			enter_block(&visit_data.scopes);
			add_block_references(visit_data, derived);
			exit_block(&visit_data.scopes);
		}
		case ^ast.Expr_Stmt: {
			add_expression_ident_references(visit_data, derived.expr);
		}
		case: {
			visitor := ast.Visitor { visit_and_add_ident_references, visit_data }
			ast.walk(&visitor, &statement.stmt_base);
		}
	}
}

add_all_constant_declarations_in_block :: proc(visit_data: ^Visit_Data, block: ^ast.Block_Stmt) {
	for statement in block.stmts {
		if value_decl, ok := statement.derived_stmt.(^ast.Value_Decl); ok && !value_decl.is_mutable {
			add_constant_declaration_names(&visit_data.scopes, value_decl.names);
		}
	}
}

add_block_references :: proc(visit_data: ^Visit_Data, block: ^ast.Block_Stmt) {
	// Constant declarations must be added before 
	// since they can be defined out of order.
	add_all_constant_declarations_in_block(visit_data, block);

	for statement in block.stmts {
		/*if value_decl, ok := statement.derived_stmt.(^ast.Value_Decl); ok && !value_decl.is_mutable {
			continue;
		}*/
		add_statement_references(visit_data, statement);	
	}	
}

push_local_declaration :: proc(scopes: ^Scopes, type: Local_Declarations_Type) {
	append(&scopes.local_declaration_stack, Local_Declarations{}); // TODO: Reuse
	scopes.current = &scopes.local_declaration_stack[len(scopes.local_declaration_stack)-1];

	scopes.current.type = type;
	clear(&scopes.current.declaration_stack);
	clear(&scopes.current.block_stack);
}

pop_local_declaration :: proc(scopes: ^Scopes) {
	pop(&scopes.local_declaration_stack);
	if len(scopes.local_declaration_stack) > 0 {
		scopes.current = &scopes.local_declaration_stack[len(scopes.local_declaration_stack)-1];
	}
	else {
		scopes.current = nil;
	}
}
add_proc_references :: proc(visit_data: ^Visit_Data, proc_lit: ^ast.Proc_Lit) {
	scopes := &visit_data.scopes;
	push_local_declaration(scopes, .Proc);
	defer pop_local_declaration(scopes);

	type := proc_lit.type;
	add_field_list_type_references(visit_data, scopes, type.params);
	if type.results != nil do add_field_list_type_references(visit_data, scopes, type.results);

	if block, ok := proc_lit.body.derived_stmt.(^ast.Block_Stmt); ok {
		enter_block(scopes);
		add_block_references(visit_data, block);
		exit_block(scopes);
	}	
}

Value_Declaration_Add_Reference_Data :: struct {
	name: string,
	visit_data: ^Visit_Data,
	/*referenced_identifiers: ^map[string]Referenced_Ident,
	scopes: ^Scopes,*/
}

maybe_get_local_declaration :: proc(visit_data: ^Visit_Data, name: string) -> ^Local_Declaration {
	if visit_data.scopes.current != nil {
		#reverse for &declared in visit_data.scopes.current.declaration_stack {
			if declared.name == name {
				return &declared;
			}
		}
		#reverse for &ld in visit_data.scopes.local_declaration_stack {
			#reverse for &declared in ld.constant_value_declaration_stack {
				if declared.name == name {
					return &declared;
				}
			}
		}
	}
	return nil;
}

name_is_declared_locally :: proc(visit_data: ^Visit_Data, name: string) -> bool {
	if visit_data.scopes.current != nil {
		#reverse for declared in visit_data.scopes.current.declaration_stack {
			if declared.name == name {
				return true;
			}
		}
		#reverse for ld in visit_data.scopes.local_declaration_stack {
			#reverse for declared in ld.constant_value_declaration_stack {
				if declared.name == name {
					return true;
				}
			}
		}
	}
	return false;
}

add_global_reference_if_not_declared_locally :: proc(visit_data: ^Visit_Data, name: string) {
	declared_locally := name_is_declared_locally(visit_data, name);
	if !declared_locally {
		//fmt.printf("%s is not declared locally\n", name);
		add_global_reference(visit_data, name);
	}
}

visit_value_declaration_and_add_references :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
	if any_node == nil {
		return nil;
	}
	data := cast(^Value_Declaration_Add_Reference_Data)visitor.data;

	handle_derived_node_with_type_field :: proc(node: $Node_Type, data: ^Value_Declaration_Add_Reference_Data) {
		if node.type != nil {
			handle_type_expression(node.type, data);			
		}
	}

	handle_type_expression :: proc(expr: ^ast.Expr, data: ^Value_Declaration_Add_Reference_Data) {
		#partial switch derived in expr.derived_expr {
			case ^ast.Ident: {
				add_global_reference_if_not_declared_locally(data.visit_data, derived.name);
			}
			case ^ast.Call_Expr: {
				handle_type_expression(derived.expr, data);
				for arg in derived.args {
					handle_type_expression(arg, data);
				}
			}
			case ^ast.Union_Type: {
				for variant in derived.variants {
					handle_type_expression(variant, data);
				}
			}
			case ^ast.Struct_Type: {
				visitor := ast.Visitor {
					visit_value_declaration_and_add_references, data,
				}
				ast.walk(&visitor, expr);
				/*for field in derived.fields {

				}*/
			}
			case ^ast.Pointer_Type: {
				handle_type_expression(derived.elem, data);
			}
			case ^ast.Array_Type: {
				if derived.len != nil {
					handle_type_expression(derived.len, data);	
				}
				handle_type_expression(derived.elem, data);
			}
			case ^ast.Dynamic_Array_Type: {
				handle_type_expression(derived.elem, data);
			}
			case ^ast.Bit_Set_Type: {
				handle_type_expression(derived.elem, data);
			}
			case ^ast.Map_Type: {
				handle_type_expression(derived.key, data);
				handle_type_expression(derived.value, data);
			}
			case ^ast.Typeid_Type: {
				if derived.specialization != nil {
					handle_type_expression(derived.specialization, data);
				}
			}
			case ^ast.Paren_Expr: {
				handle_type_expression(derived.expr, data);
			}
			case ^ast.Binary_Expr: {
				handle_type_expression(derived.left, data);
				handle_type_expression(derived.right, data);
			}
			case ^ast.Unary_Expr: {
				handle_type_expression(derived.expr, data);
			}			
			case ^ast.Selector_Expr: {
				// Dont add since these are handled by import
				handle_type_expression(derived.expr, data);
			}
			case ^ast.Basic_Lit: {
				// No type
			}
			case ^ast.Proc_Type: {
				visitor := ast.Visitor {
					visit_value_declaration_and_add_references, data,
				}
				ast.walk(&visitor, expr);
			}
			case ^ast.Helper_Type: {
				handle_type_expression(derived.type, data);
			}
			case ^ast.Comp_Lit: {
				if derived.type != nil {
					handle_type_expression(derived.type, data);
				}
				for elem in derived.elems {
					handle_type_expression(elem, data);
				}
			}
			case ^ast.Field_Value: {
				handle_type_expression(derived.value, data);
			}
			case ^ast.Multi_Pointer_Type: {
				handle_type_expression(derived.elem, data);
			}
			case ^ast.Ellipsis: {
				//handle_
			}
			case ^ast.Implicit_Selector_Expr: {
				// Don't care?
			}
			case ^ast.Basic_Directive: {
				// TODO?
			}
			case: {
				log.errorf("Unhandled type expression %v at %v\n", reflect.union_variant_typeid(expr.derived), expr.pos);
				//assert(false);
			}
		}
	} 

	#partial switch node in any_node.derived {
		case ^ast.Ident: {
			add_global_reference_if_not_declared_locally(data.visit_data, node.name);
		}
		case ^ast.Value_Decl: {			
			handle_derived_node_with_type_field(node, data);
		}
		case ^ast.Field_List: {

		}
		case ^ast.Field: {
			handle_derived_node_with_type_field(node, data);
			if node.default_value != nil {
				handle_type_expression(node.default_value, data);
			}
			return nil;
		}
		case ^ast.Helper_Type: {
			handle_derived_node_with_type_field(node, data);			
		}
		case ^ast.Distinct_Type: {
			handle_derived_node_with_type_field(node, data);			
		}
		case ^ast.Array_Type: {
			if node.len != nil do handle_type_expression(node.len, data);
			handle_type_expression(node.elem, data);
		}
		case ^ast.Dynamic_Array_Type: {
			handle_type_expression(node.elem, data);
		}
		case ^ast.Pointer_Type: {
			handle_type_expression(node.elem, data);
		}
		case ^ast.Map_Type: {
			handle_type_expression(node.key, data);
			handle_type_expression(node.value, data);
		}
		case ^ast.Binary_Expr: {
			handle_type_expression(node.left, data);
			handle_type_expression(node.right, data);
		}
		case ^ast.Unary_Expr: {
			handle_type_expression(node.expr, data);
		}
		case ^ast.Bit_Set_Type: {
			handle_type_expression(node.elem, data);
			if node.underlying != nil do handle_type_expression(node.underlying, data);
		}
		case ^ast.Enum_Type: {
			if node.base_type != nil {
				handle_type_expression(node.base_type, data);
			}
			for field in node.fields {
				if field_value, ok := field.derived.(^ast.Field_Value); ok {
					ast.walk(visitor, field_value.value);
				}
			}
			return nil;
		}
		case ^ast.Type_Cast: {
			handle_type_expression(node.type, data);
			handle_type_expression(node.expr, data);
		}
		case ^ast.Proc_Group: {
			for arg in node.args {
				if ident, ok := arg.derived.(^ast.Ident); ok {
					if proc_signature, ok := &data.visit_data.other_proc_signatures[ident.name]; ok {
						if proc_signature.is_generic {
							log.errorf("Proc '%s' in referenced proc group '%s' is generic. Calling generic procs - that are defined in your program - from hotloaded functions is not possible (It may be, but not yet).", ident.name, data.name);
							data.visit_data.failed = false;
						}
					}
					else {
						log.errorf("Proc '%s' in proc group '%s' is not defined. %v\n", ident.name, data.name, node.pos);
						data.visit_data.failed = false;
					}
					add_global_reference(data.visit_data, ident.name);
				}
			}
			return nil;
		}
		case ^ast.Selector_Expr: {
			handle_type_expression(node.expr, data);
			return nil;
		}
		case ^ast.Proc_Type: {}
		case ^ast.Struct_Type: {
			scopes := &data.visit_data.scopes;

			// If this is a struct declared inside a struct, the parents generic declarations should be inherited. So don't add a new local declaration in that case.
			push_new_local_declaration := scopes.current == nil || scopes.current.type != .Struct;
			if push_new_local_declaration {
				push_local_declaration(scopes, .Struct);
			}
			defer if push_new_local_declaration {
				pop_local_declaration(scopes);
			}
			
			if node.poly_params != nil {
				if !push_new_local_declaration {
					log.errorf("Structs defined inside a struct can't take polymorphic parameters. %v", node.pos);
					data.visit_data.failed = true;
				}
				add_field_list_type_references(data.visit_data, scopes, node.poly_params);
			}

			ast.walk(visitor, node.fields);

			return nil;
		}
		case ^ast.Union_Type: {}
		case ^ast.Basic_Lit: {}
		case ^ast.Comp_Lit: {
			if node.type != nil do handle_type_expression(node.type, data);
			for elem in node.elems {
				handle_type_expression(elem, data);
			}
			return nil;
		}
		case ^ast.Call_Expr: {
			if bd, ok := node.expr.derived_expr.(^ast.Basic_Directive); ok && bd.name == "config" {

				visit_data := data.visit_data;
				assert(len(node.args) == 2);
				name, name_ok := node.args[0].derived_expr.(^ast.Ident);
				assert(name_ok);

				hc := Hashtag_Config{
					name = name.name,
					expr = visit_data.current_file_src[node.pos.offset:node.end.offset],
				};
				append(&visit_data.hashtag_configs, hc);
				return nil;
			} 
		}
		case ^ast.Bit_Field_Field: {
			handle_type_expression(node.type, data);
		}
		case ^ast.Bit_Field_Type: {
			handle_type_expression(node.backing_type, data);
			scopes := &data.visit_data.scopes;

			// If this is a struct declared inside a struct, the parents generic declarations should be inherited. So don't add a new local declaration in that case.
			push_new_local_declaration := scopes.current == nil || scopes.current.type != .Struct;
			if push_new_local_declaration {
				push_local_declaration(scopes, .Struct);
			}
			defer if push_new_local_declaration {
				pop_local_declaration(scopes);
			}

			for field in node.fields {
				//ast.walk(visitor, field);
				handle_type_expression(field.type, data);
				handle_type_expression(field.bit_size, data);
			}
			return nil;
		}
		case ^ast.Basic_Directive: {
			//panic("Handled in case ^ast.Call_Expr");
		}
		case ^ast.Field_Value: {
			// TODO: What to do?
		}
		case ^ast.Implicit_Selector_Expr: {
			// TODO: What to do?
			return nil;
		}
		case: {
			log.errorf("Unhandled Value declaration node %v. %v\n", reflect.union_variant_typeid(any_node.derived), any_node.pos);
		}
	}
	return visitor;
}

When_Tree_Add_References_For_Declaration :: struct {
	visit_data: ^Visit_Data,
	//referenced_identifiers: ^map[string]Referenced_Ident,
	declaration_name: string,
}

visit_when_tree_and_add_references_for_specific_value_declaration :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
	if any_node == nil {
		return nil;
	}

	data := cast(^When_Tree_Add_References_For_Declaration)visitor.data;

	if value_decl, ok := any_node.derived.(^ast.Value_Decl); ok {

		for name, index in value_decl.names {
			if ident, ok := name.derived_expr.(^ast.Ident); ok {
				if ident.name == data.declaration_name {
					add_ref_data := Value_Declaration_Add_Reference_Data {
						ident.name,
						data.visit_data,
						//data.referenced_identifiers,
					}
					visitor := ast.Visitor {
						visit_value_declaration_and_add_references,
						&add_ref_data,
					}
					#partial switch derived in value_decl.values[index].derived {
						case ^ast.Proc_Lit: {
							//fmt.printf("add proc type references %s\n", ident.name);
							ast.walk(&visitor, &derived.type.node);
						}
						case: {
							//fmt.printf("When tree Value decl type %v at %v\n", reflect.union_variant_typeid(value_decl.values[index].derived), value_decl.values[index].pos);
							ast.walk(&visitor, &value_decl.values[index].expr_base);
						}
					}
				}
			}
		}
		
		return nil;
	}
	return visitor;
}


Visit_Data_And_When_Tree :: struct {
	visit_data: ^Visit_Data,
	tree: ^When_Tree,
}

visit_when_tree_and_add_all_value_declarations :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
	if any_node == nil {
		return nil;
	}

	data := cast(^Visit_Data_And_When_Tree)visitor.data;
	visit_data := data.visit_data;
	tree := data.tree;
	if decl, ok := any_node.derived.(^ast.Value_Decl); ok {
		for name_node, index in decl.names {
			name: string;
			if ident, ok := name_node.derived.(^ast.Ident); ok {
				name = ident.name;

				proc_lit: ^ast.Proc_Lit;
				if len(decl.values) > index {
					is_proc: bool;
					proc_lit, is_proc = decl.values[index].derived_expr.(^ast.Proc_Lit);
					if !is_proc {
						proc_lit = nil;
					}
				}

				if proc_lit != nil {
					if visit_data.do_add_procs_in_when_trees {
						tree.all_proc_declarations[name] = Type_Declaration_State.Defined;

						add_other_proc_signature(visit_data, name, proc_lit, decl.attributes);
					}
				}
				else {
					tree.all_type_declarations[name] = Type_Declaration_State.Defined;
				}
			}
			else {
				assert(false, "Name for value declaration is not an identifier???\n");
			}
		}
	}

	return visitor;
}

// visitor.data type = Value_Declaration_Add_Reference_Data
visit_when_tree_and_add_condition_references :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
	if any_node == nil {
		return nil;
	}

	#partial switch derived in any_node.derived {
		case ^ast.When_Stmt: {
			if derived.cond != nil {
				cond_visitor := ast.Visitor {
					visit_value_declaration_and_add_references,
					visitor.data,
				} 
				ast.walk(&cond_visitor, derived.cond);
			}

			ast.walk(visitor, derived.body);
			/*if block, ok := derived.body.derived.(^ast.Block); ok {
				for statement in block.stmts {
					ast.walk(visitor, statement);
				}
			}*/

			ast.walk(visitor, derived.else_stmt);
		}
		case ^ast.Block_Stmt: {
			return visitor;
		}
	}

	return nil;
}

When_Tree_Write_Data :: struct {
	tree: ^When_Tree,
	sb: ^strings.Builder,
	//referenced_identifiers: map[string]int,
	indent_depth: int,
}

write_when_statement :: proc(data: ^When_Tree_Write_Data, statement: ^ast.Stmt) {
	tree := cast(^When_Tree)data.tree;
	#partial switch derived in statement.derived {
		case ^ast.When_Stmt: {
			write_when_tree(data, derived);
		}
		case ^ast.Value_Decl: {
			any_name_was_referenced := false;
			for name in derived.names {
				if ident, ok := name.derived_expr.(^ast.Ident); ok {
					if tree.all_type_declarations[ident.name] == .Referenced {
						any_name_was_referenced = true;
						break;
					}
				}
			}

			if any_name_was_referenced {
				write_indent(data.sb, data.indent_depth);
				strings.write_string(data.sb, tree.file_src[derived.pos.offset:derived.end.offset]);
			}
		}
		case: {
			//assert(false);
		}
	}
}

write_when_body :: proc(data: ^When_Tree_Write_Data, body: ^ast.Stmt) {
	data.indent_depth += 1;
	/*visitor := ast.Visitor {
		visit_when_tree_and_write_all_referenced_value_declarations,
		data,
	}
	ast.walk(&visitor, &body.stmt_base);*/

	#partial switch derived in body.derived {
		case ^ast.Block_Stmt: {
			for stmt in derived.stmts {
				write_when_statement(data, stmt);
			}
		}
		case: {
			write_when_statement(data, body);
		}
	}
	data.indent_depth -= 1;
}

write_when_tree :: proc(data: ^When_Tree_Write_Data, statement: ^ast.When_Stmt) {
	tree := data.tree;
	//statement := tree.node.derived.(^ast.When_Stmt);
	write_indent(data.sb, data.indent_depth);
	strings.write_string(data.sb, "when ");
	strings.write_string(data.sb, tree.file_src[statement.cond.pos.offset:statement.cond.end.offset]);
	strings.write_string(data.sb, " {\n");

	write_when_body(data, statement.body);

	write_indent(data.sb, data.indent_depth);
	strings.write_string(data.sb, "}\n");

	if statement.else_stmt != nil {
		write_indent(data.sb, data.indent_depth);
		strings.write_string(data.sb, "else ");
		if else_when, ok := statement.else_stmt.derived.(^ast.When_Stmt); ok {
			write_when_tree(data, else_when);
		}
		else {
			strings.write_string(data.sb, "{\n");
			write_when_body(data, statement.else_stmt);
			write_indent(data.sb, data.indent_depth);
			strings.write_string(data.sb, "}\n");
		}
	}
}

write_indent :: proc(sb: ^strings.Builder, depth: int) {
	for ii in 0..<depth do strings.write_byte(sb, '\t');
}

Magic_Suffixes :: enum {
	bsd,
	darwin,
	freestanding,
	haiku,
	js,
	linux,
	wasi,
	windows,
	freebsd,
	openbsd,
	essence,

	darwin_amd64,
    darwin_arm64,
    essence_amd64,
    linux_i386,
    linux_amd64,
    linux_arm64,
    linux_arm32,
    windows_i386,
    windows_amd64,
    freebsd_i386,
    freebsd_amd64,
    openbsd_amd64,
    haiku_amd64,
    freestanding_wasm32,
    wasi_wasm32,
    js_wasm32,
    freestanding_wasm64p32,
    js_wasm64p32,
    wasi_wasm64p32,
    freestanding_amd64_sysv,
    freestanding_amd64_win64,
    freestanding_arm64,

	test
};

OS_NAMES := [type_of(ODIN_OS)]string {
	.Unknown = "unknown",
	.Windows = "windows",
	.Darwin = "darwin",
	.Linux = "linux",
	.Essence = "essence",
	.FreeBSD = "freebsd",
	.OpenBSD = "openbsd",
	.WASI = "wasi",
	.JS = "js",
	.Freestanding = "freestanding",
	.Haiku = "haiku",
	.NetBSD = "netbsd",
	.Orca = "orca",
};

ARCH_NAMES := [type_of(ODIN_ARCH)]string {
	.Unknown = "unknown",
	.amd64 = "amd64",
	.i386 = "i386",
	.arm32 = "arm32",
	.arm64 = "arm64",
	.wasm32 = "wasm32",
	.wasm64p32 = "wasm64p32",
	.riscv64 = "riscv64",
};

target_os := ODIN_OS;
target_arch := ODIN_ARCH;
allowed_magic_suffixes: [Magic_Suffixes]bool;

my_collect_package :: proc(path: string) -> (pkg: ^ast.Package, success: bool) {
	NO_POS :: tokenizer.Pos{}

	pkg_path, pkg_path_ok := filepath.abs(path)
	if !pkg_path_ok {
		return
	}

	path_pattern := fmt.tprintf("%s/*.odin", pkg_path)
	matches, err := filepath.glob(path_pattern)
	defer delete(matches)

	if err != nil {
		return
	}

	pkg = ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = pkg_path


	

	magic_suffix_names := reflect.enum_field_names(typeid_of(Magic_Suffixes));
	for match in matches {
		DOT_ODIN :: ".odin";
		name := match[:len(match)-len(DOT_ODIN)];
		skip := false;
		for suffix, index in magic_suffix_names {
			if strings.has_suffix(name, suffix) {
				log.infof("File %s is has magic suffix!", match);

				if allowed_magic_suffixes[Magic_Suffixes(index)] {
					log.info("And its allowed!");
				}
				else {
					log.info("And it NOT allowed!");
					skip = true;
				}
			}
		}
		if skip do continue;
		/*if strings.has_suffix(name, ) {
			log.infof("Skip javascript file %s", match);
			continue;
		}
		log.infof("Add file '%s'", match);*/
		src: []byte
		fullpath, ok := filepath.abs(match)
		if !ok {
			return
		}
		src, ok = os.read_entire_file(fullpath)
		if !ok {
			delete(fullpath)
			return
		}
		file := ast.new(ast.File, NO_POS, NO_POS)
		file.pkg = pkg
		file.src = string(src)



		file.fullpath = fullpath
		pkg.files[fullpath] = file
	}

	success = true
	return
}

my_parse_package_from_path :: proc(path: string, p: ^parser.Parser = nil) -> (pkg: ^ast.Package, ok: bool) {
	pkg, ok = my_collect_package(path)
	if !ok {
		return
	}
	ok = my_parse_package(pkg, p)
	return
}

file_should_be_included :: proc(file: ^ast.File) -> bool {
	tokenizor: tokenizer.Tokenizer;
	tokenizer.init(&tokenizor, file.src, file.fullpath);

	has_build_comment := false;
	any_build_tag_included := false;

	for {
		token := tokenizer.scan(&tokenizor);
		if token.kind == .File_Tag {

			tag_text := token.text;
			text := tag_text;
			if !strings.has_prefix(text, "#") {
				log.errorf("Tag text '%s' does not start with '#'", tag_text);
				return false;
			}

			text = text[1:];


			text = strings.trim_left_space(text);

			if strings.has_prefix(text, "+build") {
				text = text[len("+build"):];
				//fmt.printf("Build comment text is %v\n", text);
				has_build_comment = true;

				any_allowed := false;
				for word in strings.split_iterator(&text, ",") {
					tag := strings.trim_space(word);

					if tag == OS_NAMES[target_os] || tag == ARCH_NAMES[target_arch] {
						//log.infof("Build tag %s is allowed!", tag);
						any_build_tag_included = true;
					}
					/*for os_name in OS_NAMES {
						if tag == os_name {
							log.infof("Build tag '%s' is correct!", tag);

							if allowed_magic_suffixes[Magic_Suffixes(index)] {
								log.info("And its allowed!");
								any_build_tag_included = true;
								//return true;
							}
							else {
								log.info("And it NOT allowed!");
							}
						}
					}*/
				}					
			}
			else {
				//log.infof("Ignore file tag '%s'", tag_text);
			}
		}
		else if token.kind == .Package {
			break;			
		}
		else {
			log.errorf("Failed to parse file %s. Expected package or comment, got %v\n", file.fullpath, token.kind);
			return false;
		}
	}
		
	return !has_build_comment || any_build_tag_included;
}

parse_odin_file_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.error("Failed to parse input file.");
	sb: strings.Builder;
	sb.buf.allocator = context.temp_allocator;
	fmt.sbprintf(&sb, "%s(%d:%d): ", pos.file, pos.line, pos.column)
	fmt.sbprintf(&sb, msg, ..args)
	log.errorf(strings.to_string(sb));
}

my_parse_package :: proc(pkg: ^ast.Package, p: ^parser.Parser = nil) -> bool {
	p := p
	if p == nil {
		p = &parser.Parser{}
		p^ = parser.default_parser()
		p.err = parse_odin_file_error_handler;
	}

	ok := true

	files := make_dynamic_array_len_cap([dynamic]^ast.File, 0, len(pkg.files), context.temp_allocator)
	i := 0
	for _, file in pkg.files {
		if file_should_be_included(file) {
			append(&files, file);
			i += 1
		}
		else {
			log.infof("Skip file %s", file.fullpath);
		}
	}
	slice.sort(files[:])
	
	for file in files {
		if !parser.parse_file(p, file) {
			ok = false
		}
		else if p.error_count > 0 {
			ok = false;
		}

		/*skip := false;

		for comment in file.comments {
			if comment.node.pos.line >= file.pkg_token.pos.line {
				break;
			}

			for comment_token in comment.list {
				
			}
		}*/

		if pkg.name == "" {
			pkg.name = file.pkg_decl.name
		} else if pkg.name != file.pkg_decl.name {
			parser.error(p, file.pkg_decl.pos, "different package name, expected '%s', got '%s'", pkg.name, file.pkg_decl.name)
		}
	}

	return ok
}


main :: proc() {	

	stopwatch: time.Stopwatch;
	time.stopwatch_start(&stopwatch);
    
	do_generate_lib_code := ODIN_DEBUG;
	do_generate_loader := ODIN_DEBUG;
	package_path: string;
	lowest_logger_level := runtime.Logger_Level.Warning;

	args := os.args[1:];
	if len(args) < 1 {
		when ODIN_DEBUG {
			package_path = "test_program"
		}
		else {
			fmt.printf("Usage: %s <path_to_package> [-lib and/or -loader]\n", os.args[0]);
			os.exit(1);
		}
	}
	else {
		package_path = args[0];
		args = args[1:];
	}
	for arg in args {
		if arg == "-lib" {
			do_generate_lib_code = true;
		}
		else if arg == "-loader" {
			do_generate_loader = true;
		}
		else if arg == "-log-info" {
			lowest_logger_level = .Info;
		}
		else if arg == "-log-warn" {
			lowest_logger_level = .Warning;
		}
		else if arg == "-log-error" {
			lowest_logger_level = .Error;
		}
		else {
			fmt.printf("Unknown flag %s\n", arg);
			os.exit(1);
		}
	}

	setup_allowed_magic_suffixes();

	logger_options := runtime.Logger_Options {.Level};
	if console_can_be_colored() {
		logger_options += {.Terminal_Color};
	}
	context.logger = log.create_console_logger(lowest = lowest_logger_level, opt = logger_options);
	

	if !do_generate_lib_code && !do_generate_loader {
		fmt.printf("Usage: %s <path_to_package> [-lib and/or -loader]\n", os.args[0]);
		os.exit(1);
	}

	fmt.printf("Generate hotloading for %s.\n", package_path);
	make_dir: if error := os.make_directory("hotload_generated_code"); error != nil {
		#partial switch error in error {
			case os.General_Error: {
				#partial switch error {
					case .Exist: {
						break make_dir;
					}
				}
			}
		}
		log.errorf("Failed to create output directory: %v\n", error);
		os.exit(1);
	}
	output_path := "hotload_generated_code/code.odin"

	//package_path := "test_program";
	//pack, pack_ok := parser.parse_package_from_path("src");
	pack, pack_ok := my_parse_package_from_path(package_path);
	if !pack_ok {
		fmt.printf("Failed to parse package\n");
		os.exit(1);
	}
	if len(pack.files) == 0 {
		fmt.printf("Package %s has no files!\n", package_path);
		os.exit(1);
	}

	log.infof("Parsed package %s", package_path);
	
	visit_node :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
		visit_data := cast(^Visit_Data)visitor.data;
		if any_node == nil {
			return nil;
		}
		//fmt.printf("")
		#partial switch node in any_node.derived {
			case ^ast.Package: {
				//fmt.printf("Package: %s - %s\n\n", node.name, node.fullpath);
				return visitor;
			}
			case ^ast.File: {
				//fmt.printf("File: %s\n\n", node.fullpath);
				if visit_data.current_file_has_hotload_procs {
					append(&visit_data.hotload_files, visit_data.current_file_path);
					visit_data.current_file_has_hotload_procs = false;
					visit_data.current_file_path = "";
					visit_data.current_file_src = "";
				}
				/*if strings.has_suffix(node.fullpath, "hotload_procs.odin") {
					return nil;
				}*/
				dir, filename := filepath.split(node.fullpath);
				if matched, err := filepath.match("hotload_procs_*.odin", filename); matched {
					return nil;
				}

				visit_data.current_file_src = node.src;
				visit_data.current_file_path = node.fullpath;
				visit_data.current_file_has_hotload_procs = false;
				return visitor;
			}
			case ^ast.Import_Decl: {
				if node.fullpath not_in visit_data.imports {
					package_name: string;
					name_is_user_specified := false;
					if node.name.text != "" {
						package_name = node.name.text;
						name_is_user_specified = true;
						log.infof("Imported package '%s' has a custom name = '%s'", node.fullpath, package_name);
					}
					else {
						when false {
							success: bool;
							package_name, success = get_package_name_at_path(visit_data.package_path, strings.trim(node.fullpath, "\""), visit_data.import_file_allocator);
							if success {
								log.infof("Imported package %s name = '%s'\n", node.fullpath, package_name);
							}
							else {
								log.errorf("Failed to get package name for import %s\n", node.fullpath);
							}
						}
						else {
							package_path := strings.trim(node.fullpath, "\"");
							colon_index := strings.index_byte(package_path, ':');
							if colon_index != -1 {
								package_path = package_path[colon_index+1:];
							}
							last_slash := strings.last_index_byte(package_path, '/');
							if last_slash != -1 {
								package_name = package_path[last_slash+1:];
							}
							else {
								package_name = package_path;
							}
							log.infof("Imported package '%s' name = '%s'", node.fullpath, package_name);
						}
					}
					
					visit_data.imports[node.fullpath] = Import { 
						name = package_name, 
						name_is_user_specified = name_is_user_specified,
					};
					visit_data.packages[package_name] = Import { 
						name = package_name, 
						fullpath = node.fullpath, 
						name_is_user_specified = name_is_user_specified,
					};
					/*strings.write_string(visit_data.sb, node.import_tok.text);
					strings.write_byte(visit_data.sb, ' ');
					strings.write_string(visit_data.sb, node.fullpath);
					strings.write_byte(visit_data.sb, '\n');*/
				}

			}
			case ^ast.Block_Stmt: {
				return visitor;
			}
			case ^ast.When_Stmt: {
				tree := When_Tree {
					node = any_node.derived.(^ast.When_Stmt),
					file_src = visit_data.current_file_src,
				}

				for tree.node != nil {
					yes, is_simple := evaluate_simple_bool_expression(tree.node.cond);
					if is_simple && !yes {
						if tree.node.else_stmt != nil {
							
							if else_when, is_else_when := tree.node.else_stmt.derived.(^ast.When_Stmt); is_else_when {
								tree.node = else_when;
							}
							else if else_block, is_else_block := tree.node.else_stmt.derived.(^ast.Block_Stmt); is_else_block {
								ast.walk(visitor, else_block);
								tree.node = nil;
								break;
							}
						}
						else {
							tree.node = nil;
						}
					}
					else if is_simple && yes {
						// Add declarations to the global scope, since the when evaluated to true.
						ast.walk(visitor, tree.node.body);
						tree.node = nil;
						break;
					}
					else {
						break;
					}
				}

				if tree.node != nil {
					tree_visitor_data := Visit_Data_And_When_Tree {
						visit_data = visit_data,
						tree = &tree,
					}
					tree_visitor := ast.Visitor {
						visit_when_tree_and_add_all_value_declarations,
						&tree_visitor_data,
					}
					ast.walk(&tree_visitor, any_node);

					log.info("Tree defines:");
					for name in tree.all_type_declarations {
						log.infof("\t%s", name);
					}
					log.info("Tree procs:");
					for name in tree.all_proc_declarations {
						log.info("\t%s", name);
					}
					append(&visit_data.when_trees, tree);
				}
				else {
					//fmt.printf("When Tree was completely removed!\n");
				}
			}
			case ^ast.Value_Decl: {
				vd := (^ast.Value_Decl)(node);
				//return &declaration_visitor;
				//fmt.printf("!!!VALUE DECL!!! %v\n", visit_data.current_file_src[node.pos.offset:node.end.offset-1]);
				//if len(node.values) != len(node.names) do break;

				do_hotload := false;
				is_file_private := false;
				for attribute in vd.attributes {
					//fmt.printf("\t%v\n", attribute);
					for expression in attribute.elems {
						#partial switch e in expression.derived_expr {
							case ^ast.Ident: {
								if e.name == "hotload" {
									do_hotload = true;
								}
								else if e.name == "export" {
									//fmt.printf("Export this proc!\n");
								}
								else if e.name == "private" {
									// Package private is ok, don't care about this
								}
							}
							case ^ast.Field_Value: {
								name_ident, name_ok := e.field.derived.(^ast.Ident);
								value_literal, value_ok := e.value.derived.(^ast.Basic_Lit);
								if name_ok && value_ok {
									if name_ident.name == "private" && value_literal.tok.text == "\"file\"" {
										is_file_private = true;
									}
								}
								else {
									/*fmt.printf("Either name or value is not what was expected...\n\nName = %v\n\nValue = %v\n\n", e.field.derived, e.value.derived);
									panic("What");*/
								}
							}
							case: {
								fmt.printf("Unhandled attribute %v\n", e);
							}
						}
					}
				}
				if is_file_private {
					if do_hotload {
						visit_data.failed = true;
						log.errorf("Hotloaded procs can't be file private, or can they?");
					}
					return nil;
				}
				if do_hotload && !vd.is_mutable {
					visit_data.failed = true;
					/*for name_node, index in vd.names {
						name: string;
						//has_body := false;
						//lit: ^ast.Proc_Lit;
							//fmt.printf("\t%v\n", name.derived);
						if ident, ok := name_node.derived.(^ast.Ident); ok {
							//fmt.printf("The name is %s\n", ident.name);
							name = ident.name;
						}
					}*/

					log.errorf("Hotloaded procs must be mutable. %v.\n%s\nFix: Replace ':: proc(' with ':= proc('\n", vd.pos, visit_data.current_file_src[vd.pos.offset:vd.end.offset]);
				}
				for name_node, index in vd.names {
					name: string;
					if ident, ok := name_node.derived.(^ast.Ident); ok {
						name = ident.name;
					}					
					//fmt.printf("Declaration %s\n", name)

					if len(vd.values) == 0 {
						type_string := get_type_string(visit_data.current_file_src, vd.type);
						//fmt.printf("%s is a global variable with type %s and no value.\n", name, type_string);						
						visit_data.global_variables[name] = {
							file_src = visit_data.current_file_src,
							type_string = type_string,
							type_expr = vd.type,
						};						
					}
					else {
						value := vd.values[index];
						if proc_lit, is_proc := value.derived_expr.(^ast.Proc_Lit); is_proc {

							//fmt.printf("%s is a proc literal\n", name);
							body := proc_lit.body;
							if body != nil {
								//fmt.printf("Body = %v\n", body.derived_stmt);
								if do_hotload && len(name) > 0 {
									//fmt.printf("current src: %s\n", visit_data.current_file_src);
									//fmt.printf("%v, %v\n", len(visit_data.current_file_src), any_node.end.offset);
									//fmt.printf("Write: %s\n", visit_data.current_file_src[any_node.pos.offset:min(any_node.end.offset, len(visit_data.current_file_src))]);
									visit_data.current_file_has_hotload_procs = true;									
									
									add_proc_references(visit_data, proc_lit);

									to_write := Proc_To_Write {
										name,
										proc_lit,
										visit_data.current_file_src,
									}
									append(&visit_data.hotload_procs_to_write, to_write);
									append(&visit_data.hotload_proc_names, name);
								}
								else if len(name) > 0 && name != "main" {
									add_other_proc_signature(visit_data, name, proc_lit, vd.attributes);
								}
							}
						}
						else {
							if vd.is_mutable {
								type_string := "";
								if vd.type != nil {
									type_string = visit_data.current_file_src[vd.type.pos.offset:vd.type.end.offset];
									//fmt.printf("%s is a global variable with type %s.\n", name, type_string,);
									
								}
								else {

									#partial switch derived_value in value.derived_expr {
										case ^ast.Proc_Lit: {
											panic("Handled before!");
										}
										case ^ast.Basic_Lit: {
											#partial switch derived_value.tok.kind {
												/*case .Ident: {
													//fmt.printf("%s is a global ident.\n", name);
												}*/
												case .Integer: {
													//fmt.printf("%s is a global int.\n", name);		
													type_string = "int"								
												}
												case .Float: {
													//fmt.printf("%s is a global f64.\n", name)							
													type_string = "f64"
												}
												case .Imag: {
													//log.warnf("Imaginary global variables are not implemented");
													//fmt.printf("%s is a global imaginary.\n", name);
												}
												case .String: {
													//fmt.printf("%s is a global string.\n", name);
													type_string = "string"
												}
												case .Rune: {
													//fmt.printf("%s is a global rune.\n", name);
													type_string = "rune"
												}
												case: {
													log.warnf("Unhandled global variable Basic_Lit %v", derived_value.tok.kind);
												}
											}
										}
										case ^ast.Comp_Lit: {

											type_expr: ^ast.Expr; 
											if vd.type != nil {
												type_expr = vd.type;
											}
											else  {
												type_expr = derived_value.type;
											}

											type_string = get_type_string(visit_data.current_file_src, type_expr);
										}
										case ^ast.Call_Expr: {
											type_expr: ^ast.Expr; 
											if vd.type != nil {
												type_expr = vd.type;
											}
											else  {
												type_expr = derived_value.expr;
											}

											type_string = get_type_string(visit_data.current_file_src, type_expr);
											fmt.printf("Mutable Call expr type string = %s\n", type_string);
										}
										case ^ast.Selector_Expr: {
											type_string = visit_data.current_file_src[derived_value.expr.pos.offset:derived_value.expr.end.offset];
										}
										case ^ast.Implicit_Selector_Expr: {
											panic("Should have a type, and be handled above!");
										}
										case ^ast.Array_Type: {
											type_string = visit_data.current_file_src[derived_value.pos.offset:derived_value.end.offset];
										}
										case ^ast.Ident: {
											if derived_value.name == "true" || derived_value.name == "false" {
												type_string = "bool";
											}
											else {
												log.warnf("Global variables that are referencing other globals are not implemented\n\t%s:%d %v", vd.pos.file, vd.pos.line, visit_data.current_file_src[vd.pos.offset:vd.end.offset]);
											}
										}										
										case: {
											log.warnf("Unhandled mutable declaration: %v", value.derived_expr);
											panic("Unhandled mutable declaration");
										}
									}
								}
								if type_string != "" {
									//fmt.printf("Add global variable %s of type %s\n", name, type_string);
									visit_data.global_variables[name] = {
										file_src = visit_data.current_file_src,
										type_string = type_string,
										type_expr = vd.type,
										value_expr = value,
									}
								}
							}
							else {
								#partial switch type in value.derived_expr {
									case ^ast.Proc_Lit: {
										panic("Handled before!")
									}
									case ^ast.Struct_Type,
									     ^ast.Union_Type,
										 ^ast.Enum_Type,
										 ^ast.Ident,
										 ^ast.Distinct_Type,
										 ^ast.Array_Type,
										 ^ast.Helper_Type,
										 ^ast.Call_Expr,
										 ^ast.Basic_Lit,
										 ^ast.Binary_Expr,
										 ^ast.Comp_Lit,
										 ^ast.Selector_Expr,
										 ^ast.Unary_Expr,
										 ^ast.Type_Cast,
										 ^ast.Proc_Group,
										 ^ast.Dynamic_Array_Type,
										 ^ast.Bit_Field_Type,
										 ^ast.Bit_Set_Type: 
									{
										visit_data.all_type_declarations[name] = Type_Declaration{
											decl_string = visit_data.current_file_src[value.pos.offset:value.end.offset],
											value = value,
											file_src = visit_data.current_file_src,
										}
									}
									case: {
										
										log.errorf("Unhandled value declaration type: %v for %s %v\n", reflect.union_variant_typeid(value.derived_expr), name, value.pos);
									}
								}
							}
						}						
					}
				}

			}
			case: {
				//fmt.printf("%v\n\n\n", node);
			}
		}
		return nil;
	}


	sb: strings.Builder;
	strings.write_string(&sb, "package hotload_generated\n\n");
	strings.write_string(&sb, `// This is a generated file. Changes may be lost.`);
	strings.write_byte(&sb, '\n');
	//fmt.sbprintf(&sb, `import MAIN "{}"\n`, package_path)
	visit_data := Visit_Data {
		sb = &sb,
		package_path = package_path,
		referenced_identifiers = make(map[string]Referenced_Ident),

		do_add_procs_in_when_trees = false,
	}
	
	{
		import_file_arena: virtual.Arena;
		arena_error := virtual.arena_init_growing(&import_file_arena);
		if arena_error != .None {
			log.errorf("Failed to allocate import file arena memory\n");
			return;
		}
		visit_data.import_file_allocator = virtual.arena_allocator(&import_file_arena);
	}

	visitore := ast.Visitor{
		visit_node,
		&visit_data,
	}
	ast.walk(&visitore, &pack.node);
	if visit_data.failed {
		log.error("Hotload generation Failed.\n");
		os.exit(1);
	}
	if visit_data.current_file_has_hotload_procs {
		append(&visit_data.hotload_files, visit_data.current_file_path);
	}

	for to_write in visit_data.hotload_procs_to_write {
		visit_data.current_file_src = to_write.file_src;

		sb := visit_data.sb;
		strings.write_string(sb, "@export ")
		strings.write_string(sb, to_write.name);

		strings.write_string(sb, " :: ");

		when true {
			write_proc_literal(&visit_data, sb, to_write.lit, 0);
		}
		else {
			strings.write_string(sb, visit_data.current_file_src[to_write.lit.pos.offset:min(to_write.lit.end.offset, len(visit_data.current_file_src))]);
		}
		strings.write_string(sb, "\n");
	}

	log.info("Referenced indentifiers:");
	for ref_name, ref in visit_data.referenced_identifiers {
		log.infof("\t%s", ref_name);
	}

	

	// First loop all referenced types and add the referenced types of those types, like struct fields.
	value_decl_add_references_visitor_data := Value_Declaration_Add_Reference_Data {"", &visit_data};
	value_decl_add_references_visitor := ast.Visitor {
		visit_value_declaration_and_add_references,
		&value_decl_add_references_visitor_data,
	}
	
	// When trees:
	// - If a referenced ident is in a tree, the tree must be walked and all references inside every definition must be added.
	// 

	for {
		// Continue looping until no new references were added, to handle nested references.
		// For example:
		// A :: struct { }
		// B :: struct {a: A}
		// C :: struct {b: B}

		outside_old_len := len(visit_data.referenced_identifiers);
		// Cant loop by pointer to ref, since the referenced_identifiers map might resize when adding new identifiers inside the loop, invalidating the pointer.
		for ident, ref in visit_data.referenced_identifiers {
			set_found_and_handled :: proc(visit_data: ^Visit_Data, ident: string) {
				ref := &visit_data.referenced_identifiers[ident];
				ref.found_and_handled = true;
			}
			if ref.found_and_handled {
				continue;
			}
			value_decl_add_references_visitor_data.name = ident;
			if type_decl, ok := &visit_data.all_type_declarations[ident]; ok {
				log.infof("%s is referencing a type declaration.\n", ident);
				
				set_found_and_handled(&visit_data, ident);

				if !type_decl.value_references_have_been_added {
					type_decl.value_references_have_been_added = true;
			
					visit_data.current_file_src = type_decl.file_src;
					ast.walk(&value_decl_add_references_visitor, &type_decl.value.expr_base);
				}
				continue;
			}
			if global_var_decl, ok := &visit_data.global_variables[ident]; ok {
				log.infof("%s is referencing a global variable!\n", ident);
				set_found_and_handled(&visit_data, ident);

				if !global_var_decl.value_references_have_been_added {
					global_var_decl.value_references_have_been_added = true;


					visit_data.current_file_src = global_var_decl.file_src;
					if global_var_decl.value_expr != nil {
						#partial switch expr in global_var_decl.value_expr.derived_expr {
							case ^ast.Comp_Lit: {
								if expr.type != nil {
									ast.walk(&value_decl_add_references_visitor, expr.type);
								}
							}
							case ^ast.Call_Expr: {
								 ast.walk(&value_decl_add_references_visitor, expr.expr);
							}
							case ^ast.Selector_Expr: {
								if expr.expr != nil {
									ast.walk(&value_decl_add_references_visitor, expr.expr);
								}
							}
							case ^ast.Ident, ^ast.Unary_Expr, ^ast.Basic_Lit: break;
							case: 
								//ast.walk(&value_decl_add_references_visitor, global_var_decl.value_expr);
								fmt.panicf("Unhandled value expr for global variable: %v", global_var_decl.value_expr.derived_expr);
						}

						
					}
					if global_var_decl.type_expr != nil {
						ast.walk(&value_decl_add_references_visitor, global_var_decl.type_expr);
					}
				}
				continue;
			}

			if proc_signature, ok := &visit_data.other_proc_signatures[ident]; ok {
				log.infof("%s is referencing a proc!\n", ident);
				set_found_and_handled(&visit_data, ident);
				if !proc_signature.type_references_have_been_added {
					if proc_signature.is_generic {
						log.errorf("Called proc '%s' is generic. Calling generic procs - that are defined in your program - from hotloaded functions is not possible (It may be, but not yet).", ident);
						visit_data.failed = true;
					}
					else {
						proc_signature.type_references_have_been_added = true;

						add_references_in_proc_attributes(&visit_data, proc_signature);

						ast.walk(&value_decl_add_references_visitor, &proc_signature.type.node);
					}
				}
				continue;
			}

			if imp, ok := &visit_data.packages[ident]; ok {
				set_found_and_handled(&visit_data, ident);
				imp.is_referenced = true;
				continue;
			}

			for &when_tree in visit_data.when_trees {

				add_when_tree_condition_references :: proc(when_tree: When_Tree, data: ^Value_Declaration_Add_Reference_Data) {
					visitor := ast.Visitor {
						visit_when_tree_and_add_condition_references,
						data,
					};
					ast.walk(&visitor, when_tree.node);
				}
				if decl, ok := when_tree.all_type_declarations[ident]; ok {
					if decl != .Referenced {
						set_found_and_handled(&visit_data, ident);
						when_tree.all_type_declarations[ident] = .Referenced;

						log.infof("Found type declaration %s in when tree!\n", ident);
							
						visit_when_tree_data := When_Tree_Add_References_For_Declaration {
							//referenced_identifiers = &visit_data.referenced_identifiers,
							visit_data = &visit_data,
							declaration_name = ident,
						}
						visitor := ast.Visitor {
							visit_when_tree_and_add_references_for_specific_value_declaration,
							&visit_when_tree_data,
						}
						ast.walk(&visitor, when_tree.node);

						if !when_tree.any_referenced {
							when_tree.any_referenced = true;

							add_when_tree_condition_references(when_tree, &value_decl_add_references_visitor_data);
						}
					}
					// A declaration may be in multiple trees, so don't break here.
					continue;
				}
				if decl, ok := when_tree.all_proc_declarations[ident]; ok {
					if decl != .Referenced {
						set_found_and_handled(&visit_data, ident);
						when_tree.all_proc_declarations[ident] = .Referenced;
						log.infof("Found proc declaration %s in when tree!\n", ident);
						
						visit_when_tree_data := When_Tree_Add_References_For_Declaration {
							//referenced_identifiers = &visit_data.referenced_identifiers,
							visit_data = &visit_data,
							declaration_name = ident,
						}
						visitor := ast.Visitor {
							visit_when_tree_and_add_references_for_specific_value_declaration,
							&visit_when_tree_data,
						}
						ast.walk(&visitor, when_tree.node);

						if !when_tree.any_referenced {
							when_tree.any_referenced = true;
					
							add_when_tree_condition_references(when_tree, &value_decl_add_references_visitor_data);
						}						
					}
				}
			}
		}
		outside_did_add_any_more := outside_old_len < len(visit_data.referenced_identifiers);
		if !outside_did_add_any_more do break;
	}

	if visit_data.failed {
		log.error("Hotload generation Failed.\n");
		os.exit(1);
	}

	{

		/* // This will be generated
			other_proc: #type proc(t: Other_Type) -> int;
			foo: #type proc(x: int);
		*/
		strings.write_string(&sb, "// Called Procedures\n");
		for name, &proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			if name in visit_data.referenced_identifiers {
				do_wrapper := proc_signature.wrapped || len(proc_signature.attributes) > 0;

				if do_wrapper {
					strings.write_string(&sb, "_MAIN_");
				}
				fmt.sbprintf(&sb, "{0}: #type {1};\n", proc_signature.name, proc_signature.type_string);

				if do_wrapper {

					strings.write_string(&sb, "\n");

					for attribute, index in proc_signature.attributes {
						/*fmt.printf("Attribute %d of %s = %v\n\n", index, name, attribute);
						for elem, eindex in attribute.elems {
							#partial switch e in elem.derived_expr {
								case ^ast.Field_Value: {
									fv := e;
									fmt.printf("\tField %d = %v | %v.\n\n", eindex, fv.field.derived_expr, fv.value.derived_expr);
								}
								case: fmt.printf("\tElem %d = %v.\n\n", eindex, elem.derived);
							}
							
						}*/

						if attribute.end.offset > attribute.pos.offset {
							strings.write_string(&sb, proc_signature.file_src[attribute.pos.offset:attribute.end.offset]);	
						}
					}

					fmt.sbprintf(&sb, "{0} :: {1} {{\n\t", proc_signature.name, proc_signature.type_string);

					if proc_signature.type.results != nil {
						strings.write_string(&sb, "return ");
					}

					fmt.sbprintf(&sb, "_MAIN_{0}(", proc_signature.name);
					proc_signature.wrapped = true;

					written_param_count := 0;
					for param in proc_signature.type.params.list {
						for name in param.names {
							// TODO: Handle polymorphic name
							if written_param_count > 0 {
								strings.write_string(&sb, ", ");
							}
							#partial switch derived in name.derived_expr {
								case ^ast.Ident: {
									strings.write_string(&sb, derived.name);
								}
								case: {
									fmt.panicf("Unhandled param type %v\n", name.derived_expr);
								}
							}
							written_param_count += 1;
						}

					}
					strings.write_string(&sb, ");\n");
					strings.write_string(&sb, "}\n\n");
				}
			}
		}
		strings.write_byte(&sb, '\n');
		strings.write_string(&sb, "// Referenced Global variables\n");
		for name, global_variable in visit_data.global_variables {
			if name in visit_data.referenced_identifiers {
				fmt.sbprintf(&sb, "{0}: ^{1};\n", name, global_variable.type_string);
			}
		}
		strings.write_byte(&sb, '\n');

		
		/* // This will be generated
			setup_main_program_proc_pointers :: proc(proc_map: map[string]rawptr) {
				other_proc = cast(proc(t: Other_Type) -> int)proc_map["other_proc"];
			}
		*/
		strings.write_string(&sb, "@export setup_main_program_proc_pointers :: proc(proc_map: map[string]rawptr) {\n");

		for name, proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			if name in visit_data.referenced_identifiers {
				//fmt.sbprintf(&sb, "\t{0} = cast({1})proc_map[\"{0}\"];\n", proc_signature.name, proc_signature.type_string);
				strings.write_string(&sb, "\t");
				if proc_signature.wrapped {
					strings.write_string(&sb, "_MAIN_");
				}
				fmt.sbprintf(&sb, "%s = auto_cast proc_map[\"", proc_signature.name);
				fmt.sbprintf(&sb, "%s\"]; /* %s */\n", proc_signature.name, proc_signature.type_string);
			}
		}
		strings.write_string(&sb, "\n\t// Global Variables\n");
		for name, global_variable in visit_data.global_variables {
			if name in visit_data.referenced_identifiers {
				fmt.sbprintf(&sb, "\t{0} = auto_cast proc_map[\"{0}\"];\n", name);
			}
		}

		strings.write_string(&sb, "}\n\n");
	}

	for ident, ref in visit_data.referenced_identifiers {
		//fmt.printf("%s is referenced %d times.\n", ident, ref.count);
		if ref.found_and_handled {
			decl, ok := visit_data.all_type_declarations[ident];
			if ok {
				strings.write_string(&sb, ident);
				strings.write_string(&sb, " :: ");
				strings.write_string(&sb, decl.decl_string);
				strings.write_string(&sb, "\n\n");
			}
		}
		else {
			if !is_built_in(ident) && !is_hotloaded_proc_identifier(&visit_data, ident) {
				log.warnf("Referenced ident %s is not defined\n", ident);
			}
		}
	}



	for when_tree, index in visit_data.when_trees {
		data := When_Tree_Write_Data { tree = &visit_data.when_trees[index], sb = visit_data.sb};
		/**/
		any_referenced := false;
		for name, decl in when_tree.all_type_declarations {
			if decl == .Referenced {
				any_referenced = true;
				break;
			}
		}
		if any_referenced {
			write_when_tree(&data, when_tree.node);
		}
	}

	relative_target_package_path, rel_error := filepath.rel(os.get_current_directory(), package_path);
	if rel_error != .None {
		relative_target_package_path = package_path;
	}
	for name, imp in visit_data.packages {
		if imp.is_referenced {
			strings.write_string(visit_data.sb, "import ");
			if imp.name_is_user_specified {
				strings.write_string(visit_data.sb, name);
				strings.write_string(visit_data.sb, " ");
			}
			colon_index := strings.index_byte(imp.fullpath, ':');
			if colon_index == -1 {
				strings.write_string(visit_data.sb, "\"");
				strings.write_string(visit_data.sb, fmt.tprint("..", relative_target_package_path, strings.trim(imp.fullpath, "\""), sep="/"));
				strings.write_string(visit_data.sb, "\"\n");
			}
			else {
				strings.write_string(visit_data.sb, imp.fullpath);
				strings.write_byte(visit_data.sb, '\n');
			}
		}
	}
	
	if do_generate_lib_code {
		output := strings.to_string(sb);
		//fmt.printf("Output:\n%s\n", output);
		os.write_entire_file(output_path, transmute([]u8)output);
		fmt.printf("Output %s\n", output_path);
	}

	if do_generate_loader {
		loader_sb: strings.Builder;
		fmt.sbprintf(&loader_sb, `package {0}
// This is a generated file. Changes may be lost.

import "core:dynlib"
import "core:fmt"
import "core:strings"
`, pack.name);

		strings.write_string(&loader_sb, `
// This could be file private
Hotload_Define_Value :: union {
	bool,
	int,
	string,
}
Hotload_Command_Line_Define :: struct {
	name: string,
	value: Hotload_Define_Value,
}

hotload_create_defines_command_line_arguments :: proc(allocator := context.allocator) -> string {
	cmd_sb := strings.builder_make_len_cap(0, 256, allocator);
	for d in hotload_command_line_defines {
		fmt.sbprintf(&cmd_sb, "-define:%s=%v ", d.name, d.value);
	}
	return strings.to_string(cmd_sb);
}

hotload_command_line_defines := []Hotload_Command_Line_Define {
`);

	//{"DEV", #config(DEV, false)},
		for config, index in visit_data.hashtag_configs {
			if index > 0 do strings.write_string(&loader_sb, ",\n");
			fmt.sbprintf(&loader_sb, `	Hotload_Command_Line_Define{{"%s", %s}}`, config.name, config.expr);
		}

		strings.write_string(&loader_sb, "\n}\n\n");


		strings.write_string(&loader_sb, "hotload_files := []string {\n");
		for file_path, file_path_index in visit_data.hotload_files {
			if file_path_index > 0 do strings.write_string(&loader_sb, ",\n");
			strings.write_byte(&loader_sb, '\t');
			path := file_path;
			if strings.has_prefix(path, pack.fullpath) {
				path = path[len(pack.fullpath):];
			}
			for path[0] == '\\' || path[0] == '/' {
				path = path[1:];
			}
			strings.write_quoted_string(&loader_sb, path);
		}
		strings.write_string(&loader_sb, "\n}\n\n");


		strings.write_string(&loader_sb, "hotload_procs :: proc(lib: dynlib.Library) -> bool {");

		strings.write_string(&loader_sb, `
	if raw, found := dynlib.symbol_address(lib, "setup_main_program_proc_pointers"); found {
		setup := cast(proc(map[string]rawptr))raw;
		setup(hotload_other_proc_pointers);
	}
			`);
		
		for proc_name in visit_data.hotload_proc_names {
			fmt.sbprintf(&loader_sb, `
	if raw, found := dynlib.symbol_address(lib, "{0}"); found {{
		{0} = auto_cast raw;
	}}
	else {{
		fmt.printf("Did not find {0}\n");
		return false;
	}}`, proc_name);

		}
		strings.write_string(&loader_sb, "\n\treturn true;\n}\n");


		strings.write_string(&loader_sb, "hotload_other_proc_pointers := map[string]rawptr {\n");
		for name, proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			fmt.sbprintf(&loader_sb, "\t\"{0}\" = rawptr({0}),\n", proc_signature.name);
		}
		strings.write_string(&loader_sb, "\t// Global variable pointers\n");
		for name, global_variable in visit_data.global_variables {
			fmt.sbprintf(&loader_sb, "\t\"{0}\" = rawptr(&{0}),\n", name);
		}
		strings.write_string(&loader_sb, "}\n");

		hotload_procs_path := fmt.tprintf("%s/hotload_procs_%s_%s.odin", package_path, OS_NAMES[target_os], ARCH_NAMES[target_arch]);
		os.write_entire_file(hotload_procs_path, transmute([]u8)strings.to_string(loader_sb));
		fmt.printf("Output %s\n", hotload_procs_path);
	}
	
	fmt.printf("Finished in %v\n", time.stopwatch_duration(stopwatch));
}

is_hotloaded_proc_identifier :: proc(visit_data: ^Visit_Data, ident: string) -> bool {
	for name in visit_data.hotload_proc_names {
		if name == ident {
			return true;
		}
	}
	return false;
}

get_package_name_at_path :: proc(target_relative_path: string, package_path: string, file_allocator: mem.Allocator) -> (result_name: string, success: bool) {
	dir_path: string;
	colon_index := strings.index_byte(package_path, ':');
	if colon_index != -1 {
		if colon_index == len(package_path)-1 {
			log.errorf("Invalid package path %s, ends with ':'\n");
			return;
		}
		dir_path = fmt.tprint(strings.trim(ODIN_ROOT, filepath.SEPARATOR_STRING), package_path[:colon_index], package_path[colon_index+1:], "", sep = filepath.SEPARATOR_STRING);		
	}
	else {
		dir_path = fmt.tprint(target_relative_path, package_path, sep = filepath.SEPARATOR_STRING);
	}
	
	dir_handle, dir_error := os.open(dir_path);
	if dir_error != os.ERROR_NONE {
		log.errorf("Failed to open imported package %s (%s)\n", package_path, dir_path);
		return;
	}
	defer os.close(dir_handle);
	files, read_dir_error := os.read_dir(dir_handle, -1);
	if read_dir_error != os.ERROR_NONE {
		log.errorf("Failed to get files at imported package %s (%s)\n", package_path, dir_path);
		return;
	}

	cmp_file_info_size :: proc(a, b: os.File_Info) -> slice.Ordering {
		if a.size < b.size do return .Less;
		if a.size > b.size do return .Greater;
		return .Equal;
	}
	// Sort files by size so the smallest is read first.
	// Most of the time only one file should have to be read.
	slice.sort_by_cmp(files, cmp_file_info_size);

	file_loop: for fi in files {
		if fi.is_dir {
			continue;
		}

		extension := filepath.ext(fi.name);
		if extension != ".odin" {
			continue file_loop;
		}

		
		mem.free_all(file_allocator);

		data, file_read_success := os.read_entire_file(fi.fullpath, file_allocator);
		if !file_read_success {
			log.errorf("Failed to open imported package file %s\n", fi.fullpath);
			continue file_loop;
		}
		text := transmute(string)data;

		tokenizor: tokenizer.Tokenizer;
		tokenizer.init(&tokenizor, text, fi.fullpath);
		for {
			token := tokenizer.scan(&tokenizor);
			if token.kind == .Comment {
				continue;
			}

			if token.kind == .Package {
				name_token := tokenizer.scan(&tokenizor);
				if name_token.kind == .Ident {
					result_name = strings.clone(name_token.text);
					success = true;
					return;	
				}
				else {
					log.errorf("Failed to parse imported package file %s. Expected name after package, got %v\n", fi.fullpath, token.kind);
					continue file_loop;
				}
			}
			else {
				log.errorf("Failed to parse imported package file %s. Expected package, got %v\n", fi.fullpath, token.kind);
				continue file_loop;
			}
			break;
		}
	}
	return;
}

setup_allowed_magic_suffixes :: proc() {
	if target_os == .Windows {
		allowed_magic_suffixes[.windows] = true;
		if target_arch == .amd64 {
			allowed_magic_suffixes[.windows_amd64] = true;
		}
		else if target_arch == .i386 {
			allowed_magic_suffixes[.windows_i386] = true;
		}
	}
	else if target_os == .Darwin {
		allowed_magic_suffixes[.darwin] = true;
		if target_arch == .amd64 {
			allowed_magic_suffixes[.darwin_amd64] = true;
		}
		else if target_arch == .arm64 {
			allowed_magic_suffixes[.darwin_arm64] = true;
		}
	}
	else if target_os == .Linux {
		allowed_magic_suffixes[.linux] = true;
		if target_arch == .i386 {
			allowed_magic_suffixes[.linux_i386] = true;
		}
	    if target_arch == .amd64 {
	    	allowed_magic_suffixes[.linux_amd64] = true;
	    }
	    if target_arch == .arm64 {
	    	allowed_magic_suffixes[.linux_arm64] = true;
	    }
	    if target_arch == .arm32 {
	    	allowed_magic_suffixes[.linux_arm32] = true;
	    }
	}
	else if target_os == .Essence {
		allowed_magic_suffixes[.essence] = true;
		allowed_magic_suffixes[.essence_amd64] = true;
	}
	else if target_os == .FreeBSD {
		allowed_magic_suffixes[.freebsd] = true;
		if target_arch == .i386 {
			allowed_magic_suffixes[.freebsd_i386] = true;
		}
    	if target_arch == .amd64 {
    		allowed_magic_suffixes[.freebsd_amd64] = true;
    	}
	}
	else if target_os == .OpenBSD {
		allowed_magic_suffixes[.openbsd] = true;
    	if target_arch == .amd64 {
    		allowed_magic_suffixes[.openbsd_amd64] = true;
    	}
	}
	else if target_os == .WASI {
		allowed_magic_suffixes[.wasi] = true;
		if target_arch == .wasm32 {
			allowed_magic_suffixes[.wasi_wasm32] = true;
		}
		if target_arch == .wasm64p32 {
			allowed_magic_suffixes[.wasi_wasm64p32] = true;
		}
	}
	else if target_os == .JS {
		allowed_magic_suffixes[.js] = true;
		if target_arch == .wasm32 {
			allowed_magic_suffixes[.js_wasm32] = true;
		}
		if target_arch == .wasm64p32 {
			allowed_magic_suffixes[.js_wasm64p32] = true;
		}
	}
	else if target_os == .Freestanding {
		allowed_magic_suffixes[.freestanding] = true;
		if target_arch == .wasm32 {
			allowed_magic_suffixes[.freestanding_wasm32] = true;
		}
		if target_arch == .wasm64p32 {
			allowed_magic_suffixes[.freestanding_wasm64p32] = true;
		}				
		if target_arch == .arm64 {
			allowed_magic_suffixes[.freestanding_arm64] = true;
		}
	}
}