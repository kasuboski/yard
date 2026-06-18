//// Durable turn — conversation assembly for the agent task handler.
////
//// From DURABLE.md Component 3: Conversation Lifecycle.
////
//// Each user turn creates a new gabsurd task. The worker:
//// 1. Loads conversation history from the ConversationStore (last completed turn)
//// 2. Loads per-task checkpoints from the Checkpointer (current turn progress)
//// 3. If checkpoints exist (retry): checkpoints win, combine with conversation history
//// 4. If no checkpoints (first attempt): append user message, checkpoint it
//// 5. Resolve entry point from the assembled message log

import gleam/option
import gleam/list
import pig/ai/message.{type Message, User}
import yard/agent_checkpoint.{type EntryPoint}
import yard/checkpoint.{type Checkpointer}
import yard/conversation.{type ConversationStore}

/// The result of assembling conversation history for a turn.
pub type AssembledHistory {
  AssembledHistory(
    /// Full message log to seed the Pig agent.
    messages: List(Message),
    /// What the agent loop should do next.
    entry_point: EntryPoint,
    /// True if resuming from checkpoints (retry of a crashed attempt).
    is_retry: Bool,
  )
}

/// Assemble the working message log for a durable agent turn.
///
/// This function implements the "checkpoints ahead of table" logic:
/// - If the Checkpointer has messages from a previous attempt of this task,
///   those are used (they include the user message + any progress made).
/// - If the Checkpointer is empty (first attempt), the user message is
///   appended to the conversation history and checkpointed as msg:0.
///
/// The conversation store provides history from all previous turns.
pub fn assemble_history(
  conv_store store: ConversationStore,
  cp_store cp: Checkpointer,
  conversation_id conversation_id: String,
  user_message user_message: String,
) -> Result(AssembledHistory, AssemblyError) {
  // Load conversation history from the store (previous turns)
  let conv_history = case conversation.load(store, conversation_id) {
    Ok(option.Some(json_str)) ->
      agent_checkpoint.messages_from_json_string(json_str)
    _ -> []
  }

  // Load per-task checkpoints (current turn progress from crashed attempt)
  let cp_messages = case agent_checkpoint.load_messages(cp) {
    Ok(msgs) -> msgs
    Error(_) -> []
  }

  case cp_messages {
    [] -> {
      // First attempt at this turn — append user message and checkpoint it
      let messages = list.append(conv_history, [User(user_message)])
      let _ = agent_checkpoint.save_message(cp, 0, User(user_message))
      Ok(AssembledHistory(
        messages:,
        entry_point: agent_checkpoint.resolve_entry_point(messages),
        is_retry: False,
      ))
    }

    cp_msgs -> {
      // Retry — checkpoints are ahead of conversation table
      let messages = list.append(conv_history, cp_msgs)
      Ok(AssembledHistory(
        messages:,
        entry_point: agent_checkpoint.resolve_entry_point(messages),
        is_retry: True,
      ))
    }
  }
}

/// Error type for turn assembly.
pub type AssemblyError {
  AssemblyError(String)
}

/// Parse a JSON array string into a List(Message).
