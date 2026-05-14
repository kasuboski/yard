import ballast
import ballast/effect
import ballast/value
import gleeunit
import testing

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════════
// ballast.run — compile + run pure programs
// ═══════════════════════════════════════════════════════════════════════════

pub fn run_pure_test() {
  let assert Ok(v) =
    ballast.run(
      "
    fn double(x: Int) -> Int { x * 2 }
    pub fn main() -> Int { double(21) }
  ",
    )
  testing.equal(v, value.IntVal(42))
}

pub fn run_parse_error_test() {
  let result = ballast.run("this is not valid syntax")
  let assert Error(_) = result
  Nil
}

pub fn run_runtime_error_test() {
  let result =
    ballast.run(
      "
    pub fn main() -> Int { undefined_var }
  ",
    )
  let assert Error(_) = result
  Nil
}

// ═══════════════════════════════════════════════════════════════════════════
// ballast.start — compile + start with effect support
// ═══════════════════════════════════════════════════════════════════════════

pub fn start_with_effects_test() {
  let result =
    ballast.start(
      "
    effect get_val() -> Int
    pub fn main() -> Int {
      let x = perform get_val()
      x + 10
    }
  ",
      10_000,
    )
  let assert Ok(effect.Yielded("get_val", [], cont, _)) = result
  let res2 = ballast.resume(cont, value.IntVal(32))
  case res2 {
    effect.EvalDone(v, _) -> testing.equal(v, value.IntVal(42))
    _ -> panic
  }
}

pub fn start_pure_program_test() {
  let result =
    ballast.start(
      "
    pub fn main() -> Int { 1 + 1 }
  ",
      10_000,
    )
  let assert Ok(effect.EvalDone(v, _)) = result
  testing.equal(v, value.IntVal(2))
}

// ═══════════════════════════════════════════════════════════════════════════
// ballast.start_with_env — env value passed to main
// ═══════════════════════════════════════════════════════════════════════════

pub fn start_with_env_test() {
  let env_value = value.RecordVal([#("x", value.IntVal(100))])
  let result =
    ballast.start_with_env(
      "
    pub fn main(env: { x: Int }) -> Int { env.x + 1 }
  ",
      env_value,
      10_000,
    )
  let assert Ok(effect.EvalDone(v, _)) = result
  testing.equal(v, value.IntVal(101))
}
