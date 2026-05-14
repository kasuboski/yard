import ballast/value
import gleam/dict
import gleam/list

// ═══════════════════════════════════════════════════════════════════════════
// Environment: variable bindings
// ═══════════════════════════════════════════════════════════════════════════

/// Variable environment — maps names to runtime values.
pub type Env =
  dict.Dict(String, value.Value)

/// Create a new empty environment.
pub fn new() -> Env {
  dict.new()
}

/// Look up a variable by name.
pub fn get(env: Env, name: String) -> Result(value.Value, value.RuntimeError) {
  case dict.get(env, name) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(value.UndefinedVariable(name))
  }
}

/// Bind a variable in the environment.
pub fn insert(env: Env, name: String, val: value.Value) -> Env {
  dict.insert(env, name, val)
}

/// Extend an environment with parallel name/value lists.
/// Pairs names with values positionally.
pub fn extend(env: Env, names: List(String), values: List(value.Value)) -> Env {
  let pairs = list.zip(names, values)
  list.fold(pairs, env, fn(acc, pair) {
    let #(name, val) = pair
    dict.insert(acc, name, val)
  })
}
