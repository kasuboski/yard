//// Emit module tests — bridge between events and dispatcher.

import gleam/erlang/process
import gleam/list
import gleeunit
import yard/obs/dispatcher
import yard/obs/emit
import yard/obs/events.{type HostEvent, ActorStarted}

pub fn main() {
  gleeunit.main()
}

fn drain_events(
  subject: process.Subject(HostEvent),
  acc: List(HostEvent),
) -> List(HostEvent) {
  case process.receive(subject, 10) {
    Ok(event) -> drain_events(subject, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

pub fn emit_to_dispatcher_sends_event_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer = process.new_subject()

  // Register a consumer to capture events
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer))

  // Emit via the bridge module
  let event =
    ActorStarted(
      actor_path: "emit.chute",
      actor_hash: "EMIT1234",
      trigger_type: "test",
      trigger_source: "emit_test",
      run_id: "r_emit",
      gas: 100,
      depth: 0,
    )
  emit.to_dispatcher(dispatcher_subject, event)

  // Consumer should receive it
  let events = drain_events(consumer, [])
  let assert 1 = list.length(events)
  let assert [ActorStarted(run_id: "r_emit", ..)] = events

  process.send(dispatcher_subject, dispatcher.Stop)
}
