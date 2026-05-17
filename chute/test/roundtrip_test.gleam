import chute
import chute/ast
import chute/sexp_parse
import gleam/option
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Round-trip: source → parse → desugar → sexp → parse_sexp → AST equal ──

fn roundtrip(source: String) -> ast.Program {
  let assert Ok(program) = chute.parse(source)
  let desugared = chute.desugar(program)
  let sexp = chute.to_sexp(desugared)
  let assert Ok(reparsed) = sexp_parse.from_sexp(sexp)
  reparsed
}

// ── AST structural equality ────────────────────────────────────────────────

fn program_equal(a: ast.Program, b: ast.Program) -> Bool {
  let ast.Program(a_decls) = a
  let ast.Program(b_decls) = b
  list_equal(a_decls, b_decls, decl_equal)
}

fn decl_equal(a: ast.Declaration, b: ast.Declaration) -> Bool {
  case a, b {
    ast.EffectDecl(a_name, a_params, a_ret),
      ast.EffectDecl(b_name, b_params, b_ret)
    ->
      a_name == b_name
      && list_equal(a_params, b_params, param_equal)
      && type_equal(a_ret, b_ret)

    ast.FunctionDecl(a_name, a_pub, a_params, a_ret, a_body),
      ast.FunctionDecl(b_name, b_pub, b_params, b_ret, b_body)
    ->
      a_name == b_name
      && a_pub == b_pub
      && list_equal(a_params, b_params, param_equal)
      && type_equal(a_ret, b_ret)
      && block_equal(a_body, b_body)

    _, _ -> False
  }
}

fn param_equal(a: ast.Param, b: ast.Param) -> Bool {
  let ast.Param(a_name, a_type) = a
  let ast.Param(b_name, b_type) = b
  a_name == b_name && type_equal(a_type, b_type)
}

fn type_equal(a: ast.Type, b: ast.Type) -> Bool {
  case a, b {
    ast.TypeNamed(a_name, a_args), ast.TypeNamed(b_name, b_args) ->
      a_name == b_name && list_equal(a_args, b_args, type_equal)
    ast.TypeRecord(a_fields), ast.TypeRecord(b_fields) ->
      list_equal(a_fields, b_fields, type_field_equal)
    ast.TypeFn(a_params, a_ret), ast.TypeFn(b_params, b_ret) ->
      list_equal(a_params, b_params, type_equal) && type_equal(a_ret, b_ret)
    _, _ -> False
  }
}

fn type_field_equal(a: ast.TypeField, b: ast.TypeField) -> Bool {
  let ast.TypeField(a_name, a_type) = a
  let ast.TypeField(b_name, b_type) = b
  a_name == b_name && type_equal(a_type, b_type)
}

fn block_equal(a: ast.Block, b: ast.Block) -> Bool {
  let ast.Block(a_stmts, a_trail) = a
  let ast.Block(b_stmts, b_trail) = b
  list_equal(a_stmts, b_stmts, stmt_equal)
  && opt_equal(a_trail, b_trail, expr_equal)
}

fn stmt_equal(a: ast.Statement, b: ast.Statement) -> Bool {
  case a, b {
    ast.LetDecl(a_name, a_type, a_val), ast.LetDecl(b_name, b_type, b_val) ->
      a_name == b_name
      && opt_equal(a_type, b_type, type_equal)
      && expr_equal(a_val, b_val)
    ast.LetTryDecl(a_name, a_type, a_val), ast.LetTryDecl(b_name, b_type, b_val)
    ->
      a_name == b_name
      && opt_equal(a_type, b_type, type_equal)
      && expr_equal(a_val, b_val)
    ast.StatementExpr(a_e), ast.StatementExpr(b_e) -> expr_equal(a_e, b_e)
    _, _ -> False
  }
}

