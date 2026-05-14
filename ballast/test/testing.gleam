import ballast
import ballast/effect
import ballast/value

/// Assert two runtime values are structurally equal.
pub fn equal(actual: value.Value, expected: value.Value) {
  case value.values_equal(actual, expected) {
    True -> Nil
    False -> {
      let msg =
        "value mismatch: got "
        <> value.value_to_string(actual)
        <> ", expected "
        <> value.value_to_string(expected)
      panic as msg
    }
  }
}

/// Assert two lists of values are structurally equal.
pub fn equal_lists(actual: List(value.Value), expected: List(value.Value)) {
  equal(value.ListVal(actual), value.ListVal(expected))
}

/// Run a Chute source string, returning the resulting value.
/// Panics on parse or runtime error.
pub fn run(source: String) -> value.Value {
  case ballast.run(source) {
    Ok(v) -> v
    Error(e) -> {
      let msg = "run failed: " <> value.error_to_string(e)
      panic as msg
    }
  }
}

/// Run a Chute source string that should fail at runtime.
pub fn run_error(source: String) -> value.RuntimeError {
  case ballast.run(source) {
    Error(e) -> e
    Ok(v) -> {
      let msg = "expected error, got: " <> value.value_to_string(v)
      panic as msg
    }
  }
}

/// Start a program with effect support, returning the first EvalResult.
/// Panics on parse error.
pub fn start(source: String) -> effect.EvalResult {
  case ballast.start(source, 10_000) {
    Ok(res) -> res
    Error(msg) -> panic as msg
  }
}
