//// Value codec tests — serialize/deserialize ballast Values for checkpointing.
////
//// Every effect handler result must round-trip through JSON so it can be
//// stored as a gabsurd checkpoint and fed back on replay.

import ballast/value.{
  type Value, BoolVal, ErrorVal, FloatVal, IntVal, ListVal, NilVal, NoneVal,
  OkVal, RecordVal, SomeVal, StringVal,
}
import gleam/json
import gleeunit
import gleeunit/should
import yard/value_codec

pub fn main() {
  gleeunit.main()
}

fn round_trip(v: Value) -> Result(Value, value_codec.DecodeError) {
  value_codec.from_json(json.to_string(value_codec.encode(v)))
}

// ── Primitives ───────────────────────────────────────────────────────

pub fn int_round_trip_test() {
  should.equal(round_trip(IntVal(42)), Ok(IntVal(42)))
}

pub fn negative_int_round_trip_test() {
  should.equal(round_trip(IntVal(-7)), Ok(IntVal(-7)))
}

pub fn float_round_trip_test() {
  should.equal(round_trip(FloatVal(3.14)), Ok(FloatVal(3.14)))
}

pub fn string_round_trip_test() {
  should.equal(
    round_trip(StringVal("hello world")),
    Ok(StringVal("hello world")),
  )
}

pub fn string_with_special_chars_test() {
  let v = StringVal("tab\there\nnewline \"quote\"")
  should.equal(round_trip(v), Ok(v))
}

pub fn bool_true_round_trip_test() {
  should.equal(round_trip(BoolVal(True)), Ok(BoolVal(True)))
}

pub fn bool_false_round_trip_test() {
  should.equal(round_trip(BoolVal(False)), Ok(BoolVal(False)))
}

pub fn nil_round_trip_test() {
  should.equal(round_trip(NilVal), Ok(NilVal))
}

// ── Result / Option wrappers ─────────────────────────────────────────

pub fn ok_round_trip_test() {
  should.equal(round_trip(OkVal(IntVal(1))), Ok(OkVal(IntVal(1))))
}

pub fn error_round_trip_test() {
  should.equal(
    round_trip(ErrorVal(StringVal("oops"))),
    Ok(ErrorVal(StringVal("oops"))),
  )
}

pub fn some_round_trip_test() {
  should.equal(round_trip(SomeVal(IntVal(42))), Ok(SomeVal(IntVal(42))))
}

pub fn none_round_trip_test() {
  should.equal(round_trip(NoneVal), Ok(NoneVal))
}

// ── Composite types ──────────────────────────────────────────────────

pub fn empty_list_round_trip_test() {
  should.equal(round_trip(ListVal([])), Ok(ListVal([])))
}

pub fn list_of_primitives_round_trip_test() {
  let v = ListVal([IntVal(1), StringVal("two"), BoolVal(True), NilVal])
  should.equal(round_trip(v), Ok(v))
}

pub fn empty_record_round_trip_test() {
  should.equal(round_trip(RecordVal([])), Ok(RecordVal([])))
}

pub fn record_round_trip_test() {
  let v = RecordVal([#("name", StringVal("Alice")), #("age", IntVal(30))])
  should.equal(round_trip(v), Ok(v))
}

// ── Nested structures ────────────────────────────────────────────────

pub fn nested_list_of_records_test() {
  let v =
    ListVal([
      RecordVal([#("x", IntVal(1)), #("y", IntVal(2))]),
      RecordVal([#("x", IntVal(3)), #("y", IntVal(4))]),
    ])
  should.equal(round_trip(v), Ok(v))
}

pub fn deeply_nested_test() {
  let v =
    OkVal(
      ListVal([
        RecordVal([#("items", ListVal([StringVal("a"), StringVal("b")]))]),
      ]),
    )
  should.equal(round_trip(v), Ok(v))
}

pub fn result_of_list_test() {
  let v = OkVal(ListVal([IntVal(1), IntVal(2), IntVal(3)]))
  should.equal(round_trip(v), Ok(v))
}

// ── Error cases ──────────────────────────────────────────────────────

pub fn decode_invalid_json_test() {
  should.be_error(value_codec.from_json("not json at all"))
}

pub fn decode_unknown_type_tag_test() {
  should.be_error(value_codec.from_json("{\"type\":\"closure\",\"value\":42}"))
}
