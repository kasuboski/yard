//// Agent turn handler — runs one Pig agent turn with conversation persistence.
////
//// This is the convergence point between yard's durability primitives and
//// pig's own agent loop. Instead of reimplementing the provider call, entry
//// point resolution, and tool execution (the old skeleton approach), this
//// delegates entirely to pig:
////
////   1. Load conversation history from ConversationStore
////   2. Build a pig agent seeded with that history
////   3. Run the agent via pig.run() (normal turn) or pig.run_continue()
////      (crash recovery — resume from checkpointed messages)
////   4. Save the updated conversation back to the store
////
//// pig's `resume_from_history()` (agent/runtime.gleam) implements the full
//// entry-point resolution: ToolUse → execute tools, Stop → return cached,
//// Length/Error → re-call provider. We don't need to reimplement it.

import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError}
import gleam/result
import logging
import pig
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import pig/tool
import yard/agent_checkpoint
import yard/conversation.{type ConversationStore}

/// Result of executing an agent turn.
pub type TurnResult {
  TurnResult(messages: List(Message), final_message: Message)
}

/// Error from a turn execution.
pub type TurnError {
  TurnError(String)
}

/// Execute one agent turn using pig with conversation persistence.
///
/// This ties together the ConversationStore (yard's persistence) with
/// pig's agent loop. It:
///
/// 1. Loads conversation history from the store
/// 2. Appends the user message
/// 3. Builds a pig agent seeded with the full history
/// 4. Runs the agent via `pig.run_continue()` — pig's resume logic
///    detects the User message as the last entry and calls the provider
/// 5. Saves the updated conversation (with the assistant response) back
///
/// Parameters:
/// - `conv_store`: Yard's conversation store (PostgreSQL-backed)
/// - `conversation_id`: UUID for this conversation
/// - `user_message`: The new user message
/// - `provider`: LLM provider function
/// - `tools`: Registered tools (chute_exec, etc.)
/// - `system_prompt`: System prompt for the agent
/// - `agent_name`: Agent identifier
pub fn execute_turn(
  conv_store store: ConversationStore,
  conversation_id conversation_id: String,
  user_message user_message: String,
  provider provider: Provider,
  tools tools: List(tool.Tool),
  system_prompt system_prompt: String,
  agent_name agent_name: String,
  run_timeout_ms run_timeout_ms: Int,
) -> Result(TurnResult, TurnError) {
  // 1. Load conversation history from the store
  use history_option <- result.try(
    conversation.load(store, conversation_id)
    |> result.map_error(fn(_) {
      TurnError("failed to load conversation history")
    }),
  )

  let conv_history = case history_option {
    option.Some(json_str) ->
      agent_checkpoint.messages_from_json_string(json_str)
    option.None -> []
  }

  // 2. Append the user message
  let messages = list.append(conv_history, [message.User(user_message)])

  // 3. Build a pig agent seeded with the full history
  let pig_config =
    pig.new(provider)
    |> pig.with_agent_name(agent_name)
    |> pig.with_system_prompt(system_prompt)
    |> pig.with_tools(tools)

  let pig_config = pig.with_initial_history(pig_config, messages)

  case pig.start(pig_config) {
    Error(e) ->
      Error(TurnError("failed to start agent: " <> format_start_error(e)))
    Ok(agent) -> {
      // 4. Run the agent — pig.run_continue() detects the trailing User
      //    message and calls the provider. On crash recovery, it detects
      //    the last message type and resumes appropriately.
      case pig.run_continue_with_timeout(agent, run_timeout_ms) {
        Ok(final_message) -> {
          // 5. Get the full message history (including intermediate tool calls/results)
          let all_messages = pig.history(agent)
          // 6. Save the updated conversation
          let json_str = agent_checkpoint.messages_to_json_string(all_messages)
          case conversation.save(store, conversation_id, json_str) {
            Ok(_) -> Nil
            Error(_) ->
              logging.log(
                logging.Error,
                "agent_turn: failed to save conversation",
              )
          }
          pig.stop(agent)
          Ok(TurnResult(messages: all_messages, final_message:))
        }
        Error(e) -> {
          pig.stop(agent)
          Error(TurnError(format_ai_error(e)))
        }
      }
    }
  }
}

fn format_ai_error(e: AiError) -> String {
  case e {
    error.ApiError(message:) -> "LLM API error: " <> message
    error.InvalidResponse(detail:) -> "invalid LLM response: " <> detail
    error.RateLimited -> "rate limited"
    error.Timeout -> "LLM call timed out"
  }
}

fn format_start_error(e: StartError) -> String {
  case e {
    actor.InitTimeout -> "init timeout"
    actor.InitFailed(msg) -> msg
    actor.InitExited(_reason) -> "init exited"
  }
}
