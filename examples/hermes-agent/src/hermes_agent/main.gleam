//// Hermes Agent — Telegram Gateway main entry point.
////
//// Starts the Telegram bot with the full Hermes feature set:
////   - chute_exec tool (LLM writes Chute programs, Ballast evaluates)
////   - 16 effect handlers (VFS, KV, skills, crons, agents, learning)
////   - Yard observability (terminal + JSONL session logging)
////   - Per-user chat sessions with message persistence
////   - OpenAI-compatible LLM provider (Ollama, OpenAI, Together, etc.)
////   - Telega polling for Telegram updates
////
//// Environment variables:
////   TELEGRAM_BOT_TOKEN     — Bot token from @BotFather (required)
////   OPENAI_COMPAT_API_KEY — LLM API key (default: "ollama")
////   OPENAI_COMPAT_MODEL   — LLM model name (default: "llama3")
////   OPENAI_COMPAT_BASE_URL — LLM API base URL (default: "http://localhost:11434/v1")
////   HERMES_DB_DIR         — Directory for DB files (default: "/tmp/hermes")

import envoy
import gabsurd/client
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import pig/ai/openai
import pig/workspace
import simplifile
import telega
import telega_httpc
import yard/db
import yard/obs/dispatcher
import yard/obs/pg_events
import yard/obs/session as yard_session
import yard/obs/terminal
import yard/runner
import yard/ui/server as ui_server

import hermes_agent/chute_exec
import hermes_agent/gateway
import hermes_agent/prompt
import hermes_agent/session

// ═══════════════════════════════════════════════════════════════
// Environment configuration
// ═══════════════════════════════════════════════════════════════

fn telegram_token() -> String {
  case envoy.get("TELEGRAM_BOT_TOKEN") {
    Ok(token) -> token
    Error(_) -> {
      io.println("ERROR: TELEGRAM_BOT_TOKEN not set")
      io.println("Get a token from @BotFather on Telegram")
      panic as "TELEGRAM_BOT_TOKEN not set"
    }
  }
}

fn openai_api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn openai_model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

fn openai_base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn db_dir() -> String {
  envoy.get("HERMES_DB_DIR")
  |> result.unwrap("/tmp/hermes")
}

fn db_url() -> String {
  envoy.get("DATABASE_URL")
  |> result.unwrap("postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd")
}

fn ui_port() -> Int {
  case envoy.get("YARD_UI_PORT") {
    Ok(port_str) ->
      case int.parse(port_str) {
        Ok(port) -> port
        Error(_) -> 4001
      }
    Error(_) -> 4001
  }
}

// ═══════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════

pub fn main() {
  io.println("========================================")
  io.println("  Hermes Agent — Telegram Gateway")
  io.println("========================================")
  io.println("")

  let dir = db_dir()
  let _ = simplifile.create_directory_all(dir)

  // ── 1. Yard observability stack ──────────────────────────────
  let assert Ok(yard_dispatcher) = dispatcher.start()

  let assert Ok(yard_terminal) = terminal.start()
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_terminal))

  let yard_session_path =
    dir <> "/hermes_obs_" <> yard_session.iso_timestamp() <> ".jsonl"
  let assert Ok(yard_sess) = yard_session.start_consumer(yard_session_path)
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_sess))

  io.println("Yard observability started (terminal + JSONL)")
  io.println("Obs: " <> yard_session_path)

  // ── 2. Database setup ───────────────────────────────────────
  let assert Ok(started) = client.start(db_url())
  let global_conn = started.data
  let assert Ok(Nil) = db.migrate(global_conn)

  let workspace_path = dir <> "/hermes_workspace.db"
  let assert Ok(ws) = workspace.open(workspace_path)
  let workspace_conn = workspace.connection(ws)

  // PostgreSQL events consumer — writes events to yard_events table
  let assert Ok(yard_pg) = pg_events.start_consumer(global_conn)
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_pg))

  // ── 2b. UI dashboard ────────────────────────────────────────
  let ui = ui_port()
  let assert Ok(_) = ui_server.start(db: global_conn, port: ui)

  io.println("DB: " <> dir)
  io.println("Dashboard: http://localhost:" <> int.to_string(ui))

  // ── 3. LLM provider ─────────────────────────────────────────
  let provider =
    openai.provider_with_base_url(
      openai_api_key(),
      openai_model(),
      openai_base_url(),
    )

  io.println("LLM: " <> openai_base_url() <> " model=" <> openai_model())

  // ── 4. Session config with full features ─────────────────────
  // chute_exec tool: LLM writes Chute programs, Ballast evaluates
  // them with Yard observability piped through the dispatcher.
  let chute_cfg =
    chute_exec.config(
      workspace_conn,
      runner.emit_to_dispatcher(yard_dispatcher),
    )
  let chute_tool = chute_exec.tool(chute_cfg)

  let sess_config =
    session.SessionConfig(
      provider: provider.call,
      system_prompt: prompt.system_prompt(),
      tools: [chute_tool],
      agent_name: "hermes-agent",
      history_limit: 20,
      run_timeout_ms: 300_000,
    )

  // ── 5. Gateway config ───────────────────────────────────────
  let config =
    gateway.GatewayConfig(
      global_conn:,
      workspace_conn:,
      session_config: sess_config,
    )

  // ── 6. Start Telegram bot ───────────────────────────────────
  let token = telegram_token()
  let api_client = telega_httpc.new(token)

  let router = gateway.build_router(config)
  let settings = gateway.session_settings(config)

  io.println("Starting Telegram polling...")
  let assert Ok(_bot) =
    telega.new_for_polling(api_client:)
    |> telega.with_router(router)
    |> telega.with_session_settings(settings)
    |> telega.init_for_polling()

  io.println("")
  io.println("Hermes Agent is running!")
  io.println("Send /new to reset your session.")
  io.println("Press Ctrl+C to stop.")
  io.println("")

  // Block forever — the OTP actors handle everything
  process.sleep_forever()
}
