//// Entry point resolution tests — DURABLE.md Component 2.
////
//// After loading checkpoints, the last message determines what to do next.
//// This is pure logic — no database, no I/O.

import gleam/option
import gleeunit
import gleeunit/should
import pig/ai/message.{Assistant, Tool, User}
import pig/ai/stop_reason.{Error, Length, Stop, ToolUse}
import yard/agent_checkpoint
import yard/checkpoint

pub fn main() {
  gleeunit.main()
}

// ── Entry point resolution ───────────────────────────────────────────

/// Last message is User → should call LLM provider
pub fn user_message_calls_llm_test() {
  let msgs = [User("hello")]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.CallLlm,
  )
}

/// Last message is Tool → should call LLM provider
pub fn tool_message_calls_llm_test() {
  let msgs = [
    User("hello"),
    Assistant("hi", [], option.None, option.Some(ToolUse)),
    Tool("call_1", "result"),
  ]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.CallLlm,
  )
}

/// Last message is Assistant with Stop → done, return immediately
pub fn assistant_stop_is_done_test() {
  let msgs = [
    User("hello"),
    Assistant("hi there", [], option.None, option.Some(Stop)),
  ]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.Done,
  )
}

/// Last message is Assistant with ToolUse → execute pending tool calls
pub fn assistant_tool_use_executes_tools_test() {
  let msgs = [
    User("hello"),
    Assistant("let me check", [], option.None, option.Some(ToolUse)),
  ]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.RunTools,
  )
}

/// Last message is Assistant with Length → retry policy
pub fn assistant_length_retries_test() {
  let msgs = [
    User("hello"),
    Assistant("long response...", [], option.None, option.Some(Length)),
  ]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.Retry,
  )
}

/// Last message is Assistant with Error → fail
pub fn assistant_error_fails_test() {
  let msgs = [
    User("hello"),
    Assistant("", [], option.None, option.Some(Error)),
  ]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.Fail,
  )
}

/// Last message is Assistant with no stop_reason → call LLM (edge case)
pub fn assistant_no_stop_reason_calls_llm_test() {
  let msgs = [Assistant("partial", [], option.None, option.None)]
  should.equal(
    agent_checkpoint.resolve_entry_point(msgs),
    agent_checkpoint.CallLlm,
  )
}

/// Empty message list → call LLM (first turn)
// ── Message checkpoint round-trip ─────────────────────────────────

/// Messages saved as checkpoints can be loaded back in order.
pub fn save_then_load_messages_test() {
  let cp = checkpoint.in_memory()
  let msgs = [
    message.User("hello"),
    message.Assistant("hi", [], option.None, option.Some(stop_reason.Stop)),
  ]
  let assert Ok(Nil) = agent_checkpoint.save_messages(cp, msgs)
  let assert Ok(loaded) = agent_checkpoint.load_messages(cp)
  should.equal(loaded, msgs)
}

/// Messages with tool calls round-trip through checkpoints.
pub fn tool_call_messages_round_trip_test() {
  let cp = checkpoint.in_memory()
  let msgs = [
    message.User("check the weather"),
    message.Assistant(
      "",
      [message.ToolCall("call_1", "get_weather", "{\"city\":\"SF\"}"),],
      option.None,
      option.Some(stop_reason.ToolUse),
    ),
    message.Tool("call_1", "{\"temp\": 72}"),
  ]
  let assert Ok(Nil) = agent_checkpoint.save_messages(cp, msgs)
  let assert Ok(loaded) = agent_checkpoint.load_messages(cp)
  should.equal(loaded, msgs)
}

/// Empty checkpoint store returns empty message list.
pub fn empty_store_returns_empty_messages_test() {
  let cp = checkpoint.in_memory()
  let assert Ok(loaded) = agent_checkpoint.load_messages(cp)
  should.equal(loaded, [])
}

/// Entry point resolves correctly from loaded checkpoint messages.
pub fn entry_point_from_loaded_messages_test() {
  let cp = checkpoint.in_memory()
  let msgs = [
    message.User("hello"),
    message.Assistant("hi there", [], option.None, option.Some(stop_reason.Stop)),
  ]
  let assert Ok(Nil) = agent_checkpoint.save_messages(cp, msgs)
  let assert Ok(loaded) = agent_checkpoint.load_messages(cp)
  should.equal(
    agent_checkpoint.resolve_entry_point(loaded),
    agent_checkpoint.Done,
  )
}
