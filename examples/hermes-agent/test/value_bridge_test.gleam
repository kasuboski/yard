import ballast/value.{
  BoolVal, ErrorVal, FloatVal, IntVal, ListVal, NilVal, NoneVal, OkVal,
  RecordVal, SomeVal, StringVal,
}
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import hermes_agent/value_bridge

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// dynamic_to_value — convert Dynamic (parsed JSON) to Ballast Value
// ═══════════════════════════════════════════════════════════════

pub fn dynamic_to_value_int_test() {
  let result = value_bridge.dynamic_to_value(dynamic.int(42))
  let assert Ok(IntVal(42)) = result
}

pub fn dynamic_to_value_string_test() {
  let result = value_bridge.dynamic_to_value(dynamic.string("hello"))
  let assert Ok(StringVal("hello")) = result
}

pub fn dynamic_to_value_bool_test() {
  let result = value_bridge.dynamic_to_value(dynamic.bool(True))
  let assert Ok(BoolVal(True)) = result
}

pub fn dynamic_to_value_float_test() {
  let result = value_bridge.dynamic_to_value(dynamic.float(3.14))
  let assert Ok(FloatVal(f)) = result
  let assert True = f >. 3.0
}

pub fn dynamic_to_value_nil_test() {
  let result = value_bridge.dynamic_to_value(dynamic.nil())
  let assert Ok(NilVal) = result
}

pub fn dynamic_to_value_list_test() {
  let result =
    value_bridge.dynamic_to_value(
      dynamic.list([dynamic.int(1), dynamic.int(2)]),
    )
  let assert Ok(ListVal([IntVal(1), IntVal(2)])) = result
}

pub fn dynamic_to_value_mixed_list_test() {
  let result =
    value_bridge.dynamic_to_value(
      dynamic.list([dynamic.int(1), dynamic.string("two")]),
    )
  let assert Ok(ListVal([IntVal(1), StringVal("two")])) = result
}

pub fn dynamic_to_value_properties_test() {
  let result =
    value_bridge.dynamic_to_value(
      dynamic.properties([#(dynamic.string("x"), dynamic.int(1))]),
    )
  let assert Ok(RecordVal([#("x", IntVal(1))])) = result
}

pub fn dynamic_to_value_nested_test() {
  let result =
    value_bridge.dynamic_to_value(
      dynamic.properties([
        #(
          dynamic.string("user"),
          dynamic.properties([
            #(dynamic.string("name"), dynamic.string("bob")),
            #(dynamic.string("age"), dynamic.int(30)),
          ]),
        ),
      ]),
    )
  let assert Ok(RecordVal([#("user", RecordVal(inner))])) = result
  // dict ordering is not guaranteed — check contents
  let assert True =
    list.contains(inner, #("name", StringVal("bob")))
    && list.contains(inner, #("age", IntVal(30)))
    && list.length(inner) == 2
}

pub fn dynamic_to_value_empty_list_test() {
  let result = value_bridge.dynamic_to_value(dynamic.list([]))
  let assert Ok(ListVal([])) = result
}

pub fn dynamic_to_value_empty_record_test() {
  let result = value_bridge.dynamic_to_value(dynamic.properties([]))
  let assert Ok(RecordVal([])) = result
}

// ═══════════════════════════════════════════════════════════════
// ballast_to_json — convert Ballast Value to JSON
// ═══════════════════════════════════════════════════════════════

pub fn ballast_to_json_string_test() {
  let json_str =
    value_bridge.ballast_to_json(StringVal("hello"))
    |> json.to_string()
  let assert "\"hello\"" = json_str
}

pub fn ballast_to_json_int_test() {
  let json_str =
    value_bridge.ballast_to_json(IntVal(42))
    |> json.to_string()
  let assert "42" = json_str
}

pub fn ballast_to_json_bool_test() {
  let json_str =
    value_bridge.ballast_to_json(BoolVal(True))
    |> json.to_string()
  let assert "true" = json_str
}

pub fn ballast_to_json_float_test() {
  let json_str =
    value_bridge.ballast_to_json(FloatVal(3.14))
    |> json.to_string()
  let assert True = string.contains(json_str, "3.14")
}

pub fn ballast_to_json_nil_test() {
  let json_str =
    value_bridge.ballast_to_json(NilVal)
    |> json.to_string()
  let assert "null" = json_str
}

pub fn ballast_to_json_none_distinct_from_nil_test() {
  // NoneVal should NOT be null — it must be distinguishable from NilVal
  let none_str =
    value_bridge.ballast_to_json(NoneVal)
    |> json.to_string()
  let nil_str =
    value_bridge.ballast_to_json(NilVal)
    |> json.to_string()
  let assert True = none_str != nil_str
  let assert "\"none\"" = none_str
}

pub fn ballast_to_json_some_test() {
  let json_str =
    value_bridge.ballast_to_json(SomeVal(IntVal(7)))
    |> json.to_string()
  let assert True = string.contains(json_str, "\"some\"")
  let assert True = string.contains(json_str, "7")
}

pub fn ballast_to_json_list_test() {
  let json_str =
    value_bridge.ballast_to_json(ListVal([IntVal(1), IntVal(2)]))
    |> json.to_string()
  let assert "[1,2]" = json_str
}

pub fn ballast_to_json_record_test() {
  let json_str =
    value_bridge.ballast_to_json(RecordVal([#("name", StringVal("foo"))]))
    |> json.to_string()
  let assert "{\"name\":\"foo\"}" = json_str
}

pub fn ballast_to_json_ok_test() {
  let json_str =
    value_bridge.ballast_to_json(OkVal(IntVal(1)))
    |> json.to_string()
  let assert True = string.contains(json_str, "\"ok\"")
  let assert True = string.contains(json_str, ":1")
}

pub fn ballast_to_json_error_test() {
  let json_str =
    value_bridge.ballast_to_json(ErrorVal(StringVal("oops")))
    |> json.to_string()
  let assert True = string.contains(json_str, "\"error\"")
  let assert True = string.contains(json_str, "\"oops\"")
}
