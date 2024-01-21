package find_builtin_procs

import "core:odin/parser"
import "core:odin/ast"
import "core:fmt"

visit_node :: proc(visitor: ^ast.Visitor, any_node: ^ast.Node) -> ^ast.Visitor {
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
			return visitor;
		}
		case ^ast.Value_Decl: {
			name: string;
			do_hotload := false;
			has_body := false;
			for name_node in node.names {
				if ident, ok := name_node.derived.(^ast.Ident); ok {
					name = ident.name;
				}
			}
			for attribute in node.attributes {
				//fmt.printf("\t%v\n", attribute);
				for expression in attribute.elems {
					#partial switch e in expression.derived_expr {
						case ^ast.Ident: {
							if e.name == "builtin" {
								do_hotload = true;
								fmt.printf("%s\n", name);
							}
						}
					}
				}
			}
		}
	}
	return nil;
}

main :: proc() {
	package_path := "D:\\I\\Odin\\core\\runtime";
	//pack, pack_ok := parser.parse_package_from_path(package_path);
	pack, collect_ok := parser.collect_package(package_path);
	if !collect_ok {
		fmt.printf("Failed to collect package\n");
		return;
	}
	pack.kind = .Runtime;
	parse_ok := parser.parse_package(pack, nil);

	if !parse_ok {
		fmt.printf("Failed to parse package\n");
		return;
	}
	visitor := ast.Visitor{
		visit_node,
		nil,
	}
	ast.walk(&visitor, &pack.node);
}