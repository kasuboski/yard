//// Agent turn handler tests — durable Pig agent loop inside a gabsurd task.
////
//// Uses a mock LLM provider that returns canned responses.
//// From DURABLE.md Component 2 + Component 3.

import gleam/erlang/process
import gleam/option
import gleeunit
import pig/ai/error.{ApiError}
import pig/ai/message.{Assistant, User}
import pig/ai/provider.{InferenceResult, default_metadata, with_stop_reason}
import pig/ai/stop_reason.{Stop}
import yard/agent_checkpoint
import yard/agent_turn
import yard/checkpoint

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
  fn(_, _) {
    Error(ApiError(message: "mock failure"))
  }
}

// ── Tests: execute_turn ──────────────────────────────────────────────

/// First turn with no history: agent runs, LLM is called, result is checkpointed.
pub fn first_turn_calls_llm_and_checkpoints_test() {
  let cp = checkpoint.in_memory()
  let conv_store = conversation_in_memory()

  let response = Assistant("Hello!", [], option.None, option.Some(Stop))

  let result = agent_turn.execute_turn(
    conv_store: conv_store,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "hi",
    provider: mock_provider(response),
    tools: [],
    system_prompt: "",
  )

  let assert Ok(agent_turn.TurnResult(messages:, final_message:)) = result
  // Should have [User("hi"), Assistant("Hello!"...)]
  should.equal(messages, [
    User("hi"),
    Assistant("Hello!", [], option.None, option.Some(Stop)),
  ])
  should.equal(final_message, Assistant("Hello!", [], option.None, option.Some(Stop)))

  // Both messages should be checkpointed
  let assert Ok(checkpointed) = agent_checkpoint.load_messages(cp)
  should.equal(checkpointed, [
    User("hi"),
    Assistant("Hello!", [], option.None, option.Some(Stop)),
  ])
}

/// Turn with provider error returns error, does NOT checkpoint the response.
pub fn provider_error_returns_error_no_checkpoint_test() {
  let cp = checkpoint.in_memory()
  let conv_store = conversation_in_memory()

  let result = agent_turn.execute_turn(
    conv_store: conv_store,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "hi",
    provider: failing_provider(),
    tools: [],
    system_prompt: "",
  )

  let assert Error(agent_turn.TurnError(_)) = result

  // Only the user message should be checkpointed (it's added before the LLM call)
  let assert Ok(checkpointed) = agent_checkpoint.load_messages(cp)
  should.equal(checkpointed, [User("hi")])
}

/// Retry: checkpoints exist from previous attempt.
/// The LLM should NOT be called — the checkpointed response is returned.
pub fn retry_does_not_call_llm_test() {
  let cp = checkpoint.in_memory()
  let conv_store = conversation_in_memory()

  // Pre-populate checkpoints as if a previous attempt ran
  let _ = agent_checkpoint.save_messages(cp, [
    User("hi"),
    Assistant("cached response", [], option.None, option.Some(Stop)),
  ])

  // The provider PANICS if called — proves replay works
  let panic_provider: provider.Provider = fn(_, _) {
    panic as "PROVIDER SHOULD NOT BE CALLED ON RETRY"
  }

  let result = agent_turn.execute_turn(
    conv_store: conv_store,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "hi",
    provider: panic_provider,
    tools: [],
    system_prompt: "",
  )

  let assert Ok(agent_turn.TurnResult(final_message:, ..)) = result
  should.equal(
    final_message,
    Assistant("cached response", [], option.None, option.Some(Stop)),
  )
}

/// On success, conversation store is updated with the full message log.
pub fn conversation_saved_on_success_test() {
  let cp = checkpoint.in_memory()
  let conv_store = conversation_in_memory()

  let response = Assistant("Done!", [], option.None, option.Some(Stop))

  let _ = agent_turn.execute_turn(
    conv_store: conv_store,
    cp_store: cp,
    conversation_id: "conv-1",
    user_message: "do something",
    provider: mock_provider(response),
    tools: [],
    system_prompt: "",
  )

  // Conversation store should have the full message log
  let assert Ok(option.Some(saved_json)) =
    conversation_load(conv_store, "conv-1")
  let saved = agent_checkpoint.messages_from_json_string(saved_json)
  should.equal(saved, [
    User("do something"),
    Assistant("Done!", [], option.None, option.Some(Stop)),
  ])
}

// ── Helpers (in-memory conversation store) ───────────────────────────

import gleam/dict
import gleam/otp/actor
import yard/conversation

fn conversation_in_memory() -> conversation.ConversationStore {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(state, msg) {
      case msg {
        Load(id, reply_to) -> {
          process.send(reply_to, Ok(case dict.get(state, id) {
            Ok(v) -> option.Some(v)
            Error(_) -> option.None
          }))
          actor.continue(state)
        }
        Save(id, messages, reply_to) -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(dict.insert(state, id, messages))
        }
      }
    })
    |> actor.start()
  let subject = started.data

  conversation.ConversationStore(
    load: fn(id) {
      let reply = process.new_subject()
      process.send(subject, Load(id, reply))
      let assert Ok(Ok(result)) = process.receive(reply, 5000)
      Ok(result)
    },
    save: fn(id, messages) {
      let reply = process.new_subject()
      process.send(subject, Save(id, messages, reply))
      let assert Ok(Ok(Nil)) = process.receive(reply, 5000)
      Ok(Nil)
    },
  )
}

fn conversation_load(
  store: conversation.ConversationStore,
  id: String,
) {
  conversation.load(store, id)
}

import gleeunit/should

type Msg {
  Load(String, process.Subject(Result(option.Option(String), Nil)))
  Save(String, String, process.Subject(Result(Nil, Nil)))
}
