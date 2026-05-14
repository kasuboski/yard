import chute/ast
import chute/typecheck/types as tc
import gleam/list

/// Callback type for expression type inference.
/// Stdlib handlers need to recurse into sub-expressions but cannot
/// import the main typecheck module (would create a cycle).
pub type InferFn =
  fn(ast.Expr, tc.TypeCheckState) -> #(tc.TcType, tc.TypeCheckState)

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib detection
// ═══════════════════════════════════════════════════════════════════════════

pub fn is_stdlib_call(func: ast.Expr) -> Bool {
  case func {
    ast.ExprFieldAccess(ast.ExprVar("list"), _) -> True
    ast.ExprFieldAccess(ast.ExprVar("result"), _) -> True
    ast.ExprFieldAccess(ast.ExprVar("option"), _) -> True
    ast.ExprFieldAccess(ast.ExprVar("task"), _) -> True
    ast.ExprFieldAccess(ast.ExprVar("string"), _) -> True
    _ -> False
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib dispatch
// ═══════════════════════════════════════════════════════════════════════════

pub fn infer_stdlib_call(
  func: ast.Expr,
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case func {
    // list.map(items: List(a), fn: fn(a) -> b) -> List(b)
    ast.ExprFieldAccess(ast.ExprVar("list"), "map") ->
      infer_list_map(args, state, infer)

    // list.filter(items: List(a), fn: fn(a) -> Bool) -> List(a)
    ast.ExprFieldAccess(ast.ExprVar("list"), "filter") ->
      infer_list_filter(args, state, infer)

    // list.fold(items: List(a), init: b, fn: fn(b, a) -> b) -> b
    ast.ExprFieldAccess(ast.ExprVar("list"), "fold") ->
      infer_list_fold(args, state, infer)

    // list.length(items: List(a)) -> Int
    ast.ExprFieldAccess(ast.ExprVar("list"), "length") ->
      infer_list_length(args, state, infer)

    // result.try(result: Result(a, e1), fn: fn(a) -> Result(b, e2)) -> Result(b, e1 | e2)
    ast.ExprFieldAccess(ast.ExprVar("result"), "try") ->
      infer_result_try(args, state, infer)

    // result.map(result: Result(a, e), fn: fn(a) -> b) -> Result(b, e)
    ast.ExprFieldAccess(ast.ExprVar("result"), "map") ->
      infer_result_map(args, state, infer)

    // result.is_ok(result: Result(a, e)) -> Bool
    ast.ExprFieldAccess(ast.ExprVar("result"), "is_ok") ->
      infer_result_is_ok(args, state, infer)

    // result.is_error(result: Result(a, e)) -> Bool
    ast.ExprFieldAccess(ast.ExprVar("result"), "is_error") ->
      infer_result_is_error(args, state, infer)

    // option.map(opt: Option(a), fn: fn(a) -> b) -> Option(b)
    ast.ExprFieldAccess(ast.ExprVar("option"), "map") ->
      infer_option_map(args, state, infer)

    // string.length(s: String) -> Int
    ast.ExprFieldAccess(ast.ExprVar("string"), "length") ->
      infer_string_length(args, state, infer)

    // string.concat(a: String, b: String) -> String
    ast.ExprFieldAccess(ast.ExprVar("string"), "concat") ->
      infer_string_concat(args, state, infer)

    // task.dispatch_all(thunks: List(fn() -> Result(a, e))) -> Result(Nil, Error)
    ast.ExprFieldAccess(ast.ExprVar("task"), "dispatch_all") ->
      infer_task_dispatch_all(args, state, infer)

    // Fallback: infer all args, return fresh var
    _ -> {
      let #(state, _) = infer_args(args, state, infer)
      let #(ret, state) = tc.fresh_var(state)
      #(ret, state)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// list.* handlers
// ═══════════════════════════════════════════════════════════════════════════

// list.map(items, fn) -> List(b)
fn infer_list_map(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [list_expr, fn_expr] -> {
      let #(elem_type, state) = tc.fresh_var(state)
      let #(actual_list, state) = infer(list_expr, state)
      let state = tc.unify(actual_list, tc.TcNamed("List", [elem_type]), state)
      let #(fn_type, state) = infer(fn_expr, state)
      let #(result_type, state) = tc.fresh_var(state)
      let state = tc.unify(fn_type, tc.TcFn([elem_type], result_type), state)
      #(tc.TcNamed("List", [tc.resolve(result_type, state.subst)]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "list.map() expects 2 arguments"))
  }
}

// list.filter(items, fn) -> List(a)
fn infer_list_filter(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [list_expr, fn_expr] -> {
      let #(elem_type, state) = tc.fresh_var(state)
      let #(actual_list, state) = infer(list_expr, state)
      let state = tc.unify(actual_list, tc.TcNamed("List", [elem_type]), state)
      let #(fn_type, state) = infer(fn_expr, state)
      let state =
        tc.unify(fn_type, tc.TcFn([elem_type], tc.TcNamed("Bool", [])), state)
      #(tc.TcNamed("List", [tc.resolve(elem_type, state.subst)]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "list.filter() expects 2 arguments"))
  }
}

// list.fold(items, init, fn) -> b
fn infer_list_fold(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [list_expr, init_expr, fn_expr] -> {
      let #(elem_type, state) = tc.fresh_var(state)
      let #(actual_list, state) = infer(list_expr, state)
      let state = tc.unify(actual_list, tc.TcNamed("List", [elem_type]), state)
      let #(acc_type, state) = infer(init_expr, state)
      let #(fn_type, state) = infer(fn_expr, state)
      let state =
        tc.unify(fn_type, tc.TcFn([acc_type, elem_type], acc_type), state)
      #(tc.resolve(acc_type, state.subst), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "list.fold() expects 3 arguments"))
  }
}

// list.length(items) -> Int
fn infer_list_length(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [list_expr] -> {
      let #(elem_type, state) = tc.fresh_var(state)
      let #(actual_list, state) = infer(list_expr, state)
      let state = tc.unify(actual_list, tc.TcNamed("List", [elem_type]), state)
      #(tc.TcNamed("Int", []), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "list.length() expects 1 argument"))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// result.* handlers
// ═══════════════════════════════════════════════════════════════════════════

// result.try(result, fn) -> Result(b, e1 | e2) [auto-unioning]
fn infer_result_try(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [result_expr, fn_expr] -> {
      let #(success_a, state) = tc.fresh_var(state)
      let #(error_e1, state) = tc.fresh_var(state)
      let #(actual_result, state) = infer(result_expr, state)
      let state =
        tc.unify(
          actual_result,
          tc.TcNamed("Result", [success_a, error_e1]),
          state,
        )

      let #(success_b, state) = tc.fresh_var(state)
      let #(error_e2, state) = tc.fresh_var(state)
      let #(fn_type, state) = infer(fn_expr, state)
      let state =
        tc.unify(
          fn_type,
          tc.TcFn([success_a], tc.TcNamed("Result", [success_b, error_e2])),
          state,
        )

      // Auto-union: combine error types
      let combined_error =
        tc.TcUnion([
          tc.resolve(error_e1, state.subst),
          tc.resolve(error_e2, state.subst),
        ])
      #(
        tc.TcNamed("Result", [
          tc.resolve(success_b, state.subst),
          combined_error,
        ]),
        state,
      )
    }
    _ -> #(tc.TcError, tc.add_error(state, "result.try() expects 2 arguments"))
  }
}

// result.map(result, fn) -> Result(b, e)
fn infer_result_map(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [result_expr, fn_expr] -> {
      let #(success_a, state) = tc.fresh_var(state)
      let #(error_e, state) = tc.fresh_var(state)
      let #(actual_result, state) = infer(result_expr, state)
      let state =
        tc.unify(
          actual_result,
          tc.TcNamed("Result", [success_a, error_e]),
          state,
        )

      let #(success_b, state) = tc.fresh_var(state)
      let #(fn_type, state) = infer(fn_expr, state)
      let state = tc.unify(fn_type, tc.TcFn([success_a], success_b), state)

      #(
        tc.TcNamed("Result", [
          tc.resolve(success_b, state.subst),
          tc.resolve(error_e, state.subst),
        ]),
        state,
      )
    }
    _ -> #(tc.TcError, tc.add_error(state, "result.map() expects 2 arguments"))
  }
}

// result.is_ok(result) -> Bool
fn infer_result_is_ok(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [result_expr] -> {
      let #(a, state) = tc.fresh_var(state)
      let #(e, state) = tc.fresh_var(state)
      let #(actual, state) = infer(result_expr, state)
      let state = tc.unify(actual, tc.TcNamed("Result", [a, e]), state)
      #(tc.TcNamed("Bool", []), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "result.is_ok() expects 1 argument"))
  }
}

// result.is_error(result) -> Bool
fn infer_result_is_error(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [result_expr] -> {
      let #(a, state) = tc.fresh_var(state)
      let #(e, state) = tc.fresh_var(state)
      let #(actual, state) = infer(result_expr, state)
      let state = tc.unify(actual, tc.TcNamed("Result", [a, e]), state)
      #(tc.TcNamed("Bool", []), state)
    }
    _ -> #(
      tc.TcError,
      tc.add_error(state, "result.is_error() expects 1 argument"),
    )
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// option.* / string.* handlers
// ═══════════════════════════════════════════════════════════════════════════

// option.map(opt, fn) -> Option(b)
fn infer_option_map(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [opt_expr, fn_expr] -> {
      let #(a, state) = tc.fresh_var(state)
      let #(actual_opt, state) = infer(opt_expr, state)
      let state = tc.unify(actual_opt, tc.TcNamed("Option", [a]), state)
      let #(b, state) = tc.fresh_var(state)
      let #(fn_type, state) = infer(fn_expr, state)
      let state = tc.unify(fn_type, tc.TcFn([a], b), state)
      #(tc.TcNamed("Option", [tc.resolve(b, state.subst)]), state)
    }
    _ -> #(tc.TcError, tc.add_error(state, "option.map() expects 2 arguments"))
  }
}

// string.length(s) -> Int
fn infer_string_length(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [s_expr] -> {
      let #(actual, state) = infer(s_expr, state)
      let state = tc.unify(actual, tc.TcNamed("String", []), state)
      #(tc.TcNamed("Int", []), state)
    }
    _ -> #(
      tc.TcError,
      tc.add_error(state, "string.length() expects 1 argument"),
    )
  }
}

