//// Runner tests — core effect loop with observability.

import ballast/value.{GasExhausted, IntVal, NilVal, RuntimeError, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import yard/loader
import yard/obs/events.{
  type HostEvent, ActorCompleted, ActorStarted, EffectHandled, EffectYielded,
}
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}

pub fn main() {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────────

fn drain_events(
  subject: process.Subject(HostEvent),
  acc: List(HostEvent),
) -> List(HostEvent) {
  case process.receive(subject, 1) {
    Ok(event) -> drain_events(subject, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn test_emitter(subject: process.Subject(HostEvent)) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) { process.send(subject, event) }
}

fn make_config(
  source: String,
  handlers: dict.Dict(String, EffectHandler),
  emit: fn(HostEvent) -> Nil,
) -> RunConfig {
  let assert Ok(actor) = loader.load(source, "test.chute")
  RunConfig(
    program: actor.program,
    env: NilVal,
    gas: 10_000,
    handlers:,
    emit:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id: "r_test",
    trigger_type: "test",
    trigger_source: "runner_test",
    depth: 0,
  )
}

// ── Tests: Pure Programs ─────────────────────────────────────────────

pub fn pure_program_returns_value_test() {
  let subject = process.new_subject()
  let config =
    make_config(
      "pub fn main() -> Int { 1 + 2 }",
      dict.new(),
      test_emitter(subject),
    )

  let assert Ok(IntVal(3)) = runner.run(config)

  let events = drain_events(subject, [])
  let assert 2 = list.length(events)
  let assert [ActorStarted(..), ActorCompleted(result: "3", ..)] = events
}

pub fn pure_program_returns_string_test() {
  let subject = process.new_subject()
  let config =
    make_config(
      "pub fn main() -> String { \"hello\" }",
      dict.new(),
      test_emitter(subject),
    )

  let assert Ok(StringVal("hello")) = runner.run(config)
  let events = drain_events(subject, [])
  let assert [ActorStarted(..), ActorCompleted(..)] = events
}

pub fn pure_program_returns_nil_test() {
  let subject = process.new_subject()
  let config =
    make_config("pub fn main() -> Nil { }", dict.new(), test_emitter(subject))

  let assert Ok(NilVal) = runner.run(config)
}

// ── Tests: Single Effect ─────────────────────────────────────────────

pub fn single_effect_test() {
  let subject = process.new_subject()
  let greet_handler: EffectHandler = fn(_name, args) {
    case args {
      [StringVal(name)] -> Ok(StringVal("Hello, " <> name <> "!"))
      _ -> Error(RuntimeError("Invalid args for greet"))
    }
  }

  let handlers = dict.from_list([#("greet", greet_handler)])
  let config =
    make_config(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      handlers,
      test_emitter(subject),
    )

  let assert Ok(StringVal("Hello, world!")) = runner.run(config)

  let events = drain_events(subject, [])
  let assert 4 = list.length(events)
  let assert [
    ActorStarted(run_id: "r_test", trigger_type: "test", ..),
    EffectYielded(effect_name: "greet", ..),
    EffectHandled(effect_name: "greet", ..),
    ActorCompleted(effects_performed: 1, ..),
  ] = events
}

// ── Tests: Multiple Effects ──────────────────────────────────────────

pub fn multiple_effects_test() {
  let subject = process.new_subject()
  let greet_handler: EffectHandler = fn(_, _) { Ok(StringVal("Hello")) }
  let count_handler: EffectHandler = fn(_, _) { Ok(NilVal) }

  let handlers =
    dict.from_list([
      #("greet", greet_handler),
      #("count", count_handler),
    ])

  let config =
    make_config(
      "effect greet(name: String) -> String
       effect count(n: Int) -> Nil
       pub fn main() -> String {
         let name = perform greet(\"world\")
         let _ = perform count(42)
         name
       }",
      handlers,
      test_emitter(subject),
    )

  let assert Ok(StringVal("Hello")) = runner.run(config)

  let events = drain_events(subject, [])
  let assert 6 = list.length(events)
  let assert [
    ActorStarted(..),
    EffectYielded(effect_name: "greet", ..),
    EffectHandled(effect_name: "greet", ..),
    EffectYielded(effect_name: "count", ..),
    EffectHandled(effect_name: "count", ..),
    ActorCompleted(effects_performed: 2, ..),
  ] = events
}

// ── Tests: Unknown Effect ────────────────────────────────────────────

pub fn unknown_effect_returns_error_test() {
  let subject = process.new_subject()
  let config =
    make_config(
      "effect unknown(x: String) -> String
       pub fn main() -> String { perform unknown(\"test\") }",
      dict.new(),
      test_emitter(subject),
    )

  let assert Error(RuntimeError("Unknown effect: unknown")) = runner.run(config)

  let events = drain_events(subject, [])
  // Started, Yielded (the effect WAS yielded before we discover it's unknown), Completed
  let assert 3 = list.length(events)
  let assert [
    ActorStarted(..),
    EffectYielded(effect_name: "unknown", ..),
    ActorCompleted(result: "Error(Runtime error: Unknown effect: unknown)", ..),
  ] = events
}

// ── Tests: Handler Error ─────────────────────────────────────────────

pub fn handler_error_propagates_test() {
  let subject = process.new_subject()
  let failing_handler: EffectHandler = fn(_, _) {
    Error(RuntimeError("Handler failed"))
  }

  let handlers = dict.from_list([#("boom", failing_handler)])
  let config =
    make_config(
      "effect boom() -> String
       pub fn main() -> String { perform boom() }",
      handlers,
      test_emitter(subject),
    )

  let assert Error(RuntimeError("Handler failed")) = runner.run(config)

  let events = drain_events(subject, [])
  let assert 3 = list.length(events)
  let assert [
    ActorStarted(..),
    EffectYielded(effect_name: "boom", ..),
    ActorCompleted(result: "Error(Runtime error: Handler failed)", ..),
  ] = events
}

// ── Tests: Gas Exhaustion ────────────────────────────────────────────

pub fn gas_exhaustion_test() {
  let subject = process.new_subject()
  let assert Ok(actor) =
    loader.load("pub fn main() -> Int { 1 + 2 }", "gas.chute")

  let config =
    RunConfig(
      program: actor.program,
      env: NilVal,
      gas: 1,
      handlers: dict.new(),
      emit: test_emitter(subject),
      actor_path: actor.actor_path,
      actor_hash: actor.actor_hash,
      run_id: "r_test",
      trigger_type: "test",
      trigger_source: "runner_test",
      depth: 0,
    )

  let assert Error(GasExhausted) = runner.run(config)

  let events = drain_events(subject, [])
  let assert 2 = list.length(events)
  let assert [ActorStarted(..), ActorCompleted(..)] = events
}

// ── Tests: Event Identity ────────────────────────────────────────────

pub fn events_carry_actor_identity_test() {
  let subject = process.new_subject()
  let config =
    make_config(
      "pub fn main() -> Int { 42 }",
      dict.new(),
      test_emitter(subject),
    )

  let assert Ok(IntVal(42)) = runner.run(config)

  let events = drain_events(subject, [])
  let assert [
    ActorStarted(
      actor_path: "test.chute",
      actor_hash: hash1,
      run_id: "r_test",
      depth: 0,
      ..,
    ),
    ActorCompleted(
      actor_path: "test.chute",
      actor_hash: hash2,
      run_id: "r_test",
      ..,
    ),
  ] = events
  let assert True = hash1 == hash2
  let assert True = string.length(hash1) == 8
}

pub fn events_carry_trigger_metadata_test() {
  let subject = process.new_subject()
  let config =
    make_config(
      "pub fn main() -> Int { 42 }",
      dict.new(),
      test_emitter(subject),
    )

  let assert Ok(_) = runner.run(config)

  let events = drain_events(subject, [])
  let assert [
    ActorStarted(trigger_type: "test", trigger_source: "runner_test", ..),
    ..
  ] = events
}

// ── Tests: Effect with arguments ─────────────────────────────────────

pub fn effect_args_in_events_test() {
  let subject = process.new_subject()
  let add_handler: EffectHandler = fn(_, args) {
    case args {
      [IntVal(a), IntVal(b)] -> Ok(IntVal(a + b))
      _ -> Error(RuntimeError("Invalid args"))
    }
  }

  let handlers = dict.from_list([#("add", add_handler)])
  let config =
    make_config(
      "effect add(a: Int, b: Int) -> Int
       pub fn main() -> Int { perform add(3, 4) }",
      handlers,
      test_emitter(subject),
    )

  let assert Ok(IntVal(7)) = runner.run(config)

  let events = drain_events(subject, [])
  let assert [
    ActorStarted(..),
    EffectYielded(args_summary: "3, 4", ..),
    EffectHandled(result_summary: "7", ..),
    ActorCompleted(..),
  ] = events
}
