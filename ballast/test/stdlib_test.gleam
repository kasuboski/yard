import ballast/value
import gleeunit
import testing

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════════
// list.map — applies a function to every element
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_map_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> List(Int) {
        list.map([1, 2, 3], fn(x) { x * 2 })
      }",
    ),
    value.ListVal([value.IntVal(2), value.IntVal(4), value.IntVal(6)]),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// list.filter — keeps elements matching a predicate
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_filter_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> List(Int) {
        list.filter([1, 2, 3, 4], fn(x) { x > 2 })
      }",
    ),
    value.ListVal([value.IntVal(3), value.IntVal(4)]),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// list.fold — reduces a list with an accumulator
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_fold_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Int {
        list.fold([10, 20, 30], 0, fn(acc, x) { acc + x })
      }",
    ),
    value.IntVal(60),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// list.length — counts elements
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_length_test() {
  testing.equal(
    testing.run("pub fn main() -> Int { list.length([10, 20, 30]) }"),
    value.IntVal(3),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// result.try — chains Ok values, short-circuits on Error
// ═══════════════════════════════════════════════════════════════════════════

pub fn result_try_ok_chain_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Int, String) {
        result.try(Ok(10), fn(x) {
          result.try(Ok(20), fn(y) {
            Ok(x + y)
          })
        })
      }",
    ),
    value.OkVal(value.IntVal(30)),
  )
}

pub fn result_try_error_short_circuit_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Int, String) {
        result.try(Error(\"bad\"), fn(x) {
          Ok(x + 1)
        })
      }",
    ),
    value.ErrorVal(value.StringVal("bad")),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// result.map — transforms the Ok value, passes Error through
// ═══════════════════════════════════════════════════════════════════════════

pub fn result_map_ok_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Int, String) {
        result.map(Ok(10), fn(x) { x * 3 })
      }",
    ),
    value.OkVal(value.IntVal(30)),
  )
}

pub fn result_map_error_passthrough_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Int, String) {
        result.map(Error(\"bad\"), fn(x) { x * 3 })
      }",
    ),
    value.ErrorVal(value.StringVal("bad")),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// result.is_ok / result.is_error — classify Results
// ═══════════════════════════════════════════════════════════════════════════

pub fn result_is_ok_on_ok_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { result.is_ok(Ok(1)) }"),
    value.BoolVal(True),
  )
}

pub fn result_is_ok_on_error_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { result.is_ok(Error(\"x\")) }"),
    value.BoolVal(False),
  )
}

pub fn result_is_error_on_error_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { result.is_error(Error(\"x\")) }"),
    value.BoolVal(True),
  )
}

pub fn result_is_error_on_ok_test() {
  testing.equal(
    testing.run("pub fn main() -> Bool { result.is_error(Ok(1)) }"),
    value.BoolVal(False),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// option.map — transforms Some, passes None through
// ═══════════════════════════════════════════════════════════════════════════

pub fn option_map_some_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Option(Int) {
        option.map(Some(10), fn(x) { x + 5 })
      }",
    ),
    value.SomeVal(value.IntVal(15)),
  )
}

pub fn option_map_none_test() {
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
// string.length / string.concat — basic string operations
// ═══════════════════════════════════════════════════════════════════════════

pub fn string_length_test() {
  testing.equal(
    testing.run("pub fn main() -> Int { string.length(\"hello\") }"),
    value.IntVal(5),
  )
}

pub fn string_concat_test() {
  testing.equal(
    testing.run("pub fn main() -> String { string.concat(\"foo\", \"bar\") }"),
    value.StringVal("foobar"),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// task.dispatch_all — runs all thunks, returns Ok(Nil) on success
// ═══════════════════════════════════════════════════════════════════════════

pub fn task_dispatch_all_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Nil, String) {
        task.dispatch_all([
          fn() { Ok(1) },
          fn() { Ok(2) },
        ])
      }",
    ),
    value.OkVal(value.NilVal),
  )
}

pub fn task_dispatch_all_error_test() {
  testing.equal(
    testing.run(
      "pub fn main() -> Result(Nil, String) {
        task.dispatch_all([
          fn() { Ok(1) },
          fn() { Error(\"boom\") },
        ])
      }",
    ),
    value.ErrorVal(value.StringVal("boom")),
  )
}
