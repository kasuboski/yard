//// Chat session tests — multi-user session support for gateway.
////
//// Tests the chat session CRUD with user_key for multi-user isolation,
//// message persistence, and history retrieval for Pig agent seeding.

import gleam/list
import gleam/string
import gleeunit
import sqlight
import yard/db

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = db.migrate(conn)
  test_fn(conn)
}

// ═══════════════════════════════════════════════════════════════
// Session with user_key
// ═══════════════════════════════════════════════════════════════

pub fn get_or_create_session_for_user_creates_new_test() {
  with_db(fn(conn) {
    let user_key = "telegram:123456"
    let assert Ok(session_id) =
      db.get_or_create_session_for_user(conn, user_key)
    let assert True = string.length(session_id) > 0
  })
}

pub fn get_or_create_session_for_user_returns_existing_test() {
  with_db(fn(conn) {
    let user_key = "telegram:123456"
    let assert Ok(id1) = db.get_or_create_session_for_user(conn, user_key)
    let assert Ok(id2) = db.get_or_create_session_for_user(conn, user_key)
    let assert True = id1 == id2
  })
}

pub fn different_users_get_different_sessions_test() {
  with_db(fn(conn) {
    let assert Ok(id1) = db.get_or_create_session_for_user(conn, "telegram:111")
    let assert Ok(id2) = db.get_or_create_session_for_user(conn, "telegram:222")
    let assert True = id1 != id2
  })
}

pub fn complete_session_then_new_session_test() {
  with_db(fn(conn) {
    let user_key = "telegram:123456"
    // Create first session
    let assert Ok(id1) = db.get_or_create_session_for_user(conn, user_key)
    // Save a message to it
    let assert Ok(Nil) =
      db.save_chat_message(conn, id1, "user", "Hello from first session")

    // Complete the session
    let assert Ok(Nil) = db.complete_session(conn, id1)

    // Get_or_create should return a NEW session
    let assert Ok(id2) = db.get_or_create_session_for_user(conn, user_key)
    let assert True = id1 != id2

    // Old session messages are still there
    let assert Ok(messages) = db.get_chat_messages(conn, id1)
    let assert 1 = list.length(messages)

    // New session has no messages
    let assert Ok(new_messages) = db.get_chat_messages(conn, id2)
    let assert 0 = list.length(new_messages)
  })
}

// ═══════════════════════════════════════════════════════════════
// Recent messages (for history seeding)
// ═══════════════════════════════════════════════════════════════

pub fn get_recent_messages_returns_last_n_test() {
  with_db(fn(conn) {
    let assert Ok(session_id) =
      db.get_or_create_session_for_user(conn, "telegram:999")

    // Save 5 messages
    let assert Ok(Nil) = db.save_chat_message(conn, session_id, "user", "msg 1")
    let assert Ok(Nil) =
      db.save_chat_message(conn, session_id, "assistant", "reply 1")
    let assert Ok(Nil) = db.save_chat_message(conn, session_id, "user", "msg 2")
    let assert Ok(Nil) =
      db.save_chat_message(conn, session_id, "assistant", "reply 2")
    let assert Ok(Nil) = db.save_chat_message(conn, session_id, "user", "msg 3")

    // Get last 3 — should be the last 3 in ASC order: msg 2, reply 2, msg 3
    let assert Ok(recent) = db.get_recent_messages(conn, session_id, 3)
    let assert 3 = list.length(recent)
    let assert [m1, m2, m3] = recent
    let assert "msg 2" = m1.content
    let assert "reply 2" = m2.content
    let assert "msg 3" = m3.content
  })
}

pub fn get_recent_messages_fewer_than_limit_test() {
  with_db(fn(conn) {
    let assert Ok(session_id) =
      db.get_or_create_session_for_user(conn, "telegram:999")

    let assert Ok(Nil) =
      db.save_chat_message(conn, session_id, "user", "only msg")

    // Ask for 20 but only 1 exists
    let assert Ok(recent) = db.get_recent_messages(conn, session_id, 20)
    let assert 1 = list.length(recent)
  })
}

pub fn get_recent_messages_empty_session_test() {
  with_db(fn(conn) {
    let assert Ok(session_id) =
      db.get_or_create_session_for_user(conn, "telegram:999")

    let assert Ok(recent) = db.get_recent_messages(conn, session_id, 10)
    let assert 0 = list.length(recent)
  })
}
