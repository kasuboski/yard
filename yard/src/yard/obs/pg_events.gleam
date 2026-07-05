//// PostgreSQL event store consumer — receives HostEvents from the
//// dispatcher and writes them to the yard_events table.
////
//// This is the production replacement for the JSONL session writer.
//// Follows the same consumer pattern as obs/terminal.gleam and
//// obs/session.gleam: an OTP actor that accepts HostEvent directly.
////
//// Usage:
////   let assert Ok(consumer) = pg_events.start_consumer(db)
////   process.send(dispatcher, dispatcher.RegisterConsumer(consumer))

import birl
import gabsurd/client.{type Db}
import gleam/erlang/process.{type Name, type Subject, spawn_unlinked}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import logging
import yard/obs/events.{type HostEvent}
import yard/pg_events

// ── State ────────────────────────────────────────────────────────────

type State {
  State(db: Db)
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a pg_events consumer actor that writes HostEvents to yard_events.
/// Returns the Subject for registration with the dispatcher.
pub fn start_consumer(db: Db) -> Result(Subject(HostEvent), StartError) {
  let builder =
    actor.new(State(db:))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised pg_events consumer actor for use in a supervision tree.
pub fn supervised(
  db: Db,
  name: Name(HostEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(db:))
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

// ── Actor Implementation ─────────────────────────────────────────────

fn handle_message(
  state: State,
  event: HostEvent,
) -> actor.Next(State, HostEvent) {
  // Capture the timestamp BEFORE the async write so it reflects event-arrival
  // order (this consumer processes messages strictly in order), not
  // insert-completion order. The write itself runs fire-and-forget in an
  // unlinked process: a pool crash (e.g. `pgo_pool:checkout` exiting with
  // `noproc` during teardown, or any other exit raised inside `client.exec`)
  // dies there and never propagates back to crash this consumer. Pig emits
  // late events after the caller stops the agent, so the consumer must
  // survive writes against a pool that is already torn down.
  let db = state.db
  let created_at = birl.to_iso8601(birl.utc_now())
  process.spawn_unlinked(fn() {
    case pg_events.record_event_at(db:, event:, created_at:) {
      Ok(_) -> Nil
      Error(_) ->
        // Log and continue — don't crash the observability pipeline
        logging.log(
          logging.Error,
          "pg_events: failed to write event to yard_events",
        )
    }
  })
  actor.continue(state)
}
