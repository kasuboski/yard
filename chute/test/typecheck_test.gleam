import chute/desugar
import chute/lexer
import chute/parser
import chute/typecheck
import chute/typecheck/types as tc
import gleam/list
import gleam/string
import gleeunit

pub fn main() {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────────────

fn check(source: String) -> List(tc.TypeError) {
  case lexer.tokenize(source) {
    Error(msg) -> [tc.TypeError("tokenize error: " <> msg)]
    Ok(tokens) -> {
      case parser.parse(tokens) {
        Error(msg) -> [tc.TypeError("parse error: " <> msg)]
        Ok(program) -> {
          let desugared = desugar.desugar(program)
          typecheck.typecheck(desugared)
        }
      }
    }
  }
}

fn well_typed(source: String) -> Bool {
  list.is_empty(check(source))
}

fn has_error(source: String, expected: String) -> Bool {
  let errors = check(source)
  list.any(errors, fn(e) {
    let tc.TypeError(message: msg) = e
    string.contains(msg, expected)
  })
}

// ══════════════════════════════════════════════════════════════════════════
// Literals and primitives
// ══════════════════════════════════════════════════════════════════════════

pub fn int_literal_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Int { 42 }")
}

pub fn float_literal_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Float { 3.14 }")
}

pub fn string_literal_test() {
  let assert True = well_typed("pub fn main(env: {}) -> String { \"hello\" }")
}

pub fn bool_literal_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Bool { True }")
}

pub fn nil_literal_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Nil { Nil }")
}

pub fn empty_block_returns_nil_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Nil { }")
}

// ══════════════════════════════════════════════════════════════════════════
// Type mismatches
// ══════════════════════════════════════════════════════════════════════════

pub fn return_type_mismatch_int_string_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> String { 42 }", "Type mismatch")
}

pub fn return_type_mismatch_nil_int_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> Int { Nil }", "Type mismatch")
}

pub fn return_type_mismatch_bool_string_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> String { True }", "Type mismatch")
}

// ══════════════════════════════════════════════════════════════════════════
// Variables and let bindings
// ══════════════════════════════════════════════════════════════════════════

pub fn let_binding_inferred_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let x = 42
    x
}",
    )
}

pub fn let_binding_with_annotation_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let x: Int = 42
    x
}",
    )
}

pub fn let_binding_annotation_mismatch_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> Int {
    let x: String = 42
    x
}",
      "Type mismatch",
    )
}

pub fn variable_shadowing_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> String {
    let x = 42
    let x = \"hello\"
    x
}",
    )
}

pub fn undefined_variable_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> Int { x }", "Undefined variable")
}

pub fn env_parameter_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: { x: Int }) -> Int { env.x }",
    )
}

pub fn env_field_wrong_type_test() {
  let assert True =
    has_error(
      "
pub fn main(env: { x: Int }) -> String { env.x }",
      "Type mismatch",
    )
}

pub fn env_field_missing_test() {
  let assert True =
    has_error(
      "
pub fn main(env: { x: Int }) -> Int { env.y }",
      "has no field",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Binary operators
// ══════════════════════════════════════════════════════════════════════════

pub fn add_ints_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Int { 1 + 2 }")
}

pub fn subtract_ints_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Int { 10 - 3 }")
}

pub fn multiply_ints_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Int { 4 * 5 }")
}

pub fn divide_ints_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Int { 10 / 2 }")
}

pub fn comparison_returns_bool_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Bool { 1 > 2 }")
}

pub fn equality_returns_bool_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Bool { 1 == 2 }")
}

pub fn operator_type_mismatch_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> Int { 1 + \"hello\" }", "Type mismatch")
}

// ══════════════════════════════════════════════════════════════════════════
// Records
// ══════════════════════════════════════════════════════════════════════════

pub fn record_literal_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> { x: Int, y: Int } {
    { x: 1, y: 2 }
}",
    )
}

pub fn record_field_access_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let p = { x: 1, y: 2 }
    p.x
}",
    )
}

pub fn record_field_type_mismatch_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> String {
    let p = { x: 1, y: 2 }
    p.x
}",
      "Type mismatch",
    )
}

pub fn record_structural_mismatch_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> { x: Int } {
    { x: 1, y: 2 }
}",
      "Record field count mismatch",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Lists
// ══════════════════════════════════════════════════════════════════════════

pub fn list_literal_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> List(Int) { [1, 2, 3] }")
}

pub fn empty_list_test() {
  let assert True = well_typed("pub fn main(env: {}) -> List(Int) { [] }")
}

pub fn list_type_mismatch_test() {
  let assert True =
    has_error(
      "pub fn main(env: {}) -> List(String) { [1, 2, 3] }",
      "Type mismatch",
    )
}

