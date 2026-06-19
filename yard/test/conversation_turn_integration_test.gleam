//// Integration test: end-to-end conversation turn durability.
////
//// Validates DURABLE.md Component 3's conversation lifecycle with real PostgreSQL.
//// Uses gabsurd tasks for real checkpoint storage and PG conversation store.
////
//// Requires: docker container running (bin/postgres.sh)

import gleam/int
import gleam/option
import gleam/string
import gluid
import gleeunit
import gleeunit/should
import gabsurd/client
import gabsurd/queue
import gabsurd/task
import pig/ai/message.{Assistant, User}
import pig/ai/stop_reason.{Stop}
import yard/agent_checkpoint
import yard/checkpoint
import yard/conversation
import yard/durable_turn
import yard/gabsurd_checkpointer
import yard/pg_conversation

const db_url = "postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd"

pub fn main() {
  gleeunit.main()
}

fn unique_id() -> String {
  gluid.guidv4() |> string.lowercase()
}

fn with_db_queue(
  test_fn: fn(client.Db, String, task.Claim) -> a,
) -> a {
  let queue_name = "conv_turn_" <> int.to_string(client.unique_integer())
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  let assert Ok(Nil) = queue.create(db, queue_name)
  let assert Ok(_) =
    task.spawn(db, queue_name, "test", json.object([]), task.new_options())
  let assert Ok(claims) = task.claim(db, queue_name, "w1", 300, 1)
  let assert [claim] = claims

  let result = test_fn(db, queue_name, claim)
  let _ = queue.drop(db, queue_name)
  result
}

import gleam/json

/// First turn: no conversation history exists.
pub fn first_turn_no_history_test() {
  with_db_queue(fn(db, queue_name, claim) {
    let conv_id = unique_id()
    let conv_store = pg_conversation.from_db(db:)
    let cp = gabsurd_checkpointer.from_parts(
      db,
      queue_name,
      claim.task_id,
      claim.run_id,
      claim_timeout: 300,
    )

    let assert Ok(durable_turn.AssembledHistory(
      messages:,
      entry_point:,
      is_retry:,
    )) = durable_turn.assemble_history(
      conv_store: conv_store,
      cp_store: cp,
      conversation_id: conv_id,
      user_message: "hello",
    )

    should.equal(messages, [User("hello")])
    should.equal(entry_point, agent_checkpoint.CallLlm)
    should.equal(is_retry, False)

    // User message checkpointed as msg:0
    let assert Ok(option.Some(_)) = checkpoint.load(cp, "msg:0")
  })
}

/// Second turn: previous conversation exists in PG.
pub fn second_turn_loads_previous_history_test() {
  with_db_queue(fn(db, queue_name, claim) {
    let conv_id = unique_id()
    let conv_store = pg_conversation.from_db(db:)

    // Turn 1 completed
    let turn1_json =
      agent_checkpoint.messages_to_json_string([
        User("hi"),
        Assistant("hello!", [], option.None, option.Some(Stop)),
      ])
    let _ = conversation.save(conv_store, conv_id, turn1_json)

    let cp = gabsurd_checkpointer.from_parts(
      db,
      queue_name,
      claim.task_id,
      claim.run_id,
      claim_timeout: 300,
    )

    let assert Ok(durable_turn.AssembledHistory(messages:, ..)) =
      durable_turn.assemble_history(
        conv_store: conv_store,
        cp_store: cp,
        conversation_id: conv_id,
        user_message: "how are you",
      )

    should.equal(messages, [
      User("hi"),
      Assistant("hello!", [], option.None, option.Some(Stop)),
      User("how are you"),
    ])
  })
}

/// Crash scenario: conversation table has Turn 1, checkpoints have Turn 2.
/// Checkpoints win.
pub fn crash_retry_checkpoints_ahead_of_table_test() {
  with_db_queue(fn(db, queue_name, claim) {
    let conv_id = unique_id()
    let conv_store = pg_conversation.from_db(db:)

    // Turn 1 completed — in conversation table
    let turn1_json =
      agent_checkpoint.messages_to_json_string([
        User("turn1-msg"),
        Assistant("turn1-reply", [], option.None, option.Some(Stop)),
      ])
    let _ = conversation.save(conv_store, conv_id, turn1_json)

    // Turn 2 crashed mid-execution — checkpoints have progress
    let cp = gabsurd_checkpointer.from_parts(
      db,
      queue_name,
      claim.task_id,
      claim.run_id,
      claim_timeout: 300,
    )
    let _ = agent_checkpoint.save_messages(cp, [
      User("turn2-msg"),
      Assistant("turn2-reply", [], option.None, option.Some(Stop)),
    ])

    // Retry Turn 2
    let assert Ok(durable_turn.AssembledHistory(
      messages:,
      entry_point:,
      is_retry:,
    )) = durable_turn.assemble_history(
      conv_store: conv_store,
      cp_store: cp,
      conversation_id: conv_id,
      user_message: "turn2-msg",
    )

    should.equal(is_retry, True)
    should.equal(entry_point, agent_checkpoint.Done)
    should.equal(messages, [
      User("turn1-msg"),
      Assistant("turn1-reply", [], option.None, option.Some(Stop)),
      User("turn2-msg"),
      Assistant("turn2-reply", [], option.None, option.Some(Stop)),
    ])
  })
}
