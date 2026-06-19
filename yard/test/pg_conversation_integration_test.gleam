//// Integration test: PostgreSQL conversation store.
////
//// Requires: docker container running with durable_schema.sql applied.
//// Note: JSONB columns normalize JSON whitespace (adds spaces after colons).
//// Tests compare parsed JSON, not raw strings.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gluid
import gleeunit
import gleeunit/should
import gabsurd/client
import yard/conversation
import yard/pg_conversation

const db_url = "postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd"

pub fn main() {
  gleeunit.main()
}

fn unique_conv_id() -> String {
  gluid.guidv4() |> string.lowercase()
}

fn with_store(test_fn: fn(conversation.ConversationStore) -> a) -> a {
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  let store = pg_conversation.from_db(db:)
  let result = test_fn(store)
  process.send_exit(db.pid)
  result
}

/// Parse JSON to a canonical dynamic for comparison.
fn json_canonical(str: String) -> dynamic.Dynamic {
  let assert Ok(d) = json.parse(str, decode.dynamic)
  d
}

pub fn save_then_load_test() {
  with_store(fn(store) {
    let conv_id = unique_conv_id()
    let input = "[{\"role\":\"user\",\"content\":\"hi\"}]"
    let _ = conversation.save(store, conv_id, input)
    let loaded = conversation.load(store, conv_id)
    let assert Ok(option.Some(raw)) = loaded
    // JSONB normalizes whitespace — compare parsed structure
    should.equal(json_canonical(raw), json_canonical(input))
  })
}

pub fn load_missing_returns_none_test() {
  with_store(fn(store) {
    should.equal(
      conversation.load(store, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
      Ok(option.None),
    )
  })
}

pub fn save_overwrites_previous_test() {
  with_store(fn(store) {
    let conv_id = unique_conv_id()
    let _ = conversation.save(store, conv_id, "[\"old\"]")
    let _ = conversation.save(store, conv_id, "[\"new\"]")
    let assert Ok(option.Some(raw)) = conversation.load(store, conv_id)
    should.equal(json_canonical(raw), json_canonical("[\"new\"]"))
  })
}

pub fn multiple_conversations_coexist_test() {
  with_store(fn(store) {
    let id1 = unique_conv_id()
    let id2 = unique_conv_id()
    let _ = conversation.save(store, id1, "[\"a\"]")
    let _ = conversation.save(store, id2, "[\"b\"]")
    let assert Ok(option.Some(r1)) = conversation.load(store, id1)
    let assert Ok(option.Some(r2)) = conversation.load(store, id2)
    should.equal(json_canonical(r1), json_canonical("[\"a\"]"))
    should.equal(json_canonical(r2), json_canonical("[\"b\"]"))
  })
}
