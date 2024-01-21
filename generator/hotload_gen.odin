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

import "core:runtime"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

Block :: struct {
	first_declaration_index: int,
}

Local_Declarations_Type :: enum {
	Struct,
	Proc,
}
Local_Declarations :: struct {
	// Things declared in a proc or struct definition
	type: Local_Declarations_Type,
	declaration_stack: [dynamic]string,
	block_stack: [dynamic]Block,
}

Scopes :: struct {	
	local_declaration_stack: [dynamic]Local_Declarations,
	current: ^Local_Declarations,

	declarations_in_current_when_blocks: map[string]int,
	current_when_blocks_count: int,
}

Visit_Data :: struct {
	package_path: string,
	sb: ^strings.Builder,
	current_file_src: string,
	current_file_path: string,
	current_file_has_hotload_procs: bool,

	hotload_proc_names: [dynamic]string,
	other_proc_signatures:   map[string]Proc_Signature,
	all_type_declarations: map[string]Type_Declaration,
	when_trees: [dynamic]When_Tree,
	hotload_files: [dynamic]string,

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
}

Type_Declaration :: struct {
	decl_string: string,
	value: ^ast.Expr,
	value_references_have_been_added: bool,
	inside_when: string,
}

Type_Declaration_State :: enum u8 {
	Defined,
	Referenced,
}

When_Tree :: struct {
	any_referenced: bool,
	all_type_declarations: map[string]Type_Declaration_State,
	all_proc_declarations: map[string]Type_Declaration_State,
	node: ^ast.When_Stmt,
	file_src: string,
}


add_expression_type_reference :: proc(visit_data: ^Visit_Data, expr: ^ast.Expr) {
	#partial switch derived in expr.derived_expr {
		case ^ast.Ident: {
			add_global_reference(visit_data, derived.name);
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
		case: {
			assert(false);
		}
	}
}

add_other_proc_signature :: proc(visit_data: ^Visit_Data, name: string, proc_lit: ^ast.Proc_Lit) {
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
			add_expression_ident_references(visit_data, derived.type);
			add_expression_ident_references(visit_data, derived.default_value);
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
		add_expression_type_reference(visit_data, field.type);
		if field.default_value != nil {
			add_expression_ident_references(visit_data, field.default_value);
		}
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
				if ident, ok := derived.type.derived.(^ast.Ident); ok {
					name = ident.name;
				}
				else {
					panic("Unhandled Poly_Type type not an ident.");
				}
			}
			case: panic("Unhandled declaration name type.");
		}
		assert(len(name) > 0);
		if scopes.current_when_blocks_count > 0 {
			n := scopes.declarations_in_current_when_blocks[name];
			scopes.declarations_in_current_when_blocks[name] = n+1;
		}
		append(&scopes.current.declaration_stack, name);
	}
}

enter_block :: proc(scopes: ^Scopes) {
	append(&scopes.current.block_stack, Block { len(scopes.current.declaration_stack) });
}

exit_block :: proc(scopes: ^Scopes) {
	popped := pop(&scopes.current.block_stack);
	if len(scopes.current.declaration_stack) > popped.first_declaration_index {
		remove_range(&scopes.current.declaration_stack, popped.first_declaration_index, len(scopes.current.declaration_stack));
	}
}