pub fn list_mixed_types_test() {
  let assert True =
    has_error(
      "pub fn main(env: {}) -> List(Int) { [1, \"hello\"] }",
      "Type mismatch",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Functions and closures
// ══════════════════════════════════════════════════════════════════════════

pub fn closure_inferred_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let add = fn(x, y) { x + y }
    add(1, 2)
}",
    )
}

pub fn closure_wrong_arg_count_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> Int {
    let add = fn(x, y) { x + y }
    add(1)
}",
      "expects 2 argument",
    )
}

pub fn closure_wrong_arg_type_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> Int {
    let add = fn(x, y) { x + y }
    add(1, \"hello\")
}",
      "Type mismatch",
    )
}

pub fn closure_return_type_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let get_int = fn() { 42 }
    get_int()
}",
    )
}

pub fn function_call_test() {
  let assert True =
    well_typed(
      "
fn helper(x: Int) -> Int { x + 1 }
pub fn main(env: {}) -> Int { helper(5) }",
    )
}

pub fn function_wrong_arg_count_test() {
  let assert True =
    has_error(
      "
fn helper(x: Int) -> Int { x + 1 }
pub fn main(env: {}) -> Int { helper(5, 6) }",
      "expects 1 argument",
    )
}

pub fn function_wrong_arg_type_test() {
  let assert True =
    has_error(
      "
fn helper(x: Int) -> Int { x + 1 }
pub fn main(env: {}) -> Int { helper(\"hello\") }",
      "Type mismatch",
    )
}

pub fn function_return_mismatch_test() {
  let assert True =
    has_error(
      "
fn helper(x: Int) -> String { x + 1 }
pub fn main(env: {}) -> String { helper(5) }",
      "Type mismatch",
    )
}

pub fn undefined_function_test() {
  let assert True =
    has_error("pub fn main(env: {}) -> Int { nope(5) }", "Undefined function")
}

pub fn closure_captures_env_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let x = 10
    let get_x = fn() { x }
    get_x()
}",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Effects and perform
// ══════════════════════════════════════════════════════════════════════════

pub fn perform_effect_test() {
  let assert True =
    well_typed(
      "
effect fetch_data(id: String) -> Result(String, Error)
pub fn main(env: {}) -> Result(String, Error) {
    perform fetch_data(\"test\")
}",
    )
}

pub fn perform_wrong_arg_count_test() {
  let assert True =
    has_error(
      "
effect fetch_data(id: String) -> Result(String, Error)
pub fn main(env: {}) -> Result(String, Error) {
    perform fetch_data(\"test\", \"extra\")
}",
      "expects 1 argument",
    )
}

pub fn perform_wrong_arg_type_test() {
  let assert True =
    has_error(
      "
effect fetch_data(id: String) -> Result(String, Error)
pub fn main(env: {}) -> Result(String, Error) {
    perform fetch_data(42)
}",
      "Type mismatch",
    )
}

pub fn perform_undefined_effect_test() {
  let assert True =
    has_error(
      "
pub fn main(env: {}) -> Result(String, Error) {
    perform no_such_effect()
}",
      "Undefined effect",
    )
}

pub fn perform_return_type_test() {
  let assert True =
    has_error(
      "
effect fetch_data(id: String) -> Result(String, Error)
pub fn main(env: {}) -> String {
    perform fetch_data(\"test\")
}",
      "Type mismatch",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Constructors (Ok, Error, Some, None)
// ══════════════════════════════════════════════════════════════════════════

pub fn ok_constructor_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> Result(Int, String) { Ok(42) }")
}

pub fn error_constructor_test() {
  let assert True =
    well_typed(
      "pub fn main(env: {}) -> Result(Int, String) { Error(\"fail\") }",
    )
}

pub fn some_constructor_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> Option(Int) { Some(42) }")
}

pub fn none_value_test() {
  let assert True = well_typed("pub fn main(env: {}) -> Option(Int) { None }")
}

pub fn ok_wrong_arg_count_test() {
  let assert True =
    has_error(
      "pub fn main(env: {}) -> Result(Int, String) { Ok() }",
      "Ok() takes exactly 1 argument",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Standard library functions
// ══════════════════════════════════════════════════════════════════════════

pub fn list_map_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> List(String) {
    list.map([1, 2, 3], fn(x) { \"num\" })
}",
    )
}

pub fn list_filter_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> List(Int) {
    list.filter([1, 2, 3], fn(x) { x > 1 })
}",
    )
}

pub fn list_fold_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    list.fold([1, 2, 3], 0, fn(acc, x) { acc + x })
}",
    )
}

pub fn list_length_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> Int { list.length([1, 2, 3]) }")
}

