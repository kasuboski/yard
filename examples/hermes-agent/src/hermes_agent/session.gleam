//// Session lifecycle — platform-agnostic session management.
////
//// Uses yard's agent_turn handler for the agent loop, which delegates to
//// pig's run_continue and automatically persists conversations to the
//// ConversationStore (PostgreSQL conversations table).
////
//// The session lifecycle:
////   create()  — new conversation in DB, store config for agent_turn
////   run_prompt() — delegate to agent_turn.execute_turn() (auto-saves)
////   reset()   — create new conversation, workspace persists
////   load()    — find conversation, store config for agent_turn
////   stop()    — no-op (agents are ephemeral, created per-turn by agent_turn)

import gabsurd/client.{type Db}
import gleam/dynamic/decode
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import pig/tool
import sqlight
import yard/agent_checkpoint
import yard/agent_turn
import yard/conversation.{type ConversationStore}
import yard/pg_conversation

// ═══════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════

/// Configuration for creating sessions.
pub type SessionConfig {
  SessionConfig(
    provider: Provider,
    system_prompt: String,
    tools: List(tool.Tool),
    agent_name: String,
    history_limit: Int,
    run_timeout_ms: Int,
  )
}

/// A user session. Each turn creates an ephemeral pig agent via
/// agent_turn.execute_turn(), which runs the agent loop and
/// persists the conversation automatically.
pub type HermesSession {
  HermesSession(
    config: SessionConfig,
    db: Db,
    workspace_conn: sqlight.Connection,
    conv_store: ConversationStore,
    conversation_id: String,
    user_key: String,
  )
}

// ═══════════════════════════════════════════════════════════════
// Config helpers
// ═══════════════════════════════════════════════════════════════

/// Create a SessionConfig with just a provider and system prompt.
pub fn simple_config(
  provider: Provider,
  system_prompt: String,
) -> SessionConfig {
  SessionConfig(
    provider:,
    system_prompt:,
    tools: [],
    agent_name: "hermes",
    history_limit: 20,
    run_timeout_ms: 300_000,
  )
}

// ═══════════════════════════════════════════════════════════════
// Create
// ═══════════════════════════════════════════════════════════════

/// Create a new session with a new conversation in the DB.
pub fn create(
  config: SessionConfig,
  db: Db,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  use conversation_id <- result.try(
    pg_conversation.create_new_for_user(
      db:,
      agent_id: config.agent_name,
      user_key:,
    )
    |> result.replace_error(Nil),
  )

  let conv_store = pg_conversation.from_db(db:)

  Ok(HermesSession(
    config:,
    db:,
    workspace_conn:,
    conv_store:,
    conversation_id:,
    user_key:,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Run Prompt — delegates to yard's agent_turn
// ═══════════════════════════════════════════════════════════════

/// Run a prompt through the agent and save the conversation.
///
/// Delegates to yard's `agent_turn.execute_turn()`, which:
/// 1. Loads conversation history from the ConversationStore
/// 2. Appends the user message
/// 3. Creates an ephemeral pig agent seeded with history
/// 4. Runs via pig.run_continue() (handles tool calls, stop_reasons)
/// 5. Saves the updated conversation back to the store automatically
///
/// Returns the assistant's response text.
pub fn run_prompt(
  session: HermesSession,
  prompt: String,
) -> Result(String, Nil) {
  // Each turn gets a fresh run_id so host (yard_events) and pig
  // (pig_events) events for this invocation can be correlated.
  let run_id = case generate_run_id(session.db) {
    Ok(id) -> id
    Error(_) -> "00000000-0000-0000-0000-000000000000"
  }
  case
    agent_turn.execute_turn(
      conv_store: session.conv_store,
      conversation_id: session.conversation_id,
      user_message: prompt,
      provider: session.config.provider,
      tools: session.config.tools,
      system_prompt: session.config.system_prompt,
      agent_name: session.config.agent_name,
      run_timeout_ms: session.config.run_timeout_ms,
      bridge: option.Some(agent_turn.BridgeConfig(
        db: session.db,
        run_id: run_id,
        actor_path: session.config.agent_name,
        actor_hash: "hermes",
      )),
    )
  {
    Ok(agent_turn.TurnResult(final_message:, ..)) ->
      Ok(message_content(final_message))
    Error(agent_turn.TurnError(msg)) -> {
      io.println("[error] agent_turn failed: " <> msg)
      Error(Nil)
    }
  }
}

/// Generate a fresh UUID run_id from Postgres.
fn generate_run_id(db: Db) -> Result(String, Nil) {
  client.query_one(db, #("SELECT gen_random_uuid()::text", [], run_id_decoder()))
  |> result.replace_error(Nil)
}

fn run_id_decoder() -> decode.Decoder(String) {
  use id <- decode.field(0, decode.string)
  decode.success(id)
}

// ═══════════════════════════════════════════════════════════════
// Reset
// ═══════════════════════════════════════════════════════════════

/// Reset the session: create a fresh conversation.
///
/// The workspace (VFS + KV) persists across resets — only chat history
/// is cleared by creating a new conversation.
pub fn reset(
  config: SessionConfig,
  session: HermesSession,
  db: Db,
) -> Result(HermesSession, Nil) {
  use conversation_id <- result.try(
    pg_conversation.clear_for_user(
      db:,
      agent_id: config.agent_name,
      user_key: session.user_key,
    )
    |> result.replace_error(Nil),
  )

  let conv_store = pg_conversation.from_db(db:)

  Ok(HermesSession(
    config:,
    db:,
    workspace_conn: session.workspace_conn,
    conv_store:,
    conversation_id:,
    user_key: session.user_key,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Load
// ═══════════════════════════════════════════════════════════════

/// Load or create a session for a user.
///
/// Finds (or creates) a conversation in the DB. The conversation history
/// is loaded automatically by agent_turn.execute_turn() on the next turn.
pub fn load(
  config: SessionConfig,
  db: Db,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  use conversation_id <- result.try(
    pg_conversation.get_or_create_for_user(
      db:,
      agent_id: config.agent_name,
      user_key:,
    )
    |> result.replace_error(Nil),
  )

  let conv_store = pg_conversation.from_db(db:)

  Ok(HermesSession(
    config:,
    db:,
    workspace_conn:,
    conv_store:,
    conversation_id:,
    user_key:,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Stop
// ═══════════════════════════════════════════════════════════════

/// No-op. Agents are ephemeral — agent_turn creates and stops them
/// per turn. Kept for API compatibility with callers.
pub fn stop(_session: HermesSession) -> Nil {
  Nil
}

// ═══════════════════════════════════════════════════════════════
// Internal
// ═══════════════════════════════════════════════════════════════

/// Extract text content from a Pig Message.
fn message_content(msg: Message) -> String {
  case msg {
    message.Assistant(content:, ..) -> content
    _ -> ""
  }
}
