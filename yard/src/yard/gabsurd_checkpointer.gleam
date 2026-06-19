//// Gabsurd checkpointer adapter — bridges yard's Checkpointer
//// abstraction to gabsurd's PostgreSQL-backed checkpoint API.
////
//// This module is the production wiring. The runner uses a Checkpointer
//// interface (yard/checkpoint.gleam) which abstracts save/load of
//// step-level checkpoints. For testing, `checkpoint.in_memory()` is used.
//// In production, `gabsurd_checkpointer.from_context(ctx)` creates a
//// Checkpointer backed by gabsurd's checkpoint table.
////
//// The gabsurd checkpoint API stores `json.Json` values (serialized via
//// `json.to_string`). To store a raw JSON string from the runner:
////   - save: wrap with `json.string(json_str)` (double-encodes as a JSON string)
////   - load: decode with `json.parse(cp.state, decode.string)` (recovers original)

import gleam/dynamic/decode
import gleam/json
import gleam/option
import gabsurd/checkpoint as gabsurd_cp
import gabsurd/client.{
  type Db, type GabsurdError, ConnectionError, NotFound, QueryError,
  UnexpectedRowCount,
}
import gabsurd/context.{type Context}
import yard/checkpoint.{type Checkpointer, CheckpointError}

/// Create a Checkpointer from a gabsurd execution context.
///
/// The context provides the DB connection, queue name, task ID, run ID,
/// and claim timeout needed for checkpoint operations.
pub fn from_context(ctx: Context) -> Checkpointer {
  from_parts(
    ctx.db,
    ctx.queue_name,
    context.task_id(ctx),
    context.run_id(ctx),
    context.claim_timeout(ctx),
  )
}

/// Create a Checkpointer from individual gabsurd parts.
///
/// Use this when you have the raw components but not a full Context.
pub fn from_parts(
  db db: Db,
  queue_name queue_name: String,
  task_id task_id: BitArray,
  run_id run_id: BitArray,
  claim_timeout claim_timeout: Int,
) -> Checkpointer {
  checkpoint.Checkpointer(
    save: fn(step_name: String, json_str: String) {
      // Wrap the JSON string as a JSON string value so it round-trips
      // through gabsurd's json.to_string serialization.
      case
        gabsurd_cp.set(
          db,
          queue_name,
          task_id,
          step_name,
          json.string(json_str),
          run_id,
          claim_timeout,
        )
      {
        Ok(Nil) -> Ok(Nil)
        Error(e) -> Error(CheckpointError(format_error(e)))
      }
    },
    load: fn(step_name: String) {
      case gabsurd_cp.get(db, queue_name, task_id, step_name, False) {
        Ok(option.Some(cp)) -> {
          // cp.state is the JSON-encoded string. Decode it back.
          case json.parse(cp.state, decode.string) {
            Ok(original) -> Ok(option.Some(original))
            Error(_) ->
              Error(CheckpointError("corrupt checkpoint: " <> cp.state))
          }
        }
        Ok(option.None) -> Ok(option.None)
        Error(e) -> Error(CheckpointError(format_error(e)))
      }
    },
  )
}

fn format_error(e: GabsurdError) -> String {
  case e {
    QueryError(msg) -> "gabsurd query error: " <> msg
    UnexpectedRowCount(msg) -> "gabsurd row count: " <> msg
    NotFound -> "gabsurd: not found"
    ConnectionError(msg) -> "gabsurd connection: " <> msg
  }
}