pub fn result_try_test() {
  let assert True =
    well_typed(
      "
effect fetch(id: String) -> Result(String, Error)
pub fn main(env: {}) -> Result(String, Error) {
    result.try(perform fetch(\"a\"), fn(data) {
        Ok(data)
    })
}",
    )
}

pub fn result_map_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Result(String, Error) {
    result.map(Ok(42), fn(x) { \"got it\" })
}",
    )
}

pub fn result_is_ok_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> Bool { result.is_ok(Ok(42)) }")
}

pub fn result_is_error_test() {
  let assert True =
    well_typed(
      "pub fn main(env: {}) -> Bool { result.is_error(Error(\"fail\")) }",
    )
}

pub fn string_length_test() {
  let assert True =
    well_typed("pub fn main(env: {}) -> Int { string.length(\"hello\") }")
}

pub fn string_concat_test() {
  let assert True =
    well_typed(
      "pub fn main(env: {}) -> String { string.concat(\"hello\", \" world\") }",
    )
}

pub fn task_dispatch_all_test() {
  let assert True =
    well_typed(
      "
effect do_a() -> Result(Nil, Error)
effect do_b() -> Result(Nil, Error)
pub fn main(env: {}) -> Result(Nil, Error) {
    let intents = [
        fn() { perform do_a() },
        fn() { perform do_b() }
    ]
    task.dispatch_all(intents)
}",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Auto-unioning (Result error types)
// ══════════════════════════════════════════════════════════════════════════

pub fn auto_union_same_error_test() {
  // Both effects return same Error type — auto-union is just Error
  let assert True =
    well_typed(
      "
effect do_a() -> Result(String, Error)
effect do_b() -> Result(Nil, Error)
pub fn main(env: {}) -> Result(String, Error) {
    result.try(perform do_a(), fn(a) {
        let _ = perform do_b()
        Ok(a)
    })
}",
    )
}

pub fn ok_constructor_infers_from_context_test() {
  // Ok(42) creates Result(Int, ?e), unified with Result(Int, String)
  let assert True =
    well_typed("pub fn main(env: {}) -> Result(Int, String) { Ok(42) }")
}

// ══════════════════════════════════════════════════════════════════════════
// String interpolation
// ══════════════════════════════════════════════════════════════════════════

pub fn string_interpolation_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: { name: String }) -> String { \"Hello ${env.name}\" }",
    )
}

pub fn string_interpolation_type_error_test() {
  let assert True =
    has_error(
      "
pub fn main(env: { x: Int }) -> String { \"value: ${env.x}\" }",
      "Type mismatch",
    )
}

// ══════════════════════════════════════════════════════════════════════════
// Full programs (integration)
// ══════════════════════════════════════════════════════════════════════════

pub fn spec_example_program_test() {
  let assert True =
    well_typed(
      "
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    env.order_total
    |> perform charge_card()
    |> result.try(fn(tx_id) {
        let _ = perform send_receipt(env.user_id, tx_id)
        Ok(tx_id)
    })
}",
    )
}

pub fn empty_program_test() {
  let assert True = well_typed("")
}

pub fn effects_only_test() {
  let assert True =
    well_typed(
      "
effect fetch_data(id: String) -> Result(String, Error)
effect save_data(id: String, data: String) -> Result(Nil, Error)",
    )
}

pub fn multiple_functions_test() {
  let assert True =
    well_typed(
      "
fn double(x: Int) -> Int { x * 2 }
fn quad(x: Int) -> Int { double(double(x)) }
pub fn main(env: {}) -> Int { quad(5) }",
    )
}

pub fn function_with_record_param_test() {
  let assert True =
    well_typed(
      "
fn get_x(r: { x: Int }) -> Int { r.x }
pub fn main(env: {}) -> Int { get_x({ x: 42 }) }",
    )
}

pub fn function_with_fn_type_param_test() {
  let assert True =
    well_typed(
      "
fn apply(f: fn(Int) -> Int, x: Int) -> Int { f(x) }
pub fn main(env: {}) -> Int { apply(fn(n) { n + 1 }, 5) }",
    )
}

pub fn complex_record_access_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: { data: { items: List(Int) } }) -> List(Int) {
    env.data.items
}",
    )
}

pub fn no_global_execution_test() {
  // Only function/effect declarations allowed at top level
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int { 42 }",
    )
}

pub fn block_with_statements_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let x = 1
    let y = 2
    x + y
}",
    )
}

pub fn wildcard_binding_test() {
  let assert True =
    well_typed(
      "
pub fn main(env: {}) -> Int {
    let _ = 42
    1
}",
    )
}
