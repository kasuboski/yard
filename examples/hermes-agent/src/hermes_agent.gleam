//// Hermes Agent — 5-Pillar Agentic Operating System on the BEAM
////
//// Main entry point. Wires together:
//// - Pig (agent runtime with LLM provider)
//// - Yard (host runtime with observability)
//// - Ballast (sandboxed Chute evaluator)
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
import pig
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import pig/workspace
import yard/obs/dispatcher
import yard/obs/session
import yard/obs/terminal
import yard/runner

import hermes_agent/chute_exec
import hermes_agent/prompt

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

// ═══════════════════════════════════════════════════════════════
// Agent Construction
// ═══════════════════════════════════════════════════════════════

/// Build a Hermes PigConfig with all wiring in place.
///
/// Creates a workspace, registers the chute_exec tool,
/// sets the system prompt, and configures observability.
/// Yard events from Ballast flow to the Yard dispatcher.
pub fn build_config(
  workspace_path: String,
  yard_dispatcher: process.Subject(dispatcher.DispatcherMessage),
) -> pig.PigConfig {
  let provider =
    openai.provider_with_base_url(
      openai_api_key(),
      openai_model(),
      openai_base_url(),
    )

  // Open workspace — VFS + KV for the agent.
  // Note: workspace is SQLite-backed and persists across runs.
  // Delete the db file to start fresh.
  let assert Ok(ws) = workspace.open(workspace_path)
  let conn = workspace.connection(ws)

  // Build chute_exec tool with workspace access + Yard observability
  let cfg = chute_exec.config(conn, runner.emit_to_dispatcher(yard_dispatcher))
  let chute_tool = chute_exec.tool(cfg)

  pig.new(provider.call)
  |> pig.with_model("hermes")
  |> pig.with_agent_name("hermes-agent")
  |> pig.with_system_prompt(prompt.system_prompt())
  |> pig.with_tool(chute_tool)
  |> pig.with_terminal_output()
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
  // Note: workspace_path uses a fixed SQLite DB so VFS/KV state
  // persists between runs. Delete the file to start fresh.
  let workspace_path = "/tmp/hermes_workspace.db"
  let session_path =
    "/tmp/hermes_session_" <> session.iso_timestamp() <> ".jsonl"

  io.println("LLM:       " <> openai_model() <> " @ " <> openai_base_url())
  io.println("Workspace: " <> workspace_path)
  io.println("Session:   " <> session_path)
  io.println("Task:      " <> task)
  io.println("")

  // ── 2. Yard observability stack ──────────────────────────────
  let assert Ok(yard_dispatcher) = dispatcher.start()

  let assert Ok(yard_terminal) = terminal.start()
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_terminal))

  let assert Ok(yard_session) = session.start_consumer(session_path)
  process.send(yard_dispatcher, dispatcher.RegisterConsumer(yard_session))

  io.println("Yard observability started")
  io.println("")

  // ── 3. Build & start agent ──────────────────────────────────
  let cfg = build_config(workspace_path, yard_dispatcher)

  io.println("Starting agent...")
  let assert Ok(agent) = pig.start(cfg)
  io.println("Agent started.")
  io.println("")

  // ── 4. Run task ─────────────────────────────────────────────
  case pig.run_with_timeout(agent, task, 120_000) {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("Agent response:")
      io.println(content)
    }
    Ok(_) -> io.println("[unexpected response type]")
    Error(error.Timeout) -> io.println("[timeout — agent took too long]")
    Error(error.RateLimited) -> io.println("[rate limited — slow down]")
    Error(error.ApiError(msg)) -> io.println("[API error: " <> msg <> "]")
    Error(error.InvalidResponse(detail)) ->
      io.println("[invalid response: " <> detail <> "]")
  }

  // ── 5. Shutdown ─────────────────────────────────────────────
  // Stop the agent first, then give Yard a moment to flush
  // any pending observability events before stopping the dispatcher.
  pig.stop(agent)
  process.sleep(200)
  process.send(yard_dispatcher, dispatcher.Stop)
  io.println("")
  io.println("Session written to: " <> session_path)
  io.println("Done.")
}
