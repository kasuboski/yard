import chute
import chute/ast
import gleam/option
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Full pipeline: source → parse → desugar → sexp ────────────────────────

pub fn compile_minimal_program_test() {
  let assert Ok(sexp) = chute.compile("pub fn main(env: {}) -> Int { 42 }")
  let assert True = string.contains(sexp, "(fn pub main")
  let assert True = string.contains(sexp, "(int 42)")
}

pub fn compile_charge_card_test() {
  let source =
    "
effect charge_card(amount: Float) -> Result(String, Error)

pub fn main(env: { order_total: Float }) -> Result(String, Error) {
    env.order_total
    |> perform charge_card()
}
"
  let assert Ok(sexp) = chute.compile(source)
  // Pipeline should be desugared: charge_card(env.order_total)
  let assert True =
    string.contains(
      sexp,
      "(perform charge_card (field-access (var env) order_total))",
    )
}

pub fn compile_multiple_effects_test() {
  let source =
    "
effect do_a() -> Result(Nil, Error)
effect do_b() -> Result(Nil, Error)

pub fn main(env: {}) -> Result(Nil, Error) {
    let _ = perform do_a()
    let _ = perform do_b()
    Ok(Nil)
}
"
  let assert Ok(sexp) = chute.compile(source)
  let assert True = string.contains(sexp, "(effect do_a ()")
  let assert True = string.contains(sexp, "(effect do_b ()")
  let assert True = string.contains(sexp, "(perform do_a)")
  let assert True = string.contains(sexp, "(perform do_b)")
  // Ok is a constructor call: Ok(Nil) -> (call (var Ok) (nil))
  let assert True = string.contains(sexp, "(call (var Ok)")
}

pub fn compile_string_interpolation_test() {
  let source =
    "pub fn main(env: { name: String }) -> String { \"Hello ${env.name}\" }"
  let assert Ok(sexp) = chute.compile(source)
  let assert True =
    string.contains(
      sexp,
      "(string \"Hello \" (interp (field-access (var env) name)))",
    )
}

pub fn compile_chained_pipeline_test() {
  let source =
    "
fn double(x: Int) -> Int { x }
pub fn main(env: { x: Int }) -> Int {
    env.x |> double() |> double()
}
"
  let assert Ok(sexp) = chute.compile(source)
  // double(double(env.x)) after desugaring
  let assert True =
    string.contains(
      sexp,
      "(call (var double) (call (var double) (field-access (var env) x)))",
    )
}

pub fn compile_record_and_list_test() {
  let source =
    "
pub fn main(env: {}) -> Nil {
    let point = { x: 1, y: 2 }
    let items = [1, 2, 3]
    Nil
}
"
  let assert Ok(sexp) = chute.compile(source)
  let assert True = string.contains(sexp, "(record (x (int 1)) (y (int 2)))")
  let assert True = string.contains(sexp, "(list (int 1) (int 2) (int 3))")
}

pub fn compile_closure_test() {
  let source =
    "
pub fn main(env: {}) -> Int {
    let add_one = fn(n) { n + 1 }
    add_one(5)
}
"
  let assert Ok(sexp) = chute.compile(source)
  let assert True =
    string.contains(sexp, "(closure (n) (block (binop + (var n) (int 1))))")
  let assert True = string.contains(sexp, "(call (var add_one) (int 5))")
}

pub fn compile_comparison_ops_test() {
  let source =
    "
pub fn main(env: { x: Int }) -> Bool {
    let a = env.x > 0
    let b = env.x != 5
    a
}
"
  let assert Ok(sexp) = chute.compile(source)
  let assert True =
    string.contains(sexp, "(binop > (field-access (var env) x) (int 0))")
  let assert True =
    string.contains(sexp, "(binop != (field-access (var env) x) (int 5))")
}

// ── Desugar via public API ─────────────────────────────────────────────────

pub fn desugar_unwraps_groups_test() {
  // The parser produces ExprGroup for (expr). Desugarer unwraps them.
  let source = "pub fn main(env: {}) -> Int { (42) }"
  let assert Ok(program) = chute.parse(source)
  let desugared = chute.desugar(program)
  // Check the AST directly — trailing should be ExprInt, not ExprGroup
  let assert ast.Program([
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprInt(42)))),
  ]) = desugared
}

pub fn desugar_normalizes_empty_block_test() {
  let source = "pub fn main(env: {}) -> Nil { }"
  let assert Ok(program) = chute.parse(source)
  let desugared = chute.desugar(program)
  // Empty block gets explicit Nil
  let assert ast.Program([
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprNil))),
  ]) = desugared
}

// ── Error cases ────────────────────────────────────────────────────────────

pub fn compile_error_unterminated_string_test() {
  let assert Error("Unterminated string literal") =
    chute.compile("fn f() -> String { \"hello }")
}

pub fn compile_error_syntax_test() {
  let assert Error(_) = chute.compile("???")
}

// ── Task dispatch program from spec ────────────────────────────────────────

pub fn compile_task_dispatch_test() {
  let source =
    "
effect do_a() -> Result(Nil, Error)
effect do_b() -> Result(Nil, Error)

pub fn main(env: { trigger: String }) -> List(fn() -> Result(Nil, Error)) {
    let intents = [
        fn() { perform do_a() },
        fn() { perform do_b() }
    ]
    intents
}
"
  let assert Ok(sexp) = chute.compile(source)
  let assert True = string.contains(sexp, "(effect do_a")
  let assert True = string.contains(sexp, "(effect do_b")
  // Closures with perform inside
  let assert True = string.contains(sexp, "(closure () (block (perform do_a)))")
  let assert True = string.contains(sexp, "(closure () (block (perform do_b)))")
}

// ── Nested field access and complex expressions ───────────────────────────

pub fn compile_complex_arithmetic_test() {
  let source =
    "
pub fn compute(env: { a: Int, b: Int, c: Int }) -> Int {
    env.a + env.b * env.c
}
"
  let assert Ok(sexp) = chute.compile(source)
  // Should be: a + (b * c) — addition wrapping the multiplication
  let assert True =
    string.contains(
      sexp,
      "(binop + (field-access (var env) a) (binop * (field-access (var env) b) (field-access (var env) c)))",
    )
}

// ── Full spec example (charge card + send receipt) ─────────────────────────

pub fn compile_full_spec_example_test() {
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
  let assert Ok(sexp) = chute.compile(source)
  // Verify the S-expression contains all expected parts
  let assert True = string.starts_with(sexp, "(program\n")
  let assert True =
    string.contains(sexp, "(effect charge_card ((amount Float))")
  let assert True =
    string.contains(
      sexp,
      "(effect send_receipt ((user_id String) (tx_id String))",
    )
  let assert True = string.contains(sexp, "(fn pub main")
  let assert True =
    string.contains(
      sexp,
      "(perform charge_card (field-access (var env) order_total))",
    )
}