fn expr_equal(a: ast.Expr, b: ast.Expr) -> Bool {
  case a, b {
    ast.ExprVar(a_n), ast.ExprVar(b_n) -> a_n == b_n
    ast.ExprInt(a_v), ast.ExprInt(b_v) -> a_v == b_v
    ast.ExprFloat(a_v), ast.ExprFloat(b_v) -> a_v == b_v
    ast.ExprBool(a_v), ast.ExprBool(b_v) -> a_v == b_v
    ast.ExprNil, ast.ExprNil -> True
    ast.ExprString(a_p), ast.ExprString(b_p) ->
      list_equal(a_p, b_p, string_part_equal)
    ast.ExprRecord(a_f), ast.ExprRecord(b_f) ->
      list_equal(a_f, b_f, record_field_equal)
    ast.ExprList(a_e), ast.ExprList(b_e) -> list_equal(a_e, b_e, expr_equal)
    ast.ExprCall(a_f, a_a), ast.ExprCall(b_f, b_a) ->
      expr_equal(a_f, b_f) && list_equal(a_a, b_a, expr_equal)
    ast.ExprFieldAccess(a_r, a_field), ast.ExprFieldAccess(b_r, b_field) ->
      expr_equal(a_r, b_r) && a_field == b_field
    ast.ExprPerform(a_n, a_a), ast.ExprPerform(b_n, b_a) ->
      a_n == b_n && list_equal(a_a, b_a, expr_equal)
    ast.ExprBinaryOp(a_l, a_op, a_r), ast.ExprBinaryOp(b_l, b_op, b_r) ->
      binop_equal(a_op, b_op) && expr_equal(a_l, b_l) && expr_equal(a_r, b_r)
    ast.ExprClosure(a_p, a_b), ast.ExprClosure(b_p, b_b) ->
      a_p == b_p && block_equal(a_b, b_b)
    ast.ExprPipeline(a_l, a_r), ast.ExprPipeline(b_l, b_r) ->
      expr_equal(a_l, b_l) && expr_equal(a_r, b_r)
    ast.ExprCase(a_s, a_br), ast.ExprCase(b_s, b_br) ->
      expr_equal(a_s, b_s) && list_equal(a_br, b_br, case_branch_equal)
    _, _ -> False
  }
}

fn binop_equal(a: ast.BinOp, b: ast.BinOp) -> Bool {
  case a, b {
    ast.OpEq, ast.OpEq -> True
    ast.OpNeq, ast.OpNeq -> True
    ast.OpLt, ast.OpLt -> True
    ast.OpLe, ast.OpLe -> True
    ast.OpGt, ast.OpGt -> True
    ast.OpGe, ast.OpGe -> True
    ast.OpAdd, ast.OpAdd -> True
    ast.OpSub, ast.OpSub -> True
    ast.OpMul, ast.OpMul -> True
    ast.OpDiv, ast.OpDiv -> True
    _, _ -> False
  }
}

fn string_part_equal(a: ast.StringPart, b: ast.StringPart) -> Bool {
  case a, b {
    ast.StringText(a_t), ast.StringText(b_t) -> a_t == b_t
    ast.StringInterpolation(a_e), ast.StringInterpolation(b_e) ->
      expr_equal(a_e, b_e)
    _, _ -> False
  }
}

fn record_field_equal(a: ast.RecordField, b: ast.RecordField) -> Bool {
  let ast.RecordField(a_n, a_v) = a
  let ast.RecordField(b_n, b_v) = b
  a_n == b_n && expr_equal(a_v, b_v)
}

fn case_branch_equal(a: ast.CaseBranch, b: ast.CaseBranch) -> Bool {
  case a, b {
    ast.CaseBranch(a_p, a_b), ast.CaseBranch(b_p, b_b) ->
      expr_equal(a_p, b_p) && block_equal(a_b, b_b)
    ast.CaseWildcard(a_b), ast.CaseWildcard(b_b) -> block_equal(a_b, b_b)
    _, _ -> False
  }
}

fn opt_equal(
  a: option.Option(a),
  b: option.Option(b),
  eq: fn(a, b) -> Bool,
) -> Bool {
  case a, b {
    option.None, option.None -> True
    option.Some(a_val), option.Some(b_val) -> eq(a_val, b_val)
    _, _ -> False
  }
}

fn list_equal(a: List(a), b: List(b), eq: fn(a, b) -> Bool) -> Bool {
  case a, b {
    [], [] -> True
    [a_head, ..a_tail], [b_head, ..b_tail] ->
      eq(a_head, b_head) && list_equal(a_tail, b_tail, eq)
    _, _ -> False
  }
}

// ── Round-trip tests ───────────────────────────────────────────────────────

