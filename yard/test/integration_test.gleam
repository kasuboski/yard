//// Integration test — full yard stack: runner → dispatcher → consumers.
////
//// Tests the complete observability pipeline:
//// runner.emit_to_dispatcher → dispatcher → session writer + terminal

import ballast/value.{IntVal, NilVal, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import simplifile
import yard/loader
import yard/obs/dispatcher
import yard/obs/events.{type HostEvent, ActorCompleted, ActorStarted}
import yard/obs/session
import yard/runner.{type EffectHandler, RunConfig, emit_to_dispatcher}

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

pub fn runner_with_dispatcher_emits_events_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer))

  let assert Ok(actor) =
    loader.load("pub fn main() -> Int { 42 }", "test.chute")

  let config =
    RunConfig(
      program: actor.program,
      env: NilVal,
      gas: 10_000,
      handlers: dict.new(),
      emit: emit_to_dispatcher(dispatcher_subject),
      actor_path: actor.actor_path,
      actor_hash: actor.actor_hash,
      run_id: "r_integration",
      trigger_type: "test",
      trigger_source: "integration_test",
      depth: 0,
    checkpointer: option.None,
    )

  let assert Ok(IntVal(42)) = runner.run(config)

  let events = drain_events(consumer, [])
  let assert 2 = list.length(events)
  let assert [
    ActorStarted(run_id: "r_integration", ..),
    ActorCompleted(result: "42", run_id: "r_integration", ..),
  ] = events

  process.send(dispatcher_subject, dispatcher.Stop)
}

pub fn runner_with_effect_and_session_writer_test() {
  let path = "/tmp/yard_integration_" <> session.iso_timestamp() <> ".jsonl"

  let assert Ok(dispatcher_subject) = dispatcher.start()
  let assert Ok(consumer_subject) = session.start_consumer(path)

  // Register session writer as a consumer of the dispatcher
  process.send(
    dispatcher_subject,
    dispatcher.RegisterConsumer(consumer_subject),
  )

  let greet_handler: EffectHandler = fn(_, _) { Ok(StringVal("Hi")) }
  let handlers = dict.from_list([#("greet", greet_handler)])

  let assert Ok(actor) =
    loader.load(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      "greet.chute",
    )

  let config =
    RunConfig(
      program: actor.program,
      env: NilVal,
      gas: 10_000,
      handlers:,
      emit: emit_to_dispatcher(dispatcher_subject),
      actor_path: actor.actor_path,
      actor_hash: actor.actor_hash,
      run_id: "r_session",
      trigger_type: "test",
      trigger_source: "session_test",
      depth: 0,
    checkpointer: option.None,
    )

  let assert Ok(StringVal("Hi")) = runner.run(config)

  // Give the session writer time to flush
  process.sleep(50)

  // Read the JSONL file back
  let assert Ok(content) = simplifile.read(path)
  let lines =
    content
    |> string.split("\n")
    |> list.filter(fn(l) { l != "" })

  // Should have 4 lines: Started, Yielded, Handled, Completed
  let assert 4 = list.length(lines)

  // Each line should be valid JSON with the right event types
  let assert [line0, line1, line2, line3] = lines
  let assert True = string.contains(line0, "actor_started")
  let assert True = string.contains(line1, "effect_yielded")
  let assert True = string.contains(line2, "effect_handled")
  let assert True = string.contains(line3, "actor_completed")

  // All lines should carry the same run_id
  list.each(lines, fn(line) {
    let assert True = string.contains(line, "\"run_id\":\"r_session\"")
  })

  process.send(dispatcher_subject, dispatcher.Stop)
}
