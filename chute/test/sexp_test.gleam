import chute/ast
import chute/sexp
import gleam/option
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Simple program ─────────────────────────────────────────────────────────

pub fn minimal_program_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "main",
        True,
        [ast.Param("env", ast.TypeRecord([]))],
        ast.TypeNamed("Int", []),
        ast.Block([], option.Some(ast.ExprInt(42))),
      ),
    ])
  let result = sexp.to_sexp(program)
  let assert True =
    result == "(program\n(fn pub main ((env (Record))) Int (block (int 42))))"
}

// ── Expressions via full program ───────────────────────────────────────────

pub fn var_expr_test() {
  let result = expr_sexp(ast.ExprVar("x"))
  let assert True = result == "(var x)"
}

pub fn int_expr_test() {
  let result = expr_sexp(ast.ExprInt(42))
  let assert True = result == "(int 42)"
}

pub fn float_expr_test() {
  let result = expr_sexp(ast.ExprFloat(3.14))
  let assert True = result == "(float 3.14)"
}

pub fn bool_true_test() {
  let result = expr_sexp(ast.ExprBool(True))
  let assert True = result == "(bool true)"
}

pub fn bool_false_test() {
  let result = expr_sexp(ast.ExprBool(False))
  let assert True = result == "(bool false)"
}

pub fn nil_expr_test() {
  let result = expr_sexp(ast.ExprNil)
  let assert True = result == "(nil)"
}

pub fn string_literal_test() {
  let result = expr_sexp(ast.ExprString([ast.StringText("hello")]))
  let assert True = result == "(string \"hello\")"
}

pub fn string_empty_test() {
  let result = expr_sexp(ast.ExprString([]))
  let assert True = result == "(string \"\")"
}

pub fn string_with_escape_test() {
  let result = expr_sexp(ast.ExprString([ast.StringText("line1\nline2")]))
  let assert True = result == "(string \"line1\\nline2\")"
}

pub fn string_with_interpolation_test() {
  let expr =
    ast.ExprString([
      ast.StringText("Hello "),
      ast.StringInterpolation(ast.ExprVar("name")),
    ])
  let result = expr_sexp(expr)
  let assert True = result == "(string \"Hello \" (interp (var name)))"
}

pub fn call_expr_test() {
  let expr =
    ast.ExprCall(ast.ExprVar("f"), [
      ast.ExprVar("x"),
      ast.ExprInt(1),
    ])
  let result = expr_sexp(expr)
  let assert True = result == "(call (var f) (var x) (int 1))"
}

pub fn call_no_args_test() {
  let result = expr_sexp(ast.ExprCall(ast.ExprVar("f"), []))
  let assert True = result == "(call (var f))"
}

pub fn field_access_test() {
  let result = expr_sexp(ast.ExprFieldAccess(ast.ExprVar("env"), "name"))
  let assert True = result == "(field-access (var env) name)"
}

pub fn perform_expr_test() {
  let result =
    expr_sexp(ast.ExprPerform("charge_card", [ast.ExprVar("amount")]))
  let assert True = result == "(perform charge_card (var amount))"
}

pub fn perform_no_args_test() {
  let result = expr_sexp(ast.ExprPerform("do_thing", []))
  let assert True = result == "(perform do_thing)"
}

pub fn binop_add_test() {
  let result =
    expr_sexp(ast.ExprBinaryOp(ast.ExprVar("x"), ast.OpAdd, ast.ExprInt(1)))
  let assert True = result == "(binop + (var x) (int 1))"
}

pub fn binop_eq_test() {
  let result =
    expr_sexp(ast.ExprBinaryOp(ast.ExprVar("x"), ast.OpEq, ast.ExprInt(0)))
  let assert True = result == "(binop == (var x) (int 0))"
}

pub fn binop_mul_test() {
  let result =
    expr_sexp(ast.ExprBinaryOp(ast.ExprVar("a"), ast.OpMul, ast.ExprVar("b")))
  let assert True = result == "(binop * (var a) (var b))"
}

pub fn record_literal_test() {
  let result =
    expr_sexp(
      ast.ExprRecord([
        ast.RecordField("x", ast.ExprInt(1)),
        ast.RecordField("y", ast.ExprInt(2)),
      ]),
    )
  let assert True = result == "(record (x (int 1)) (y (int 2)))"
}

pub fn empty_record_test() {
  let result = expr_sexp(ast.ExprRecord([]))
  let assert True = result == "(record)"
}

