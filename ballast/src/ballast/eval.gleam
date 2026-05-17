import ballast/effect
import ballast/env
import ballast/value
import chute/ast
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/string

// ═══════════════════════════════════════════════════════════════════════════
// Eval context — holds top-level declarations
// ═══════════════════════════════════════════════════════════════════════════

pub type EvalContext {
  EvalContext(
    functions: dict.Dict(String, ast.Declaration),
    effects: dict.Dict(String, ast.Declaration),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════

/// Run a program with no env value. Finds `pub fn main()` and evaluates it.
pub fn run(program: ast.Program, gas: Int) -> effect.EvalResult {
  run_with_env(program, value.NilVal, gas)
}

/// Run a program, passing an env value as the first argument to `main()`.
pub fn run_with_env(
  program: ast.Program,
  env_value: value.Value,
  gas: Int,
) -> effect.EvalResult {
  let ctx = build_context(program)
  case dict.get(ctx.functions, "main") {
    Ok(ast.FunctionDecl(
      name: _,
      public: _,
      params: params,
      return_type: _,
      body: body,
    )) -> {
      let main_env = case params {
        [ast.Param(name: param_name, type_: _), ..] ->
          env.insert(env.new(), param_name, env_value)
        [] -> env.new()
      }
      eval_block(body, main_env, ctx, gas, fn(v, g) { effect.EvalDone(v, g) })
    }
    Ok(_) -> effect.EvalError(value.RuntimeError("main is not a function"))
    Error(_) -> effect.EvalError(value.UndefinedFunction("main"))
  }
}

/// Evaluate a single expression in a given environment (for testing).
pub fn eval_expr(
  expr: ast.Expr,
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
) -> effect.EvalResult {
  eval_k(expr, e, ctx, gas, fn(v, g) { effect.EvalDone(v, g) })
}

// ═══════════════════════════════════════════════════════════════════════════
// Context builder
// ═══════════════════════════════════════════════════════════════════════════

fn build_context(program: ast.Program) -> EvalContext {
  let init = EvalContext(functions: dict.new(), effects: dict.new())
  list.fold(program.declarations, init, fn(ctx, decl) {
    case decl {
      ast.FunctionDecl(name: name, ..) ->
        EvalContext(..ctx, functions: dict.insert(ctx.functions, name, decl))
      ast.EffectDecl(name: name, ..) ->
        EvalContext(..ctx, effects: dict.insert(ctx.effects, name, decl))
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════════
// Gas
// ═══════════════════════════════════════════════════════════════════════════

/// Decrement gas. Returns Error(GasExhausted) if exhausted.
fn tick(gas: Int) -> Result(Int, value.RuntimeError) {
  case gas > 0 {
    True -> Ok(gas - 1)
    False -> Error(value.GasExhausted)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Block evaluation (CPS — continuations capture rest-of-block on yield)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_block(
  block: ast.Block,
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  eval_stmts(block.statements, block.trailing, e, ctx, gas, k)
}

fn eval_stmts(
  stmts: List(ast.Statement),
  trailing: option.Option(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case stmts {
    [] -> {
      case trailing {
        option.Some(expr) -> eval_k(expr, e, ctx, gas, k)
        option.None -> k(value.NilVal, gas)
      }
    }
    [ast.LetDecl(name, _, value_expr), ..rest] -> {
      eval_k(value_expr, e, ctx, gas, fn(v, g) {
        eval_stmts(rest, trailing, env.insert(e, name, v), ctx, g, k)
      })
    }
    [ast.LetTryDecl(name, _, value_expr), ..rest] -> {
      eval_k(value_expr, e, ctx, gas, fn(v, g) {
        case v {
          value.OkVal(inner) ->
            eval_stmts(rest, trailing, env.insert(e, name, inner), ctx, g, k)
          value.ErrorVal(_) as err -> k(err, g)
          _ ->
            effect.EvalError(value.TypeMismatch("Result", value.type_name(v)))
        }
      })
    }
    [ast.StatementExpr(expr), ..rest] -> {
      eval_k(expr, e, ctx, gas, fn(_, g) {
        eval_stmts(rest, trailing, e, ctx, g, k)
      })
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Core expression evaluator (CPS)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_k(
  expr: ast.Expr,
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case tick(gas) {
    Error(err) -> effect.EvalError(err)
    Ok(gas) -> {
      case expr {
        // ── Literals ────────────────────────────────────────────────────
        ast.ExprInt(n) -> k(value.IntVal(n), gas)
        ast.ExprFloat(f) -> k(value.FloatVal(f), gas)
        ast.ExprBool(b) -> k(value.BoolVal(b), gas)
        ast.ExprNil -> k(value.NilVal, gas)

        // ── String with interpolation ──────────────────────────────────
        ast.ExprString(parts) -> eval_string_k(parts, e, ctx, gas, "", k)

        // ── Variable ──────────────────────────────────────────────────
        ast.ExprVar("Nil") -> k(value.NilVal, gas)
        ast.ExprVar("None") -> k(value.NoneVal, gas)
        ast.ExprVar(name) -> {
          case env.get(e, name) {
            Ok(v) -> k(v, gas)
            Error(err) -> effect.EvalError(err)
          }
        }

        // ── Binary operator ──────────────────────────────────────────
        ast.ExprBinaryOp(left, op, right) -> {
          eval_k(left, e, ctx, gas, fn(lval, g1) {
            eval_k(right, e, ctx, g1, fn(rval, g2) {
              case apply_binop(op, lval, rval) {
                Ok(v) -> k(v, g2)
                Error(err) -> effect.EvalError(err)
              }
            })
          })
        }

        // ── Perform (yield to host) ──────────────────────────────────
        ast.ExprPerform(name, args) -> {
          eval_args_k(args, e, ctx, gas, fn(arg_vals, g) {
            effect.Yielded(
              name,
              arg_vals,
              effect.make_continuation(fn(host_val) { k(host_val, g) }),
              g,
            )
          })
        }

        // ── Function call ────────────────────────────────────────────
        ast.ExprCall(func, args) -> eval_call_k(func, args, e, ctx, gas, k)

        // ── Field access ─────────────────────────────────────────────
        ast.ExprFieldAccess(record_expr, field) -> {
          eval_k(record_expr, e, ctx, gas, fn(record_val, g) {
            case value.record_get(record_val, field) {
              Ok(v) -> k(v, g)
              Error(err) -> effect.EvalError(err)
            }
          })
        }

        // ── Record literal ───────────────────────────────────────────
        ast.ExprRecord(fields) -> eval_record_k(fields, e, ctx, gas, [], k)

        // ── List literal ─────────────────────────────────────────────
        ast.ExprList(elements) -> {
          eval_args_k(elements, e, ctx, gas, fn(vals, g) {
            k(value.ListVal(vals), g)
          })
        }

        // ── Closure ──────────────────────────────────────────────────
        ast.ExprClosure(params, body) -> {
          k(value.ClosureVal(params, body, e), gas)
        }

        // ── Case expression ──────────────────────────────────────────────
        ast.ExprCase(subject, branches) ->
          eval_case_k(subject, branches, e, ctx, gas, k)

        // ── Group (should be desugared, evaluate inner) ──────────────
        ast.ExprGroup(inner) -> eval_k(inner, e, ctx, gas, k)

        // ── Pipeline (should be desugared) ────────────────────────────
        ast.ExprPipeline(_, _) ->
          effect.EvalError(value.RuntimeError(
            "Unexpected pipeline (should be desugared)",
          ))
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// String interpolation (CPS)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_string_k(
  parts: List(ast.StringPart),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  acc: String,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case parts {
    [] -> k(value.StringVal(acc), gas)
    [ast.StringText(text), ..rest] ->
      eval_string_k(rest, e, ctx, gas, acc <> text, k)
    [ast.StringInterpolation(expr), ..rest] -> {
      eval_k(expr, e, ctx, gas, fn(v, g) {
        eval_string_k(rest, e, ctx, g, acc <> display_value(v), k)
      })
    }
  }
}

/// Convert a value to its display string form for interpolation.
fn display_value(v: value.Value) -> String {
  case v {
    value.StringVal(s) -> s
    value.IntVal(n) -> int.to_string(n)
    value.FloatVal(f) -> int.to_string(float.truncate(f)) <> ".0"
    value.BoolVal(True) -> "True"
    value.BoolVal(False) -> "False"
    value.NilVal -> "Nil"
    other -> value.value_to_string(other)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Record literal evaluation (CPS)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_record_k(
  fields: List(ast.RecordField),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  acc: List(#(String, value.Value)),
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case fields {
    [] -> k(value.RecordVal(list.reverse(acc)), gas)
    [ast.RecordField(name, value_expr), ..rest] -> {
      eval_k(value_expr, e, ctx, gas, fn(v, g) {
        eval_record_k(rest, e, ctx, g, [#(name, v), ..acc], k)
      })
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Argument list evaluation (CPS, left-to-right)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_args_k(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(List(value.Value), Int) -> effect.EvalResult,
) -> effect.EvalResult {
  eval_args_loop(args, e, ctx, gas, [], k)
}

fn eval_args_loop(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  acc: List(value.Value),
  k: fn(List(value.Value), Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [] -> k(list.reverse(acc), gas)
    [arg, ..rest] -> {
      eval_k(arg, e, ctx, gas, fn(v, g) {
        eval_args_loop(rest, e, ctx, g, [v, ..acc], k)
      })
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Case expression evaluation (CPS)
// ═══════════════════════════════════════════════════════════════════════════

fn eval_case_k(
  subject: ast.Expr,
  branches: List(ast.CaseBranch),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  eval_k(subject, e, ctx, gas, fn(subject_val, g) {
    eval_case_branches(subject_val, branches, e, ctx, g, k)
  })
}

fn eval_case_branches(
  subject_val: value.Value,
  branches: List(ast.CaseBranch),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case branches {
    [] -> effect.EvalError(value.MatchError(value.value_to_string(subject_val)))
    [ast.CaseBranch(pattern, body), ..rest] -> {
      eval_k(pattern, e, ctx, gas, fn(pattern_val, g) {
        case value.values_equal(subject_val, pattern_val) {
          True -> eval_block(body, e, ctx, g, k)
          False -> eval_case_branches(subject_val, rest, e, ctx, g, k)
        }
      })
    }
    [ast.CaseWildcard(body), ..] -> {
      // Wildcard always matches — since we get here, no prior branch matched.
      eval_block(body, e, ctx, gas, k)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Function call dispatch
// ═══════════════════════════════════════════════════════════════════════════

fn eval_call_k(
  func: ast.Expr,
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case func {
    // ── Constructors ───────────────────────────────────────────────
    ast.ExprVar("Ok") ->
      eval_args_k(args, e, ctx, gas, fn(vals, g) {
        case vals {
          [v] -> k(value.OkVal(v), g)
          _ -> effect.EvalError(value.ArityMismatch("Ok", 1, list.length(vals)))
        }
      })

    ast.ExprVar("Error") ->
      eval_args_k(args, e, ctx, gas, fn(vals, g) {
        case vals {
          [v] -> k(value.ErrorVal(v), g)
          _ ->
            effect.EvalError(value.ArityMismatch("Error", 1, list.length(vals)))
        }
      })

    ast.ExprVar("Some") ->
      eval_args_k(args, e, ctx, gas, fn(vals, g) {
        case vals {
          [v] -> k(value.SomeVal(v), g)
          _ ->
            effect.EvalError(value.ArityMismatch("Some", 1, list.length(vals)))
        }
      })

    ast.ExprVar("None") ->
      eval_args_k(args, e, ctx, gas, fn(vals, g) {
        case vals {
          [] -> k(value.NoneVal, g)
          _ ->
            effect.EvalError(value.ArityMismatch("None", 0, list.length(vals)))
        }
      })

    // ── Stdlib ─────────────────────────────────────────────────────
    ast.ExprFieldAccess(ast.ExprVar("list"), "map") ->
      stdlib_list_map(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("list"), "filter") ->
      stdlib_list_filter(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("list"), "fold") ->
      stdlib_list_fold(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("list"), "length") ->
      stdlib_list_length(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("result"), "try") ->
      stdlib_result_try(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("result"), "map") ->
      stdlib_result_map(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("result"), "is_ok") ->
      stdlib_result_is_ok(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("result"), "is_error") ->
      stdlib_result_is_error(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("option"), "map") ->
      stdlib_option_map(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("string"), "length") ->
      stdlib_string_length(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("string"), "concat") ->
      stdlib_string_concat(args, e, ctx, gas, k)
    ast.ExprFieldAccess(ast.ExprVar("task"), "dispatch_all") ->
      stdlib_task_dispatch_all(args, e, ctx, gas, k)

    // ── User-defined function or closure in env ────────────────────
    ast.ExprVar(name) -> {
      case dict.get(ctx.functions, name) {
        Ok(decl) ->
          eval_args_k(args, e, ctx, gas, fn(vals, g) {
            call_function(decl, vals, ctx, g, k)
          })
        Error(_) -> {
          // Must be a closure in the environment
          case env.get(e, name) {
            Ok(value.ClosureVal(params, body, closed_env)) ->
              eval_args_k(args, e, ctx, gas, fn(vals, g) {
                call_closure(params, body, closed_env, vals, ctx, g, k)
              })
            Ok(other) ->
              effect.EvalError(value.NotCallable(value.type_name(other)))
            Error(_) -> effect.EvalError(value.UndefinedFunction(name))
          }
        }
      }
    }

    // ── General case: evaluate func to a value, then apply ─────────
    _ -> {
      eval_k(func, e, ctx, gas, fn(func_val, g1) {
        eval_args_k(args, e, ctx, g1, fn(vals, g2) {
          apply_value(func_val, vals, ctx, g2, k)
        })
      })
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Function / closure application
// ═══════════════════════════════════════════════════════════════════════════

fn apply_value(
  func_val: value.Value,
  args: List(value.Value),
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case func_val {
    value.ClosureVal(params, body, closed_env) ->
      call_closure(params, body, closed_env, args, ctx, gas, k)
    _ -> effect.EvalError(value.NotCallable(value.type_name(func_val)))
  }
}

fn call_function(
  decl: ast.Declaration,
  arg_vals: List(value.Value),
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case decl {
    ast.FunctionDecl(
      name: _,
      public: _,
      params: params,
      return_type: _,
      body: body,
    ) -> {
      let param_names = list.map(params, fn(p) { p.name })
      let fn_env = env.extend(env.new(), param_names, arg_vals)
      eval_block(body, fn_env, ctx, gas, k)
    }
    _ -> effect.EvalError(value.RuntimeError("Expected function declaration"))
  }
}

fn call_closure(
  params: List(String),
  body: ast.Block,
  closed_env: env.Env,
  arg_vals: List(value.Value),
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case list.length(params) == list.length(arg_vals) {
    False ->
      effect.EvalError(value.ArityMismatch(
        "closure",
        list.length(params),
        list.length(arg_vals),
      ))
    True -> {
      let closure_env = env.extend(closed_env, params, arg_vals)
      eval_block(body, closure_env, ctx, gas, k)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Binary operators
// ═══════════════════════════════════════════════════════════════════════════

fn apply_binop(
  op: ast.BinOp,
  lval: value.Value,
  rval: value.Value,
) -> Result(value.Value, value.RuntimeError) {
  case op {
    ast.OpAdd -> int_op(fn(a, b) { a + b }, lval, rval)
    ast.OpSub -> int_op(fn(a, b) { a - b }, lval, rval)
    ast.OpMul -> int_op(fn(a, b) { a * b }, lval, rval)
    ast.OpDiv -> {
      case lval, rval {
        value.IntVal(a), value.IntVal(b) -> {
          case b == 0 {
            True -> Error(value.DivisionByZero)
            False -> Ok(value.IntVal(a / b))
          }
        }
        _, _ -> type_err("Int", lval, rval)
      }
    }
    ast.OpEq -> Ok(value.BoolVal(value.values_equal(lval, rval)))
    ast.OpNeq -> Ok(value.BoolVal(!value.values_equal(lval, rval)))
    ast.OpLt -> int_cmp(fn(a, b) { a < b }, lval, rval)
    ast.OpLe -> int_cmp(fn(a, b) { a <= b }, lval, rval)
    ast.OpGt -> int_cmp(fn(a, b) { a > b }, lval, rval)
    ast.OpGe -> int_cmp(fn(a, b) { a >= b }, lval, rval)
  }
}

fn int_op(
  f: fn(Int, Int) -> Int,
  lval: value.Value,
  rval: value.Value,
) -> Result(value.Value, value.RuntimeError) {
  case lval, rval {
    value.IntVal(a), value.IntVal(b) -> Ok(value.IntVal(f(a, b)))
    _, _ -> type_err("Int", lval, rval)
  }
}

fn int_cmp(
  f: fn(Int, Int) -> Bool,
  lval: value.Value,
  rval: value.Value,
) -> Result(value.Value, value.RuntimeError) {
  case lval, rval {
    value.IntVal(a), value.IntVal(b) -> Ok(value.BoolVal(f(a, b)))
    _, _ -> type_err("Int", lval, rval)
  }
}

fn type_err(
  expected: String,
  lval: value.Value,
  rval: value.Value,
) -> Result(value.Value, value.RuntimeError) {
  Error(value.TypeMismatch(
    expected,
    value.type_name(lval) <> " and " <> value.type_name(rval),
  ))
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: list.map
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_list_map(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [list_expr, fn_expr] ->
      eval_k(list_expr, e, ctx, gas, fn(list_val, g1) {
        eval_k(fn_expr, e, ctx, g1, fn(fn_val, g2) {
          case list_val {
            value.ListVal(items) -> map_loop(items, fn_val, ctx, g2, [], k)
            _ ->
              effect.EvalError(value.TypeMismatch(
                "List",
                value.type_name(list_val),
              ))
          }
        })
      })
    _ -> effect.EvalError(value.ArityMismatch("list.map", 2, list.length(args)))
  }
}

fn map_loop(
  items: List(value.Value),
  fn_val: value.Value,
  ctx: EvalContext,
  gas: Int,
  acc: List(value.Value),
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case items {
    [] -> k(value.ListVal(list.reverse(acc)), gas)
    [item, ..rest] ->
      apply_value(fn_val, [item], ctx, gas, fn(result, g) {
        map_loop(rest, fn_val, ctx, g, [result, ..acc], k)
      })
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: list.filter
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_list_filter(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [list_expr, fn_expr] ->
      eval_k(list_expr, e, ctx, gas, fn(list_val, g1) {
        eval_k(fn_expr, e, ctx, g1, fn(fn_val, g2) {
          case list_val {
            value.ListVal(items) -> filter_loop(items, fn_val, ctx, g2, [], k)
            _ ->
              effect.EvalError(value.TypeMismatch(
                "List",
                value.type_name(list_val),
              ))
          }
        })
      })
    _ ->
      effect.EvalError(value.ArityMismatch("list.filter", 2, list.length(args)))
  }
}

fn filter_loop(
  items: List(value.Value),
  fn_val: value.Value,
  ctx: EvalContext,
  gas: Int,
  acc: List(value.Value),
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case items {
    [] -> k(value.ListVal(list.reverse(acc)), gas)
    [item, ..rest] ->
      apply_value(fn_val, [item], ctx, gas, fn(result, g) {
        case result {
          value.BoolVal(True) ->
            filter_loop(rest, fn_val, ctx, g, [item, ..acc], k)
          _ -> filter_loop(rest, fn_val, ctx, g, acc, k)
        }
      })
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: list.fold
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_list_fold(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [list_expr, init_expr, fn_expr] ->
      eval_k(list_expr, e, ctx, gas, fn(list_val, g1) {
        eval_k(init_expr, e, ctx, g1, fn(init_val, g2) {
          eval_k(fn_expr, e, ctx, g2, fn(fn_val, g3) {
            case list_val {
              value.ListVal(items) ->
                fold_loop(items, init_val, fn_val, ctx, g3, k)
              _ ->
                effect.EvalError(value.TypeMismatch(
                  "List",
                  value.type_name(list_val),
                ))
            }
          })
        })
      })
    _ ->
      effect.EvalError(value.ArityMismatch("list.fold", 3, list.length(args)))
  }
}

fn fold_loop(
  items: List(value.Value),
  acc: value.Value,
  fn_val: value.Value,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case items {
    [] -> k(acc, gas)
    [item, ..rest] ->
      apply_value(fn_val, [acc, item], ctx, gas, fn(result, g) {
        fold_loop(rest, result, fn_val, ctx, g, k)
      })
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: list.length
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_list_length(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [list_expr] ->
      eval_k(list_expr, e, ctx, gas, fn(list_val, g) {
        case list_val {
          value.ListVal(items) -> k(value.IntVal(list.length(items)), g)
          _ ->
            effect.EvalError(value.TypeMismatch(
              "List",
              value.type_name(list_val),
            ))
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch("list.length", 1, list.length(args)))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: result.try
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_result_try(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [result_expr, fn_expr] ->
      eval_k(result_expr, e, ctx, gas, fn(result_val, g1) {
        case result_val {
          value.OkVal(inner) ->
            eval_k(fn_expr, e, ctx, g1, fn(fn_val, g2) {
              apply_value(fn_val, [inner], ctx, g2, k)
            })
          error_val -> k(error_val, g1)
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch("result.try", 2, list.length(args)))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: result.map
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_result_map(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [result_expr, fn_expr] ->
      eval_k(result_expr, e, ctx, gas, fn(result_val, g1) {
        case result_val {
          value.OkVal(inner) ->
            eval_k(fn_expr, e, ctx, g1, fn(fn_val, g2) {
              apply_value(fn_val, [inner], ctx, g2, fn(mapped, g3) {
                k(value.OkVal(mapped), g3)
              })
            })
          error_val -> k(error_val, g1)
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch("result.map", 2, list.length(args)))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: result.is_ok / result.is_error
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_result_is_ok(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [result_expr] ->
      eval_k(result_expr, e, ctx, gas, fn(result_val, g) {
        case result_val {
          value.OkVal(_) -> k(value.BoolVal(True), g)
          _ -> k(value.BoolVal(False), g)
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch("result.is_ok", 1, list.length(args)))
  }
}

fn stdlib_result_is_error(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [result_expr] ->
      eval_k(result_expr, e, ctx, gas, fn(result_val, g) {
        case result_val {
          value.ErrorVal(_) -> k(value.BoolVal(True), g)
          _ -> k(value.BoolVal(False), g)
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch(
        "result.is_error",
        1,
        list.length(args),
      ))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: option.map
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_option_map(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [opt_expr, fn_expr] ->
      eval_k(opt_expr, e, ctx, gas, fn(opt_val, g1) {
        case opt_val {
          value.SomeVal(inner) ->
            eval_k(fn_expr, e, ctx, g1, fn(fn_val, g2) {
              apply_value(fn_val, [inner], ctx, g2, fn(mapped, g3) {
                k(value.SomeVal(mapped), g3)
              })
            })
          value.NoneVal -> k(value.NoneVal, g1)
          _ ->
            effect.EvalError(value.TypeMismatch(
              "Option",
              value.type_name(opt_val),
            ))
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch("option.map", 2, list.length(args)))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: string.length
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_string_length(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [s_expr] ->
      eval_k(s_expr, e, ctx, gas, fn(s_val, g) {
        case s_val {
          value.StringVal(s) -> k(value.IntVal(string.length(s)), g)
          _ ->
            effect.EvalError(value.TypeMismatch(
              "String",
              value.type_name(s_val),
            ))
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch(
        "string.length",
        1,
        list.length(args),
      ))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: string.concat
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_string_concat(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [a_expr, b_expr] ->
      eval_k(a_expr, e, ctx, gas, fn(a_val, g1) {
        eval_k(b_expr, e, ctx, g1, fn(b_val, g2) {
          case a_val, b_val {
            value.StringVal(a), value.StringVal(b) ->
              k(value.StringVal(a <> b), g2)
            value.StringVal(_), _ ->
              effect.EvalError(value.TypeMismatch(
                "String",
                value.type_name(b_val),
              ))
            _, _ ->
              effect.EvalError(value.TypeMismatch(
                "String",
                value.type_name(a_val),
              ))
          }
        })
      })
    _ ->
      effect.EvalError(value.ArityMismatch(
        "string.concat",
        2,
        list.length(args),
      ))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stdlib: task.dispatch_all
// ═══════════════════════════════════════════════════════════════════════════

fn stdlib_task_dispatch_all(
  args: List(ast.Expr),
  e: env.Env,
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case args {
    [thunks_expr] ->
      eval_k(thunks_expr, e, ctx, gas, fn(thunks_val, g) {
        case thunks_val {
          value.ListVal(thunks) -> dispatch_all_loop(thunks, ctx, g, k)
          _ ->
            effect.EvalError(value.TypeMismatch(
              "List",
              value.type_name(thunks_val),
            ))
        }
      })
    _ ->
      effect.EvalError(value.ArityMismatch(
        "task.dispatch_all",
        1,
        list.length(args),
      ))
  }
}

fn dispatch_all_loop(
  thunks: List(value.Value),
  ctx: EvalContext,
  gas: Int,
  k: fn(value.Value, Int) -> effect.EvalResult,
) -> effect.EvalResult {
  case thunks {
    [] -> k(value.OkVal(value.NilVal), gas)
    [thunk, ..rest] ->
      apply_value(thunk, [], ctx, gas, fn(result, g) {
        case result {
          value.ErrorVal(_) -> k(result, g)
          _ -> dispatch_all_loop(rest, ctx, g, k)
        }
      })
  }
}
