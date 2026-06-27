//// Integration test: durable handler — Chute program execution via gabsurd worker.
////
//// This test exercises the full production path:
//// 1. Spawn a gabsurd task with Chute source in params
//// 2. Claim the task
//// 3. Execute via durable_handler.execute_chute with a gabsurd checkpointer
//// 4. Verify the result is correct AND checkpoints are persisted
//// 5. Re-execute with the same task_id — verify replay from PostgreSQL
////
//// Requires: docker container running (bin/postgres.sh)

import ballast/value.{IntVal, StringVal}
import gabsurd/client
import gabsurd/context
import gabsurd/queue
import gabsurd/task
import gabsurd/worker
import gleam/dict
import gleam/int
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import testing
import yard/checkpoint
import yard/durable_handler
import yard/gabsurd_checkpointer
import yard/obs/events
import yard/runner
import yard/value_codec

pub fn main() {
  gleeunit.main()
}

fn noop_emit(_: events.HostEvent) -> Nil {
  Nil
}

fn with_queue_and_task(
  source: String,
  _handlers: dict.Dict(String, runner.EffectHandler),
  test_fn: fn(client.Db, String, context.Context, task.Claim) -> a,
) -> a {
  let queue_name =
    "yard_handler_test_" <> int.to_string(client.unique_integer())
  testing.with_pg_db(fn(db) {
    let assert Ok(Nil) = queue.create(db, queue_name)

    let params =
      json.object([
        #("agent_id", json.string("agent-1")),
        #("user_key", json.string("user-1")),
        #("actor_source", json.string(source)),
      ])

    let assert Ok(_) =
      task.spawn(db, queue_name, "run-chute", params, task.new_options())
    let assert Ok(claims) = task.claim(db, queue_name, "w1", 300, 1)
    let assert [claim] = claims

    let ctx =
      context.Context(
        db: db,
        queue_name: queue_name,
        claim: claim,
        claim_timeout: 300,
      )

    let result = test_fn(db, queue_name, ctx, claim)
    let _ = queue.drop(db, queue_name)
    result
  })
}

/// A Chute program with one effect runs through the durable handler.
pub fn single_effect_durable_run_test() {
  let greet: runner.EffectHandler = fn(_, args) {
    case args {
      [StringVal(name)] -> Ok(StringVal("Hello, " <> name <> "!"))
      _ -> Error(value.RuntimeError("bad args"))
    }
  }

  with_queue_and_task(
    "effect greet(name: String) -> String
     pub fn main() -> String { perform greet(\"world\") }",
    dict.from_list([#("greet", greet)]),
    fn(db, queue_name, ctx, claim) {
      let result =
        durable_handler.execute_chute(
          ctx:,
          handlers: dict.from_list([#("greet", greet)]),
          actor_source: "effect greet(name: String) -> String
           pub fn main() -> String { perform greet(\"world\") }",
          emit: noop_emit,
        )

      // Should be Complete with the handler result
      let assert worker.Complete(json_val) = result
      let json_str = json.to_string(json_val)
      // The result should contain the encoded value
      let assert True = string.contains(json_str, "Hello, world!")

      // Checkpoint should be persisted in PostgreSQL
      let cp =
        gabsurd_checkpointer.from_parts(
          db,
          queue_name,
          claim.task_id,
          claim.run_id,
          claim_timeout: 300,
        )
      let assert Ok(option.Some(cp_json)) = checkpoint.load(cp, "0:greet")
      let assert Ok(StringVal("Hello, world!")) = value_codec.from_json(cp_json)
    },
  )
}

/// Re-execution with the same task_id replays from checkpoints.
/// The handler is NOT called — if it were, it would panic.
pub fn replay_skips_handler_test() {
  let source =
    "effect double(n: Int) -> Int
     pub fn main() -> Int { perform double(21) }"

  with_queue_and_task(
    source,
    dict.from_list([
      #("double", fn(_, args) {
        case args {
          [IntVal(n)] -> Ok(IntVal(n * 2))
          _ -> Error(value.RuntimeError("bad args"))
        }
      }),
    ]),
    fn(_db, _queue_name, ctx, _claim) {
      // First run — handler executes
      let result1 =
        durable_handler.execute_chute(
          ctx:,
          handlers: dict.from_list([
            #("double", fn(_, args) {
              case args {
                [IntVal(n)] -> Ok(IntVal(n * 2))
                _ -> Error(value.RuntimeError("bad args"))
              }
            }),
          ]),
          actor_source: source,
          emit: noop_emit,
        )
      let assert worker.Complete(json_val1) = result1
      let assert True = string.contains(json.to_string(json_val1), "42")

      // Second run — handler should NOT be called (replay from checkpoint)
      // We use a panic handler to prove it's never called
      let result2 =
        durable_handler.execute_chute(
          ctx:,
          handlers: dict.from_list([
            #("double", fn(_, _) {
              panic as "HANDLER SHOULD NOT BE CALLED ON REPLAY"
            }),
          ]),
          actor_source: source,
          emit: noop_emit,
        )
      let assert worker.Complete(json_val2) = result2
      // Result should still be 42 (from checkpoint)
      let assert True = string.contains(json.to_string(json_val2), "42")
    },
  )
}

/// Multi-effect program: all effects checkpointed, correct final result.
pub fn multi_effect_durable_run_test() {
  let source =
    "effect add(a: Int, b: Int) -> Int
     effect mul(a: Int, b: Int) -> Int
     pub fn main() -> Int {
       let x = perform add(3, 4)
       perform mul(x, 2)
     }"

  with_queue_and_task(
    source,
    dict.from_list([
      #("add", fn(_, args) {
        case args {
          [IntVal(a), IntVal(b)] -> Ok(IntVal(a + b))
          _ -> Error(value.RuntimeError("bad args"))
        }
      }),
      #("mul", fn(_, args) {
        case args {
          [IntVal(a), IntVal(b)] -> Ok(IntVal(a * b))
          _ -> Error(value.RuntimeError("bad args"))
        }
      }),
    ]),
    fn(db, queue_name, ctx, claim) {
      let result =
        durable_handler.execute_chute(
          ctx:,
          handlers: dict.from_list([
            #("add", fn(_, args) {
              case args {
                [IntVal(a), IntVal(b)] -> Ok(IntVal(a + b))
                _ -> Error(value.RuntimeError("bad args"))
              }
            }),
            #("mul", fn(_, args) {
              case args {
                [IntVal(a), IntVal(b)] -> Ok(IntVal(a * b))
                _ -> Error(value.RuntimeError("bad args"))
              }
            }),
          ]),
          actor_source: source,
          emit: noop_emit,
        )
      let assert worker.Complete(json_val) = result
      let assert True = string.contains(json.to_string(json_val), "14")

      // Both checkpoints persisted
      let cp =
        gabsurd_checkpointer.from_parts(
          db,
          queue_name,
          claim.task_id,
          claim.run_id,
          claim_timeout: 300,
        )
      let assert Ok(option.Some(json0)) = checkpoint.load(cp, "0:add")
      let assert Ok(IntVal(7)) = value_codec.from_json(json0)
      let assert Ok(option.Some(json1)) = checkpoint.load(cp, "1:mul")
      let assert Ok(IntVal(14)) = value_codec.from_json(json1)
    },
  )
}
