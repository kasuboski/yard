//// Session lifecycle tests — HermesSession type + create/reset/load.
////
//// Tests the platform-agnostic session management logic.
//// Uses fake providers (no real LLM calls) to exercise Pig agent lifecycle.

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import hermes_agent/session
import pig/ai/message
import pig/ai/provider
import pig/workspace
import pig/workspace/kv
import sqlight
import yard/db

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn test_config(provider: provider.Provider) -> session.SessionConfig {
  session.simple_config(provider, "You are a test agent.")
}

fn with_dbs(test_fn: fn(sqlight.Connection, sqlight.Connection) -> a) -> a {
  let assert Ok(global_conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = db.migrate(global_conn)
  let assert Ok(ws) = workspace.open("file::memory:")
  test_fn(global_conn, workspace.connection(ws))
}

/// A fake provider that always returns a fixed text response.
fn fixed_provider(text: String) -> provider.Provider {
  fn(_messages, _tools) {
    Ok(provider.from_message(message.Assistant(text, [], option.None)))
  }
}

/// A fake provider that tracks call count via a counter function.
fn counting_provider(text: String, counter: Ref(Int)) -> provider.Provider {
  fn(_messages, _tools) {
    let n = counter.get()
    counter.set(n + 1)
    Ok(provider.from_message(message.Assistant(text, [], option.None)))
  }
}

// Simple mutable ref for tracking provider calls
type Ref(a) {
  Ref(get: fn() -> a, set: fn(a) -> Nil)
}

fn new_ref(initial: Int) -> Ref(Int) {
  let _cell = process.new_subject()
  // Use a simple actor-based ref
  let assert Ok(started) =
    actor.new(initial)
    |> actor.on_message(fn(state: Int, msg) {
      case msg {
        GetRef(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
        SetRef(val) -> actor.continue(val)
      }
    })
    |> actor.start()
  let subject = started.data
  Ref(
    get: fn() { process.call(subject, 1000, fn(r) { GetRef(r) }) },
    set: fn(v) { process.send(subject, SetRef(v)) },
  )
}

type RefMsg {
  GetRef(reply: process.Subject(Int))
  SetRef(value: Int)
}

// ═══════════════════════════════════════════════════════════════
// Create session
// ═══════════════════════════════════════════════════════════════

pub fn create_session_returns_session_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("Hello!")
    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )
    let assert True = string.length(sess.session_id) > 0
    session.stop(sess)
  })
}

pub fn create_session_assigns_user_key_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("Hello!")
    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "telegram:123",
      )
    let assert "telegram:123" = sess.user_key
    session.stop(sess)
  })
}

// ═══════════════════════════════════════════════════════════════
// Run prompt
// ═══════════════════════════════════════════════════════════════

pub fn run_prompt_returns_response_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("I am Hermes!")
    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )

    let assert Ok(response) = session.run_prompt(sess, "Who are you?")
    let assert True =
      string.contains(response, "Hermes") || string.contains(response, "Hello")

    session.stop(sess)
  })
}

pub fn run_prompt_saves_messages_to_db_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("Response text")
    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )

    let assert Ok(_response) = session.run_prompt(sess, "User question")

    // Messages should be saved to the DB
    let assert Ok(messages) = db.get_chat_messages(global_conn, sess.session_id)
    let assert 2 = list.length(messages)
    let assert [user_msg, assistant_msg] = messages
    let assert "user" = user_msg.role
    let assert "User question" = user_msg.content
    let assert "assistant" = assistant_msg.role
    let assert "Response text" = assistant_msg.content

    session.stop(sess)
  })
}

// ═══════════════════════════════════════════════════════════════
// Reset session
// ═══════════════════════════════════════════════════════════════

pub fn reset_session_creates_new_agent_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let ref = new_ref(0)
    let provider = counting_provider("Hello", ref)

    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )

    // Run a prompt
    let assert Ok(_) = session.run_prompt(sess, "First prompt")
    let assert 1 = ref.get()

    // Reset — should create a new agent
    let assert Ok(new_sess) = session.reset(test_config(provider), sess)

    // Different session ID (old session completed, new one created)
    let assert True = new_sess.session_id != sess.session_id

    // Same user key
    let assert "test_user" = new_sess.user_key

    session.stop(new_sess)
  })
}

pub fn reset_session_preserves_workspace_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("OK")

    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )

    // Store something in workspace KV via the workspace connection
    let assert Ok(Nil) = kv.remember(workspace_conn, "test_key", "test_value")

    // Reset session
    let assert Ok(new_sess) = session.reset(test_config(provider), sess)

    // Workspace data should still be there
    let assert Ok(val) = kv.recall(workspace_conn, "test_key")
    let assert "test_value" = val

    session.stop(new_sess)
  })
}

// ═══════════════════════════════════════════════════════════════
// Load session (history seeding from DB)
// ═══════════════════════════════════════════════════════════════

pub fn load_session_creates_agent_with_history_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("Initial response")

    // Create and run a session with messages
    let assert Ok(sess) =
      session.create(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )
    let assert Ok(_) = session.run_prompt(sess, "Hello there")
    session.stop(sess)

    // Load the session — should recreate with history
    let assert Ok(loaded) =
      session.load(
        test_config(provider),
        global_conn,
        workspace_conn,
        "test_user",
      )

    // Same session ID since the session is still active in DB
    let assert True = sess.session_id == loaded.session_id

    session.stop(loaded)
  })
}

pub fn load_session_no_existing_session_creates_fresh_test() {
  with_dbs(fn(global_conn, workspace_conn) {
    let provider = fixed_provider("Fresh response")

    // Load for a user that has never chatted
    let assert Ok(sess) =
      session.load(
        test_config(provider),
        global_conn,
        workspace_conn,
        "new_user:999",
      )

    // Should have created a new session
    let assert True = string.length(sess.session_id) > 0

    session.stop(sess)
  })
}
