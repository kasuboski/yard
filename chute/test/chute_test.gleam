import chute
import chute/ast
import gleam/option
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── End-to-end tests: source string → AST via chute.parse ─────────────────

// The "juicy main" example from the language spec
pub fn full_charge_card_program_test() {
  let source =
    "
// 1. Verbs (Declared Capabilities)
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

// 2. Nouns (Standardized Entrypoint)
pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {

    // 3. Linear compute + ROP Pipeline
    env.order_total
    |> perform charge_card()
}
"
  let assert Ok(ast.Program(declarations)) = chute.parse(source)
  let assert [
    ast.EffectDecl("charge_card", _, _),
    ast.EffectDecl("send_receipt", _, _),
    ast.FunctionDecl("main", True, _, _, _),
  ] = declarations
}

// Concurrent task dispatch example from the spec
pub fn task_dispatch_program_test() {
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
  let assert Ok(ast.Program(declarations)) = chute.parse(source)
  let assert [
    ast.EffectDecl("do_a", _, _),
    ast.EffectDecl("do_b", _, _),
    ast.FunctionDecl("main", True, _, _, _),
  ] = declarations
}

// Minimal program: single fn returning a literal
pub fn minimal_program_test() {
  let source = "pub fn main(env: {}) -> Int { 42 }"
  let assert Ok(ast.Program([ast.FunctionDecl("main", True, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.Some(ast.ExprInt(42))) = body
}

// Multiple functions with shadowing
pub fn multiple_functions_with_shadowing_test() {
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
  let assert Ok(ast.Program(declarations)) = chute.parse(source)
  let assert [
    ast.FunctionDecl("helper", False, _, _, _),
    ast.FunctionDecl("main", True, _, _, _),
  ] = declarations
}

// Complex nested expressions
pub fn complex_expressions_test() {
  let source =
    "
pub fn compute(env: { a: Int, b: Int, c: Int }) -> Int {
    let sum = env.a + env.b * env.c
    let is_valid = sum > 10
    is_valid
}
"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  // sum = a + (b * c)
  let assert ast.Block(
    [
      ast.LetDecl("sum", option.None, sum_expr),
      ast.LetDecl("is_valid", option.None, cmp_expr),
    ],
    option.Some(ast.ExprVar("is_valid")),
  ) = body

  let assert ast.ExprBinaryOp(
    ast.ExprFieldAccess(ast.ExprVar("env"), "a"),
    ast.OpAdd,
    ast.ExprBinaryOp(
      ast.ExprFieldAccess(ast.ExprVar("env"), "b"),
      ast.OpMul,
      ast.ExprFieldAccess(ast.ExprVar("env"), "c"),
    ),
  ) = sum_expr

  let assert ast.ExprBinaryOp(ast.ExprVar("sum"), ast.OpGt, ast.ExprInt(10)) =
    cmp_expr
}

// Record literal construction and field access
pub fn record_construction_test() {
  let source =
    "
pub fn main(env: {}) -> { x: Int, y: Int } {
    let point = { x: 1, y: 2 }
    point
}
"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block(
    [ast.LetDecl("point", option.None, record_expr)],
    option.Some(ast.ExprVar("point")),
  ) = body
  let assert ast.ExprRecord([
    ast.RecordField("x", ast.ExprInt(1)),
    ast.RecordField("y", ast.ExprInt(2)),
  ]) = record_expr
}

// Chained pipelines
pub fn chained_pipeline_test() {
  let source =
    "
fn double(x: Int) -> Int { x }

pub fn main(env: {}) -> Int {
    env.x
    |> double()
    |> double()
}
"
  let assert Ok(ast.Program([_, ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  // double(double(env.x)) after desugaring
  let assert ast.Block(
    [],
    option.Some(ast.ExprCall(
      ast.ExprVar("double"),
      [
        ast.ExprCall(
          ast.ExprVar("double"),
          [ast.ExprFieldAccess(ast.ExprVar("env"), "x")],
        ),
      ],
    )),
  ) = body
}

// Closure passed as argument (using simpler types since fn types in annotations aren't yet supported)
pub fn closure_as_arg_test() {
  let source =
    "
pub fn main(env: {}) -> Int {
    let add_one = fn(n) { n + 1 }
    add_one(5)
}
"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block(
    [
      ast.LetDecl(
        "add_one",
        option.None,
        ast.ExprClosure(
          ["n"],
          ast.Block(
            [],
            option.Some(ast.ExprBinaryOp(
              ast.ExprVar("n"),
              ast.OpAdd,
              ast.ExprInt(1),
            )),
          ),
        ),
      ),
    ],
    option.Some(ast.ExprCall(ast.ExprVar("add_one"), [ast.ExprInt(5)])),
  ) = body
}

// Empty block returns Nil
pub fn empty_block_returns_nil_test() {
  let source = "pub fn main(env: {}) -> Nil { }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.None) = body
}

// Error: unterminated string
pub fn error_unterminated_string_test() {
  let assert Error("Unterminated string literal") =
    chute.parse("fn f() -> String { \"hello }")
}

// Error: unexpected token
pub fn error_unexpected_token_test() {
  let result = chute.parse("fn f() -> Int { ??? }")
  let assert Error(_) = result
}

// String with interpolation
pub fn string_interpolation_test() {
  let source =
    "pub fn main(env: { name: String }) -> String { \"Hello ${env.name}\" }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.Some(ast.ExprString(parts))) = body
  let assert [
    ast.StringText("Hello "),
    ast.StringInterpolation(ast.ExprFieldAccess(ast.ExprVar("env"), "name")),
  ] = parts
}

// Comparison operators
pub fn comparison_operators_test() {
  let source = "pub fn main(env: { x: Int }) -> Bool { env.x != 0 }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block(
    [],
    option.Some(ast.ExprBinaryOp(
      ast.ExprFieldAccess(ast.ExprVar("env"), "x"),
      ast.OpNeq,
      ast.ExprInt(0),
    )),
  ) = body
}

// Result type with chained constructors
pub fn result_type_test() {
  let source =
    "
pub fn main(env: {}) -> Result(Int, Error) {
    Ok(42)
}
"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, return_type, body)])) =
    chute.parse(source)
  let assert ast.TypeNamed(
    "Result",
    [ast.TypeNamed("Int", []), ast.TypeNamed("Error", [])],
  ) = return_type
  let assert ast.Block(
    [],
    option.Some(ast.ExprCall(ast.ExprVar("Ok"), [ast.ExprInt(42)])),
  ) = body
}

// ── Function types in type position ────────────────────────────────────────

pub fn fn_type_simple_test() {
  let source = "fn apply(f: fn(Int) -> Int, x: Int) -> Int { x }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, params, _, _)])) =
    chute.parse(source)
  let assert [ast.Param("f", fn_type), ast.Param("x", ast.TypeNamed("Int", []))] =
    params
  let assert ast.TypeFn([ast.TypeNamed("Int", [])], ast.TypeNamed("Int", [])) =
    fn_type
}

pub fn fn_type_multi_param_test() {
  let source = "fn map(f: fn(String, Int) -> Bool) -> Nil { Nil }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, params, _, _)])) =
    chute.parse(source)
  let assert [ast.Param("f", fn_type)] = params
  let assert ast.TypeFn(
    [ast.TypeNamed("String", []), ast.TypeNamed("Int", [])],
    ast.TypeNamed("Bool", []),
  ) = fn_type
}

pub fn fn_type_nested_test() {
  let source = "fn compose(f: fn(fn(Int) -> Int) -> Bool) -> Nil { Nil }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, params, _, _)])) =
    chute.parse(source)
  let assert [ast.Param("f", fn_type)] = params
  let assert ast.TypeFn(
    [ast.TypeFn([ast.TypeNamed("Int", [])], ast.TypeNamed("Int", []))],
    ast.TypeNamed("Bool", []),
  ) = fn_type
}

pub fn fn_type_in_effect_test() {
  let source =
    "effect task_dispatch_all(intents: List(fn() -> Result(Nil, Error))) -> Result(List(Nil), Error)"
  let assert Ok(ast.Program([ast.EffectDecl(_, params, return_type)])) =
    chute.parse(source)
  let assert [ast.Param("intents", list_type)] = params
  let assert ast.TypeNamed(
    "List",
    [
      ast.TypeFn(
        [],
        ast.TypeNamed(
          "Result",
          [ast.TypeNamed("Nil", []), ast.TypeNamed("Error", [])],
        ),
      ),
    ],
  ) = list_type
  let assert ast.TypeNamed(
    "Result",
    [
      ast.TypeNamed("List", [ast.TypeNamed("Nil", [])]),
      ast.TypeNamed("Error", []),
    ],
  ) = return_type
}

pub fn fn_type_as_return_test() {
  let source = "fn make_adder(x: Int) -> fn(Int) -> Int { fn(n) { n } }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, return_type, _)])) =
    chute.parse(source)
  let assert ast.TypeFn([ast.TypeNamed("Int", [])], ast.TypeNamed("Int", [])) =
    return_type
}

// ── String interpolation with expressions ──────────────────────────────────

pub fn string_interpolation_with_field_access_test() {
  let source =
    "pub fn main(env: { name: String }) -> String { \"Hello ${env.name}\" }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.Some(ast.ExprString(parts))) = body
  let assert [
    ast.StringText("Hello "),
    ast.StringInterpolation(ast.ExprFieldAccess(ast.ExprVar("env"), "name")),
  ] = parts
}

pub fn string_interpolation_with_expression_test() {
  let source =
    "pub fn main(env: { x: Int, y: Int }) -> String { \"Sum: ${x + y}\" }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.Some(ast.ExprString(parts))) = body
  // The interpolation should parse x + y as a binary expression
  let assert [
    ast.StringText("Sum: "),
    ast.StringInterpolation(ast.ExprBinaryOp(
      ast.ExprVar("x"),
      ast.OpAdd,
      ast.ExprVar("y"),
    )),
  ] = parts
}

pub fn string_interpolation_with_call_test() {
  let source =
    "pub fn main(env: { name: String }) -> String { \"Hello ${string.upper(name)}\" }"
  let assert Ok(ast.Program([ast.FunctionDecl(_, _, _, _, body)])) =
    chute.parse(source)
  let assert ast.Block([], option.Some(ast.ExprString(parts))) = body
  let assert [
    ast.StringText("Hello "),
    ast.StringInterpolation(ast.ExprCall(
      ast.ExprFieldAccess(ast.ExprVar("string"), "upper"),
      [ast.ExprVar("name")],
    )),
  ] = parts
}

// Full task_dispatch program now works with fn types
pub fn full_task_dispatch_program_test() {
  let source =
    "
effect do_a() -> Result(Nil, Error)
effect do_b() -> Result(Nil, Error)
effect task_dispatch_all(intents: List(fn() -> Result(Nil, Error))) -> Result(List(Nil), Error)

pub fn main(env: { trigger: String }) -> Result(Nil, Error) {
    let intents = [
        fn() { perform do_a() },
        fn() { perform do_b() }
    ]
    perform task_dispatch_all(intents)
}
"
  let assert Ok(ast.Program(declarations)) = chute.parse(source)
  let assert [
    ast.EffectDecl("do_a", _, _),
    ast.EffectDecl("do_b", _, _),
    ast.EffectDecl("task_dispatch_all", _, _),
    ast.FunctionDecl("main", True, _, _, _),
  ] = declarations
}