pub fn list_literal_test() {
  let result =
    expr_sexp(ast.ExprList([ast.ExprInt(1), ast.ExprInt(2), ast.ExprInt(3)]))
  let assert True = result == "(list (int 1) (int 2) (int 3))"
}

pub fn empty_list_test() {
  let result = expr_sexp(ast.ExprList([]))
  let assert True = result == "(list)"
}

pub fn closure_test() {
  let result =
    expr_sexp(ast.ExprClosure(
      ["x", "y"],
      ast.Block(
        [],
        option.Some(ast.ExprBinaryOp(
          ast.ExprVar("x"),
          ast.OpAdd,
          ast.ExprVar("y"),
        )),
      ),
    ))
  let assert True =
    result == "(closure (x y) (block (binop + (var x) (var y))))"
}

pub fn closure_no_params_test() {
  let result =
    expr_sexp(ast.ExprClosure([], ast.Block([], option.Some(ast.ExprNil))))
  let assert True = result == "(closure () (block (nil)))"
}

// ── Blocks & Statements ───────────────────────────────────────────────────

pub fn block_with_let_and_trailing_test() {
  let block =
    ast.Block(
      [ast.LetDecl("x", option.None, ast.ExprInt(42))],
      option.Some(ast.ExprVar("x")),
    )
  let result = block_sexp(block)
  let assert True = result == "(block (let x (int 42)) (var x))"
}

pub fn block_with_typed_let_test() {
  let block =
    ast.Block(
      [
        ast.LetDecl("x", option.Some(ast.TypeNamed("Int", [])), ast.ExprInt(42)),
      ],
      option.Some(ast.ExprVar("x")),
    )
  let result = block_sexp(block)
  let assert True = result == "(block (let x Int (int 42)) (var x))"
}

pub fn block_empty_test() {
  let result = block_sexp(ast.Block([], option.None))
  let assert True = result == "(block)"
}

// ── Types ──────────────────────────────────────────────────────────────────

pub fn type_named_simple_test() {
  let result = type_sexp(ast.TypeNamed("Int", []))
  let assert True = result == "Int"
}

pub fn type_named_parameterized_test() {
  let t =
    ast.TypeNamed("Result", [
      ast.TypeNamed("String", []),
      ast.TypeNamed("Error", []),
    ])
  let result = type_sexp(t)
  let assert True = result == "(Result String Error)"
}

pub fn type_nested_parameterized_test() {
  let t =
    ast.TypeNamed("List", [
      ast.TypeNamed("Result", [
        ast.TypeNamed("Int", []),
        ast.TypeNamed("Error", []),
      ]),
    ])
  let result = type_sexp(t)
  let assert True = result == "(List (Result Int Error))"
}

pub fn type_record_test() {
  let t =
    ast.TypeRecord([
      ast.TypeField("name", ast.TypeNamed("String", [])),
      ast.TypeField("age", ast.TypeNamed("Int", [])),
    ])
  let result = type_sexp(t)
  let assert True = result == "(Record (name String) (age Int))"
}

pub fn type_fn_test() {
  let t =
    ast.TypeFn(
      [ast.TypeNamed("Int", []), ast.TypeNamed("String", [])],
      ast.TypeNamed("Bool", []),
    )
  let result = type_sexp(t)
  let assert True = result == "(Fn (Int String) Bool)"
}

// ── Full program from spec ─────────────────────────────────────────────────

pub fn full_charge_card_program_test() {
  let program =
    ast.Program([
      ast.EffectDecl(
        "charge_card",
        [ast.Param("amount", ast.TypeNamed("Float", []))],
        ast.TypeNamed("Result", [
          ast.TypeNamed("String", []),
          ast.TypeNamed("Error", []),
        ]),
      ),
      ast.EffectDecl(
        "send_receipt",
        [
          ast.Param("user_id", ast.TypeNamed("String", [])),
          ast.Param("tx_id", ast.TypeNamed("String", [])),
        ],
        ast.TypeNamed("Result", [
          ast.TypeNamed("Nil", []),
          ast.TypeNamed("Error", []),
        ]),
      ),
      ast.FunctionDecl(
        "main",
        True,
        [
          ast.Param(
            "env",
            ast.TypeRecord([
              ast.TypeField("user_id", ast.TypeNamed("String", [])),
              ast.TypeField("order_total", ast.TypeNamed("Float", [])),
            ]),
          ),
        ],
        ast.TypeNamed("Result", [
          ast.TypeNamed("String", []),
          ast.TypeNamed("Error", []),
        ]),
        ast.Block(
          [],
          option.Some(
            ast.ExprCall(ast.ExprVar("charge_card"), [
              ast.ExprFieldAccess(ast.ExprVar("env"), "order_total"),
            ]),
          ),
        ),
      ),
    ])
  let sexp = sexp.to_sexp(program)
  let assert True = string.starts_with(sexp, "(program\n")
  let assert True =
    string.contains(
      sexp,
      "(effect charge_card ((amount Float)) (Result String Error))",
    )
  let assert True =
    string.contains(
      sexp,
      "(effect send_receipt ((user_id String) (tx_id String)) (Result Nil Error))",
    )
  let assert True = string.contains(sexp, "(fn pub main")
  let assert True =
    string.contains(
      sexp,
      "(call (var charge_card) (field-access (var env) order_total))",
    )
}

