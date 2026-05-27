//// Session lifecycle — platform-agnostic session management.
////
//// HermesSession holds a Pig agent, workspace connection, session ID,
//// and user key. This module provides create/reset/load operations
//// that are reusable across platforms (Telegram, Discord, web UI).
////
//// The session lifecycle:
////   create()  — new Pig agent + workspace, fresh session in DB
////   run_prompt() — pig.run() + save messages to DB
////   reset()   — stop agent, complete session, create fresh agent + session
////   load()    — find active session, recreate agent with history from DB
////   stop()    — stop the Pig agent

import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError}
import gleam/result
import pig
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import pig/tool
import sqlight
import yard/db

// ═══════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════

/// Configuration for creating sessions.
///
/// Carries the provider, system prompt, tools, and agent name
/// so that session.create/load/reset can build a properly configured
/// Pig agent without hardcoding these details.
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

/// A user session holding a live Pig agent, workspace connection, session ID,
/// and user key (for session lookup in the global DB).
pub type HermesSession {
  HermesSession(
    agent: pig.Agent,
    workspace_conn: sqlight.Connection,
    global_conn: sqlight.Connection,
    session_id: String,
    user_key: String,
    run_timeout_ms: Int,
  )
}

// ═══════════════════════════════════════════════════════════════
// Config helpers
// ═══════════════════════════════════════════════════════════════

/// Create a SessionConfig with just a provider and system prompt.
/// No tools, agent_name="hermes", history_limit=20.
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

/// Create a new session with a fresh Pig agent.
///
/// Creates a new chat session in the global DB for the user_key,
/// starts a Pig agent configured from SessionConfig, and returns the session.
pub fn create(
  config: SessionConfig,
  global_conn: sqlight.Connection,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  // Create session in DB
  use session_id <- result.try(
    db.get_or_create_session_for_user(global_conn, user_key)
    |> result.replace_error(Nil),
  )

  // Start Pig agent
  use agent <- result.try(
    start_agent(config, [])
    |> result.replace_error(Nil),
  )

  Ok(HermesSession(
    agent:,
    workspace_conn:,
    global_conn:,
    session_id:,
    user_key:,
    run_timeout_ms: config.run_timeout_ms,
  ))
}

// ═══════════════════════════════════════════════════════════════

/// Run a prompt through the Pig agent and save messages to DB.
///
/// Returns the assistant's response text.
pub fn run_prompt(
  session: HermesSession,
  prompt: String,
) -> Result(String, Nil) {
  case pig.try_run_with_timeout(session.agent, prompt, session.run_timeout_ms) {
    Ok(Ok(response)) -> {
      let content = message_content(response)
      // Save both messages to global DB
      let _ =
        db.save_chat_message(
          session.global_conn,
          session.session_id,
          "user",
          prompt,
        )
      let _ =
        db.save_chat_message(
          session.global_conn,
          session.session_id,
          "assistant",
          content,
        )
      Ok(content)
    }
    _ -> Error(Nil)
  }
}

// ═══════════════════════════════════════════════════════════════
// Reset
// ═══════════════════════════════════════════════════════════════

/// Reset the session: stop the old agent, complete the session, create fresh.
///
/// The workspace (VFS + KV) persists across resets — only chat history is cleared.
pub fn reset(
  config: SessionConfig,
  session: HermesSession,
) -> Result(HermesSession, Nil) {
  // Complete the old session in DB first (so create gets a new one).
  let _ = db.complete_session(session.global_conn, session.session_id)

  // Try to create a new session. If it fails, restart the old agent
  // so the caller isn't left with a dead session.
  case
    create(
      config,
      session.global_conn,
      session.workspace_conn,
      session.user_key,
    )
  {
    Ok(new_session) -> {
      // New session ready — stop old agent.
      pig.stop(session.agent)
      Ok(new_session)
    }
    Error(e) -> {
      // Create failed. Old agent is still alive — restart the completed
      // DB session so the old agent can keep working.
      let _ =
        db.get_or_create_session_for_user(session.global_conn, session.user_key)
      Error(e)
    }
  }
}

// ═══════════════════════════════════════════════════════════════

/// Load or create a session for a user.
///
/// If an active session exists in the DB, creates a Pig agent seeded
/// with the last N messages from that session via with_initial_history().
/// If no session exists, creates a fresh one.
pub fn load(
  config: SessionConfig,
  global_conn: sqlight.Connection,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  // Get or create session for user
  use session_id <- result.try(
    db.get_or_create_session_for_user(global_conn, user_key)
    |> result.replace_error(Nil),
  )

  // Load recent messages for history seeding
  let history = case
    db.get_recent_messages(global_conn, session_id, config.history_limit)
  {
    Ok(messages) -> messages_to_history(messages)
    Error(_) -> []
  }

  // Start Pig agent with optional history
  use agent <- result.try(
    start_agent(config, history)
    |> result.replace_error(Nil),
  )

  Ok(HermesSession(
    agent:,
    workspace_conn:,
    global_conn:,
    session_id:,
    user_key:,
    run_timeout_ms: config.run_timeout_ms,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Stop
// ═══════════════════════════════════════════════════════════════

/// Stop the session's Pig agent.
pub fn stop(session: HermesSession) -> Nil {
  pig.stop(session.agent)
}

// ═══════════════════════════════════════════════════════════════
// Internal
// ═══════════════════════════════════════════════════════════════

/// Start a Pig agent from SessionConfig with optional initial history.
fn start_agent(
  config: SessionConfig,
  history: List(Message),
) -> Result(pig.Agent, StartError) {
  let pig_config =
    pig.new(config.provider)
    |> pig.with_agent_name(config.agent_name)
    |> pig.with_system_prompt(config.system_prompt)

  // Register tools
  let pig_config =
    list.fold(config.tools, pig_config, fn(cfg, t) { pig.with_tool(cfg, t) })

  // Seed history if present
  let pig_config = case history {
    [] -> pig_config
    messages -> pig.with_initial_history(pig_config, messages)
  }

  pig.start(pig_config)
}

/// Extract text content from a Pig Message.
fn message_content(msg: Message) -> String {
  case msg {
    message.Assistant(content:, ..) -> content
    _ -> ""
  }
}

/// Convert DB ChatMessage rows to Pig Message list for history seeding.
/// Lossy: tool calls, thinking blocks, tool results are not preserved.
fn messages_to_history(messages: List(db.ChatMessage)) -> List(Message) {
  list.map(messages, fn(msg) {
    case msg.role {
      "user" -> message.User(msg.content)
      "assistant" -> message.Assistant(msg.content, [], option.None)
      "system" -> message.System(msg.content)
      _ -> message.User(msg.content)
    }
  })
}
