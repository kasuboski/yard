//// Durability — replay-or-record of effect results across retries.
////
//// This is the seam between the Runner and the persistence layer. The Runner
//// calls `lookup`/`record` keyed by step index + effect name. The store owns
//// the key scheme ("{step}:{effect}") and the Value↔JSON codec.
////
//// Error policy (ADR-0001): lookup is best-effort (an optimisation: skip
//// work); record is a guarantee (this Run is resumable). A record failure
//// surfaces; a lookup failure falls through to fresh execution.

import ballast/value.{type Value}
import gleam/int
import gleam/json
import gleam/option.{type Option}
import yard/checkpoint.{type Checkpointer}
import yard/value_codec

pub type DurabilityError {
  DurabilityError(String)
}

/// Replay-or-record store for effect results.
///
/// The Runner calls `lookup` before running a handler (replay path) and
/// `record` after a handler succeeds (persist for future replay).
/// The key scheme and serialisation are internal to the store.
pub type DurableStore {
  DurableStore(
    /// Ok(Some(v)) → replay this step, skip the handler.
    /// Ok(None) → nothing stored, run the handler fresh.
    /// Error(_) → store unreadable; fall through to fresh (best-effort).
    lookup: fn(Int, String) -> Result(Option(Value), DurabilityError),
    /// Persist a handler result so a later retry can replay it.
    /// Error surfaces — see ADR-0001.
    record: fn(Int, String, Value) -> Result(Nil, DurabilityError),
  )
}

/// Wrap a stringly-keyed Checkpointer with the effect keyspace + codec.
pub fn from_checkpointer(cp: Checkpointer) -> DurableStore {
  DurableStore(
    lookup: fn(step, effect_name) {
      case checkpoint.load(cp, key(step, effect_name)) {
        Ok(option.Some(json_str)) ->
          case value_codec.from_json(json_str) {
            Ok(v) -> Ok(option.Some(v))
            Error(_) -> Ok(option.None)
          }
        Ok(option.None) -> Ok(option.None)
        Error(_) -> Ok(option.None)
      }
    },
    record: fn(step, effect_name, result) {
      let json_value = value_codec.encode(result)
      case
        checkpoint.save(cp, key(step, effect_name), json.to_string(json_value))
      {
        Ok(Nil) -> Ok(Nil)
        Error(e) -> Error(DurabilityError(checkpoint_error_to_string(e)))
      }
    },
  )
}

/// No-op store: behaves as if no checkpointer is present.
pub fn none() -> DurableStore {
  DurableStore(lookup: fn(_, _) { Ok(option.None) }, record: fn(_, _, _) {
    Ok(Nil)
  })
}

/// In-memory store for testing.
pub fn in_memory() -> DurableStore {
  from_checkpointer(checkpoint.in_memory())
}

/// Convert a DurabilityError to a display string.
pub fn error_to_string(e: DurabilityError) -> String {
  case e {
    DurabilityError(msg) -> msg
  }
}

fn key(step: Int, effect_name: String) -> String {
  int.to_string(step) <> ":" <> effect_name
}

fn checkpoint_error_to_string(e: checkpoint.CheckpointError) -> String {
  case e {
    checkpoint.CheckpointError(msg) -> msg
  }
}
