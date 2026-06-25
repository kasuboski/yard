//// Session lifecycle — platform-agnostic session management.
////
//// Uses yard's ConversationStore for persistence (PostgreSQL conversations
//// table) instead of the legacy chat_sessions/chat_messages tables.
//// This is the convergence point: Hermes uses yard primitives directly.
////
//// The session lifecycle:
////   create()  — new pig agent + workspace, new conversation in DB
////   run_prompt() — pig.run() + save conversation to ConversationStore
////   reset()   — stop agent, create new conversation, workspace persists
////   load()    — find conversation, recreate agent with history from store
////   stop()    — stop the pig agent

import gabsurd/client.{type Db}
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError}
import gleam/result
import pig
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import pig/tool
import sqlight
import yard/agent_checkpoint
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

/// A user session holding a live Pig agent, workspace connection,
/// conversation store, conversation ID, and user key.
pub type HermesSession {
  HermesSession(
    agent: pig.Agent,
    workspace_conn: sqlight.Connection,
    conv_store: ConversationStore,
    conversation_id: String,
    user_key: String,
    run_timeout_ms: Int,
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

/// Create a new session with a fresh Pig agent and new conversation.
pub fn create(
  config: SessionConfig,
  db: Db,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  // Create conversation in DB
  use conversation_id <- result.try(
    pg_conversation.get_or_create_for_user(
      db:,
      agent_id: config.agent_name,
      user_key:,
    )
    |> result.replace_error(Nil),
  )

  // Start Pig agent
  use agent <- result.try(
    start_agent(config, [])
    |> result.replace_error(Nil),
  )

  let conv_store = pg_conversation.from_db(db:)

  Ok(HermesSession(
    agent:,
    workspace_conn:,
    conv_store:,
    conversation_id:,
    user_key:,
    run_timeout_ms: config.run_timeout_ms,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Run Prompt
// ═══════════════════════════════════════════════════════════════

/// Run a prompt through the Pig agent and save the conversation.
///
/// Returns the assistant's response text.
pub fn run_prompt(
  session: HermesSession,
  prompt: String,
) -> Result(String, Nil) {
  case pig.try_run_with_timeout(session.agent, prompt, session.run_timeout_ms) {
    Ok(Ok(response)) -> {
      let content = message_content(response)
      // Persist: load existing conversation, append user + assistant,
      // save back to the store.
      persist_turn(session, prompt, response)
      Ok(content)
    }
    _ -> Error(Nil)
  }
}

/// Save the current turn (user prompt + assistant response) to the
/// ConversationStore. Loads existing history, appends the new messages,
/// and saves the full log.
fn persist_turn(
  session: HermesSession,
  prompt: String,
  response: Message,
) -> Nil {
  let existing = case
    conversation.load(session.conv_store, session.conversation_id)
  {
    Ok(option.Some(json_str)) ->
      agent_checkpoint.messages_from_json_string(json_str)
    _ -> []
  }
  let updated = list.append(existing, [message.User(prompt), response])
  let json_str = agent_checkpoint.messages_to_json_string(updated)
  case
    conversation.save(session.conv_store, session.conversation_id, json_str)
  {
    Ok(_) -> Nil
    Error(_) ->
      io.println(
        "[warn] Failed to save conversation " <> session.conversation_id,
      )
  }
}

// ═══════════════════════════════════════════════════════════════
// Reset
// ═══════════════════════════════════════════════════════════════

/// Reset the session: stop the old agent, create a fresh conversation.
///
/// The workspace (VFS + KV) persists across resets — only chat history
/// is cleared by creating a new conversation.
pub fn reset(
  config: SessionConfig,
  session: HermesSession,
  db: Db,
) -> Result(HermesSession, Nil) {
  // Stop old agent
  pig.stop(session.agent)

  // Create a brand-new conversation (not get_or_create, which would find the old one)
  use conversation_id <- result.try(
    pg_conversation.create_new_for_user(
      db:,
      agent_id: config.agent_name,
      user_key: session.user_key,
    )
    |> result.replace_error(Nil),
  )

  // Start fresh agent
  use agent <- result.try(
    start_agent(config, [])
    |> result.replace_error(Nil),
  )

  let conv_store = pg_conversation.from_db(db:)

  Ok(HermesSession(
    agent:,
    workspace_conn: session.workspace_conn,
    conv_store:,
    conversation_id:,
    user_key: session.user_key,
    run_timeout_ms: config.run_timeout_ms,
  ))
}

// ═══════════════════════════════════════════════════════════════
// Load
// ═══════════════════════════════════════════════════════════════

/// Load or create a session for a user.
///
/// If a conversation exists in the DB, creates a Pig agent seeded
/// with the last N messages from that conversation via with_initial_history().
/// If no conversation exists, creates a fresh one.
pub fn load(
  config: SessionConfig,
  db: Db,
  workspace_conn: sqlight.Connection,
  user_key: String,
) -> Result(HermesSession, Nil) {
  // Get or create conversation for user
  use conversation_id <- result.try(
    pg_conversation.get_or_create_for_user(
      db:,
      agent_id: config.agent_name,
      user_key:,
    )
    |> result.replace_error(Nil),
  )

  // Load recent messages for history seeding
  let conv_store = pg_conversation.from_db(db:)
  let history = case conversation.load(conv_store, conversation_id) {
    Ok(option.Some(json_str)) -> {
      let all_messages = agent_checkpoint.messages_from_json_string(json_str)
      // Only seed the last N messages (history_limit)
      take_last_n(all_messages, config.history_limit)
    }
    _ -> []
  }

  // Start Pig agent with optional history
  use agent <- result.try(
    start_agent(config, history)
    |> result.replace_error(Nil),
  )

  Ok(HermesSession(
    agent:,
    workspace_conn:,
    conv_store:,
    conversation_id:,
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

/// Take the last N elements of a list (preserving order).
fn take_last_n(messages: List(Message), n: Int) -> List(Message) {
  let len = list.length(messages)
  case len <= n {
    True -> messages
    False -> {
      let drop = len - n
      list.drop(messages, drop)
    }
  }
}