add_statement_references :: proc(visit_data: ^Visit_Data, statement: ^ast.Stmt) {
	#partial switch derived in statement.derived_stmt {
		case ^ast.Value_Decl: {
			for value in derived.values {
				add_expression_ident_references(visit_data, value);
			}
			if derived.type != nil do add_expression_type_reference(visit_data, derived.type);
			add_declaration_names(&visit_data.scopes, derived.names);
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
				else /*if else_when, ok := derived.else_stmt.derived_stmt.(^ast.When_Stmt); ok*/ {
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
						append(&scopes.current.declaration_stack, decl);
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

add_block_references :: proc(visit_data: ^Visit_Data, block: ^ast.Block_Stmt) {
	for statement in block.stmts {
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

add_global_reference_if_not_declared_locally :: proc(visit_data: ^Visit_Data, name: string) {
	declared_locally := false;
	if visit_data.scopes.current != nil {
		#reverse for declared in visit_data.scopes.current.declaration_stack {
			if declared == name {
				declared_locally = true;
				break;				
			}
		}
	}
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
				//add_reference_to_ident(&data.visit_data.referenced_identifiers, derived.name);
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
					fmt.printf("Proc group proc %s\n", ident.name);
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
		case ^ast.Call_Expr: {}
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

						add_other_proc_signature(visit_data, name, proc_lit);
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
			package_path = "small_test_program"
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
		}
	}
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
	if error := os.make_directory("hotload_generated_code"); error != os.ERROR_NONE && error != os.ERROR_ALREADY_EXISTS {
		fmt.printf("Failed to create output directory\n");
	}
	output_path := "hotload_generated_code/code.odin"

	//package_path := "test_program";
	//pack, pack_ok := parser.parse_package_from_path("src");
	pack, pack_ok := parser.parse_package_from_path(package_path);
	if !pack_ok {
		fmt.printf("Failed to parse package\n");
		os.exit(1);
	}
	if len(pack.files) == 0 {
		fmt.printf("Package %s has no files!\n", package_path);
		os.exit(1);
	}

	log.info("Parsed package %s", package_path);
	
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
				if strings.has_suffix(node.fullpath, "hotload_procs.odin") {
					return nil;
				}

				visit_data.current_file_src = node.src;
				visit_data.current_file_path = node.fullpath;
				visit_data.current_file_has_hotload_procs = false;
				return visitor;
			}
			case ^ast.Import_Decl: {
				if node.fullpath not_in visit_data.imports {
					package_name, success := get_package_name_at_path(visit_data.package_path, strings.trim(node.fullpath, "\""), visit_data.import_file_allocator);
					if success {
						log.info("Imported package %s name = %s\n", node.fullpath, package_name);
					}
					else {
						log.errorf("Failed to get package name for import %s\n", node.fullpath);
					}
					
					visit_data.imports[node.fullpath] = Import { name = package_name };
					visit_data.packages[package_name] = Import { name = package_name, fullpath = node.fullpath};
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
				//return &declaration_visitor;
				//fmt.printf("%v\n", node);
				if len(node.values) != len(node.names) do break;

				do_hotload := false;
				for attribute in node.attributes {
					//fmt.printf("\t%v\n", attribute);
					for expression in attribute.elems {
						#partial switch e in expression.derived_expr {
							case ^ast.Ident: {
								if e.name == "hotload" {
									//fmt.printf("Hotload this proc!\n");
									do_hotload = true;
								}
								else if e.name == "export" {
									//fmt.printf("Export this proc!\n");
								}
							}
						}
					}
				}
				if do_hotload && !node.is_mutable {
					visit_data.failed = true;
					/*for name_node, index in node.names {
						name: string;
						//has_body := false;
						//lit: ^ast.Proc_Lit;
							//fmt.printf("\t%v\n", name.derived);
						if ident, ok := name_node.derived.(^ast.Ident); ok {
							//fmt.printf("The name is %s\n", ident.name);
							name = ident.name;
						}
					}*/

					log.errorf("Hotloaded procs must be mutable. %v.\n%s\nFix: Replace ':: proc(' with ':= proc('\n", node.pos, visit_data.current_file_src[node.pos.offset:node.end.offset]);
				}
				for name_node, index in node.names {
					name: string;
					has_body := false;
					lit: ^ast.Proc_Lit;
					if ident, ok := name_node.derived.(^ast.Ident); ok {
						name = ident.name;
					}					
					//fmt.printf("Declaration %s\n", name)

					value := node.values[index];
					if node.is_mutable {
						#partial switch type in value.derived_expr {
							case ^ast.Proc_Lit: {
								//fmt.printf("%s is a proc literal\n", name);
								lit = type;
								body := type.body;
								if body != nil {
									//fmt.printf("Body = %v\n", body.derived_stmt);
									has_body = true;
								}
							}
						}
					}
					else {
						#partial switch type in value.derived_expr {
							case ^ast.Proc_Lit: {
								//fmt.printf("%s is a proc literal\n", name);
								lit = type;
								body := type.body;
								if body != nil {
									//fmt.printf("Body = %v\n", body.derived_stmt);
									has_body = true;
								}
							}
							case ^ast.Struct_Type: {
								//fmt.printf("%s is a struct type\n", name);
								visit_data.all_type_declarations[name] = Type_Declaration{
								 	decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
								 	value = value,
								 };
							}
							case ^ast.Union_Type: {
								visit_data.all_type_declarations[name] = Type_Declaration{
								 	decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
								 	value = value,
								 };
							}
							case ^ast.Enum_Type: {
								//fmt.printf("%s is an enum type\n", name);
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Ident: {
								//fmt.printf("%s is an ident\n", name);
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Distinct_Type: {
								//fmt.printf("%s is a distinct type\n", name);
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Array_Type: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Helper_Type: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Call_Expr: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Basic_Lit: {
								//fmt.printf("%s is a basic lit\n", name);
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Binary_Expr: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Comp_Lit: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Selector_Expr: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Unary_Expr: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Type_Cast: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case ^ast.Proc_Group: {
								visit_data.all_type_declarations[name] = Type_Declaration{
									decl_string = visit_data.current_file_src[type.pos.offset:type.end.offset],
									value = value,
								};
							}
							case: {
								
								log.errorf("Unhandled value declaration type: %v for %s %v\n", reflect.union_variant_typeid(value.derived_expr), name, value.pos);
							}
						}
					}
					if has_body && do_hotload && len(name) > 0 {
						//fmt.printf("current src: %s\n", visit_data.current_file_src);
						//fmt.printf("%v, %v\n", len(visit_data.current_file_src), any_node.end.offset);
						//fmt.printf("Write: %s\n", visit_data.current_file_src[any_node.pos.offset:min(any_node.end.offset, len(visit_data.current_file_src))]);
						visit_data.current_file_has_hotload_procs = true;
						sb := visit_data.sb;
						strings.write_string(sb, "@export ")
						proc_lit := value.derived_expr.(^ast.Proc_Lit);
						strings.write_string(sb, name);

						strings.write_string(sb, " :: ");
						//write_proc_literal(sb, proc_lit);
						
						//proc_visitor := ast.Visitor { visit_proc_node, visit_data}
						//ast.walk(&proc_visitor, proc_lit);

						add_proc_references(visit_data, proc_lit);

						strings.write_string(visit_data.sb, visit_data.current_file_src[proc_lit.pos.offset:min(proc_lit.end.offset, len(visit_data.current_file_src))]);
						strings.write_string(sb, "\n");
						append(&visit_data.hotload_proc_names, name);
					}
					else if has_body && len(name) > 0 && name != "main" {
						add_other_proc_signature(visit_data, name, lit);
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
	
	arena: virtual.Arena;
	arena_error := virtual.arena_init_growing(&arena);
	if arena_error != .None {
		log.errorf("Failed to allocate arena memory\n");
		return;
	}
	visit_data.import_file_allocator = virtual.arena_allocator(&arena);

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
		for ident, ref in &visit_data.referenced_identifiers {
			if ref.found_and_handled {
				continue;
			}
			value_decl_add_references_visitor_data.name = ident;
			if decl, ok := &visit_data.all_type_declarations[ident]; ok {
				ref.found_and_handled = true;
				if !decl.value_references_have_been_added {
					decl.value_references_have_been_added = true;
			
					ast.walk(&value_decl_add_references_visitor, &decl.value.expr_base);
				}
				continue;
			}

			if proc_signature, ok := &visit_data.other_proc_signatures[ident]; ok {
				ref.found_and_handled = true;
				if !proc_signature.type_references_have_been_added {
					if proc_signature.is_generic {
						log.errorf("Called proc '%s' is generic. Calling generic procs - that are defined in your program - from hotloaded functions is not possible (It may be, but not yet).", ident);
						visit_data.failed = true;
					}
					else {
						proc_signature.type_references_have_been_added = true;

						ast.walk(&value_decl_add_references_visitor, &proc_signature.type.node);
					}
				}
				continue;
			}

			if imp, ok := &visit_data.packages[ident]; ok {
				ref.found_and_handled = true;
				imp.is_referenced = true;
				continue;
			}

			for when_tree in &visit_data.when_trees {

				add_when_tree_condition_references :: proc(when_tree: When_Tree, data: ^Value_Declaration_Add_Reference_Data) {
					visitor := ast.Visitor {
						visit_when_tree_and_add_condition_references,
						data,
					};
					ast.walk(&visitor, when_tree.node);
				}
				if decl, ok := when_tree.all_type_declarations[ident]; ok {
					if decl != .Referenced {
						ref.found_and_handled = true;
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
						ref.found_and_handled = true;
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
		/*other_proc: #type proc(t: Other_Type) -> int;

		// This will be generated
		setup_main_program_proc_pointers :: proc(proc_map: map[string]rawptr) {
			other_proc = cast(proc(t: Other_Type) -> int)proc_map["other_proc"];
		}*/
		for name, proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			if name in visit_data.referenced_identifiers {
				fmt.sbprintf(&sb, "{0}: #type {1};\n", proc_signature.name, proc_signature.type_string);
			}
		}
		strings.write_byte(&sb, '\n');

		strings.write_string(&sb, "@export setup_main_program_proc_pointers :: proc(proc_map: map[string]rawptr) {\n");

		for name, proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			if name in visit_data.referenced_identifiers {
				//fmt.sbprintf(&sb, "\t{0} = cast({1})proc_map[\"{0}\"];\n", proc_signature.name, proc_signature.type_string);
				fmt.sbprintf(&sb, "\t{0} = auto_cast proc_map[\"{0}\"];\n", proc_signature.name, proc_signature.type_string);
			}
		}

		strings.write_string(&sb, "}\n\n");
	}

	for ident, ref in visit_data.referenced_identifiers {
		//fmt.printf("%s is referenced %d times.\n", ident, count);
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
			colon_index := strings.index_byte(imp.fullpath, ':');
			if colon_index == -1 {
				strings.write_string(visit_data.sb, "import \"");
				strings.write_string(visit_data.sb, fmt.tprint(relative_target_package_path, "..", strings.trim(imp.fullpath, "\""), sep="/"));
				strings.write_string(visit_data.sb, "\"\n");
			}
			else {
				strings.write_string(visit_data.sb, "import ");
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

`, pack.name);

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
		setup(other_proc_pointers);
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


		strings.write_string(&loader_sb, "other_proc_pointers := map[string]rawptr {\n");
		for name, proc_signature in visit_data.other_proc_signatures {
			if proc_signature.is_generic do continue;
			fmt.sbprintf(&loader_sb, "\t\"{0}\" = rawptr({0}),\n", proc_signature.name);
		}
		strings.write_string(&loader_sb, "}\n");

		hotload_procs_path := fmt.tprintf("%s/hotload_procs.odin", package_path);
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
