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
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
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
  // Write to yard_events. Fire-and-forget — a write failure logs but
  // does not crash the consumer (events are best-effort observability).
  case pg_events.record_event(db: state.db, event:) {
    Ok(_) -> actor.continue(state)
    Error(_) -> {
      // Log and continue — don't crash the observability pipeline
      actor.continue(state)
    }
  }
}
