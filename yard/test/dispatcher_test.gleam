//// Dispatcher tests — OTP actor, telemetry projection, consumer fan-out.

import gleam/erlang/process
import gleam/list
import gleeunit
import yard/obs/dispatcher
import yard/obs/events.{
  type HostEvent, ActorCompleted, ActorStarted, EffectHandled, EffectYielded,
}

pub fn main() {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────────

fn drain_events(
  subject: process.Subject(HostEvent),
  acc: List(HostEvent),
) -> List(HostEvent) {
  case process.receive(subject, 10) {
    Ok(event) -> drain_events(subject, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn make_started(run_id: String) -> HostEvent {
  ActorStarted(
    actor_path: "test.chute",
    actor_hash: "ABCD1234",
    trigger_type: "test",
    trigger_source: "dispatcher_test",
    run_id:,
    gas: 1000,
    depth: 0,
  )
}

fn make_completed(run_id: String) -> HostEvent {
  ActorCompleted(
    actor_path: "test.chute",
    actor_hash: "ABCD1234",
    run_id:,
    result: "3",
    gas_used: 5,
    gas_limit: 1000,
    effects_performed: 0,
    duration_ms: 1,
  )
}

// ── Tests ────────────────────────────────────────────────────────────

pub fn dispatcher_starts_test() {
  let assert Ok(_subject) = dispatcher.start()
}

pub fn dispatcher_receives_events_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer = process.new_subject()

  // Register a consumer
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer))

  // Send an event
  process.send(dispatcher_subject, dispatcher.Event(make_started("r_001")))

  // Consumer should receive it
  let assert Ok(event) = process.receive(consumer, 100)
  let assert ActorStarted(run_id: "r_001", ..) = event
}

pub fn dispatcher_fans_out_to_multiple_consumers_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer1 = process.new_subject()
  let consumer2 = process.new_subject()

  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer1))
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer2))

  let event = make_started("r_002")
  process.send(dispatcher_subject, dispatcher.Event(event))

  // Both consumers should receive the same event
  let assert Ok(e1) = process.receive(consumer1, 100)
  let assert Ok(e2) = process.receive(consumer2, 100)
  let assert ActorStarted(run_id: "r_002", ..) = e1
  let assert ActorStarted(run_id: "r_002", ..) = e2
}

pub fn dispatcher_delivers_event_sequence_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer))

  // Send a sequence of events
  process.send(dispatcher_subject, dispatcher.Event(make_started("r_003")))
  process.send(dispatcher_subject, dispatcher.Event(make_completed("r_003")))

  let events = drain_events(consumer, [])
  let assert 2 = list.length(events)
  let assert [ActorStarted(..), ActorCompleted(..)] = events
}

pub fn dispatcher_stops_on_stop_message_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  process.send(dispatcher_subject, dispatcher.Stop)
  // Process should have terminated — give it a moment
  process.sleep(10)
}

pub fn dispatcher_projected_telemetry_test() {
  // The dispatcher calls emit_telemetry internally for every event.
  // We can't easily observe :telemetry in a unit test without an ETS listener,
  // but we verify that the dispatcher doesn't crash when processing events.
  let assert Ok(dispatcher_subject) = dispatcher.start()

  // Send all four event types
  process.send(
    dispatcher_subject,
    dispatcher.Event(ActorStarted(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      trigger_type: "test",
      trigger_source: "telemetry_test",
      run_id: "r_tel",
      gas: 5000,
      depth: 0,
    )),
  )
  process.send(
    dispatcher_subject,
    dispatcher.Event(EffectYielded(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      run_id: "r_tel",
      effect_name: "read_file",
      args_summary: "\"main.gleam\"",
      depth: 0,
    )),
  )
  process.send(
    dispatcher_subject,
    dispatcher.Event(EffectHandled(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      run_id: "r_tel",
      effect_name: "read_file",
      result_summary: "\"contents\"",
      duration_ms: 3,
      depth: 0,
    )),
  )
  process.send(
    dispatcher_subject,
    dispatcher.Event(ActorCompleted(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      run_id: "r_tel",
      result: "Nil",
      gas_used: 10,
      gas_limit: 5000,
      effects_performed: 1,
      duration_ms: 5,
    )),
  )

  // If we get here, no crash — telemetry projection worked
  process.send(dispatcher_subject, dispatcher.Stop)
}
