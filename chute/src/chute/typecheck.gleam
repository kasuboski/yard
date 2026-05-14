import chute/ast
import chute/typecheck/stdlib
import chute/typecheck/types as tc
import gleam/dict
import gleam/list
import gleam/option

// ═══════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════

/// Type-check a Chute program. Returns a list of type errors.
/// An empty list means the program is well-typed.
pub fn typecheck(program: ast.Program) -> List(tc.TypeError) {
  let state = tc.new_state()
  let state = check_program(program, state)
  list.reverse(state.errors)
}

// ═══════════════════════════════════════════════════════════════════════════
// Program-level type checking
// ═══════════════════════════════════════════════════════════════════════════

fn check_program(
  program: ast.Program,
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  let ast.Program(declarations) = program
  // Pass 1: collect all effect + function signatures
  let state = collect_signatures(declarations, state)
  // Pass 2: check each function body
  check_fn_bodies(declarations, state)
}

fn collect_signatures(
  decls: List(ast.Declaration),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case decls {
    [] -> state
    [decl, ..rest] -> {
      let state = case decl {
        ast.EffectDecl(name, params, return_type) -> {
          let param_types =
            list.map(params, fn(p) { tc.ast_type_to_tc(p.type_) })
          let ret = tc.ast_type_to_tc(return_type)
          tc.TypeCheckState(
            ..state,
            effects: dict.insert(
              state.effects,
              name,
              tc.EffectSig(param_types, ret),
            ),
          )
        }
        ast.FunctionDecl(name, _public, params, return_type, _body) -> {
          let param_types =
            list.map(params, fn(p) { tc.ast_type_to_tc(p.type_) })
          let ret = tc.ast_type_to_tc(return_type)
          tc.TypeCheckState(
            ..state,
            functions: dict.insert(
              state.functions,
              name,
              tc.FnSig(param_types, ret),
            ),
          )
        }
      }
      collect_signatures(rest, state)
    }
  }
}

fn check_fn_bodies(
  decls: List(ast.Declaration),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case decls {
    [] -> state
    [decl, ..rest] -> {
      let state = case decl {
        ast.EffectDecl(..) -> state
        ast.FunctionDecl(name, _public, params, return_type, body) ->
          check_function_body(name, params, return_type, body, state)
      }
      check_fn_bodies(rest, state)
    }
  }
}

fn check_function_body(
  _name: String,
  params: List(ast.Param),
  return_type: ast.Type,
  body: ast.Block,
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  let state = tc.TypeCheckState(..state, env: dict.new())
  let state = add_params_to_env(params, state)
  let #(body_type, state) = infer_block(body, state)
  let expected = tc.ast_type_to_tc(return_type)
  let state = tc.unify(body_type, expected, state)
  tc.TypeCheckState(..state, env: dict.new())
}

