//// Gateway integration tests — telega handler wiring.
////
//// Tests the Telegram-specific handlers using telega's testing toolkit.
//// Uses a fake provider (no real LLM) and in-memory databases.
////
//// Telega's conversation DSL uses default test IDs:
////   from_id = 987_654_321, chat_id = 123_456_789
//// So the session key is "123456789:987654321"
//// and user_key_from_key extracts "telegram:987654321".

import gabsurd/client
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import hermes_agent/gateway
import hermes_agent/session
import pig/ai/message
import pig/ai/provider
import pig/workspace
import telega/router
import telega/testing/conversation
import testing
import yard/agent_checkpoint
import yard/conversation as yard_conv
import yard/pg_conversation

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

/// A fake provider that echoes the user's message back.
fn echo_provider() -> provider.Provider {
  fn(messages, _tools) {
    case list.last(messages) {
      Ok(message.User(content:)) ->
        Ok(
          provider.from_message(message.Assistant(
            "Echo: " <> content,
            [],
            option.None,
            option.None,
          )),
        )
      _ ->
        Ok(
          provider.from_message(message.Assistant(
            "Hello!",
            [],
            option.None,
            option.None,
          )),
        )
    }
  }
}

fn with_gateway(test_fn: fn(gateway.GatewayConfig, client.Db) -> a) -> a {
  testing.with_clean_db(fn(global_conn) {
    testing.clean_registry(global_conn)
    let assert Ok(ws) = workspace.open("file::memory:")
    let config =
      gateway.GatewayConfig(
        global_conn:,
        workspace_conn: workspace.connection(ws),
        session_config: session.simple_config(
          echo_provider(),
          "You are a test agent.",
        ),
      )
    test_fn(config, global_conn)
  })
}

/// Telega's test default from_id — all conversation.send() messages use this.
const test_from_id = 987_654_321

/// User key matching telega's test defaults.
fn test_user_key() -> String {
  "telegram:" <> int.to_string(test_from_id)
}

// ═══════════════════════════════════════════════════════════════
// Tests — existing (text + /new command)
// ═══════════════════════════════════════════════════════════════

pub fn text_handler_echos_back_test() {
  with_gateway(fn(config, _global_conn) {
    let router = gateway.build_router(config)

    conversation.conversation_test()
    |> conversation.send("Hello bot")
    |> conversation.expect_reply_containing("Echo: Hello bot")
    |> conversation.run(router, fn() {
      case
        session.create(
          session.simple_config(echo_provider(), "You are a test agent."),
          config.global_conn,
          config.workspace_conn,
          "test:123",
        )
      {
        Ok(sess) -> sess
        Error(_) -> panic as "Failed to create session"
      }
    })
  })
}

pub fn new_command_resets_session_test() {
  with_gateway(fn(config, _global_conn) {
    let router = gateway.build_router(config)

    conversation.conversation_test()
    |> conversation.send("Hello")
    |> conversation.expect_reply_containing("Echo")
    |> conversation.send("/new")
    |> conversation.expect_reply_containing("fresh")
    |> conversation.run(router, fn() {
      case
        session.create(
          session.simple_config(echo_provider(), "You are a test agent."),
          config.global_conn,
          config.workspace_conn,
          "test:456",
        )
      {
        Ok(sess) -> sess
        Error(_) -> panic as "Failed to create session"
      }
    })
  })
}

// ═══════════════════════════════════════════════════════════════
// Tests — user key extraction
// ═══════════════════════════════════════════════════════════════

pub fn user_key_from_key_extracts_from_id_test() {
  let key = "123456789:987654321"
  let user_key = gateway.user_key_from_key(key)
  let assert "telegram:987654321" = user_key
}

pub fn user_key_from_key_handles_group_chat_test() {
  let key = "-1001234567890:67890"
  let user_key = gateway.user_key_from_key(key)
  let assert "telegram:67890" = user_key
}

// ═══════════════════════════════════════════════════════════════
// Tests — session persistence (M9 gap fixes)
// ═══════════════════════════════════════════════════════════════

/// Test that get_session loads an existing session from DB.
///
/// 1. Pre-create a session for the test user_key and run a prompt (saves to DB)
/// 2. Stop the session (agent dies, simulating restart)
/// 3. Send a message via conversation.run_with() with full session_settings
/// 4. get_session should find the DB session and load it with history
/// 5. The echo provider responds
pub fn session_persistence_round_trip_test() {
  with_gateway(fn(config, global_conn) {
    // Pre-create a session and save messages to DB
    let assert Ok(sess) =
      session.create(
        session.simple_config(echo_provider(), "You are a test agent."),
        config.global_conn,
        config.workspace_conn,
        test_user_key(),
      )
    let assert Ok(_) = session.run_prompt(sess, "First message")
    let conv_id = sess.conversation_id
    session.stop(sess)

    // Verify messages were saved to conversations table
    let store = pg_conversation.from_db(db: config.global_conn)
    let assert Ok(option.Some(json_str)) = yard_conv.load(store, conv_id)
    let messages = agent_checkpoint.messages_from_json_string(json_str)
    let assert 2 = list.length(messages)

    // Now start a conversation with full session_settings.
    // get_session will be called with key "123456789:987654321"
    // which extracts user_key "telegram:987654321" and calls session.load()
    let router = gateway.build_router(config)
    let settings = gateway.session_settings(config)

    conversation.conversation_test()
    |> conversation.send("Second message")
    |> conversation.expect_reply_containing("Echo: Second message")
    |> conversation.run_with(
      fn(ctx, upd) { router.handle(router, ctx, upd) },
      settings,
    )

    // Verify 4 messages total (2 from first session + 2 from loaded session)
    let assert Ok(option.Some(json_str)) = yard_conv.load(store, conv_id)
    let messages = agent_checkpoint.messages_from_json_string(json_str)
    let assert 4 = list.length(messages)
  })
}

/// Test that first message for a brand new user creates a proper session.
///
/// No pre-existing session in DB. get_session returns None (fails to load).
/// default_session creates with "pending" user_key.
/// handle_text detects "pending" and creates proper session with real user_key.
/// Response is sent and messages are persisted to DB.
pub fn first_message_creates_session_for_new_user_test() {
  with_gateway(fn(config, global_conn) {
    // No pre-existing session — fresh user

    let router = gateway.build_router(config)
    let settings = gateway.session_settings(config)

    conversation.conversation_test()
    |> conversation.send("Hello new bot")
    |> conversation.expect_reply_containing("Echo: Hello new bot")
    |> conversation.run_with(
      fn(ctx, upd) { router.handle(router, ctx, upd) },
      settings,
    )

    // Verify messages were saved to conversations table
    let user_key = test_user_key()
    let assert Ok(conv_id) =
      pg_conversation.get_or_create_for_user(
        db: global_conn,
        agent_id: "hermes",
        user_key:,
      )
    let store = pg_conversation.from_db(db: global_conn)
    let assert Ok(option.Some(json_str)) = yard_conv.load(store, conv_id)
    let messages = agent_checkpoint.messages_from_json_string(json_str)
    let assert 2 = list.length(messages)
    let assert [user_msg, assistant_msg] = messages
    let assert message.User("Hello new bot") = user_msg
    let assert message.Assistant(content:, ..) = assistant_msg
    let assert True = string.contains(content, "Echo")
  })
}
