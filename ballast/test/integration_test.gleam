import ballast
import ballast/effect
import ballast/value
import gleeunit
import testing

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════════
// Pure program
// ═══════════════════════════════════════════════════════════════════════════

pub fn pure_program_test() {
  let assert Ok(v) =
    ballast.run(
      "
    fn add(a: Int, b: Int) -> Int { a + b }
    pub fn main() -> Int { add(20, 22) }
  ",
    )
  testing.equal(v, value.IntVal(42))
}

// ═══════════════════════════════════════════════════════════════════════════
// Program with closures and let bindings
// ═══════════════════════════════════════════════════════════════════════════

pub fn closure_program_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> Int {
      let make_adder = fn(x) { fn(y) { x + y } }
      let add5 = make_adder(5)
      add5(37)
    }
  ",
    )
  testing.equal(v, value.IntVal(42))
}

// ═══════════════════════════════════════════════════════════════════════════
// Record + field access
// ═══════════════════════════════════════════════════════════════════════════

pub fn record_program_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> Int {
      let r = { x: 10, y: 20 }
      r.x + r.y
    }
  ",
    )
  testing.equal(v, value.IntVal(30))
}

// ═══════════════════════════════════════════════════════════════════════════
// result.try chain
// ═══════════════════════════════════════════════════════════════════════════

pub fn result_try_chain_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> Result(Int, String) {
      result.try(Ok(10), fn(x) {
        result.try(Ok(20), fn(y) {
          Ok(x + y)
        })
      })
    }
  ",
    )
  testing.equal(v, value.OkVal(value.IntVal(30)))
}

// ═══════════════════════════════════════════════════════════════════════════
// result.try short-circuits on error
// ═══════════════════════════════════════════════════════════════════════════

pub fn result_try_error_short_circuit_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> Result(Int, String) {
      result.try(Error(\"bad\"), fn(x) {
        Ok(x + 1)
      })
    }
  ",
    )
  testing.equal(v, value.ErrorVal(value.StringVal("bad")))
}

// ═══════════════════════════════════════════════════════════════════════════
// Effect with yield + resume
// ═══════════════════════════════════════════════════════════════════════════

pub fn effect_yield_resume_test() {
  let assert Ok(res) =
    ballast.start(
      "
    effect get_id() -> Int
    pub fn main() -> Int {
      let id = perform get_id()
      id * 2
    }
  ",
      10_000,
    )
  case res {
    effect.Yielded("get_id", [], cont, _) -> {
      let res2 = ballast.resume(cont, value.IntVal(21))
      case res2 {
        effect.EvalDone(v, _) -> testing.equal(v, value.IntVal(42))
        _ -> panic
      }
    }
    _ -> panic
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Full spec-like program: charge_card + send_receipt
// ═══════════════════════════════════════════════════════════════════════════

pub fn charge_card_send_receipt_test() {
  let env_value =
    value.RecordVal([
      #("user_id", value.StringVal("user-1")),
      #("order_total", value.FloatVal(99.9)),
    ])
  let assert Ok(res) =
    ballast.start_with_env(
      "
    effect charge_card(amount: Float) -> Result(String, String)
    effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, String)

    pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, String) {
      env.order_total
      |> perform charge_card()
      |> result.try(fn(tx_id) {
        let _ = perform send_receipt(env.user_id, tx_id)
        Ok(tx_id)
      })
    }
  ",
      env_value,
      10_000,
    )
  case res {
    effect.Yielded("charge_card", args1, cont1, _) -> {
      testing.equal_lists(args1, [value.FloatVal(99.9)])
      let res2 = ballast.resume(cont1, value.OkVal(value.StringVal("TX-123")))
      case res2 {
        effect.Yielded("send_receipt", args2, cont2, _) -> {
          testing.equal_lists(args2, [
            value.StringVal("user-1"),
            value.StringVal("TX-123"),
          ])
          let res3 = ballast.resume(cont2, value.OkVal(value.NilVal))
          case res3 {
            effect.EvalDone(v, _) ->
              testing.equal(v, value.OkVal(value.StringVal("TX-123")))
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
// list.map
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_map_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> List(Int) {
      list.map([1, 2, 3], fn(x) { x * 2 })
    }
  ",
    )
  testing.equal(
    v,
    value.ListVal([value.IntVal(2), value.IntVal(4), value.IntVal(6)]),
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// String interpolation
// ═══════════════════════════════════════════════════════════════════════════

pub fn string_interpolation_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> String {
      let name = \"World\"
      \"Hello, ${name}!\"
    }
  ",
    )
  testing.equal(v, value.StringVal("Hello, World!"))
}

// ═══════════════════════════════════════════════════════════════════════════
// list.fold
// ═══════════════════════════════════════════════════════════════════════════

pub fn list_fold_test() {
  let assert Ok(v) =
    ballast.run(
      "
    pub fn main() -> Int {
      list.fold([10, 20, 30], 0, fn(acc, x) { acc + x })
    }
  ",
    )
  testing.equal(v, value.IntVal(60))
}

// ═══════════════════════════════════════════════════════════════════════════
// Compile once, run many times with different envs
// ═══════════════════════════════════════════════════════════════════════════

pub fn prepare_once_run_many_test() {
  let assert Ok(prog) =
    ballast.prepare(
      "
    pub fn main(env: { x: Int }) -> Int { env.x + 1 }
  ",
    )

  let assert Ok(v1) =
    ballast.run_program_with_env(
      prog,
      value.RecordVal([#("x", value.IntVal(10))]),
      10_000,
    )
  testing.equal(v1, value.IntVal(11))

  let assert Ok(v2) =
    ballast.run_program_with_env(
      prog,
      value.RecordVal([#("x", value.IntVal(99))]),
      10_000,
    )
  testing.equal(v2, value.IntVal(100))
}

// ═══════════════════════════════════════════════════════════════════════════
// AST-level effect start
// ═══════════════════════════════════════════════════════════════════════════

pub fn start_program_ast_test() {
  let assert Ok(prog) =
    ballast.prepare(
      "
    effect get_val() -> Int
    pub fn main() -> Int {
      let x = perform get_val()
      x + 10
    }
  ",
    )
  let res = ballast.start_program(prog, 10_000)
  case res {
    effect.Yielded("get_val", [], cont, _) -> {
      let res2 = ballast.resume(cont, value.IntVal(32))
      case res2 {
        effect.EvalDone(v, _) -> testing.equal(v, value.IntVal(42))
        _ -> panic
      }
    }
    _ -> panic
  }
}
