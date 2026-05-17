import chute/ast
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/string

// ═══════════════════════════════════════════════════════════════════════════
// Runtime value types
// ═══════════════════════════════════════════════════════════════════════════

/// Runtime representation of Chute values.
pub type Value {
  IntVal(Int)
  FloatVal(Float)
  StringVal(String)
  BoolVal(Bool)
  NilVal
  RecordVal(fields: List(#(String, Value)))
  ListVal(elements: List(Value))
  ClosureVal(
    params: List(String),
    body: ast.Block,
    env: dict.Dict(String, Value),
  )
  OkVal(value: Value)
  ErrorVal(value: Value)
  SomeVal(value: Value)
  NoneVal
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime error types
// ═══════════════════════════════════════════════════════════════════════════

pub type RuntimeError {
  RuntimeError(message: String)
  UndefinedVariable(name: String)
  UndefinedFunction(name: String)
  UndefinedEffect(name: String)
  TypeMismatch(expected: String, actual: String)
  ArityMismatch(context: String, expected: Int, actual: Int)
  FieldMissing(record: String, field: String)
  DivisionByZero
  GasExhausted
  NotCallable(type_: String)
  MatchError(subject: String)
}

// ═══════════════════════════════════════════════════════════════════════════
// Value formatting (for debugging and error messages)
// ═══════════════════════════════════════════════════════════════════════════

pub fn value_to_string(v: Value) -> String {
  case v {
    IntVal(n) -> int.to_string(n)
    FloatVal(f) ->
      // Truncate to int for the whole part, show ".0" minimum
      int.to_string(float.truncate(f)) <> ".0"
    StringVal(s) -> "\"" <> s <> "\""
    BoolVal(b) ->
      case b {
        True -> "True"
        False -> "False"
      }
    NilVal -> "Nil"
    RecordVal(fields) ->
      "{ "
      <> string.join(
        list.map(fields, fn(f) { f.0 <> ": " <> value_to_string(f.1) }),
        ", ",
      )
      <> " }"
    ListVal(elems) ->
      "[" <> string.join(list.map(elems, value_to_string), ", ") <> "]"
    ClosureVal(..) -> "<closure>"
    OkVal(inner) -> "Ok(" <> value_to_string(inner) <> ")"
    ErrorVal(inner) -> "Error(" <> value_to_string(inner) <> ")"
    SomeVal(inner) -> "Some(" <> value_to_string(inner) <> ")"
    NoneVal -> "None"
  }
}

pub fn error_to_string(e: RuntimeError) -> String {
  case e {
    RuntimeError(msg) -> "Runtime error: " <> msg
    UndefinedVariable(name) -> "Undefined variable: " <> name
    UndefinedFunction(name) -> "Undefined function: " <> name
    UndefinedEffect(name) -> "Undefined effect: " <> name
    TypeMismatch(expected, actual) ->
      "Type mismatch: expected " <> expected <> ", got " <> actual
    ArityMismatch(context, expected, actual) ->
      context
      <> " expects "
      <> int.to_string(expected)
      <> " argument(s), got "
      <> int.to_string(actual)
    FieldMissing(record, field) ->
      "Field '" <> field <> "' not found in " <> record
    DivisionByZero -> "Division by zero"
    GasExhausted -> "Gas exhausted (possible infinite loop)"
    NotCallable(type_) -> "Cannot call value of type: " <> type_
    MatchError(subject) ->
      "Non-exhaustive case: no matching branch for " <> subject
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Value helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Look up a field in a record value by name.
pub fn record_get(record: Value, field: String) -> Result(Value, RuntimeError) {
  case record {
    RecordVal(fields) ->
      case list.key_find(fields, field) {
        Ok(v) -> Ok(v)
        Error(_) -> Error(FieldMissing(value_to_string(record), field))
      }
    _ -> Error(TypeMismatch("record", value_to_string(record)))
  }
}

/// Check if two values are structurally equal.
pub fn values_equal(a: Value, b: Value) -> Bool {
  case a, b {
    IntVal(x), IntVal(y) -> x == y
    FloatVal(x), FloatVal(y) -> x == y
    StringVal(x), StringVal(y) -> x == y
    BoolVal(x), BoolVal(y) -> x == y
    NilVal, NilVal -> True
    OkVal(x), OkVal(y) -> values_equal(x, y)
    ErrorVal(x), ErrorVal(y) -> values_equal(x, y)
    SomeVal(x), SomeVal(y) -> values_equal(x, y)
    NoneVal, NoneVal -> True
    ListVal(xs), ListVal(ys) -> lists_equal(xs, ys)
    RecordVal(fs1), RecordVal(fs2) -> records_equal(fs1, fs2)
    _, _ -> False
  }
}

fn lists_equal(a: List(Value), b: List(Value)) -> Bool {
  case a, b {
    [], [] -> True
    [ha, ..ta], [hb, ..tb] -> values_equal(ha, hb) && lists_equal(ta, tb)
    _, _ -> False
  }
}

fn records_equal(a: List(#(String, Value)), b: List(#(String, Value))) -> Bool {
  let a_sorted = list.sort(a, fn(x, y) { string.compare(x.0, y.0) })
  let b_sorted = list.sort(b, fn(x, y) { string.compare(x.0, y.0) })
  record_fields_equal(a_sorted, b_sorted)
}

fn record_fields_equal(
  a: List(#(String, Value)),
  b: List(#(String, Value)),
) -> Bool {
  case a, b {
    [], [] -> True
    [#(na, va), ..ra], [#(nb, vb), ..rb] ->
      na == nb && values_equal(va, vb) && record_fields_equal(ra, rb)
    _, _ -> False
  }
}

/// The type name of a value (for error messages).
pub fn type_name(v: Value) -> String {
  case v {
    IntVal(_) -> "Int"
    FloatVal(_) -> "Float"
    StringVal(_) -> "String"
    BoolVal(_) -> "Bool"
    NilVal -> "Nil"
    RecordVal(_) -> "Record"
    ListVal(_) -> "List"
    ClosureVal(..) -> "Closure"
    OkVal(_) -> "Ok"
    ErrorVal(_) -> "Error"
    SomeVal(_) -> "Some"
    NoneVal -> "None"
  }
}
