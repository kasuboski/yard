//// Agent turn handler — runs one Pig agent turn with full durability.
////
//// From DURABLE.md Component 2 + Component 3.
//// This is the handler for the "run-agent-turn" gabsurd task.
////
//// Each call:
//// 1. Assembles history from conversation store + checkpoints
//// 2. Determines entry point (CallLlm / Done / RunTools / etc.)
//// 3. If retry with Done entry point: returns cached messages, no LLM call
//// 4. If fresh/retry with CallLlm: creates Pig agent, runs one turn
//// 5. Checkpoints new messages
//// 6. Saves conversation to store on success

import pig/ai/error.{type AiError, ApiError, InvalidResponse, RateLimited, Timeout}
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import yard/agent_checkpoint.{CallLlm, Done}
import yard/checkpoint.{type Checkpointer}
import yard/conversation.{type ConversationStore}
import yard/durable_turn

/// Result of executing a durable agent turn.
pub type TurnResult {
  TurnResult(
    messages: List(Message),
    final_message: Message,
  )
}

/// Error from a turn execution.
pub type TurnError {
  TurnError(String)
}

/// Execute one durable agent turn.
///
/// This function ties together the conversation store, checkpoint store,
/// and Pig's LLM provider. It handles both first-turn and retry scenarios.
///
/// Parameters:
/// - `conv_store`: PostgreSQL conversation store for multi-turn persistence
/// - `cp_store`: Checkpoint store for per-task message durability
/// - `conversation_id`: Unique ID for this conversation
/// - `user_message`: The new user message for this turn
/// - `provider`: LLM provider function
/// - `tools`: Available tools for the agent
/// - `system_prompt`: System prompt for the agent
pub fn execute_turn(
  conv_store store: ConversationStore,
  cp_store cp: Checkpointer,
  conversation_id conversation_id: String,
  user_message user_message: String,
  provider provider: Provider,
  tools _tools: List(Nil),
  system_prompt _system_prompt: String,
) -> Result(TurnResult, TurnError) {
  // Assemble history (handles first-turn vs retry)
  let assert Ok(durable_turn.AssembledHistory(
    messages:,
    entry_point:,
    is_retry: _,
  )) = durable_turn.assemble_history(
    conv_store: store,
    cp_store: cp,
    conversation_id:,
    user_message:,
  )

  // Determine what to do based on entry point
  case entry_point {
    Done -> {
      // Retry completed: last message is Stop, return immediately
      // No LLM call needed
      let assert Ok(final) = gleam_list_last(messages)
      save_conversation(store, conversation_id, messages)
      Ok(TurnResult(messages:, final_message: final))
    }

    CallLlm -> {
      // Need to call the LLM — either first turn or retry with pending messages
      call_llm_and_checkpoint(provider, cp, store, conversation_id, messages)
    }

    _ -> {
      // RunTools / Retry / Fail — for now, treat as needing an LLM call.
      // In a full implementation, RunTools would execute tool calls here.
      call_llm_and_checkpoint(provider, cp, store, conversation_id, messages)
    }
  }
}

fn call_llm_and_checkpoint(
  provider: Provider,
  cp: Checkpointer,
  store: ConversationStore,
  conversation_id: String,
  messages: List(Message),
) -> Result(TurnResult, TurnError) {
  // Call the provider with the assembled messages
  case provider(messages, []) {
    Error(e) ->
      Error(TurnError(format_ai_error(e)))
    Ok(result) -> {
      // Checkpoint the LLM response
      let response_idx = list.length(messages)
      let _ = agent_checkpoint.save_message(cp, response_idx, result.message)

      // Build the full message log
      let full_messages = list.append(messages, [result.message])

      // Save conversation to store
      save_conversation(store, conversation_id, full_messages)

      Ok(TurnResult(
        messages: full_messages,
        final_message: result.message,
      ))
    }
  }
}

fn save_conversation(
  store: ConversationStore,
  conversation_id: String,
  messages: List(Message),
) -> Nil {
  let json_str = agent_checkpoint.messages_to_json_string(messages)
  let _ = conversation.save(store, conversation_id, json_str)
  Nil
}

fn format_ai_error(e: AiError) -> String {
  case e {
    ApiError(message:) -> "LLM API error: " <> message
    RateLimited -> "LLM rate limited"
    Timeout -> "LLM timeout"
    InvalidResponse(detail:) -> "LLM invalid response: " <> detail
  }
}

// ── Internal helpers ─────────────────────────────────────────────────

import gleam/list

fn gleam_list_last(lst: List(a)) -> Result(a, Nil) {
  list.last(lst)
}
