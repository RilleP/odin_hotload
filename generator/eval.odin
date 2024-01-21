package hotload_gen

import "core:odin/ast"

evaluate_simple_bool_expression :: proc(any_expr: ^ast.Expr) -> (result: bool, is_simple: bool) {
	#partial switch expr in any_expr.derived {
		case ^ast.Ident: {
			if expr.name == "true" {
				return true, true;
			}
			else if expr.name == "false" {
				return false, true;
			}
		}
		case ^ast.Binary_Expr: {
			left := evaluate_simple_bool_expression(expr.left) or_return;
			right := evaluate_simple_bool_expression(expr.right) or_return;
			#partial switch expr.op.kind {
				case .Cmp_And: {
					return left && right, true;
				}
				case .Cmp_Or: {
					return left || right, true;
				}
			}
		}
		case ^ast.Unary_Expr: {
			yes := evaluate_simple_bool_expression(expr.expr) or_return;
			#partial switch expr.op.kind {
				case .Not: {
					return !yes, true;
				}
			}
		}
		case ^ast.Paren_Expr: {
			return evaluate_simple_bool_expression(expr.expr);
		}
	}
	return false, false;
}