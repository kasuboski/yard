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
  // Fire-and-forget: run the write in an unlinked process so a pool crash
  // (e.g. `pgo_pool:checkout` exiting with `noproc` during teardown, or any
  // other exit raised inside `client.exec`) dies there and never propagates
  // back to crash this consumer. Observability is best-effort — a write that
  // fails or crashes is silently dropped. Late events may arrive after the
  // caller's pool is torn down, so the consumer must survive such writes.
  let db = state.db
  process.spawn_unlinked(fn() {
    case pg_events.record_event(db:, event:) {
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
