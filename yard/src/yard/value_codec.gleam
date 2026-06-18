//// Ballast Value serialization for checkpointing.
////
//// Every effect handler result must be serializable to JSON so it can be
//// stored as a checkpoint and fed back to Ballast on replay. ClosureVal
//// cannot be serialized — but per the DURABLE.md design invariant, effect
//// handlers never produce closures.
////
//// JSON format (tagged union):
////   {"type":"int","value":42}
////   {"type":"string","value":"hello"}
////   {"type":"nil"}
////   {"type":"list","elements":[...]}
////   {"type":"record","fields":[{"name":"x","value":{...}}]}
////   etc.

import ballast/value.{
  type Value, BoolVal, ClosureVal, ErrorVal, FloatVal, IntVal, ListVal, NilVal,
  NoneVal, OkVal, RecordVal, SomeVal, StringVal,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Error from decoding a value.
pub type DecodeError {
  InvalidJson(String)
  UnknownTypeTag(String)
  DecodingFailed(String)
}

/// Encode a ballast Value to JSON.
pub fn encode(v: Value) -> json.Json {
  case v {
    IntVal(n) ->
      json.object([
        #("type", json.string("int")),
        #("value", json.int(n)),
      ])
    FloatVal(f) ->
      json.object([
        #("type", json.string("float")),
        #("value", json.float(f)),
      ])
    StringVal(s) ->
      json.object([
        #("type", json.string("string")),
        #("value", json.string(s)),
      ])
    BoolVal(b) ->
      json.object([
        #("type", json.string("bool")),
        #("value", json.bool(b)),
      ])
    NilVal -> json.object([#("type", json.string("nil"))])
    OkVal(inner) ->
      json.object([
        #("type", json.string("ok")),
        #("value", encode(inner)),
      ])
    ErrorVal(inner) ->
      json.object([
        #("type", json.string("error")),
        #("value", encode(inner)),
      ])
    SomeVal(inner) ->
      json.object([
        #("type", json.string("some")),
        #("value", encode(inner)),
      ])
    NoneVal -> json.object([#("type", json.string("none"))])
    ListVal(elems) ->
      json.object([
        #("type", json.string("list")),
        #("elements", json.array(from: elems, of: encode)),
      ])
    RecordVal(fields) ->
      json.object([
        #("type", json.string("record")),
        #(
          "fields",
          json.array(
            from: fields,
            of: fn(f) {
              json.object([
                #("name", json.string(f.0)),
                #("value", encode(f.1)),
              ])
            },
          ),
        ),
      ])
    ClosureVal(..) -> json.object([#("type", json.string("closure"))])
  }
}

/// Decode a JSON string back into a ballast Value.
pub fn from_json(json_str: String) -> Result(Value, DecodeError) {
  use parsed <- result.try(
    json.parse(json_str, decode.dynamic)
    |> result.map_error(fn(e) { InvalidJson(string.inspect(e)) }),
  )
  decode.run(parsed, value_decoder())
  |> result.map_error(fn(e) { DecodingFailed(string.inspect(e)) })
}

/// Decoder for a ballast Value from dynamic data.
pub fn value_decoder() -> decode.Decoder(Value) {
  use type_tag <- decode.field("type", decode.string)

  case type_tag {
    "int" -> {
      use n <- decode.field("value", decode.int)
      decode.success(IntVal(n))
    }
    "float" -> {
      use f <- decode.field("value", decode.float)
      decode.success(FloatVal(f))
    }
    "string" -> {
      use s <- decode.field("value", decode.string)
      decode.success(StringVal(s))
    }
    "bool" -> {
      use b <- decode.field("value", decode.bool)
      decode.success(BoolVal(b))
    }
    "nil" -> decode.success(NilVal)
    "none" -> decode.success(NoneVal)
    "ok" -> {
      use inner <- decode.field("value", value_decoder())
      decode.success(OkVal(inner))
    }
    "error" -> {
      use inner <- decode.field("value", value_decoder())
      decode.success(ErrorVal(inner))
    }
    "some" -> {
      use inner <- decode.field("value", value_decoder())
      decode.success(SomeVal(inner))
    }
    "list" -> {
      use elems <- decode.field("elements", decode.list(of: value_decoder()))
      decode.success(ListVal(elems))
    }
    "record" -> {
      use raw_fields <- decode.field("fields", decode.list(of: field_decoder()))
      let fields = list.map(raw_fields, fn(f) { #(f.0, f.1) })
      decode.success(RecordVal(fields))
    }
    _ -> decode.failure(NilVal, "valid type tag (got: " <> type_tag <> ")")
  }
}

fn field_decoder() -> decode.Decoder(#(String, Value)) {
  use name <- decode.field("name", decode.string)
  use val <- decode.field("value", value_decoder())
  decode.success(#(name, val))
}
