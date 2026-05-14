import ballast
import ballast/value
import gleeunit
import testing

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════════
// Literals — source text evaluates to the expected value
// ═══════════════════════════════════════════════════════════════════════════

pub fn int_literal_test() {
  testing.equal(testing.run("pub fn main() -> Int { 42 }"), value.IntVal(42))
}

pub fn float_literal_test() {
  testing.equal(
    testing.run("pub fn main() -> Float { 3.14 }"),
    value.FloatVal(3.14),
  )
}

pub fn string_literal_test() {
  testing.equal(
    testing.run("pub fn main() -> String { \"hello\" }"),
    value.StringVal("hello"),
  )
}

pub fn bool_true_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { True }"),
    value.BoolVal(True),
  )
}

pub fn bool_false_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { False }"),
    value.BoolVal(False),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Variables & let bindings — names resolve to their bound values
// ═══════════════════════════════════════════════════════════════════════════

pub fn let_binding_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        let x = 42
        x
      }",
    ),
    value.IntVal(42),
  )
}

pub fn let_shadowing_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        let x = 1
        let x = 2
        x
      }",
    ),
    value.IntVal(2),
  )
}

pub fn undefined_variable_test() {
  let err = testing.run_error("pub fn main() -> Int { nope }")
  let assert value.UndefinedVariable("nope") = err
  Nil
}

// ═══════════════════════════════════════════════════════════════════════════
// Arithmetic — operators produce correct results
// ═══════════════════════════════════════════════════════════════════════════

pub fn add_test() {
  testing.equal(testing.run("pub fn main() -> Int { 3 + 4 }"), value.IntVal(7))
}

pub fn sub_test() {
  testing.equal(testing.run("pub fn main() -> Int { 10 - 3 }"), value.IntVal(7))
}

pub fn mul_test() {
  testing.equal(testing.run("pub fn main() -> Int { 6 * 7 }"), value.IntVal(42))
}

pub fn div_test() {
  testing.equal(testing.run("pub fn main() -> Int { 42 / 6 }"), value.IntVal(7))
}

pub fn div_by_zero_test() {
  let err = testing.run_error("pub fn main() -> Int { 1 / 0 }")
  let assert value.DivisionByZero = err
  Nil
}

// ═══════════════════════════════════════════════════════════════════════════
// Comparison — operators produce correct boolean results
// ═══════════════════════════════════════════════════════════════════════════

pub fn eq_true_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 42 == 42 }"),
    value.BoolVal(True),
  )
}

pub fn eq_false_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 1 == 2 }"),
    value.BoolVal(False),
  )
}

pub fn neq_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 1 != 2 }"),
    value.BoolVal(True),
  )
}

pub fn lt_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 1 < 2 }"),
    value.BoolVal(True),
  )
}

pub fn le_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 2 <= 2 }"),
    value.BoolVal(True),
  )
}

pub fn gt_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 5 > 3 }"),
    value.BoolVal(True),
  )
}

pub fn ge_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { 3 >= 3 }"),
    value.BoolVal(True),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Records — field access retrieves the correct value
// ═══════════════════════════════════════════════════════════════════════════

pub fn record_field_access_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> String {
        { name: \"Alice\", age: 30 }.name
      }",
    ),
    value.StringVal("Alice"),
  )
}

pub fn field_missing_test() {
  let err = testing.run_error("pub fn main() -> Int { { x: 1 }.missing }")
  let assert value.FieldMissing(_, "missing") = err
  Nil
}

// ═══════════════════════════════════════════════════════════════════════════
// Lists — list literals evaluate to the correct elements
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_length_test() {
  testing.equal(
    testing.run("pub fn main() -> Int { list.length([1, 2, 3]) }"),
    value.IntVal(3),
  )
}

pub fn empty_list_test() {
  testing.equal(
    testing.run("pub fn main() -> Int { list.length([]) }"),
    value.IntVal(0),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Closures — closures capture their environment and apply correctly
// ═══════════════════════════════════════════════════════════════════════════

pub fn closure_applied_test() {
  testing.equal(
    testing.run("pub fn main() -> Int { (fn(x) { x + 1 })(41) }"),
    value.IntVal(42),
  )
}

pub fn closure_captures_env_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        let y = 10
        let f = fn(x) { x + y }
        f(5)
      }",
    ),
    value.IntVal(15),
  )
}

pub fn nested_closure_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        let make_adder = fn(x) { fn(y) { x + y } }
        let add5 = make_adder(5)
        add5(37)
      }",
    ),
    value.IntVal(42),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Constructors — Ok/Error/Some/None produce the right wrapped values
// ═══════════════════════════════════════════════════════════════════════════

pub fn ok_constructor_test() {
  testing.equal(
    testing.run("pub fn main() -> Result(Int, String) { Ok(42) }"),
    value.OkVal(value.IntVal(42)),
  )
}

pub fn error_constructor_test() {
  testing.equal(
    testing.run("pub fn main() -> Result(Int, String) { Error(\"fail\") }"),
    value.ErrorVal(value.StringVal("fail")),
  )
}

pub fn some_constructor_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Option(Int) {
        option.map(Some(10), fn(x) { x + 5 })
      }",
    ),
    value.SomeVal(value.IntVal(15)),
  )
}

pub fn none_constructor_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Option(Int) {
        option.map(None, fn(x) { x + 5 })
      }",
    ),
    value.NoneVal,
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// User-defined functions — helper functions compute correctly
// ═══════════════════════════════════════════════════════════════════════════

pub fn user_function_test() {
  testing.equal(
    testing.run(
      "
      fn double(x: Int) -> Int { x * 2 }
      pub fn main() -> Int { double(21) }
    ",
    ),
    value.IntVal(42),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// String interpolation — ${expr} substitutes the value
// ═══════════════════════════════════════════════════════════════════════════

pub fn string_interpolation_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> String {
        let name = \"World\"
        \"Hello, ${name}!\"
      }",
    ),
    value.StringVal("Hello, World!"),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Empty block — a block with no trailing expression evaluates to Nil
// ═══════════════════════════════════════════════════════════════════════════

pub fn empty_block_returns_nil_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        let _ = 1
      }",
    ),
    value.NilVal,
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Gas exhaustion — programs that exceed their gas budget fail
// ═══════════════════════════════════════════════════════════════════════════

pub fn gas_exhausted_test() {
  case ballast.run_with_gas("pub fn main() -> Int { 42 }", 0) {
    Error(value.GasExhausted) -> Nil
    _other -> panic as "expected GasExhausted"
  }
}
