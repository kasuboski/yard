//// Gateway — Telegram bot integration via telega.
////
//// Wires HermesSession into telega's ChatInstance actor lifecycle.
//// Provides session callbacks, text handler, and command handlers
//// that delegate to the platform-agnostic session module.
////
//// Architecture:
////   telega ChatInstance holds HermesSession in memory
////   ├── Text handler: session.run_prompt() → reply.with_text()
////   ├── /new command: session.reset_with_provider() → reply
////   └── Session callbacks: load from DB via get_session
////
//// Session key flow:
////   1. telega builds key = "{chat_id}:{from_id}" from each update
////   2. get_session(key) extracts from_id → "telegram:{from_id}" → session.load()
////   3. If no DB session, falls through to default_session() with "pending" user_key
////   4. handle_text detects "pending" and creates proper session with real user_key

import gleam/int
import gleam/io
import gleam/option
import gleam/string
import pig
import sqlight
import telega/bot
import telega/reply
import telega/router
import telega/update

import hermes_agent/session.{type HermesSession, type SessionConfig}
import yard/db

// ═══════════════════════════════════════════════════════════════
// Config
// ═══════════════════════════════════════════════════════════════

/// Configuration needed to create session settings.
/// Closes over SessionConfig and DB connections so the callbacks
/// can create HermesSession instances.
pub type GatewayConfig {
  GatewayConfig(
    global_conn: sqlight.Connection,
    workspace_conn: sqlight.Connection,
    session_config: SessionConfig,
  )
}

// ═══════════════════════════════════════════════════════════════
// User key extraction
// ═══════════════════════════════════════════════════════════════

/// Extract user_key from telega's internal session key.
///
/// Telega keys are "{chat_id}:{from_id}". We extract from_id
/// and prefix with "telegram:" to create a platform-namespaced key.
/// In private chats, chat_id == from_id; in groups they differ.
pub fn user_key_from_key(key: String) -> String {
  case string.split(key, ":") {
    [_chat_id, from_id_str] ->
      case int.parse(from_id_str) {
        Ok(from_id) -> "telegram:" <> int.to_string(from_id)
        Error(_) -> key
      }
    _ -> key
  }
}

/// Extract user_key from a telega update's from_id.
pub fn user_key_from_update(upd: update.Update) -> String {
  "telegram:" <> int.to_string(upd.from_id)
}

// ═══════════════════════════════════════════════════════════════
// Session Settings — telega callbacks
// ═══════════════════════════════════════════════════════════════

/// Create telega SessionSettings wired to the Hermes session lifecycle.
///
/// - get_session: loads existing session from DB via session.load()
/// - default_session: creates with "pending" user_key (fixed on first message)
/// - persist_session: no-op (messages saved by run_prompt after each turn)
pub fn session_settings(
  config: GatewayConfig,
) -> bot.SessionSettings(HermesSession, Nil) {
  bot.SessionSettings(
    default_session: fn() {
      // Fallback: creates session with placeholder user_key.
      // On first message, handle_text will detect "pending" and create
      // a proper session with the real user_key from the update context.
      case
        session.create(
          config.session_config,
          config.global_conn,
          config.workspace_conn,
          "pending",
        )
      {
        Ok(sess) -> sess
        Error(_) -> panic as "Failed to create default HermesSession"
      }
    },
    get_session: fn(key) {
      let user_key = user_key_from_key(key)
      case
        session.load(
          config.session_config,
          config.global_conn,
          config.workspace_conn,
          user_key,
        )
      {
        Ok(sess) -> Ok(option.Some(sess))
        Error(_) -> Ok(option.None)
      }
    },
    persist_session: fn(_key, sess) {
      // Messages are already saved by run_prompt after each turn.
      // HermesSession holds a live Pig agent (not serializable),
      // so there's nothing additional to persist here.
      Ok(sess)
    },
  )
}

// ═══════════════════════════════════════════════════════════════
// Router — text + command handlers
// ═══════════════════════════════════════════════════════════════

/// Build the telega router with Hermes handlers.
pub fn build_router(
  config: GatewayConfig,
) -> router.Router(HermesSession, Nil) {
  router.new("hermes_gateway")
  |> router.on_any_text(handle_text(config))
  |> router.on_commands(["new", "reset"], handle_new(config))
}

/// Text handler: run prompt through Pig agent and reply.
///
/// If the session has a "pending" user_key (from default_session fallback),
/// creates a proper session with the real user_key from the update context.
fn handle_text(
  config: GatewayConfig,
) -> fn(bot.Context(HermesSession, Nil), String) ->
  Result(bot.Context(HermesSession, Nil), Nil) {
  fn(ctx: bot.Context(HermesSession, Nil), text) {
    io.println("[text] Received message for user: " <> ctx.session.user_key)

    // Fix "pending" user_key if needed (first message from new user)
    let ctx = ensure_user_key(config, ctx)

    let response = session.run_prompt(ctx.session, text)
    case response {
      Ok(content) -> {
        let _ = reply.with_text(ctx, content)
        Ok(ctx)
      }
      Error(_) -> {
        let _ = reply.with_text(ctx, "Sorry, I encountered an error.")
        Ok(ctx)
      }
    }
  }
}

/// /new command handler: reset the session.
fn handle_new(
  config: GatewayConfig,
) -> fn(bot.Context(HermesSession, Nil), update.Command) ->
  Result(bot.Context(HermesSession, Nil), Nil) {
  fn(ctx: bot.Context(HermesSession, Nil), _command) {
    io.println("[/new] Reset requested for user: " <> ctx.session.user_key)

    // Fix "pending" user_key if needed
    let ctx = ensure_user_key(config, ctx)

    case session.reset(config.session_config, ctx.session) {
      Ok(new_session) -> {
        io.println("[/new] Reset OK, new session: " <> new_session.session_id)
        let assert Ok(ctx) = bot.next_session(ctx, new_session)
        let _ = reply.with_text(ctx, "Starting fresh! Workspace preserved.")
        io.println("[/new] Reply sent, returning updated context")
        Ok(ctx)
      }
      Error(_) -> {
        io.println("[/new] ERROR: session.reset failed!")
        let _ = reply.with_text(ctx, "Failed to reset session.")
        Ok(ctx)
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Internal
// ═══════════════════════════════════════════════════════════════

/// Ensure the session has a real user_key, not "pending".
///
/// When telega falls through to default_session(), the session is
/// created with user_key="pending". On the first real message, we
/// extract the user_id from the update context and create a proper
/// session, stopping the pending agent.
fn ensure_user_key(
  config: GatewayConfig,
  ctx: bot.Context(HermesSession, Nil),
) -> bot.Context(HermesSession, Nil) {
  case ctx.session.user_key == "pending" {
    False -> ctx
    True -> {
      let user_key = user_key_from_update(ctx.update)
      // Stop the pending agent and create a proper session
      pig.stop(ctx.session.agent)
      let _ = db.complete_session(config.global_conn, ctx.session.session_id)
      case
        session.create(
          config.session_config,
          config.global_conn,
          config.workspace_conn,
          user_key,
        )
      {
        Ok(new_session) -> {
          let assert Ok(ctx) = bot.next_session(ctx, new_session)
          ctx
        }
        Error(_) -> ctx
        // Keep pending session as fallback
      }
    }
  }
}
