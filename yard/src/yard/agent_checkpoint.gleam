//// Agent checkpoint utilities — entry point resolution and
//// message-log checkpointing for Pig agent durability.
////
//// From DURABLE.md Component 2: The Message-Log Pattern.
//// Each message is checkpointed as "msg:{N}". On retry, the message log
//// is rebuilt from checkpoints. The last message determines what happens next.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/dynamic/decode
import gleam/result
import pig/ai/message.{
  type Message, Assistant, System, Tool, User,
}
import pig/ai/stop_reason
import yard/checkpoint.{type Checkpointer}

/// What the agent loop should do after loading checkpointed messages.
pub type EntryPoint {
  CallLlm
  Done
  RunTools
  Retry
  Fail
}

/// Determine the entry point from the last message in a conversation.
pub fn resolve_entry_point(messages: List(Message)) -> EntryPoint {
  case list.last(messages) {
    Error(Nil) -> CallLlm
    Ok(msg) -> {
      case msg {
        User(_) -> CallLlm
        Tool(_, _) -> CallLlm
        System(_) -> CallLlm
        Assistant(_, _, _, sr) -> {
          case sr {
            option.None -> CallLlm
            option.Some(reason) -> {
              case reason {
                stop_reason.Stop -> Done
                stop_reason.ToolUse -> RunTools
                stop_reason.Length -> Retry
                stop_reason.Error -> Fail
                stop_reason.Unknown(_) -> CallLlm
              }
            }
          }
        }
      }
    }
  }
}

/// Load checkpointed messages from a Checkpointer.
///
/// Walks msg:0, msg:1, msg:2, ... until a checkpoint is missing.
pub fn load_messages(
  cp: Checkpointer,
) -> Result(List(Message), checkpoint.CheckpointError) {
  load_messages_loop(cp, 0, [])
}

fn load_messages_loop(
  cp: Checkpointer,
  index: Int,
  acc: List(Message),
) -> Result(List(Message), checkpoint.CheckpointError) {
  let step_name = "msg:" <> int.to_string(index)
  case checkpoint.load(cp, step_name) {
    Ok(option.Some(json_str)) -> {
      case message_from_json(json_str) {
        Ok(msg) -> load_messages_loop(cp, index + 1, [msg, ..acc])
        Error(_) -> Ok(list.reverse(acc))
      }
    }
    Ok(option.None) -> Ok(list.reverse(acc))
    Error(e) -> Error(e)
  }
}

/// Save a message as checkpoint "msg:{index}".
pub fn save_message(
  cp: Checkpointer,
  index: Int,
  msg: Message,
) -> Result(Nil, checkpoint.CheckpointError) {
  checkpoint.save(cp, "msg:" <> int.to_string(index), message_to_json_string(msg))
}

/// Save all messages as checkpoints msg:0 through msg:N.
pub fn save_messages(
  cp: Checkpointer,
  messages: List(Message),
) -> Result(Nil, checkpoint.CheckpointError) {
  save_messages_loop(cp, messages, 0)
}

fn save_messages_loop(
  cp: Checkpointer,
  messages: List(Message),
  index: Int,
) -> Result(Nil, checkpoint.CheckpointError) {
  case messages {
    [] -> Ok(Nil)
    [msg, ..rest] -> {
      use _ <- result.try(save_message(cp, index, msg))
      save_messages_loop(cp, rest, index + 1)
    }
  }
}

// ── Message serialization ────────────────────────────────────────────

fn message_to_json_string(msg: Message) -> String {
  json.to_string(message_to_json(msg))
}

fn message_from_json(json_str: String) -> Result(Message, Nil) {
  case json.parse(json_str, decode.dynamic) {
    Error(_) -> Error(Nil)
    Ok(parsed) -> {
      case decode.run(parsed, message_decoder()) {
        Ok(msg) -> Ok(msg)
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn message_to_json(msg: Message) -> json.Json {
  case msg {
    User(content) ->
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ])
    System(content) ->
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ])
    Assistant(content, tool_calls, thinking, sr) ->
      json.object([
        #("role", json.string("assistant")),
        #("content", json.string(content)),
        #("tool_calls", json.array(from: tool_calls, of: tool_call_to_json)),
        #(
          "thinking",
          case thinking {
            option.Some(t) -> json.string(t.content)
            option.None -> json.null()
          },
        ),
        #(
          "stop_reason",
          case sr {
            option.Some(r) -> json.string(stop_reason.to_string(r))
            option.None -> json.string("")
          },
        ),
      ])
    Tool(tool_call_id, content) ->
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string(content)),
      ])
  }
}

fn tool_call_to_json(tc: message.ToolCall) -> json.Json {
  json.object([
    #("id", json.string(tc.id)),
    #("name", json.string(tc.name)),
    #("arguments_json", json.string(tc.arguments_json)),
  ])
}

fn message_decoder() -> decode.Decoder(Message) {
  use role <- decode.field("role", decode.string)
  case role {
    "user" -> {
      use content <- decode.field("content", decode.string)
      decode.success(User(content))
    }
    "system" -> {
      use content <- decode.field("content", decode.string)
      decode.success(System(content))
    }
    "assistant" -> {
      use content <- decode.field("content", decode.string)
      use tool_calls <- decode.field(
        "tool_calls",
        decode.list(of: tool_call_decoder()),
      )
      use sr <- decode.field("stop_reason", stop_reason_opt_decoder())
      decode.success(Assistant(content, tool_calls, option.None, sr))
    }
    "tool" -> {
      use tool_call_id <- decode.field("tool_call_id", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(Tool(tool_call_id, content))
    }
    _ -> decode.failure(User("unknown"), "valid role")
  }
}

fn tool_call_decoder() -> decode.Decoder(message.ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use args <- decode.field("arguments_json", decode.string)
  decode.success(message.ToolCall(id:, name:, arguments_json: args))
}

fn stop_reason_opt_decoder() -> decode.Decoder(Option(stop_reason.StopReason)) {
  decode.map(decode.string, fn(raw) {
    case raw {
      "" -> option.None
      _ -> option.Some(stop_reason.from_string(raw))
    }
  })
}
