//// Integration test: durable runner against real PostgreSQL via gabsurd.
////
//// This is the capstone test for DURABLE.md Component 1:
//// - Run a Chute program with a gabsurd-backed Checkpointer
//// - Verify effect results are checkpointed in PostgreSQL
//// - Verify replay: second run with same task_id loads checkpoints instead of
////   calling handlers
////
//// Requires: docker container running (bin/postgres.sh)

import ballast/value.{IntVal, NilVal, RuntimeError, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleeunit
import yard/checkpoint
import yard/gabsurd_checkpointer
import yard/loader
import yard/obs/events.{
  type HostEvent, EffectHandled,
  EffectReplayed,
}
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}
import yard/value_codec
import gabsurd/client
import gabsurd/queue
import gabsurd/task

const db_url = "postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd"

pub fn main() {
  gleeunit.main()
}

fn with_queue(
  test_fn: fn(client.Db, String) -> a,
) -> a {
  let queue_name = "yard_runner_test_" <> int.to_string(client.unique_integer())
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  let assert Ok(Nil) = queue.create(db, queue_name)
  let result = test_fn(db, queue_name)
  let _ = queue.drop(db, queue_name)
  result
}

/// Helper: spawn a task, claim it, and build a RunConfig with a gabsurd checkpointer.
fn make_durable_config(
  db,
  queue_name: String,
  claim: task.Claim,
  source: String,
  handlers: dict.Dict(String, EffectHandler),
  emit: fn(HostEvent) -> Nil,
) -> RunConfig {
  let assert Ok(actor) = loader.load(source, "test.chute")
  let cp =
    gabsurd_checkpointer.from_parts(
      db,
      queue_name,
      claim.task_id,
      claim.run_id,
      claim_timeout: 300,
    )

  RunConfig(
    program: actor.program,
    env: NilVal,
    gas: 10_000,
    handlers:,
    emit:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id: "r_pg_test",
    trigger_type: "test",
    trigger_source: "pg_integration",
    depth: 0,
    checkpointer: option.Some(cp),
  )
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

fn test_emitter(subject: process.Subject(HostEvent)) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) { process.send(subject, event) }
}

