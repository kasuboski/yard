//// Durable turn tests — conversation assembly and checkpoint-first logic.
////
//// From DURABLE.md Component 3: on retry, checkpoints are always ahead
//// of the conversations table. The worker loads from both and uses
//// whichever is further ahead.

import gleam/option
import gleeunit
import gleeunit/should
import pig/ai/message.{Assistant, User}
import pig/ai/stop_reason.{Stop, ToolUse}
import yard/agent_checkpoint
import yard/checkpoint
import yard/conversation
import yard/durable_turn

pub fn main() {
  gleeunit.main()
}

// ── First turn: no conversation history, no checkpoints ─────────────

pub fn first_turn_appends_user_message_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  let result = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "hello",
  )

  let assert Ok(durable_turn.AssembledHistory(messages:, entry_point:, is_retry:)) =
    result

  // Should have just the user message
  should.equal(messages, [User("hello")])
  should.equal(entry_point, agent_checkpoint.CallLlm)
  should.equal(is_retry, False)
}

// ── First turn: user message is checkpointed as msg:0 ───────────────

pub fn first_turn_checkpoints_user_message_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  let _ = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "hello",
  )

  // msg:0 should contain the user message
  let assert Ok(messages) = agent_checkpoint.load_messages(cp)
  should.equal(messages, [User("hello")])
}

// ── Second turn: loads previous history from conversation store ─────

pub fn second_turn_loads_previous_history_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  // Simulate Turn 1 completed: conversation store has 1 message
  let _ =
    conversation.save(conv, "conv-1", "[{\"role\":\"user\",\"content\":\"hi\"}]")

  let result = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "how are you",
  )

  let assert Ok(durable_turn.AssembledHistory(messages:, ..)) = result
  // Should have: [User("hi"), User("how are you")]
  should.equal(messages, [User("hi"), User("how are you")])
}

// ── Retry: checkpoints ahead of conversation table ──────────────────

pub fn retry_uses_checkpoints_over_conversation_history_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  // Conversation store has Turn 1 state
  let _ =
    conversation.save(conv, "conv-1", "[{\"role\":\"user\",\"content\":\"turn1\"}]")

  // Checkpoints have Turn 2 progress (user msg + LLM response)
  let _ = agent_checkpoint.save_messages(cp, [
    User("turn2"),
    Assistant("response", [], option.None, option.Some(Stop)),
  ])

  let result = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "turn2",
  )

  let assert Ok(durable_turn.AssembledHistory(
    messages:,
    entry_point:,
    is_retry:,
  )) = result

  // Checkpoints win: should have [User("turn1"), User("turn2"), Assistant("response"...)]
  should.equal(is_retry, True)
  should.equal(entry_point, agent_checkpoint.Done)
  should.equal(messages, [
    User("turn1"),
    User("turn2"),
    Assistant("response", [], option.None, option.Some(Stop)),
  ])
}

// ── Retry with partial progress: assistant requested tools ──────────

pub fn retry_with_tool_use_resumes_tool_execution_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  let _ =
    conversation.save(conv, "conv-1", "[{\"role\":\"user\",\"content\":\"check\"}]")

  // Checkpoints show assistant requested tool use
  let _ = agent_checkpoint.save_messages(cp, [
    User("weather"),
    Assistant("", [], option.None, option.Some(ToolUse)),
  ])

  let result = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "weather",
  )

  let assert Ok(durable_turn.AssembledHistory(entry_point:, is_retry:, ..)) =
    result
  should.equal(is_retry, True)
  should.equal(entry_point, agent_checkpoint.RunTools)
}

// ── Missing conversation: treated as empty history ──────────────────

pub fn missing_conversation_treated_as_empty_test() {
  let cp = checkpoint.in_memory()
  let conv = conversation.in_memory()

  let result = durable_turn.assemble_history(
    conv_store: conv,
    cp_store: cp,
    conversation_id: "nonexistent",
    user_message: "hello",
  )

  let assert Ok(durable_turn.AssembledHistory(messages:, ..)) = result
  should.equal(messages, [User("hello")])
}
