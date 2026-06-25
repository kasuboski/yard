//// Hermes Agent — 5-Pillar Agentic Operating System on the BEAM
////
//// CLI entry point. Uses the same session machinery as the Telegram
//// gateway (HermesSession, chat_messages, workspace persistence) but
//// runs a single prompt and exits.
////
//// The agent uses chute_exec as its primary tool — the LLM writes Chute
//// programs which are executed in Ballast's sandbox with Hermes effect
//// handlers bridging to Pig's workspace (VFS + KV).
////
//// Architecture:
////
////   LLM (via OpenAI-compatible provider)
////     │
////     ├─ tool call: chute_exec(source, env)
////     │     │
////     │     └─ Yard runner → Ballast evaluator
////     │           │
////     │           ├─ emit_event  → cell actor (events echoed back to LLM)
////     │           ├─ read_file   → Pig workspace VFS
////     │           ├─ write_file  → Pig workspace VFS
////     │           ├─ list_files  → Pig workspace VFS
////     │           ├─ recall      → Pig workspace KV
////     │           └─ store       → Pig workspace KV
////     │
////     └─ response: JSON with result + events + gas_used
////
//// Running: `gleam run`
//// Environment: OPENAI_COMPAT_BASE_URL, OPENAI_COMPAT_API_KEY,
////              OPENAI_COMPAT_MODEL (defaults to Ollama localhost)

import envoy
import gleam/erlang/process
import gleam/io
import gleam/result
import gabsurd/client
import pig/ai/openai
import pig/workspace
import simplifile
import yard/db
import yard/obs/dispatcher
import yard/obs/session as yard_session
import yard/obs/terminal
import yard/runner

import hermes_agent/chute_exec
import hermes_agent/prompt
import hermes_agent/session

// ═══════════════════════════════════════════════════════════════
// Config — Environment Variables
// ═══════════════════════════════════════════════════════════════

fn openai_base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn openai_api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn openai_model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

fn db_dir() -> String {
  envoy.get("HERMES_DB_DIR")
  |> result.unwrap("/tmp/hermes")
}

fn db_url() -> String {
  envoy.get("DATABASE_URL")
  |> result.unwrap("postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd")
}

// ═══════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════

/// The task to send to the agent. Swap this variable to test different prompts.
const task = "List the files in the workspace root, then write a greeting."

pub fn main() {
  io.println("╔════════════════════════════════════════════════════╗")
  io.println("║  Hermes Agent — 5-Pillar Agentic OS on the BEAM   ║")
  io.println("╚════════════════════════════════════════════════════╝")
  io.println("")

  // ── 1. Config ────────────────────────────────────────────────
  let dir = db_dir()
  let _ = simplifile.create_directory_all(dir)

  let workspace_path = dir <> "/hermes_workspace.db"
  let yard_session_path =
    dir <> "/hermes_obs_" <> yard_session.iso_timestamp() <> ".jsonl"

  io.println("LLM:       " <> openai_model() <> " @ " <> openai_base_url())
  io.println("DB:        " <> dir)
  io.println("Workspace: " <> workspace_path)
  io.println("Obs:       " <> yard_session_path)
  io.println("Task:      " <> task)
  io.println("")

  // ── 2. Yard observability stack ──────────────────────────────
  let assert Ok(yard_dispatcher) = dispatcher.start()

  let assert Ok(yard_terminal) = terminal.start()
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_terminal))

  let assert Ok(yard_sess) = yard_session.start_consumer(yard_session_path)
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_sess))

  io.println("Yard observability started")

  // ── 3. Database setup ───────────────────────────────────────
  let assert Ok(started) = client.start(db_url())
  let global_conn = started.data
  let assert Ok(Nil) = db.migrate(global_conn)

  let assert Ok(ws) = workspace.open(workspace_path)
  let workspace_conn = workspace.connection(ws)

  // ── 4. Build session config with chute_exec tool ─────────────
  let provider =
    openai.provider_with_base_url(
      openai_api_key(),
      openai_model(),
      openai_base_url(),
    )

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

  // ── 5. Load session ────────────────────────────────────────
  // CLI user_key is "cli:local" — shared across CLI runs.
  // Conversation history persists in chat_messages.
  io.println("Starting session...")
  let assert Ok(sess) =
    session.load(sess_config, global_conn, workspace_conn, "cli:local")
  io.println("Session: " <> sess.session_id)
  io.println("")

  // ── 6. Run task ─────────────────────────────────────────────
  case session.run_prompt(sess, task) {
    Ok(response) -> {
      io.println("Agent response:")
      io.println(response)
    }
    Error(_) -> io.println("[error running agent]")
  }

  // ── 7. Shutdown ─────────────────────────────────────────────
  // Stop the session, give Yard a moment to flush pending events,
  // then stop the dispatcher.
  session.stop(sess)
  process.sleep(200)
  process.send(yard_dispatcher, dispatcher.Stop)
  io.println("")
  io.println("Observability: " <> yard_session_path)
  io.println("Messages:      " <> db_url())
  io.println("Done.")
}
