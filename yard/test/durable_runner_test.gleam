//// Durable runner tests — checkpoint integration in the runner.
////
//// Tests that effect results are checkpointed, and that replay feeds
//// stored results instead of calling handlers.
//// From DURABLE.md Component 1: Ballast Effect Checkpointing.

import ballast/value.{IntVal, NilVal, RuntimeError, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleeunit
import yard/checkpoint
import yard/loader
import yard/obs/events.{
  type HostEvent, ActorCompleted, ActorStarted, EffectHandled, EffectYielded,
  EffectReplayed,
}
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}
import yard/value_codec

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
  checkpointer: option.Option(checkpoint.Checkpointer),
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
    trigger_source: "durable_test",
    depth: 0,
    checkpointer:,
  )
}


// ── Tests: Checkpointing ─────────────────────────────────────────────

/// After a run with a checkpointer, each effect result is checkpointed.
pub fn effect_results_are_checkpointed_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  let greet_handler: EffectHandler = fn(_, args) {
    case args {
      [StringVal(name)] -> Ok(StringVal("Hello, " <> name <> "!"))
      _ -> Error(RuntimeError("bad args"))
    }
  }

  let config =
    make_config(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      dict.from_list([#("greet", greet_handler)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Ok(StringVal("Hello, world!")) = runner.run(config)

  // Checkpoint "0:greet" should contain the serialized handler result
  let assert Ok(option.Some(json_str)) = checkpoint.load(cp, "0:greet")
  let assert Ok(StringVal("Hello, world!")) = value_codec.from_json(json_str)
}

/// Multiple effects each get their own checkpoint.
pub fn multiple_effects_checkpointed_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  let h1: EffectHandler = fn(_, _) { Ok(StringVal("first")) }
  let h2: EffectHandler = fn(_, _) { Ok(IntVal(42)) }

  let config =
    make_config(
      "effect first() -> String
       effect second() -> Int
       pub fn main() -> Int {
         let _ = perform first()
         perform second()
       }",
      dict.from_list([#("first", h1), #("second", h2)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Ok(IntVal(42)) = runner.run(config)

  let assert Ok(option.Some(json1)) = checkpoint.load(cp, "0:first")
  let assert Ok(StringVal("first")) = value_codec.from_json(json1)

  let assert Ok(option.Some(json2)) = checkpoint.load(cp, "1:second")
  let assert Ok(IntVal(42)) = value_codec.from_json(json2)
}

// ── Tests: Replay ────────────────────────────────────────────────────

/// On replay, stored checkpoints are fed to Ballast instead of calling handlers.
/// Handlers should NOT be called at all.
pub fn replay_skips_handler_calls_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  // Pre-populate checkpoint as if a previous attempt ran
  let _ =
    checkpoint.save(
      cp,
      "0:greet",
      json.to_string(value_codec.encode(StringVal("replayed!"))),
    )

  // Handler that panics if called — proves it's never invoked during replay
  let handler: EffectHandler = fn(_, _) {
    panic as "handler should NOT be called during replay"
  }

  let config =
    make_config(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Ok(StringVal("replayed!")) = runner.run(config)
}

/// Replay emits EffectReplayed events instead of EffectYielded/EffectHandled.
pub fn replay_emits_effect_replayed_events_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  let _ =
    checkpoint.save(
      cp,
      "0:greet",
      json.to_string(value_codec.encode(StringVal("cached"))),
    )

  let handler: EffectHandler = fn(_, _) {
    panic as "should not be called"
  }

  let config =
    make_config(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Ok(_) = runner.run(config)

  let events = drain_events(subject, [])
  // Should see: ActorStarted, EffectReplayed, ActorCompleted
  let assert 3 = list.length(events)
  let assert [ActorStarted(..), EffectReplayed(..), ActorCompleted(..)] = events
}

/// Replay for multi-effect program: first effect replays, second is fresh.
pub fn partial_replay_then_fresh_execution_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  // Pre-populate only the first effect checkpoint
  let _ =
    checkpoint.save(
      cp,
      "0:first",
      json.to_string(value_codec.encode(StringVal("from_checkpoint"))),
    )

  let _call_counter = process.new_subject()

  let h1: EffectHandler = fn(_, _) {
    panic as "first handler should not be called during replay"
  }
  let h2: EffectHandler = fn(_, _) {
    // Signal that we were called
    process.send(subject, events.EffectYielded(
      actor_path: "", actor_hash: "", run_id: "", effect_name: "second_called",
      args_summary: "", depth: 0,
    ))
    Ok(IntVal(99))
  }

  let config =
    make_config(
      "effect first() -> String
       effect second() -> Int
       pub fn main() -> Int {
         let _ = perform first()
         perform second()
       }",
      dict.from_list([#("first", h1), #("second", h2)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Ok(IntVal(99)) = runner.run(config)

  // Second effect should now also be checkpointed
  let assert Ok(option.Some(json2)) = checkpoint.load(cp, "1:second")
  let assert Ok(IntVal(99)) = value_codec.from_json(json2)
}

// ── Tests: No checkpointing without a checkpointer ───────────────────

/// Without a checkpointer, the runner behaves exactly as before.
pub fn no_checkpointer_means_no_durability_test() {
  let subject = process.new_subject()

  let greet_handler: EffectHandler = fn(_, args) {
    case args {
      [StringVal(name)] -> Ok(StringVal("Hello, " <> name <> "!"))
      _ -> Error(RuntimeError("bad args"))
    }
  }

  let config =
    make_config(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      dict.from_list([#("greet", greet_handler)]),
      test_emitter(subject),
      option.None,
    )

  let assert Ok(StringVal("Hello, world!")) = runner.run(config)

  let events = drain_events(subject, [])
  // Normal events: ActorStarted, EffectYielded, EffectHandled, ActorCompleted
  let assert 4 = list.length(events)
  let assert [
    ActorStarted(..),
    EffectYielded(effect_name: "greet", ..),
    EffectHandled(effect_name: "greet", ..),
    ActorCompleted(..),
  ] = events
}

/// Handler errors are NOT checkpointed.
pub fn handler_error_not_checkpointed_test() {
  let subject = process.new_subject()
  let cp = checkpoint.in_memory()

  let failing_handler: EffectHandler = fn(_, _) {
    Error(RuntimeError("handler failed"))
  }

  let config =
    make_config(
      "effect boom() -> String
       pub fn main() -> String { perform boom() }",
      dict.from_list([#("boom", failing_handler)]),
      test_emitter(subject),
      option.Some(cp),
    )

  let assert Error(RuntimeError("handler failed")) = runner.run(config)

  // No checkpoint should exist for the failed handler
  let assert Ok(option.None) = checkpoint.load(cp, "0:boom")
}
