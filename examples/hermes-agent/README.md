# Hermes Agent — 5-Pillar Agentic Operating System

A long-lived autonomous agent on the BEAM that accomplishes tasks by **writing and executing programs** rather than calling APIs directly. Built on [Pig](https://github.com/joshuabamboo/pig) (agent runtime), [Yard](../../yard/) (host runtime + observability), [Chute](../../chute/) (language), and [Ballast](../../ballast/) (sandboxed evaluator).

```
LLM (OpenAI-compatible)
  │
  ├─ tool call: chute_exec(source, env)
  │     │
  │     └─ Yard runner → Ballast sandbox
  │           │
  │           ├─ write_file  → workspace VFS (SQLite)
  │           ├─ read_file   → workspace VFS
  │           ├─ list_files  → workspace VFS
  │           ├─ store       → workspace KV (SQLite)
  │           ├─ recall      → workspace KV
  │           ├─ emit_event  → Yard observability
  │           ├─ register_skill / get_skill / list_skills → global DB
  │           ├─ schedule_cron / list_crons / cancel_cron → cron engine
  │           ├─ tell_user   → event collector
  │           └─ learn       → workspace KV (hermes_learned: prefix)
  │
  └─ response: {"ok": <result>, "gas_used": 42, "events": [...]}
```

## How It Works

### The Agent Loop

Hermes is a **Pig agent** — an OTP actor holding conversation history. Each turn:

1. The user sends a message via `pig.run(agent, prompt)`
2. The LLM (via OpenAI-compatible provider) decides what to do
3. If it calls `chute_exec`, the LLM-written Chute program runs in Ballast's sandbox
4. The result (JSON + events + gas) feeds back to the LLM
5. The LLM responds to the user or makes another tool call
6. History, workspace (VFS + KV), and agent state all persist across turns

The LLM never performs I/O directly. It **writes programs** that perform I/O through algebraic effects. This is the core idea: the agent's "cognitive instructions" are executable code, not natural language wishes.

### Why Chute?

Chute is a small functional language purpose-built for LLM-generated programs:

- **Algebraic effects** — `perform write_file(...)`, `perform recall(...)` — give the LLM controlled I/O without shell access or arbitrary code execution
- **Structured error handling** — `let try x = perform read_file("missing.txt")` short-circuits on Error, so the LLM doesn't need to nest `case` expressions
- **Gas metering** — every run has a gas limit (10,000 units), preventing infinite loops
- **Deterministic** — same source always produces the same behavior, making it testable and auditable
- **Sandboxed** — Ballast evaluates Chute without touching the filesystem, network, or OS

The LLM generates Chute source as a string inside a tool call. The host compiles and runs it. The result comes back as structured JSON. This is safer than shell execution and more flexible than a fixed set of API calls.

### The Two-Database Architecture

```
┌─────────────────────────────────────┐
│  Global DB (Yard, SQLite)           │
│                                     │
│  agents, agent_handlers             │
│  skills, schedules, runs            │
│  providers, chat_sessions, messages │
│                                     │
│  Schema managed by Parrot (sqlc)    │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  Per-Agent Workspace DB (Pig, SQLite)│
│                                     │
│  VFS: virtual filesystem            │
│  KV: key-value memory store         │
│                                     │
│  One DB file per agent              │
│  Persists across conversation turns │
└─────────────────────────────────────┘
```

- **Global DB** — agent registry, skill definitions, cron schedules, run history, providers, chat. Schema is codegen'd from SQL via Parrot. Shared across all agents.
- **Workspace DB** — each agent gets its own SQLite file with a virtual filesystem (VFS) and key-value store (KV). State persists across turns. Files written in turn 1 are readable in turn 2.

## The 5 Pillars

| Pillar | Status | Implementation |
|--------|--------|---------------|
| **Skills** | ✅ Done | `register_skill`, `get_skill`, `list_skills` effects. Skills are named Chute programs stored in the global DB. |
| **Memory** | ✅ Done | `store`/`recall` (workspace KV) + `learn` (prefixed KV for agent facts) + VFS files. Persists across turns. |
| **Crons** | ✅ Done | `schedule_cron`, `list_crons`, `cancel_cron` effects. Cron engine OTP actor with `automata` for cron parsing. Fires skills with per-agent handlers via the handler registry. |
| **Learning** | ✅ Done | `learn(key, fact)` stores observations with `hermes_learned:` prefix. `emit_event` traces create auditable thought logs. |
| **Agents** | ✅ Done | `register_agent`, `list_agents` effects. Agent registry with handler bindings in `agent_handlers` table. |

## Effect Handlers

The LLM has access to 16 effects through `chute_exec`:

| Effect | Category | Description |
|--------|----------|-------------|
| `emit_event` | Observability | Emit a named thought trace event |
| `write_file` | VFS | Create/overwrite a file in workspace |
| `read_file` | VFS | Read a file from workspace |
| `list_files` | VFS | List files under a path |
| `store` | KV | Save a key-value fact |
| `recall` | KV | Retrieve a key-value fact |
| `register_skill` | Skills | Register a named Chute program |
| `get_skill` | Skills | Look up a skill by name |
| `list_skills` | Skills | List all active skills |
| `list_agents` | Agents | List registered agents |
| `register_agent` | Agents | Register a new agent |
| `tell_user` | Conversation | Send a message to the user |
| `learn` | Learning | Store a learned fact |
| `schedule_cron` | Cron | Schedule a skill on a cron expression |
| `list_crons` | Cron | List active schedules |
| `cancel_cron` | Cron | Cancel a schedule |

### Handler Tiers

```gleam
// 6 base handlers (workspace only)
effects.all_handlers(conn, collector)

// 13 handlers (+ global DB for skills, agents, conversation, learning)
effects.all_handlers_with_global(conn, global_conn, collector)

// 16 handlers (+ cron engine)
effects.all_handlers_with_cron(conn, global_conn, collector, engine)
```

## Cron Engine & Handler Registry

The cron engine is an OTP actor that fires skills on schedule:

```gleam
let engine = cron_engine.start_with_registry(conn, registry)

// Register a skill, then schedule it
cron_engine.register(engine, skill_id: "my-skill", cron_expr: "0 9 * * 1-5", agent_id: Some("agent-1"))

// Tick fires due schedules (call from a timer or external scheduler)
let fired = cron_engine.tick(engine)
```

### Per-Agent Handler Resolution

Different scheduled tasks need different effects. An issue triage agent needs `fetch_issue`, `fetch_linked`, `run_agent`. A daily report agent needs `http_get`, `send_email`. The **handler registry** makes this work:

```gleam
// 1. Register handler builders in the registry
let registry =
  handler_registry.new()
  |> handler_registry.register("github_fetch", github_fetch_builder)
  |> handler_registry.register("run_agent", run_agent_builder)
  |> handler_registry.register("emit_event", emit_event_builder)

// 2. Bind effects to handlers per agent (stored in agent_handlers table)
db.insert_agent_handler(conn, agent_id: "issue-triage", effect_name: "fetch_issue", handler_name: "github_fetch")
db.insert_agent_handler(conn, agent_id: "issue-triage", effect_name: "fetch_linked", handler_name: "github_fetch")
db.insert_agent_handler(conn, agent_id: "issue-triage", effect_name: "run_agent", handler_name: "run_agent")

// 3. When the cron engine fires a schedule tied to this agent,
//    it loads the bindings, resolves handlers via the registry,
//    and runs the skill with those specific handlers
```

This is the same pattern [`examples/issue-triage`](../issue-triage/) uses, but generalized through a registry instead of hardcoded handlers.

## Running

```bash
# Start Ollama (or any OpenAI-compatible API)
ollama serve

# Set environment (defaults to Ollama localhost)
export OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
export OPENAI_COMPAT_MODEL=llama3

# Run the agent
cd examples/hermes-agent
gleam run
```

The agent will:
1. Start the Yard observability stack (terminal + JSONL session logging)
2. Open a workspace at `/tmp/hermes_workspace.db` (delete to start fresh)
3. Start the Pig agent with `chute_exec` as its tool
4. Send the task defined in `src/hermes_agent.gleam`
5. Print the response and write session to `/tmp/hermes_session_*.jsonl`

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_COMPAT_BASE_URL` | `http://localhost:11434/v1` | LLM API endpoint |
| `OPENAI_COMPAT_API_KEY` | `ollama` | API key |
| `OPENAI_COMPAT_MODEL` | `llama3` | Model name |

## Testing

```bash
cd examples/hermes-agent
gleam test            # 71 tests
```

Tests use fake providers (canned LLM responses) and in-memory SQLite databases. No external services needed.

| Test File | Tests | What It Proves |
|-----------|-------|----------------|
| `chute_exec_test.gleam` | 7 | Chute compilation, execution, gas, workspace effects |
| `effects_test.gleam` | 31 | All 16 handlers + collector + handler registry counts |
| `conversation_test.gleam` | 6 | Multi-turn loop: history, VFS, KV, error recovery |
| `run_tracking_test.gleam` | 5 | Run recording in global DB |
| `value_bridge_test.gleam` | 22 | Ballast Value ↔ JSON conversion |

### The Multi-Turn Proof

The conversation tests prove the core claim: **Pig is the conversation loop**. The agent actor holds `history: List(Message)` across `pig.run()` calls. Workspace state (VFS files, KV facts) persists across turns because the same SQLite connection is used:

```
Turn 1: chute_exec writes "data.txt" → "secret value"
Turn 2: chute_exec reads "data.txt"  → "secret value" ✅ persists
```

## Architecture Layers

```
┌────────────────────────────────────────────────────┐
│  Hermes Agent (this example)                       │
│                                                    │
│  hermes_agent.gleam        — wiring & main loop    │
│  chute_exec.gleam          — pig tool → yard runner │
│  effects.gleam             — 16 effect handlers     │
│  prompt.gleam              — system prompt          │
│  value_bridge.gleam        — ballast ↔ JSON bridge  │
├────────────────────────────────────────────────────┤
│  Yard (host runtime)                               │
│                                                    │
│  runner.gleam              — effect loop            │
│  loader.gleam              — chute compiler         │
│  db.gleam                  — global DB CRUD         │
│  skill_repo.gleam          — skill domain layer     │
│  cron_engine.gleam         — OTP cron actor         │
│  handler_registry.gleam    — per-agent handlers     │
│  obs/                      — dispatcher + consumers │
├────────────────────────────────────────────────────┤
│  Pig (agent runtime)                               │
│                                                    │
│  agent/                    — OTP actor, history     │
│  ai/                       — provider, messages     │
│  workspace/                — VFS + KV (SQLite)      │
├────────────────────────────────────────────────────┤
│  Chute (language) + Ballast (evaluator)             │
│                                                    │
│  parser → desugar → ballast evaluator               │
│  algebraic effects, gas metering, sandboxed         │
└────────────────────────────────────────────────────┘
```

## Yard Features Used

| Feature | Module | What Hermes Uses It For |
|---------|--------|------------------------|
| **Runner** | `yard/runner` | Execute Chute programs with effect handlers and gas limits |
| **Loader** | `yard/loader` | Compile Chute source → Ballast AST with actor hash |
| **Global DB** | `yard/db` | 9 tables: agents, skills, schedules, runs, providers, chat |
| **Skill Repo** | `yard/skill_repo` | Register, lookup, list, deactivate skills |
| **Cron Engine** | `yard/cron_engine` | OTP actor: schedule, tick, fire, reschedule |
| **Handler Registry** | `yard/handler_registry` | Resolve per-agent handler bindings from DB |
| **Observability** | `yard/obs/*` | Dispatcher → terminal consumer + JSONL session files |
| **Parrot** | SQL codegen | Schema + queries → type-safe `sql.gleam` |

## Future Work

### Telegram Chat Integration

The next natural step is connecting Hermes to Telegram for real-world social chat:

```
User → Telegram Bot API → Webhook/Polling
  → Hermes Agent (pig.run)
  → LLM decides: respond directly? Run chute_exec?
  → chute_exec runs with effects
  → Response → Telegram Bot API → User
```

This requires:
1. A Telegram bot adapter (polling or webhook) that translates messages to `pig.run()` calls
2. Session management (map Telegram chat ID → Pig agent + workspace)
3. Streaming responses (Telegram supports editing messages for progressive output)
4. The `tell_user` effect could push proactive messages to the Telegram chat

The multi-turn conversation tests already prove this works — just swap the fake provider for a real LLM and the test assertions for Telegram API calls.

### Specialist Agents

IDEA.md describes a hub-and-spoke model where a Generalist coordinates specialists:

```
Generalist ←→ User
   │
   ├─→ CodeReviewExpert (performs ask_role)
   ├─→ InfraArchitect (performs ask_role)
   └─→ ResearchAgent (performs ask_role)
```

Building blocks in place:
- `register_agent` / `list_agents` — agent registry
- `spawn_subagent` — needs provider access inside Ballast handlers
- VFS mailbox — `/inbox/architect/report.json` for pass-by-reference

### Additional Effects

| Effect | Purpose | Status |
|--------|---------|--------|
| `ask_llm(prompt)` | Raw inference call for sub-tasks | Needs provider access in handlers |
| `ask_role(role, task)` | Delegate to specialist agent | Needs agent spawning |
| `spawn_subagent(manifest)` | Create specialist on demand | Needs provider + agent lifecycle |
| `run_tool(name, args)` | Execute another Chute program | Needs nested runner support |
| `shell_exec(cmd)` | Execute OS commands | Safety considerations |

### Production Cron

The cron engine is tick-based — something external calls `tick()`. For production:

```gleam
// Timer-based tick every 60 seconds
fn start_timer(engine) {
  process.sleep(60_000)
  let _ = cron_engine.tick(engine)
  start_timer(engine)
}
```

Or use a BEAM timer via `gleam/erlang/process` for non-blocking periodic ticks.
