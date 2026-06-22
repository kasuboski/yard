//// Checkpoint store — the durability abstraction for the runner.
////
//// Provides a simple save/load interface for step-level checkpoints.
//// In production, this is backed by gabsurd's PostgreSQL checkpoint API.
//// For testing, `in_memory()` provides a process-based implementation.
////
//// Checkpoint naming convention (from DURABLE.md):
////   "{index}:{effect_name}" — e.g. "0:charge_card", "1:send_email"

import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor

/// Error type for checkpoint operations.
pub type CheckpointError {
  CheckpointError(String)
}

/// A checkpoint store — abstracts save/load of step results.
///
/// The runner uses this to persist effect handler results so they can be
/// replayed on retry. Production wires this to gabsurd's checkpoint API;
/// tests use `in_memory()`.
pub type Checkpointer {
  Checkpointer(
    save: fn(String, String) -> Result(Nil, CheckpointError),
    load: fn(String) -> Result(Option(String), CheckpointError),
  )
}

// ── Internal: actor messages ─────────────────────────────────────────

type Msg {
  Save(String, String, process.Subject(Result(Nil, Nil)))
  Load(String, process.Subject(Result(Option(String), Nil)))
}

/// Create an in-memory checkpointer for testing.
///
/// Uses an OTP actor internally so concurrent access is safe.
/// State is lost when the process terminates.
pub fn in_memory() -> Checkpointer {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(state, msg) {
      case msg {
        Save(step, value, reply_to) -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(dict.insert(state, step, value))
        }
        Load(step, reply_to) -> {
          let result = case dict.get(state, step) {
            Ok(v) -> option.Some(v)
            Error(Nil) -> option.None
          }
          process.send(reply_to, Ok(result))
          actor.continue(state)
        }
      }
    })
    |> actor.start()
  let subject = started.data

  Checkpointer(
    save: fn(step_name: String, json_str: String) {
      let reply = process.new_subject()
      process.send(subject, Save(step_name, json_str, reply))
      let assert Ok(Ok(Nil)) = process.receive(reply, 5000)
      Ok(Nil)
    },
    load: fn(step_name: String) {
      let reply = process.new_subject()
      process.send(subject, Load(step_name, reply))
      let assert Ok(Ok(result)) = process.receive(reply, 5000)
      Ok(result)
    },
  )
}

/// Save a checkpoint for a step.
pub fn save(
  cp: Checkpointer,
  step_name: String,
  json_str: String,
) -> Result(Nil, CheckpointError) {
  cp.save(step_name, json_str)
}

/// Load a checkpoint for a step.
/// Returns `Ok(Some(json))` if found, `Ok(None)` if not found.
pub fn load(
  cp: Checkpointer,
  step_name: String,
) -> Result(Option(String), CheckpointError) {
  cp.load(step_name)
}
