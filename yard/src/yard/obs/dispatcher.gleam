//// Shared OTP dispatcher for host observability events.
////
//// The dispatcher is a single OTP actor for the whole system:
//// 1. Receives `Event(HostEvent)` messages
//// 2. Projects to `:telemetry` — always, by construction
//// 3. Fans out the full event to registered consumers (fire-and-forget)
//// 4. Accepts `RegisterConsumer(Subject(HostEvent))` to dynamically add consumers
////
//// All runners emit to this dispatcher. Consumers (session writer, terminal
//// printer) are separate OTP actors that receive a copy of every event.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import yard/obs/events.{type HostEvent, emit_telemetry}

// ── Public Types ─────────────────────────────────────────────────────

/// Messages that the dispatcher actor can receive.
pub type DispatcherMessage {
  /// A host event to dispatch to consumers and telemetry.
  Event(HostEvent)
  /// Register a new consumer to receive host events.
  RegisterConsumer(Subject(HostEvent))
  /// Stop the dispatcher actor (for testing/cleanup).
  Stop
}

// ── Internal Types ───────────────────────────────────────────────────

type State {
  State(consumers: List(Subject(HostEvent)))
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a new dispatcher actor.
pub fn start() -> Result(Subject(DispatcherMessage), StartError) {
  let builder =
    actor.new(State(consumers: []))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised dispatcher actor for use in a supervision tree.
pub fn supervised(
  name: process.Name(DispatcherMessage),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(consumers: []))
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
  msg: DispatcherMessage,
) -> actor.Next(State, DispatcherMessage) {
  case msg {
    Event(event) -> {
      // Always project to telemetry — lightweight, always-on metrics
      emit_telemetry(event)
      // Fan out to all registered consumers (fire-and-forget)
      list.each(state.consumers, fn(consumer) { process.send(consumer, event) })
      actor.continue(state)
    }
    RegisterConsumer(subject) -> {
      actor.continue(State(consumers: [subject, ..state.consumers]))
    }
    Stop -> actor.stop()
  }
}
