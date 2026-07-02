//// Write-side Pig Bridge — verifies execute_turn captures pig's
//// agent-internal SessionEvents into the pig_events table when a
//// BridgeConfig is supplied.
////
//// Requires: docker container running with durable_schema.sql applied.

import gabsurd/client
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import parrot/dev
import pig/ai/message
import pig/ai/provider.{InferenceResult, default_metadata, with_stop_reason}
import pig/ai/stop_reason.{Stop}
import testing
import yard/agent_turn
import yard/conversation

pub fn main() {
  gleeunit.main()
}

const run_id = "00000000-0000-0000-0000-0000000000bb"

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_pg_db(fn(db) {
    testing.clean_durable(db)
    test_fn(db)
  })
}

fn mock_provider(response: message.Message) -> provider.Provider {
  fn(_messages, _tools) {
    Ok(InferenceResult(
      message: response,
      metadata: default_metadata() |> with_stop_reason(Stop),
    ))
  }
}

/// Count pig_events rows for this run_id.
fn count_pig_events(db: client.Db) -> Int {
  let sql = "SELECT COUNT(*)::int FROM pig_events WHERE run_id::text = $1"
  case
    client.query_one(db, #(sql, [dev.ParamString(run_id)], count_decoder()))
  {
    Ok(n) -> n
    Error(_) -> 0
  }
}

fn count_decoder() -> decode.Decoder(Int) {
  use n <- decode.field(0, decode.int)
  decode.success(n)
}

/// True if any pig_events row for this run_id has a "pig.*" event_type.
fn has_pig_event_type(db: client.Db) -> Bool {
  let sql = "SELECT event_type FROM pig_events WHERE run_id::text = $1 LIMIT 1"
  case
    client.query_one(db, #(sql, [dev.ParamString(run_id)], string_decoder()))
  {
    Ok(et) -> string.starts_with(et, "pig.")
    Error(_) -> False
  }
}

fn string_decoder() -> decode.Decoder(String) {
  use s <- decode.field(0, decode.string)
  decode.success(s)
}

/// The pig_events consumer writes asynchronously via pig's dispatcher, so the
/// row may not be visible the instant run_continue returns. This is the standard
/// wait-for-async-side-effect pattern: poll the store until the predicate holds,
/// with a bounded number of retries (no arbitrary long sleep).
fn wait_until(db: client.Db, predicate: fn(client.Db) -> Bool) -> Bool {
  wait_until_loop(db, predicate, 50)
}

fn wait_until_loop(db, predicate, remaining) -> Bool {
  case predicate(db) {
    True -> True
    False if remaining <= 0 -> False
    False -> {
      process.sleep(10)
      wait_until_loop(db, predicate, remaining - 1)
    }
  }
}

/// execute_turn with a BridgeConfig writes pig events to pig_events.
pub fn bridge_captures_pig_events_test() {
  with_db(fn(db) {
    let conv_store = conversation.in_memory()

    let response =
      message.Assistant("Hello!", [], option.None, option.Some(Stop))

    let result =
      agent_turn.execute_turn(
        conv_store: conv_store,
        conversation_id: "conv-bridge-1",
        user_message: "hi",
        provider: mock_provider(response),
        tools: [],
        system_prompt: "",
        agent_name: "test-agent",
        run_timeout_ms: 5000,
        bridge: option.Some(agent_turn.BridgeConfig(
          db: db,
          run_id: run_id,
          actor_path: "actors/test.chute",
          actor_hash: "abcd1234",
        )),
      )

    let assert Ok(agent_turn.TurnResult(..)) = result

    // The pig_events consumer writes asynchronously; wait for the side effect
    // to land (pig emits SessionStarted/InferenceStarted/InferenceCompleted).
    let arrived = wait_until(db, fn(d) { count_pig_events(d) >= 1 })
    should.be_true(arrived)

    // And at least one of those rows carries a pig.* event_type.
    should.be_true(has_pig_event_type(db))
  })
}
