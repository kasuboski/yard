//// Conversation store tests — persistence for multi-turn message logs.
////
//// From DURABLE.md Component 3: Conversation Lifecycle.
//// The conversation store persists the full message log for each
//// conversation, updated only on task completion.

import gleam/option
import gleeunit
import gleeunit/should
import yard/conversation

pub fn main() {
  gleeunit.main()
}

// ── In-memory conversation store ─────────────────────────────────────

pub fn save_then_load_returns_messages_test() {
  let store = conversation.in_memory()
  let msgs = "[{\"role\":\"user\",\"content\":\"hello\"}]"
  let _ = conversation.save(store, "conv-1", msgs)
  should.equal(conversation.load(store, "conv-1"), Ok(option.Some(msgs)))
}

pub fn load_missing_returns_none_test() {
  let store = conversation.in_memory()
  should.equal(conversation.load(store, "nonexistent"), Ok(option.None))
}

pub fn save_overwrites_previous_test() {
  let store = conversation.in_memory()
  let _ = conversation.save(store, "conv-1", "[\"old\"]")
  let _ = conversation.save(store, "conv-1", "[\"new\"]")
  should.equal(conversation.load(store, "conv-1"), Ok(option.Some("[\"new\"]")))
}

pub fn multiple_conversations_coexist_test() {
  let store = conversation.in_memory()
  let _ = conversation.save(store, "conv-1", "[\"a\"]")
  let _ = conversation.save(store, "conv-2", "[\"b\"]")
  let _ = conversation.save(store, "conv-3", "[\"c\"]")
  should.equal(conversation.load(store, "conv-1"), Ok(option.Some("[\"a\"]")))
  should.equal(conversation.load(store, "conv-2"), Ok(option.Some("[\"b\"]")))
  should.equal(conversation.load(store, "conv-3"), Ok(option.Some("[\"c\"]")))
}

pub fn empty_conversation_id_works_test() {
  let store = conversation.in_memory()
  let _ = conversation.save(store, "", "[\"data\"]")
  should.equal(conversation.load(store, ""), Ok(option.Some("[\"data\"]")))
}