// ── Pipeline desugared output ──────────────────────────────────────────────

pub fn pipeline_becomes_nested_calls_test() {
  let expr =
    ast.ExprCall(ast.ExprVar("double"), [
      ast.ExprCall(ast.ExprVar("double"), [
        ast.ExprFieldAccess(ast.ExprVar("env"), "x"),
      ]),
    ])
  let result = expr_sexp(expr)
  let assert True =
    result
    == "(call (var double) (call (var double) (field-access (var env) x)))"
}

// ── All binary operators ──────────────────────────────────────────────────

pub fn all_binop_symbols_test() {
  let assert "(binop == (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpEq, ast.ExprInt(2)))
  let assert "(binop != (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpNeq, ast.ExprInt(2)))
  let assert "(binop < (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpLt, ast.ExprInt(2)))
  let assert "(binop <= (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpLe, ast.ExprInt(2)))
  let assert "(binop > (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpGt, ast.ExprInt(2)))
  let assert "(binop >= (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpGe, ast.ExprInt(2)))
  let assert "(binop + (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpAdd, ast.ExprInt(2)))
  let assert "(binop - (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpSub, ast.ExprInt(2)))
  let assert "(binop * (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpMul, ast.ExprInt(2)))
  let assert "(binop / (int 1) (int 2))" =
    expr_sexp(ast.ExprBinaryOp(ast.ExprInt(1), ast.OpDiv, ast.ExprInt(2)))
}

// ── Non-public function ───────────────────────────────────────────────────

pub fn private_function_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "helper",
        False,
        [ast.Param("x", ast.TypeNamed("Int", []))],
        ast.TypeNamed("Int", []),
        ast.Block([], option.Some(ast.ExprVar("x"))),
      ),
    ])
  let result = sexp.to_sexp(program)
  let assert True = string.contains(result, "(fn helper")
  let assert False = string.contains(result, "pub helper")
}

// ── Helpers: wrap expressions/types in a minimal program ──────────────────
// We create a program with a single function, then extract the relevant
// S-expression fragment. The full output is always:
//   (program\n(fn _ () TYPE (block EXPR)))
// After the "(block " prefix, the rest is EXPR + ")))" (block close, fn close, program close).
// So we split on "(block " and drop the last 3 characters from the remainder.

fn expr_sexp(expr: ast.Expr) -> String {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "_",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block([], option.Some(expr)),
      ),
    ])
  let sexp = sexp.to_sexp(program)
  let assert Ok(#(_, after_block)) = string.split_once(sexp, on: "(block ")
  // after_block = "EXPR)))" — drop the trailing ")))"
  string.drop_end(after_block, up_to: 3)
}

fn block_sexp(block: ast.Block) -> String {
  let program =
    ast.Program([
      ast.FunctionDecl("_", False, [], ast.TypeNamed("Nil", []), block),
    ])
  let sexp = sexp.to_sexp(program)
  // Split on " Nil " to get past the type, then drop trailing "))"
  let assert Ok(#(_, after_type)) = string.split_once(sexp, on: " Nil ")
  // after_type = "BLOCK))" — drop trailing "))" (fn close + program close)
  string.drop_end(after_type, up_to: 2)
}

fn type_sexp(t: ast.Type) -> String {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "_",
        False,
        [],
        t,
        ast.Block([], option.Some(ast.ExprNil)),
      ),
    ])
  let sexp = sexp.to_sexp(program)
  // sexp = "(program\n(fn _ () TYPE (block (nil))))"
  let assert Ok(#(_, after_params)) = string.split_once(sexp, on: "(fn _ () ")
  let assert Ok(#(type_str, _)) = string.split_once(after_params, on: " (block")
  type_str
}
