import ballast/effect
import ballast/value
import gleeunit
import testing

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════════
// perform yields to the host, resume continues execution
// ═══════════════════════════════════════════════════════════════════════════

pub fn simple_yield_resume_test() {
  let res =
    testing.start(
      "
    effect greet(name: String) -> String
    pub fn main() -> String { perform greet(\"World\") }
  ",
    )
  case res {
    effect.Yielded("greet", args, cont, _) -> {
      testing.equal_lists(args, [value.StringVal("World")])
      let res2 = effect.resume(cont, value.StringVal("Hello!"))
      case res2 {
        effect.EvalDone(v, _) -> testing.equal(v, value.StringVal("Hello!"))
        _ -> panic
      }
    }
    _ -> panic
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Multiple performs in sequence yield one at a time, preserving order
// ═══════════════════════════════════════════════════════════════════════════

pub fn multiple_performs_sequential_test() {
  let res =
    testing.start(
      "
    effect get_name() -> String
    effect get_age() -> Int
    pub fn main() -> String {
      let name = perform get_name()
      let _age = perform get_age()
      name
    }
  ",
    )
  case res {
    effect.Yielded("get_name", [], cont1, _) -> {
      let res2 = effect.resume(cont1, value.StringVal("Alice"))
      case res2 {
        effect.Yielded("get_age", [], cont2, _) -> {
          let res3 = effect.resume(cont2, value.IntVal(30))
          case res3 {
            effect.EvalDone(v, _) -> testing.equal(v, value.StringVal("Alice"))
            _ -> panic
          }
        }
        _ -> panic
      }
    }
    _ -> panic
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// perform with arguments evaluates and yields them correctly
// ═══════════════════════════════════════════════════════════════════════════

pub fn perform_with_args_test() {
  let res =
    testing.start(
      "
    effect concat(a: String, b: String) -> String
    pub fn main() -> String { perform concat(\"hello\", \" world\") }
  ",
    )
  case res {
    effect.Yielded("concat", args, cont, _) -> {
      testing.equal_lists(args, [
        value.StringVal("hello"),
        value.StringVal(" world"),
      ])
      let res2 = effect.resume(cont, value.StringVal("hello world"))
      case res2 {
        effect.EvalDone(v, _) ->
          testing.equal(v, value.StringVal("hello world"))
        _ -> panic
      }
    }
    _ -> panic
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// perform in a pipeline desugars correctly and yields with the piped value
// ═══════════════════════════════════════════════════════════════════════════

pub fn perform_in_pipeline_test() {
  let res =
    testing.start(
      "
    effect double(x: Int) -> Int
    pub fn main() -> Int { 21 |> perform double() }
  ",
    )
  case res {
    effect.Yielded("double", args, cont, _) -> {
      testing.equal_lists(args, [value.IntVal(21)])
      let res2 = effect.resume(cont, value.IntVal(42))
      case res2 {
        effect.EvalDone(v, _) -> testing.equal(v, value.IntVal(42))
        _ -> panic
      }
    }
    _ -> panic
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// A perform inside a closure (thunk) yields when the thunk is called
// ═══════════════════════════════════════════════════════════════════════════

pub fn perform_inside_closure_test() {
  let res =
    testing.start(
      "
    effect get_val() -> Int
    pub fn main() -> Int {
      let thunk = fn() { perform get_val() }
      thunk()
    }
  ",
    )
  case res {
    effect.Yielded("get_val", [], cont, _) -> {
      let res2 = effect.resume(cont, value.IntVal(99))
      case res2 {
        effect.EvalDone(v, _) -> testing.equal(v, value.IntVal(99))
        _ -> panic
      }
    }
    _ -> panic
  }
}