pub fn roundtrip_minimal_test() {
  let source = "pub fn main(env: {}) -> Int { 42 }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_charge_card_test() {
  let source =
    "
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    env.order_total
    |> perform charge_card()
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_multiple_functions_test() {
  let source =
    "
fn helper(x: Int) -> Int {
    let x = x + 1
    x
}

pub fn main(env: {}) -> Int {
    let result = helper(5)
    result
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_record_and_list_test() {
  let source =
    "
pub fn main(env: {}) -> Nil {
    let point = { x: 1, y: 2 }
    let items = [1, 2, 3]
    Nil
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_closure_test() {
  let source =
    "
pub fn main(env: {}) -> Int {
    let add_one = fn(n) { n + 1 }
    add_one(5)
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_string_interpolation_test() {
  let source =
    "pub fn main(env: { name: String }) -> String { \"Hello ${env.name}\" }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_comparison_ops_test() {
  let source =
    "
pub fn main(env: { x: Int }) -> Bool {
    let a = env.x > 0
    let b = env.x != 5
    let c = env.x <= 10
    a
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_task_dispatch_test() {
  let source =
    "
effect do_a() -> Result(Nil, Error)
effect do_b() -> Result(Nil, Error)

pub fn main(env: { trigger: String }) -> Result(Nil, Error) {
    let intents = [
        fn() { perform do_a() },
        fn() { perform do_b() }
    ]
    intents
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_complex_arithmetic_test() {
  let source =
    "
pub fn compute(env: { a: Int, b: Int, c: Int }) -> Int {
    env.a + env.b * env.c
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_empty_block_test() {
  let source = "pub fn main(env: {}) -> Nil { }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_typed_let_test() {
  let source =
    "
fn apply(f: fn(Int) -> Int, x: Int) -> Int {
    let y: Int = f(x)
    y
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_float_test() {
  let source = "pub fn main(env: {}) -> Float { 3.14 }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_bool_test() {
  let source =
    "
pub fn main(env: {}) -> Bool {
    let a = True
    let b = False
    a
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_fn_type_in_effect_test() {
  let source =
    "effect task_dispatch(intents: List(fn() -> Result(Nil, Error))) -> Result(List(Nil), Error)"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_string_with_escape_test() {
  let source =
    "pub fn main(env: {}) -> String { \"line1\\nline2\\t\\\"quoted\\\"\" }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_empty_record_type_test() {
  let source = "pub fn main(env: {}) -> Nil { Nil }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_all_binops_test() {
  let source =
    "
pub fn main(env: { a: Int, b: Int }) -> Bool {
    let _ = a == b
    let _ = a != b
    let _ = a < b
    let _ = a <= b
    let _ = a > b
    let _ = a >= b
    let _ = a + b
    let _ = a - b
    let _ = a * b
    let _ = a / b
    True
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_case_simple_test() {
  let source =
    "
pub fn main(env: { x: Int }) -> Int {
    case env.x { 1 -> 42  _ -> 0 }
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_case_with_block_test() {
  let source =
    "
pub fn main(env: { x: Int }) -> Int {
    case env.x {
        1 -> {
            let y = env.x + 10
            y
        }
        _ -> env.x
    }
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_case_string_pattern_test() {
  let source =
    "
pub fn main(env: { action: String }) -> Int {
    case env.action { \"refund\" -> 1  \"charge\" -> 2  _ -> 0 }
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_nested_fn_type_test() {
  let source = "fn compose(f: fn(fn(Int) -> Int) -> Bool) -> Nil { Nil }"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_let_try_test() {
  let source =
    "
pub fn main(env: {}) -> Result(Int, String) {
    let try x = Ok(42)
    Ok(x)
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

pub fn roundtrip_let_try_with_type_test() {
  let source =
    "
pub fn main(env: {}) -> Result(Int, String) {
    let try x: Int = Ok(42)
    Ok(x)
}
"
  let assert Ok(original) = chute.parse(source)
  let desugared = chute.desugar(original)
  let result = roundtrip(source)
  let assert True = program_equal(desugared, result)
}

// ── Direct sexp_parse error tests ──────────────────────────────────────────

pub fn parse_sexp_error_empty_test() {
  let assert Error(_) = sexp_parse.from_sexp("")
}

pub fn parse_sexp_error_unterminated_test() {
  let assert Error(_) = sexp_parse.from_sexp("(program")
}

pub fn parse_sexp_error_garbage_test() {
  let assert Error(_) = sexp_parse.from_sexp("not a program")
}
