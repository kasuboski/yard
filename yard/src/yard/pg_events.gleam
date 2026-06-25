//// PostgreSQL event store — replaces JSONL observability with a
//// queryable yard_events table.
////
//// From DURABLE.md Component 4: Yard's JSONL observability is replaced
//// by a `yard_events` table in PostgreSQL, JOINable with gabsurd's
//// absurd_checkpoints and absurd_runs on run_id.

import gleam/json
import gleam/option
import parrot/dev
import gabsurd/client.{type Db}
import yard/obs/events.{type HostEvent}

/// Record a HostEvent to the yard_events table.
///
/// This is the PostgreSQL equivalent of the JSONL session writer.
/// In production, the dispatcher fans out to both this and any remaining
/// consumers (terminal, telemetry).
pub fn record_event(
  db db: Db,
  event event: HostEvent,
) -> Result(Nil, EventStoreError) {
  let #(event_type, payload, duration_ms) = event_to_parts(event)
  let sql =
    "
    INSERT INTO yard_events (run_id, event_type, payload, duration_ms)
    VALUES ($1::uuid, $2, $3::jsonb, $4)
    "
  let run_id = event_run_id(event)
  case
    client.exec(db, #(
      sql,
      [
        dev.ParamString(run_id),
        dev.ParamString(event_type),
        dev.ParamString(json.to_string(payload)),
        dev.ParamNullable(
          case duration_ms {
            option.Some(ms) -> option.Some(dev.ParamInt(ms))
            option.None -> option.None
          },
        ),
      ],
    ))
  {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(EventStoreError(error_to_string(e)))
  }
}

/// Error type for the event store.
pub type EventStoreError {
  EventStoreError(String)
}

/// Extract event_type, payload JSON, and duration_ms from a HostEvent.
fn event_to_parts(event: HostEvent) -> #(String, json.Json, option.Option(Int)) {
  case event {
    events.ActorStarted(
      actor_path:,
      actor_hash:,
      trigger_type:,
      trigger_source:,
      run_id: _,
      gas:,
      depth:,
    ) -> #(
      "actor_started",
      json.object([
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("trigger_type", json.string(trigger_type)),
        #("trigger_source", json.string(trigger_source)),
        #("gas", json.int(gas)),
        #("depth", json.int(depth)),
      ]),
      option.None,
    )

    events.ActorCompleted(
      actor_path:,
      actor_hash:,
      run_id: _,
      result:,
      gas_used:,
      gas_limit:,
      effects_performed:,
      duration_ms:,
    ) -> #(
      "actor_completed",
      json.object([
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("result", json.string(result)),
        #("gas_used", json.int(gas_used)),
        #("gas_limit", json.int(gas_limit)),
        #("effects_performed", json.int(effects_performed)),
      ]),
      option.Some(duration_ms),
    )

    events.EffectYielded(
      actor_path:,
      actor_hash:,
      run_id: _,
      effect_name:,
      args_summary:,
      depth:,
    ) -> #(
      "effect_yielded",
      json.object([
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("effect_name", json.string(effect_name)),
        #("args_summary", json.string(args_summary)),
        #("depth", json.int(depth)),
      ]),
      option.None,
    )

    events.EffectHandled(
      actor_path:,
      actor_hash:,
      run_id: _,
      effect_name:,
      result_summary:,
      duration_ms:,
      depth:,
    ) -> #(
      "effect_handled",
      json.object([
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("effect_name", json.string(effect_name)),
        #("result_summary", json.string(result_summary)),
        #("depth", json.int(depth)),
      ]),
      option.Some(duration_ms),
    )

    events.EffectReplayed(
      actor_path:,
      actor_hash:,
      run_id: _,
      effect_name:,
      step:,
      depth:,
    ) -> #(
      "effect_replayed",
      json.object([
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("effect_name", json.string(effect_name)),
        #("step", json.int(step)),
        #("depth", json.int(depth)),
      ]),
      option.None,
    )
  }
}

fn event_run_id(event: HostEvent) -> String {
  case event {
    events.ActorStarted(run_id:, ..) -> run_id
    events.ActorCompleted(run_id:, ..) -> run_id
    events.EffectYielded(run_id:, ..) -> run_id
    events.EffectHandled(run_id:, ..) -> run_id
    events.EffectReplayed(run_id:, ..) -> run_id
  }
}

fn error_to_string(e: client.GabsurdError) -> String {
  case e {
    client.QueryError(msg) -> "query: " <> msg
    client.UnexpectedRowCount(msg) -> "row count: " <> msg
    client.NotFound -> "not found"
    client.ConnectionError(msg) -> "connection: " <> msg
  }
}
