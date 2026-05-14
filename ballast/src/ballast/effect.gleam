import ballast/env
import ballast/value
import gleam/int
import gleam/list
import gleam/string

// ═══════════════════════════════════════════════════════════════════════════
// Evaluation result types
// ═══════════════════════════════════════════════════════════════════════════

/// Result of evaluating an expression. Three possible outcomes:
/// - EvalDone: normal completion with a value
/// - Yielded: hit a `perform`, waiting for the host to resume
/// - EvalError: runtime error
pub type EvalResult {
  EvalDone(value: value.Value, gas: Int)
  Yielded(
    effect: String,
    args: List(value.Value),
    continuation: Continuation,
    gas: Int,
  )
  EvalError(error: value.RuntimeError)
}

/// A captured continuation that can be resumed with a value from the host.
/// Wraps a Gleam closure that, given a host-provided value, continues evaluation.
pub opaque type Continuation {
  Continuation(resume: fn(value.Value) -> EvalResult)
}

/// Create a continuation from a resume function.
pub fn make_continuation(
  resume: fn(value.Value) -> EvalResult,
) -> Continuation {
  Continuation(resume)
}

/// Resume a continuation with a host-provided value.
/// Returns the next evaluation result (EvalDone, another Yielded, or EvalError).
pub fn resume(
  continuation: Continuation,
  host_value: value.Value,
) -> EvalResult {
  let Continuation(resume_fn) = continuation
  resume_fn(host_value)
}

// ═══════════════════════════════════════════════════════════════════════════
// EvalResult helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Format an EvalResult for debugging.
pub fn eval_result_to_string(r: EvalResult) -> String {
  case r {
    EvalDone(v, gas) ->
      "Done("
      <> value.value_to_string(v)
      <> ", gas="
      <> int.to_string(gas)
      <> ")"
    Yielded(effect_name, args, _, gas) ->
      "Yielded("
      <> effect_name
      <> ", ["
      <> string.join(list.map(args, value.value_to_string), ", ")
      <> "], gas="
      <> int.to_string(gas)
      <> ")"
    EvalError(e) -> "Error(" <> value.error_to_string(e) <> ")"
  }
}

/// Extract a simple Result from an EvalResult.
/// EvalDone → Ok(value), Yielded → Error(UndefinedEffect), EvalError → Error(error)
pub fn to_result(r: EvalResult) -> Result(value.Value, value.RuntimeError) {
  case r {
    EvalDone(v, _) -> Ok(v)
    Yielded(effect_name, _, _, _) ->
      Error(value.UndefinedEffect("Unexpected perform: " <> effect_name))
    EvalError(e) -> Error(e)
  }
}

/// The type of a continuation callback used in CPS evaluation.
/// When a sub-expression finishes evaluating, this continuation is called
/// with the resulting value and remaining gas.
pub type Kont =
  fn(value.Value, Int) -> EvalResult

/// Continuation for statement evaluation — threads the environment.
pub type StmtKont =
  fn(env.Env, Int) -> EvalResult