// string.concat(a, b) -> String
fn infer_string_concat(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [a_expr, b_expr] -> {
      let #(actual_a, state) = infer(a_expr, state)
      let state = tc.unify(actual_a, tc.TcNamed("String", []), state)
      let #(actual_b, state) = infer(b_expr, state)
      let state = tc.unify(actual_b, tc.TcNamed("String", []), state)
      #(tc.TcNamed("String", []), state)
    }
    _ -> #(
      tc.TcError,
      tc.add_error(state, "string.concat() expects 2 arguments"),
    )
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// task.* handlers
// ═══════════════════════════════════════════════════════════════════════════

// task.dispatch_all(thunks) -> Result(Nil, Error)
// Accepts List(fn() -> Result(a, e)) — element type is unified but otherwise unconstrained
fn infer_task_dispatch_all(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TcType, tc.TypeCheckState) {
  case args {
    [thunks_expr] -> {
      // The thunks arg must be a List of zero-arg closures
      let #(thunk_return, state) = tc.fresh_var(state)
      let #(thunk_error, state) = tc.fresh_var(state)
      let thunk_type =
        tc.TcFn([], tc.TcNamed("Result", [thunk_return, thunk_error]))
      let #(actual, state) = infer(thunks_expr, state)
      let state = tc.unify(actual, tc.TcNamed("List", [thunk_type]), state)
      // dispatch_all returns Result(Nil, Error) per spec
      #(
        tc.TcNamed("Result", [tc.TcNamed("Nil", []), tc.TcNamed("Error", [])]),
        state,
      )
    }
    _ -> #(
      tc.TcError,
      tc.add_error(state, "task.dispatch_all() expects 1 argument"),
    )
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

fn infer_args(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
) -> #(tc.TypeCheckState, List(tc.TcType)) {
  infer_args_helper(args, state, infer, [])
}

fn infer_args_helper(
  args: List(ast.Expr),
  state: tc.TypeCheckState,
  infer: InferFn,
  acc: List(tc.TcType),
) -> #(tc.TypeCheckState, List(tc.TcType)) {
  case args {
    [] -> #(state, list.reverse(acc))
    [arg, ..rest] -> {
      let #(t, state) = infer(arg, state)
      infer_args_helper(rest, state, infer, [t, ..acc])
    }
  }
}
