//// Agent turn handler tests — Pig agent loop with conversation persistence.
////
//// Uses a mock LLM provider that returns canned responses.
//// The new execute_turn delegates to pig's run_continue, so these tests
//// verify the conversation persistence seam rather than checkpoint replay.

import gleam/option
import gleeunit
import gleeunit/should
import pig/ai/error.{ApiError}
import pig/ai/message.{Assistant, User}
import pig/ai/provider.{InferenceResult, default_metadata, with_stop_reason}
import pig/ai/stop_reason.{Stop}
import yard/agent_checkpoint
import yard/agent_turn
import yard/conversation

pub fn main() {
  gleeunit.main()
}

// ── Mock Provider ────────────────────────────────────────────────────

/// Create a mock provider that always returns a fixed message.
fn mock_provider(response: message.Message) -> provider.Provider {
  fn(_messages, _tools) {
    Ok(InferenceResult(
      message: response,
      metadata: default_metadata() |> with_stop_reason(Stop),
    ))
  }
}

/// Provider that fails with an API error.
fn failing_provider() -> provider.Provider {
  fn(_, _) { Error(ApiError(message: "mock failure")) }
}

// ── Tests: execute_turn ──────────────────────────────────────────────

/// First turn with no history: agent runs, LLM is called, result is returned.
pub fn first_turn_calls_llm_and_returns_test() {
  let conv_store = conversation.in_memory()

  let response = Assistant("Hello!", [], option.None, option.Some(Stop))

  let result =
    agent_turn.execute_turn(
      conv_store: conv_store,
      conversation_id: "conv-1",
      user_message: "hi",
      provider: mock_provider(response),
      tools: [],
      system_prompt: "",
      agent_name: "test-agent",
    )

  let assert Ok(agent_turn.TurnResult(messages:, final_message:)) = result
  // Should have [User("hi"), Assistant("Hello!"...)]
  should.equal(messages, [
    User("hi"),
    Assistant("Hello!", [], option.None, option.Some(Stop)),
  ])
  should.equal(
    final_message,
    Assistant("Hello!", [], option.None, option.Some(Stop)),
  )
}

/// Turn with provider error returns a TurnError.
pub fn provider_error_returns_error_test() {
  let conv_store = conversation.in_memory()

  let result =
    agent_turn.execute_turn(
      conv_store: conv_store,
      conversation_id: "conv-1",
      user_message: "hi",
      provider: failing_provider(),
      tools: [],
      system_prompt: "",
      agent_name: "test-agent",
    )

  let assert Error(agent_turn.TurnError(_)) = result
}

/// On success, conversation store is updated with the full message log.
pub fn conversation_saved_on_success_test() {
  let conv_store = conversation.in_memory()

  let response = Assistant("Done!", [], option.None, option.Some(Stop))

  let _ =
    agent_turn.execute_turn(
      conv_store: conv_store,
      conversation_id: "conv-1",
      user_message: "do something",
      provider: mock_provider(response),
      tools: [],
      system_prompt: "",
      agent_name: "test-agent",
    )

  // Conversation store should have the full message log
  let assert Ok(option.Some(saved_json)) =
    conversation.load(conv_store, "conv-1")
  let saved = agent_checkpoint.messages_from_json_string(saved_json)
  should.equal(saved, [
    User("do something"),
    Assistant("Done!", [], option.None, option.Some(Stop)),
  ])
}
