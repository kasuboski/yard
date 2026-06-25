//// Integration test: gabsurd checkpointer adapter against real PostgreSQL.
////
//// Tests that the Checkpointer created from a gabsurd Context can
//// save and load checkpoints through the real Absurd schema.
////
//// Requires: docker container running (bin/postgres.sh)

import gabsurd/client
import gabsurd/queue
import gabsurd/task
import gleam/int
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import testing
import yard/checkpoint
import yard/gabsurd_checkpointer

pub fn main() {
  gleeunit.main()
}

fn with_setup(test_fn: fn(client.Db, String, task.Claim) -> a) -> a {
  let queue_name = "yard_cp_test_" <> int.to_string(client.unique_integer())
  testing.with_pg_db(fn(db) {
    let assert Ok(Nil) = queue.create(db, queue_name)

    // Spawn a task and claim it so we have a valid run_id
    let assert Ok(_spawned) =
      task.spawn(
        db,
        queue_name,
        "test_task",
        json.object([#("agent_id", json.string("agent-1"))]),
        task.new_options(),
      )
    let assert Ok(claims) = task.claim(db, queue_name, "test-worker", 300, 1)
    let assert [claim] = claims

    let result = test_fn(db, queue_name, claim)

    let _ = queue.drop(db, queue_name)
    result
  })
}

pub fn save_then_load_checkpoint_test() {
  with_setup(fn(db, queue_name, claim) {
    let cp =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )

    let result =
      checkpoint.save(cp, "0:greet", "{\"type\":\"string\",\"value\":\"hi\"}")
    should.be_ok(result)

    let loaded = checkpoint.load(cp, "0:greet")
    should.equal(
      loaded,
      Ok(option.Some("{\"type\":\"string\",\"value\":\"hi\"}")),
    )
  })
}

pub fn load_missing_checkpoint_returns_none_test() {
  with_setup(fn(db, queue_name, claim) {
    let cp =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )

    let loaded = checkpoint.load(cp, "0:nonexistent")
    should.equal(loaded, Ok(option.None))
  })
}

pub fn multiple_checkpoints_coexist_test() {
  with_setup(fn(db, queue_name, claim) {
    let cp =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )

    let _ = checkpoint.save(cp, "0:first", "value-0")
    let _ = checkpoint.save(cp, "1:second", "value-1")
    let _ = checkpoint.save(cp, "2:third", "value-2")

    should.equal(checkpoint.load(cp, "0:first"), Ok(option.Some("value-0")))
    should.equal(checkpoint.load(cp, "1:second"), Ok(option.Some("value-1")))
    should.equal(checkpoint.load(cp, "2:third"), Ok(option.Some("value-2")))
  })
}

/// Verifies that checkpoint data survives across separate Checkpointer instances
/// (simulates a crash + retry where the worker creates a fresh Checkpointer).
pub fn checkpoint_persists_across_connections_test() {
  with_setup(fn(db, queue_name, claim) {
    // First checkpointer saves
    let cp1 =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )
    let _ = checkpoint.save(cp1, "0:greet", "persisted-value")

    // Second checkpointer (same task_id/run_id) loads
    let cp2 =
      gabsurd_checkpointer.from_parts(
        db,
        queue_name,
        claim.task_id,
        claim.run_id,
        claim_timeout: 300,
      )
    should.equal(
      checkpoint.load(cp2, "0:greet"),
      Ok(option.Some("persisted-value")),
    )
  })
}