fn add_params_to_env(
  params: List(ast.Param),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case params {
    [] -> state
    [ast.Param(name, type_), ..rest] -> {
      let state =
        tc.TypeCheckState(
          ..state,
          env: dict.insert(state.env, name, tc.ast_type_to_tc(type_)),
        )
      add_params_to_env(rest, state)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: blocks and statements
// ═══════════════════════════════════════════════════════════════════════════

fn infer_block(
  block: ast.Block,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let ast.Block(statements, trailing) = block
  let state = infer_statements(statements, state)
  case trailing {
    option.Some(expr) -> infer_expr(expr, state)
    option.None -> #(tc.TcNamed("Nil", []), state)
  }
}

fn infer_statements(
  stmts: List(ast.Statement),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case stmts {
    [] -> state
    [stmt, ..rest] -> {
      let state = infer_statement(stmt, state)
      infer_statements(rest, state)
    }
  }
}

fn infer_statement(
  stmt: ast.Statement,
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case stmt {
    ast.LetDecl(name, type_annotation, value) -> {
      let #(value_type, state) = infer_expr(value, state)
      let final_type = case type_annotation {
        option.Some(annotated) -> {
          let expected = tc.ast_type_to_tc(annotated)
          let state = tc.unify(value_type, expected, state)
          tc.resolve(expected, state.subst)
        }
        option.None -> value_type
      }
      let state = case type_annotation {
        option.Some(_) -> state
        option.None -> state
      }
      tc.TypeCheckState(..state, env: dict.insert(state.env, name, final_type))
    }
    ast.StatementExpr(expr) -> {
      let #(_, state) = infer_expr(expr, state)
      state
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: expressions
// ═══════════════════════════════════════════════════════════════════════════

fn infer_expr(
  expr: ast.Expr,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case expr {
    // ── Literals ─────────────────────────────────────────────────────────
    ast.ExprInt(_) -> #(tc.TcNamed("Int", []), state)
    ast.ExprFloat(_) -> #(tc.TcNamed("Float", []), state)
    ast.ExprBool(_) -> #(tc.TcNamed("Bool", []), state)
    ast.ExprNil -> #(tc.TcNamed("Nil", []), state)

    // ── Variable reference ───────────────────────────────────────────────
    ast.ExprVar(name) -> {
      case dict.get(state.env, name) {
        Ok(t) -> #(tc.resolve(t, state.subst), state)
        Error(_) -> {
          case name {
            "None" -> {
              let #(t, state) = tc.fresh_var(state)
              #(tc.TcNamed("Option", [t]), state)
            }
            "Nil" -> #(tc.TcNamed("Nil", []), state)
            _ -> #(
              tc.TcError,
              tc.add_error(state, "Undefined variable: " <> name),
            )
          }
        }
      }
    }

    // ── String literal ───────────────────────────────────────────────────
    ast.ExprString(parts) -> {
      let state = check_string_parts(parts, state)
      #(tc.TcNamed("String", []), state)
    }

    // ── Binary operator ──────────────────────────────────────────────────
    ast.ExprBinaryOp(left, op, right) -> {
      let #(lt, state) = infer_expr(left, state)
      let #(rt, state) = infer_expr(right, state)
      infer_binop(op, lt, rt, state)
    }

    // ── Field access ─────────────────────────────────────────────────────
    ast.ExprFieldAccess(record, field) -> {
      case is_module_name(record) {
        True -> {
          let module_name = case record {
            ast.ExprVar(n) -> n
            _ -> "<unknown>"
          }
          #(
            tc.TcError,
            tc.add_error(
              state,
              "Cannot use "
                <> module_name
                <> "."
                <> field
                <> " as a value — call it directly",
            ),
          )
        }
        False -> {
          let #(rec_type, state) = infer_expr(record, state)
          infer_field_access(rec_type, field, state)
        }
      }
    }

    // ── Function call ────────────────────────────────────────────────────
    ast.ExprCall(func, args) -> infer_call(func, args, state)

    // ── Perform ──────────────────────────────────────────────────────────
    ast.ExprPerform(name, args) -> infer_perform(name, args, state)

    // ── Record literal ───────────────────────────────────────────────────
    ast.ExprRecord(fields) -> infer_record_literal(fields, state)

    // ── List literal ─────────────────────────────────────────────────────
    ast.ExprList(elements) -> infer_list_literal(elements, state)

    // ── Closure ──────────────────────────────────────────────────────────
    ast.ExprClosure(params, body) -> infer_closure(params, body, state)

    // ── Pipeline (should be desugared; handle gracefully) ────────────────
    ast.ExprPipeline(left, right) -> {
      let #(_, state) = infer_expr(left, state)
      let #(_, state) = infer_expr(right, state)
      #(
        tc.TcError,
        tc.add_error(
          state,
          "Pipeline was not fully desugared — type cannot be inferred",
        ),
      )
    }

    // ── Group (should be desugared; handle gracefully) ───────────────────
    ast.ExprGroup(inner) -> infer_expr(inner, state)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: binary operators
// ═══════════════════════════════════════════════════════════════════════════

fn infer_binop(
  op: ast.BinOp,
  left_type: tc.TcType,
  right_type: tc.TcType,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let is_comparison = case op {
    ast.OpEq | ast.OpNeq | ast.OpLt | ast.OpLe | ast.OpGt | ast.OpGe -> True
    _ -> False
  }
  let state = tc.unify(left_type, right_type, state)
  case is_comparison {
    True -> #(tc.TcNamed("Bool", []), state)
    False -> #(left_type, state)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: field access
// ═══════════════════════════════════════════════════════════════════════════

fn infer_field_access(
  record_type: tc.TcType,
  field: String,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let resolved = tc.resolve(record_type, state.subst)
  case resolved {
    tc.TcRecord(fields) -> {
      case find_field_type(fields, field) {
        Ok(field_type) -> #(tc.resolve(field_type, state.subst), state)
        Error(_) -> #(
          tc.TcError,
          tc.add_error(
            state,
            "Record type "
              <> tc.tc_type_to_string(resolved)
              <> " has no field '"
              <> field
              <> "'",
          ),
        )
      }
    }
    _ -> #(
      tc.TcError,
      tc.add_error(
        state,
        "Cannot access field '"
          <> field
          <> "' on non-record type: "
          <> tc.tc_type_to_string(resolved),
      ),
    )
  }
}

fn find_field_type(
  fields: List(tc.TcTypeField),
  name: String,
) -> Result(tc.TcType, Nil) {
  case fields {
    [] -> Error(Nil)
    [tc.TcTypeField(n, t), ..rest] -> {
      case n == name {
        True -> Ok(t)
        False -> find_field_type(rest, name)
      }
    }
  }
}

fn is_module_name(expr: ast.Expr) -> Bool {
  case expr {
    ast.ExprVar("list") -> True
    ast.ExprVar("result") -> True
    ast.ExprVar("option") -> True
    ast.ExprVar("task") -> True
    ast.ExprVar("string") -> True
    ast.ExprVar("int") -> True
    ast.ExprVar("float") -> True
    _ -> False
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: function calls
// ═══════════════════════════════════════════════════════════════════════════

fn infer_call(
  func: ast.Expr,
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case func {
    ast.ExprVar("Ok") -> infer_ok_constructor(args, state)
    ast.ExprVar("Error") -> infer_error_constructor(args, state)
    ast.ExprVar("Some") -> infer_some_constructor(args, state)
    _ -> {
      case stdlib.is_stdlib_call(func) {
        True -> stdlib.infer_stdlib_call(func, args, state, infer_expr)
        False -> infer_regular_call(func, args, state)
      }
    }
  }
}

// ── Constructors ──────────────────────────────────────────────────────────

fn infer_ok_constructor(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [value] -> {
      let #(value_type, state) = infer_expr(value, state)
      let #(error_type, state) = tc.fresh_var(state)
      #(tc.TcNamed("Result", [value_type, error_type]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "Ok() takes exactly 1 argument"))
  }
}

fn infer_error_constructor(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [value] -> {
      let #(error_type, state) = infer_expr(value, state)
      let #(success_type, state) = tc.fresh_var(state)
      #(tc.TcNamed("Result", [success_type, error_type]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "Error() takes exactly 1 argument"))
  }
}

fn infer_some_constructor(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [value] -> {
      let #(value_type, state) = infer_expr(value, state)
      #(tc.TcNamed("Option", [value_type]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "Some() takes exactly 1 argument"))
  }
}

// ── Regular (user-defined) function calls ─────────────────────────────────

fn infer_regular_call(
  func: ast.Expr,
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case func {
    ast.ExprVar(name) -> {
      case dict.get(state.env, name) {
        Ok(fn_type) -> infer_call_with_type(fn_type, args, name, state)
        Error(_) -> {
          case dict.get(state.functions, name) {
            Ok(tc.FnSig(param_types, return_type)) -> {
              let state =
                tc.check_arity(
                  name,
                  list.length(param_types),
                  list.length(args),
                  state,
                )
              let #(state, arg_types) = infer_args(args, state)
              let state = tc.unify_arg_types(param_types, arg_types, state)
              #(tc.resolve(return_type, state.subst), state)
            }
            Error(_) -> #(
              tc.TcError,
              tc.add_error(state, "Undefined function: " <> name),
            )
          }
        }
      }
    }
    _ -> {
      let #(func_type, state) = infer_expr(func, state)
      infer_call_with_type(func_type, args, "<closure>", state)
    }
  }
}

fn infer_call_with_type(
  func_type: tc.TcType,
  args: List(ast.Expr),
  context: String,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let resolved = tc.resolve(func_type, state.subst)
  case resolved {
    tc.TcFn(param_types, return_type) -> {
      let state =
        tc.check_arity(
          context,
          list.length(param_types),
          list.length(args),
          state,
        )
      let #(state, arg_types) = infer_args(args, state)
      let state = tc.unify_arg_types(param_types, arg_types, state)
      #(tc.resolve(return_type, state.subst), state)
    }
    tc.TcError -> {
      let #(state, _) = infer_args(args, state)
      #(tc.TcError, state)
    }
    _ -> {
      let #(state, _) = infer_args(args, state)
      #(
        tc.TcError,
        tc.add_error(
          state,
          "Cannot call non-function type: " <> tc.tc_type_to_string(resolved),
        ),
      )
    }
  }
}

fn infer_args(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TypeCheckState, List(tc.TcType)) {
  infer_args_helper(args, state, [])
}

fn infer_args_helper(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  acc: List(tc.TcType),
) -> #(tc.TypeCheckState, List(tc.TcType)) {
  case args {
    [] -> #(state, list.reverse(acc))
    [arg, ..rest] -> {
      let #(t, state) = infer_expr(arg, state)
      infer_args_helper(rest, state, [t, ..acc])
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: perform (effect calls)
// ═══════════════════════════════════════════════════════════════════════════

fn infer_perform(
  name: String,
  args: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  case dict.get(state.effects, name) {
    Ok(tc.EffectSig(param_types, return_type)) -> {
      let state =
        tc.check_arity(
          "effect " <> name,
          list.length(param_types),
          list.length(args),
          state,
        )
      let #(state, arg_types) = infer_args(args, state)
      let state = tc.unify_arg_types(param_types, arg_types, state)
      #(tc.resolve(return_type, state.subst), state)
    }
    Error(_) -> #(tc.TcError, tc.add_error(state, "Undefined effect: " <> name))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: record literal
// ═══════════════════════════════════════════════════════════════════════════

fn infer_record_literal(
  fields: List(ast.RecordField),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let #(state, tc_fields) = infer_record_fields(fields, state, [])
  #(tc.TcRecord(tc_fields), state)
}

fn infer_record_fields(
  fields: List(ast.RecordField),
  state: tc.TypeCheckState,
  acc: List(tc.TcTypeField),
) -> #(tc.TypeCheckState, List(tc.TcTypeField)) {
  case fields {
    [] -> #(state, list.reverse(acc))
    [ast.RecordField(name, value), ..rest] -> {
      let #(value_type, state) = infer_expr(value, state)
      infer_record_fields(rest, state, [tc.TcTypeField(name, value_type), ..acc])
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: list literal
// ═══════════════════════════════════════════════════════════════════════════

fn infer_list_literal(
  elements: List(ast.Expr),
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let #(elem_type, state) = tc.fresh_var(state)
  let state = unify_list_elements(elements, elem_type, state)
  #(tc.TcNamed("List", [tc.resolve(elem_type, state.subst)]), state)
}

fn unify_list_elements(
  elements: List(ast.Expr),
  expected: tc.TcType,
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case elements {
    [] -> state
    [elem, ..rest] -> {
      let #(elem_type, state) = infer_expr(elem, state)
      let state = tc.unify(elem_type, expected, state)
      unify_list_elements(rest, expected, state)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: closures
// ═══════════════════════════════════════════════════════════════════════════

fn infer_closure(
  params: List(String),
  body: ast.Block,
  state: tc.TypeCheckState,
) -> #(tc.TcType, tc.TypeCheckState) {
  let #(param_types, state) = fresh_vars_for(params, state, [])
  let state = extend_env(params, param_types, state)
  let #(body_type, state) = infer_block(body, state)
  #(tc.TcFn(param_types, body_type), state)
}

fn fresh_vars_for(
  params: List(String),
  state: tc.TypeCheckState,
  acc: List(tc.TcType),
) -> #(List(tc.TcType), tc.TypeCheckState) {
  case params {
    [] -> #(list.reverse(acc), state)
    [_, ..rest] -> {
      let #(t, state) = tc.fresh_var(state)
      fresh_vars_for(rest, state, [t, ..acc])
    }
  }
}

fn extend_env(
  names: List(String),
  types: List(tc.TcType),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case names, types {
    [], [] -> state
    [n, ..ns], [t, ..ts] -> {
      let state = tc.TypeCheckState(..state, env: dict.insert(state.env, n, t))
      extend_env(ns, ts, state)
    }
    _, _ -> state
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type inference: string parts
// ═══════════════════════════════════════════════════════════════════════════

fn check_string_parts(
  parts: List(ast.StringPart),
  state: tc.TypeCheckState,
) -> tc.TypeCheckState {
  case parts {
    [] -> state
    [ast.StringText(_), ..rest] -> check_string_parts(rest, state)
    [ast.StringInterpolation(expr), ..rest] -> {
      let #(t, state) = infer_expr(expr, state)
      let state = tc.unify(t, tc.TcNamed("String", []), state)
      check_string_parts(rest, state)
    }
  }
}
