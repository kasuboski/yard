//// Conversation serialization tests — List(Message) ↔ JSON for
//// the conversations table.
////
//// The conversations table stores the full message log as a JSONB array.
//// These helpers serialize/deserialize List(Message) ↔ String.

import gleam/option
import gleeunit
import gleeunit/should
import pig/ai/message.{Assistant, System, Tool, User}
import pig/ai/stop_reason.{Error, Length, Stop, ToolUse}
import yard/agent_checkpoint

pub fn main() {
  gleeunit.main()
}

fn round_trip(messages: List(message.Message)) {
  let json_str = agent_checkpoint.messages_to_json_string(messages)
  agent_checkpoint.messages_from_json_string(json_str)
}

pub fn empty_list_round_trip_test() {
  should.equal(round_trip([]), [])
}

pub fn single_user_round_trip_test() {
  should.equal(round_trip([User("hello")]), [User("hello")])
}

pub fn multi_message_round_trip_test() {
  let msgs = [
    User("charge $99"),
    Assistant("", [], option.None, option.Some(ToolUse)),
    Tool("call_1", "{\"ok\": \"tx_456\"}"),
    Assistant("Done! Charged $99.", [], option.None, option.Some(Stop)),
  ]
  should.equal(round_trip(msgs), msgs)
}

pub fn system_message_round_trip_test() {
  let msgs = [System("You are a helpful assistant"), User("hi")]
  should.equal(round_trip(msgs), msgs)
}

pub fn tool_calls_round_trip_test() {
  let msgs = [
    User("check weather"),
    Assistant(
      "",
      [
        message.ToolCall("call_1", "get_weather", "{\"city\":\"SF\"}"),
        message.ToolCall("call_2", "get_time", "{\"tz\":\"PST\"}"),
      ],
      option.None,
      option.Some(ToolUse),
    ),
  ]
  should.equal(round_trip(msgs), msgs)
}

pub fn all_stop_reasons_round_trip_test() {
  let msgs = [
    Assistant("stop", [], option.None, option.Some(Stop)),
    Assistant("tool", [], option.None, option.Some(ToolUse)),
    Assistant("length", [], option.None, option.Some(Length)),
    Assistant("error", [], option.None, option.Some(Error)),
  ]
  should.equal(round_trip(msgs), msgs)
}

pub fn no_stop_reason_round_trip_test() {
  let msgs = [Assistant("partial", [], option.None, option.None)]
  should.equal(round_trip(msgs), msgs)
}

pub fn invalid_json_returns_empty_test() {
  should.equal(agent_checkpoint.messages_from_json_string("not json"), [])
}

pub fn empty_json_array_returns_empty_test() {
  should.equal(agent_checkpoint.messages_from_json_string("[]"), [])
}