/// A Chute program with two effects runs, and both effect results are
/// checkpointed in PostgreSQL.
pub fn effects_checkpointed_to_postgres_test() {
  with_queue(fn(db, queue_name) {
    let assert Ok(_spawned) =
      task.spawn(
        db,
        queue_name,
        "run_chute",
        json.object([]),
        task.new_options(),
      )
    let assert Ok(claims) = task.claim(db, queue_name, "w1", 300, 1)
    let assert [claim] = claims

    let subject = process.new_subject()
    let greet: EffectHandler = fn(_, args) {
      case args {
        [StringVal(name)] -> Ok(StringVal("Hello, " <> name <> "!"))
        _ -> Error(RuntimeError("bad args"))
      }
    }
    let count: EffectHandler = fn(_, _) { Ok(IntVal(42)) }

    let config =
      make_durable_config(
        db,
        queue_name,
        claim,
        "effect greet(name: String) -> String
         effect count() -> Int
         pub fn main() -> Int {
           let _ = perform greet(\"world\")
           perform count()
         }",
        dict.from_list([#("greet", greet), #("count", count)]),
        test_emitter(subject),
      )

    let assert Ok(IntVal(42)) = runner.run(config)

    // Verify both checkpoints exist in PostgreSQL by loading them directly
    let cp =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )
    let assert Ok(option.Some(json0)) = checkpoint.load(cp, "0:greet")
    let assert Ok(StringVal("Hello, world!")) = value_codec.from_json(json0)

    let assert Ok(option.Some(json1)) = checkpoint.load(cp, "1:count")
    let assert Ok(IntVal(42)) = value_codec.from_json(json1)
  })
}

/// The capstone replay test: run a program, then re-run with the SAME
/// task_id — handlers should NOT be called because checkpoints are loaded.
pub fn replay_skips_handlers_on_second_run_test() {
  with_queue(fn(db, queue_name) {
    let assert Ok(_) =
      task.spawn(
        db,
        queue_name,
        "run_chute",
        json.object([]),
        task.new_options(),
      )
    let assert Ok(claims) = task.claim(db, queue_name, "w1", 300, 1)
    let assert [claim] = claims

    // First run: handlers execute normally, results are checkpointed
    let subject1 = process.new_subject()
    let greet: EffectHandler = fn(_, args) {
      case args {
        [StringVal(_)] -> Ok(StringVal("first-run-result"))
        _ -> Error(RuntimeError("bad args"))
      }
    }

    let config1 =
      make_durable_config(
        db,
        queue_name,
        claim,
        "effect greet(name: String) -> String
         pub fn main() -> String { perform greet(\"world\") }",
        dict.from_list([#("greet", greet)]),
        test_emitter(subject1),
      )

    let assert Ok(StringVal("first-run-result")) = runner.run(config1)

    // Second run: SAME task_id → replay from checkpoints
    // The handler is a PANIC — if it gets called, the test crashes
    let subject2 = process.new_subject()
    let panic_handler: EffectHandler = fn(_, _) {
      panic as "HANDLER SHOULD NOT BE CALLED DURING REPLAY"
    }

    let config2 =
      make_durable_config(
        db,
        queue_name,
        claim,
        "effect greet(name: String) -> String
         pub fn main() -> String { perform greet(\"world\") }",
        dict.from_list([#("greet", panic_handler)]),
        test_emitter(subject2),
      )

    let assert Ok(StringVal("first-run-result")) = runner.run(config2)

    // Verify replay events were emitted
    let events = drain_events(subject2, [])
    let has_replay = list.any(events, fn(e) {
      case e {
        EffectReplayed(..) -> True
        _ -> False
      }
    })
    let assert True = has_replay
  })
}

/// A multi-effect program: partial replay (first effect replayed, second fresh).
pub fn partial_replay_then_fresh_test() {
  with_queue(fn(db, queue_name) {
    let assert Ok(_) =
      task.spawn(
        db,
        queue_name,
        "run_chute",
        json.object([]),
        task.new_options(),
      )
    let assert Ok(claims) = task.claim(db, queue_name, "w1", 300, 1)
    let assert [claim] = claims

    let subject = process.new_subject()

    // Pre-populate only the first checkpoint
    let cp_init =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )
    let _ =
      checkpoint.save(
        cp_init,
        "0:first",
        json.to_string(value_codec.encode(StringVal("from_pg_checkpoint"))),
      )

    let first: EffectHandler = fn(_, _) {
      panic as "first handler should not be called during replay"
    }
    let second: EffectHandler = fn(_, _) { Ok(IntVal(77)) }

    let config =
      make_durable_config(
        db,
        queue_name,
        claim,
        "effect first() -> String
         effect second() -> Int
         pub fn main() -> Int {
           let _ = perform first()
           perform second()
         }",
        dict.from_list([#("first", first), #("second", second)]),
        test_emitter(subject),
      )

    let assert Ok(IntVal(77)) = runner.run(config)

    // Both checkpoints should now exist
    let assert Ok(option.Some(json1)) = checkpoint.load(cp_init, "1:second")
    let assert Ok(IntVal(77)) = value_codec.from_json(json1)

    // Verify we got both EffectReplayed (for first) and EffectHandled (for second)
    let events = drain_events(subject, [])
    let has_replay = list.any(events, fn(e) {
      case e {
        EffectReplayed(..) -> True
        _ -> False
      }
    })
    let has_handled = list.any(events, fn(e) {
      case e {
        EffectHandled(..) -> True
        _ -> False
      }
    })
    let assert True = has_replay
    let assert True = has_handled
  })
}
