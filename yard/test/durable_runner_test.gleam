//// Durable runner tests — durability behavior through the runner.
////
//// Tests verify behavior: replay skips handlers, record failures surface,
//// and the non-durable path works as before. Implementation details (key
//// scheme, codec, store internals) are never asserted on directly.

import ballast/value.{type Value, IntVal, RuntimeError, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/string
import gleeunit
import yard/durability
import yard/loader
import yard/obs/events.{type HostEvent}
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}

pub fn main() {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────────

fn test_emitter(subject: process.Subject(HostEvent)) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) { process.send(subject, event) }
}

fn make_config(
  source: String,
  handlers: dict.Dict(String, EffectHandler),
  emit: fn(HostEvent) -> Nil,
  store: durability.DurableStore,
) -> RunConfig {
  let assert Ok(actor) = loader.load(source, "test.chute")
  RunConfig(
    program: actor.program,
    env: value.NilVal,
    gas: 10_000,
    handlers:,
    emit:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id: "r_test",
    trigger_type: "test",
    trigger_source: "durable_test",
    depth: 0,
    store:,
  )
}

fn greet_program() -> String {
  "effect greet(name: String) -> String
   pub fn main() -> String { perform greet(\"world\") }"
}

fn two_effect_program() -> String {
  "effect first() -> String
   effect second() -> Int
   pub fn main() -> Int {
     let _ = perform first()
     perform second()
   }"
}

// ── Tests: Replay (behavior — survives refactor) ─────────────────────

/// When a store has a checkpointed result, the runner replays it
/// instead of calling the handler. The handler must not run.
pub fn replay_skips_handler_calls_test() {
  let subject = process.new_subject()
  let store = durability.in_memory()

  // Pre-populate as if a previous attempt ran this effect
  let _ = store.record(0, "greet", StringVal("replayed!"))

  // Handler that panics if called — proves it's never invoked during replay
  let handler: EffectHandler = fn(_, _) {
    panic as "handler should NOT be called during replay"
  }

  let config =
    make_config(
      greet_program(),
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      store,
    )

  let assert Ok(StringVal("replayed!")) = runner.run(config)
}

/// For a multi-effect program where only the first is checkpointed,
/// the first replays and the second runs fresh.
pub fn partial_replay_then_fresh_execution_test() {
  let subject = process.new_subject()
  let store = durability.in_memory()

  let _ = store.record(0, "first", StringVal("from_checkpoint"))

  let h1: EffectHandler = fn(_, _) {
    panic as "first handler should not be called during replay"
  }
  let h2: EffectHandler = fn(_, _) { Ok(IntVal(99)) }

  let config =
    make_config(
      two_effect_program(),
      dict.from_list([#("first", h1), #("second", h2)]),
      test_emitter(subject),
      store,
    )

  // Final result comes from the fresh second handler
  let assert Ok(IntVal(99)) = runner.run(config)
}

// ── Tests: Record failure surfaces (ADR-0001) ────────────────────────

/// A store that fails to record causes the run to fail — record is a
/// guarantee, not best-effort (ADR-0001).
pub fn record_failure_surfaces_error_test() {
  let subject = process.new_subject()

  let failing_store =
    durability.DurableStore(
      lookup: fn(_, _) { Ok(option.None) },
      record: fn(_, _, _) {
        Error(durability.DurabilityError("store unreachable"))
      },
    )

  let handler: EffectHandler = fn(_, _) { Ok(StringVal("did the work")) }

  let config =
    make_config(
      greet_program(),
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      failing_store,
    )

  let assert Error(RuntimeError(msg)) = runner.run(config)
  // The error message must indicate a durability failure
  let assert True = string.contains(msg, "durability")
}

// ── Tests: Lookup failure is best-effort (ADR-0001) ──────────────────

/// A store that fails to look up a checkpoint falls through to fresh
/// execution — lookup is best-effort, not a guarantee (ADR-0001).
pub fn lookup_failure_falls_to_fresh_test() {
  let subject = process.new_subject()

  let failing_lookup_store =
    durability.DurableStore(
      lookup: fn(_, _) -> Result(Option(Value), durability.DurabilityError) {
        Error(durability.DurabilityError("store unreadable"))
      },
      record: fn(_, _, _) { Ok(Nil) },
    )

  let handler: EffectHandler = fn(_, _) { Ok(StringVal("ran fresh")) }

  let config =
    make_config(
      greet_program(),
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      failing_lookup_store,
    )

  // Despite the lookup error, the handler runs and the run succeeds
  let assert Ok(StringVal("ran fresh")) = runner.run(config)
}

// ── Tests: Non-durable path ─────────────────────────────────────────

/// Without a durable store, the runner runs handlers normally with no
/// replay or recording.
pub fn non_durable_run_executes_handlers_test() {
  let subject = process.new_subject()

  let call_count = process.new_subject()

  let handler: EffectHandler = fn(_, _) {
    process.send(call_count, Nil)
    Ok(StringVal("Hello, world!"))
  }

  let config =
    make_config(
      greet_program(),
      dict.from_list([#("greet", handler)]),
      test_emitter(subject),
      durability.none(),
    )

  let assert Ok(StringVal("Hello, world!")) = runner.run(config)

  // Handler was called exactly once
  let assert Ok(Nil) = process.receive(call_count, 100)
  let assert Error(_) = process.receive(call_count, 100)
}

/// Handler errors are not recorded — the run fails with the handler error.
pub fn handler_error_fails_run_test() {
  let subject = process.new_subject()
  let store = durability.in_memory()

  let failing_handler: EffectHandler = fn(_, _) {
    Error(RuntimeError("handler failed"))
  }

  let config =
    make_config(
      "effect boom() -> String
       pub fn main() -> String { perform boom() }",
      dict.from_list([#("boom", failing_handler)]),
      test_emitter(subject),
      store,
    )

  let assert Error(RuntimeError("handler failed")) = runner.run(config)
}
