//// Value bridge — converts Ballast Values to/from JSON and Dynamic.
////
//// This is the translation layer between Ballast's internal Value type
//// and the JSON/Dynamic representations used by Pig's tool system.

import ballast/value.{
  type Value, BoolVal, ClosureVal, ErrorVal, FloatVal, IntVal, ListVal, NilVal,
  NoneVal, OkVal, RecordVal, SomeVal, StringVal,
}
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

/// Convert a Ballast Value to a JSON value for inclusion in tool responses.
///
/// Note: NilVal maps to JSON `null`, while NoneVal maps to the string
/// `"none"` to preserve the semantic distinction between an explicit nil
/// and an absent optional value.
pub fn ballast_to_json(val: Value) -> json.Json {
  case val {
    StringVal(s) -> json.string(s)
    IntVal(n) -> json.int(n)
    BoolVal(b) -> json.bool(b)
    FloatVal(f) -> json.float(f)
    NilVal -> json.null()
    ListVal(elems) -> json.preprocessed_array(list.map(elems, ballast_to_json))
    RecordVal(fields) ->
      json.object(
        list.map(fields, fn(pair) {
          let #(key, val) = pair
          #(key, ballast_to_json(val))
        }),
      )
    OkVal(inner) -> json.object([#("ok", ballast_to_json(inner))])
    ErrorVal(inner) -> json.object([#("error", ballast_to_json(inner))])
    SomeVal(inner) -> json.object([#("some", ballast_to_json(inner))])
    NoneVal -> json.string("none")
    ClosureVal(..) -> json.string("<closure>")
  }
}

/// Convert a Dynamic value (parsed JSON from Pig) into a Ballast Value
/// for use as the env in Yard's RunConfig.
///
/// Tries decoders in order: int → float → string → bool, then composite
/// types by classification (Nil, List, Map/Dict). Int is checked before
/// float to avoid BEAM integer values being misidentified as floats.
pub fn dynamic_to_value(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  // Try int first — on BEAM, ints must be tried before floats
  case decode.run(dyn, decode.int) {
    Ok(n) -> Ok(IntVal(n))
    Error(_) -> try_float(dyn)
  }
}

fn try_float(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  case decode.run(dyn, decode.float) {
    Ok(f) -> Ok(FloatVal(f))
    Error(_) -> try_string(dyn)
  }
}

fn try_string(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  case decode.run(dyn, decode.string) {
    Ok(s) -> Ok(StringVal(s))
    Error(_) -> try_bool(dyn)
  }
}

fn try_bool(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  case decode.run(dyn, decode.bool) {
    Ok(b) -> Ok(BoolVal(b))
    Error(_) -> try_composite(dyn)
  }
}

fn try_composite(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  case dynamic.classify(dyn) {
    "Nil" -> Ok(NilVal)
    "List" -> try_list(dyn)
    "Map" | "Dict" -> try_dict(dyn)
    _ -> Error(Nil)
  }
}

fn try_list(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  use items <- result.try(
    decode.run(dyn, decode.list(decode.dynamic))
    |> result.replace_error(Nil),
  )

  items
  |> list.map(dynamic_to_value)
  |> result.all()
  |> result.map(ListVal)
}

fn try_dict(dyn: dynamic.Dynamic) -> Result(Value, Nil) {
  use entries <- result.try(
    decode.run(dyn, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil),
  )

  entries
  |> dict.to_list()
  |> list.map(fn(pair) {
    let #(key, val) = pair
    use v <- result.map(dynamic_to_value(val))
    #(key, v)
  })
  |> result.all()
  |> result.map(RecordVal)
}
