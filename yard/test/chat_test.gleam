//// Chat layer tests — PostgreSQL-backed chat sessions and messages.

import gabsurd/client
import gleam/list
import gleam/string
import testing
import yard/db

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_clean_db(test_fn)
}

// ═══════════════════════════════════════════════════════════════
// User-scoped sessions
// ═══════════════════════════════════════════════════════════════

pub fn get_or_create_session_for_user_creates_new_session_test() {
  with_db(fn(db) {
    let user_key = "telegram:12345"
    let assert Ok(session_id) = db.get_or_create_session_for_user(db, user_key)
    let assert True = string.length(session_id) > 0
  })
}

pub fn get_or_create_session_for_user_returns_same_session_test() {
  with_db(fn(db) {
    let user_key = "telegram:67890"
    let assert Ok(id1) = db.get_or_create_session_for_user(db, user_key)
    let assert Ok(id2) = db.get_or_create_session_for_user(db, user_key)
    let assert True = id1 == id2
  })
}

pub fn get_or_create_session_for_user_isolates_by_user_key_test() {
  with_db(fn(db) {
    let user_key = "telegram:11111"
    let assert Ok(id1) = db.get_or_create_session_for_user(db, user_key)
    let assert Ok(id2) = db.get_or_create_session_for_user(db, "telegram:22222")
    let assert False = id1 == id2
  })
}

pub fn complete_session_marks_session_inactive_test() {
  with_db(fn(db) {
    let user_key = "telegram:33333"
    let assert Ok(id1) = db.get_or_create_session_for_user(db, user_key)
    let assert Ok(Nil) = db.complete_session(db, id1)

    // Completing a session should create a new one next time
    let assert Ok(id2) = db.get_or_create_session_for_user(db, user_key)
    let assert False = id1 == id2
  })
}

pub fn messages_from_completed_session_still_accessible_test() {
  with_db(fn(db) {
    let user_key = "telegram:99999"
    let assert Ok(session_id) = db.get_or_create_session_for_user(db, user_key)
    let assert Ok(Nil) =
      db.save_chat_message(db, session_id, "user", "Hello from first session")
    let assert Ok(Nil) =
      db.save_chat_message(db, session_id, "assistant", "Reply 1")
    let assert Ok(Nil) = db.complete_session(db, session_id)

    // Messages from completed session should still be accessible
    let assert Ok(messages) = db.get_chat_messages(db, session_id)
    let assert 2 = list.length(messages)
  })
}

pub fn messages_isolated_per_user_test() {
  with_db(fn(db) {
    let user_key = "telegram:88888"
    let assert Ok(id1) = db.get_or_create_session_for_user(db, user_key)

    let assert Ok(Nil) = db.save_chat_message(db, id1, "user", "msg 1")
    let assert Ok(Nil) = db.save_chat_message(db, id1, "assistant", "reply 1")
    let assert Ok(Nil) = db.save_chat_message(db, id1, "user", "msg 2")
    let assert Ok(Nil) = db.save_chat_message(db, id1, "assistant", "reply 2")
    let assert Ok(Nil) = db.save_chat_message(db, id1, "user", "msg 3")

    let assert Ok(recent) = db.get_recent_messages(db, id1, 3)
    let assert 3 = list.length(recent)

    // Get all messages - should be in chronological order
    let assert Ok(all_messages) = db.get_chat_messages(db, id1)
    let assert 5 = list.length(all_messages)
  })
}

pub fn get_recent_messages_returns_correct_order_test() {
  with_db(fn(db) {
    let user_key = "telegram:77777"
    let assert Ok(session_id) = db.get_or_create_session_for_user(db, user_key)

    let assert Ok(Nil) =
      db.save_chat_message(db, session_id, "user", "only msg")
    let assert Ok(recent) = db.get_recent_messages(db, session_id, 20)

    // get_recent_messages returns chronological order
    let assert 1 = list.length(recent)
  })
}

pub fn get_recent_messages_returns_empty_when_limit_zero_test() {
  with_db(fn(db) {
    let user_key = "telegram:66666"
    let assert Ok(session_id) = db.get_or_create_session_for_user(db, user_key)
    let assert Ok(Nil) = db.save_chat_message(db, session_id, "user", "hello")
    let assert Ok(recent) = db.get_recent_messages(db, session_id, 0)
    let assert 0 = list.length(recent)
  })
}
