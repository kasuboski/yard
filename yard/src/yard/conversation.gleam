//// Conversation store — persistence for multi-turn message logs.
////
//// From DURABLE.md Component 3: each conversation has a full message log
//// persisted as a JSON array. Updated only on task completion.
//// On retry, checkpoints (per-task) are ahead of this table.
////
//// In production, this is backed by a PostgreSQL `conversations` table.
//// For testing, `in_memory()` provides a process-based implementation.

import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor

/// Error type for conversation operations.
pub type ConversationError {
  ConversationError(String)
}

/// A conversation store — abstracts load/save of message logs.
///
/// Messages are stored as JSON strings (the serialized List(Message)).
/// Production wires this to a PostgreSQL conversations table.
pub type ConversationStore {
  ConversationStore(
    load: fn(String) -> Result(Option(String), ConversationError),
    save: fn(String, String) -> Result(Nil, ConversationError),
  )
}

// ── Internal: actor messages ─────────────────────────────────────────

type Msg {
  Load(String, process.Subject(Result(Option(String), Nil)))
  Save(String, String, process.Subject(Result(Nil, Nil)))
}

/// Create an in-memory conversation store for testing.
pub fn in_memory() -> ConversationStore {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(state, msg) {
      case msg {
        Load(id, reply_to) -> {
          let result = case dict.get(state, id) {
            Ok(v) -> option.Some(v)
            Error(Nil) -> option.None
          }
          process.send(reply_to, Ok(result))
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

  ConversationStore(
    load: fn(id: String) {
      let reply = process.new_subject()
      process.send(subject, Load(id, reply))
      let assert Ok(Ok(result)) = process.receive(reply, 5000)
      Ok(result)
    },
    save: fn(id: String, messages: String) {
      let reply = process.new_subject()
      process.send(subject, Save(id, messages, reply))
      let assert Ok(Ok(Nil)) = process.receive(reply, 5000)
      Ok(Nil)
    },
  )
}

/// Load a conversation's message log.
/// Returns `Ok(Some(json))` if found, `Ok(None)` if not.
pub fn load(
  store: ConversationStore,
  conversation_id: String,
) -> Result(Option(String), ConversationError) {
  store.load(conversation_id)
}

/// Save a conversation's message log (replaces previous).
pub fn save(
  store: ConversationStore,
  conversation_id: String,
  messages_json: String,
) -> Result(Nil, ConversationError) {
  store.save(conversation_id, messages_json)
}
