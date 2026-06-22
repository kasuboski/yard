# Durable Execution

How Yard survives crashes and resumes work without re-calling the LLM or
re-running side effects. Built on [gabsurd](../../gabsurd) (Gleam bindings
for [Absurd](https://github.com/earendil-works/absurd)), a PostgreSQL-native
durable workflow engine.

---

## The Problem

Yard runs Chute programs via Ballast's CPS evaluator. Before durability, a
BEAM node crash mid-execution lost everything — no resume, no retry, no
recovery. A crash after an LLM response but before the tool returned meant
the response was gone. Re-running the program re-called every handler,
risking double-charges and non-deterministic results.

Durability solves this at two levels:

1. **Chute/Ballast effect execution** — checkpoint each effect handler result
   so a crashed run can be replayed and resumed
2. **Pig agent loops** — checkpoint each LLM response and tool result so a
   crashed conversation can be resumed without re-calling the LLM

Both levels run inside gabsurd tasks, use PostgreSQL as the durable store,
and are transparent to the Chute program and the LLM.

---

## Architecture

```
User sends message
  │
  ▼
Gateway spawns gabsurd task "run-agent-turn" (one task per user turn)
  │
  ▼
gabsurd worker claims task
  │
  ├─ Load conversation history from conversations table
  ├─ Load per-task checkpoints from previous attempt (if retry)
  ├─ If checkpoints exist, use them (ahead of table); else use table history
  ├─ Append user message to log (checkpoint "msg:0")
  ├─ Create Pig agent seeded with assembled history
  ├─ Run Pig loop via run_continue():
  │    ├─ LLM inference → checkpoint "msg:N"
  │    ├─ Tool call: chute_exec → run Ballast program:
  │    │    ├─ Effect yielded → handler runs → checkpoint "{idx}:{effect_name}"
  │    │    └─ Program complete → checkpoint tool result as "msg:N+1"
  │    ├─ LLM inference → checkpoint "msg:N+2"
  │    └─ ... until stop_reason = Stop
  ├─ Save full message log to conversations table
  ├─ Return final assistant message
  └─ Task completed
```

### Crash Recovery

If the BEAM node crashes, gabsurd retries the task automatically:

1. **Load checkpoints** — walk the ordered checkpoint list, rebuilding the
   message log and effect results
2. **Determine entry point** — the last checkpointed message decides what
   happens next (see Entry Point Resolution below)
3. **Resume** — execute only the steps after the last checkpoint

LLM responses are never re-generated. They are loaded from PostgreSQL. Only
new steps after the last checkpoint actually execute.

---

## Module Map

```
yard/src/yard/
├── value_codec.gleam         # Ballast Value ↔ JSON tagged-union serialization
├── checkpoint.gleam          # Checkpointer abstraction (save/load step results)
├── runner.gleam              # Effect loop — handle_yield wraps with checkpoint/replay
├── conversation.gleam        # ConversationStore abstraction (multi-turn persistence)
├── pg_conversation.gleam     # PostgreSQL-backed ConversationStore
├── gabsurd_checkpointer.gleam # Bridges Checkpointer to gabsurd's PG checkpoint API
├── agent_checkpoint.gleam    # Entry point resolution + message-log checkpointing
├── durable_turn.gleam        # Conversation+checkpoint merge ("checkpoints ahead of table")
├── agent_turn.gleam          # Durable Pig LLM call with checkpoint/retry
├── durable_handler.gleam     # gabsurd worker handler for running Chute programs
├── pg_events.gleam           # PostgreSQL event store (replaces JSONL)
├── pg_cron.gleam             # pg_cron scheduler (replaces OTP cron engine)
├── ui/
│   ├── queries.gleam         # SQL queries for the dashboard
│   ├── template.gleam        # HTML dashboard generator
│   └── server.gleam          # mist HTTP server (routes + handlers)
└── sql/
    ├── durable_schema.sql    # conversations + yard_events table DDL
    └── cron_test_stub.sql    # Mock cron.schedule/unschedule for testing
```

---

## Effect Checkpointing

### The Continuation Problem

Ballast continuations are opaque BEAM closures — they cannot be serialized.
You can't snapshot "where the program is." Instead, durability uses
**replay-based recovery**:

1. Load ordered checkpoints (all effect results from the previous attempt)
2. Re-execute the Ballast program from the beginning
3. At each `handle_yield`, instead of calling the handler, feed the stored
   result (replay)
4. When checkpoints run out, call handlers normally (fresh execution)
5. Continue and checkpoint new results

This works because Ballast is **pure between effects** — the CPS evaluator is
deterministic given the same inputs. The effect results are the only source
of non-determinism, and those are stored.

### Checkpoint Naming

Effect yields are checkpointed as `"{index}:{effect_name}"`:

```
"0:charge_card"
"1:send_email"
"2:update_ledger"
```

The index guarantees uniqueness (composite PK: `task_id + checkpoint_name`).
The effect name provides human-readable observability.

### Integration Point

The runner's `handle_yield` function is the single seam. When a
`Checkpointer` is present in `RunConfig`, each yield either loads a stored
checkpoint (replay path) or runs the handler and saves the result (fresh
path). When no checkpointer is present, the runner behaves exactly as before.

Replay emits an `EffectReplayed` event instead of `EffectYielded` +
`EffectHandled`, so consumers can distinguish live execution from replay in
the type system.

### Gas Accounting

Replay steps are **exempt from gas counting**. Gas is consumed by handler
execution, which does not occur during replay. The theoretical risk of an
infinite replay loop is bounded because replay replays a finite, already-
executed step sequence terminating at a checkpoint.

### Handler Idempotency

Because handlers may execute more than once (crash after handler succeeds but
before checkpoint writes), all handlers must be **idempotent**:

- Use **set semantics** — compute the full replacement value, not append/increment
- Handlers that mutate the agent's own SQLite must tolerate being called twice
  with the same inputs
- The checkpoint is written AFTER the handler succeeds, so on retry the handler
  runs once and the checkpoint catches up

### The Determinism Invariant

Chute is deterministic by design — all non-determinism is exposed as an
effect. There is no `random()`, `timestamp()`, or `uuid()` as a bare language
primitive. Any such operation is an effect that yields to the handler and is
checkpointed. Consequently every Chute program is durable-compatible by
construction. There is no need to exclude programs from durability.

---

## Agent Loop Durability

### The Message-Log Pattern

The Pig agent loop runs inside a single gabsurd task. Each message (user,
assistant, tool result) is checkpointed as it's produced:

```
"msg:0" → {"role": "user", "content": "Charge $99"}
"msg:1" → {"role": "assistant", "content": "", "tool_calls": [...], "stop_reason": "tool_use"}
"msg:2" → {"role": "tool", "tool_call_id": "call_abc", "content": "{\"ok\": \"tx_456\"}"}
"msg:3" → {"role": "assistant", "content": "Done! Charged $99.", "stop_reason": "stop"}
```

On retry, the message log is rebuilt from checkpoints. The LLM only runs for
messages after the last checkpoint.

### Entry Point Resolution

After loading checkpoints, the last message determines what happens next:

| Last message | `stop_reason` | Action |
|---|---|---|
| `User` / `Tool` | — | Call the LLM provider |
| `Assistant` | `Stop` | Done — return immediately |
| `Assistant` | `ToolUse` | Execute the pending tool calls |
| `Assistant` | `Length` | Apply retry policy |
| `Assistant` | `Error` | Fail the task |
| `Assistant` | (none) | Call the LLM provider |
| (empty) | — | Call the LLM provider (first turn) |

This is the same decision logic as Pig's `update.gleam`, applied to the
checkpointed message instead of a live provider response.

---

## Conversation Lifecycle

### One Task Per Turn

A gabsurd task is one-shot — the worker claims it, runs the handler function,
and when it returns the task is complete. There is no "suspend until next
message" primitive. Each user turn creates a new task.

```
Turn 1:
  User: "Charge $99"
  → spawn_task("run-agent-turn", {conversation_id, user_message})
  → worker loads history = [] from conversations table
  → runs Pig loop → LLM → tool → result → LLM: "Done!"
  → saves [User, Assistant, Tool, Assistant] to conversations table
  → task completes

Turn 2:
  User: "Now refund it"
  → spawn_task("run-agent-turn", {conversation_id, user_message})
  → worker loads history = [4 messages] from conversations table
  → appends User("Now refund it")
  → runs Pig loop → LLM sees full history → responds
  → saves updated message log to conversations table
  → task completes
```

### Checkpoints Ahead of Table

On crash retry, gabsurd checkpoints (per-task) are always ahead of the
conversations table (per-conversation). The worker loads from both and uses
whichever is further ahead:

| | Conversations Table | gabsurd Checkpoints |
|---|---|---|
| Scope | Entire conversation (all turns) | Single task (single turn) |
| Updated | On task completion | On each step within a turn |
| On crash | Reflects last completed turn | Reflects last completed step of in-progress turn |
| Used for | Seeding next turn's agent | Resuming crashed turn |
| Lifecycle | Persistent across turns | Per-task, cleaned up by gabsurd |

### Ephemeral Agent

The Pig agent is created fresh for each turn — seeded with assembled history,
runs one turn, then discarded. It holds no durable state.

---

## Two-Database Strategy

The split axis is **agent-private storage vs. everything higher-level**.
Each agent keeps its own SQLite for its own storage; everything above the
agent (platform, conversations, app state, durability) lives in PostgreSQL.

### SQLite: Agent's Own Storage

- One SQLite database **per agent** for its private storage
- Agent-scoped VFS and KV stores — the agent's own working state
- Owned entirely by the agent; not queryable from the platform layer

### PostgreSQL: Everything Higher-Level

- gabsurd schema (tasks, runs, checkpoints, events)
- `yard_events` table (observability, replaces JSONL)
- pg_cron schedules (`cron.job`)
- `conversations` (multi-turn message logs)
- Higher-level app state (documents, settings, caches)
- Agent configuration (tool registries, system prompts)

### Consistency Model

The two databases can partially succeed (checkpoint written but agent-storage
write fails, or vice versa). This is handled by:

1. **Idempotent handlers** — set semantics, so re-execution is safe
2. **Checkpoint-after-write ordering** — checkpoints saved after handler succeeds
3. **No sagas needed** — the combination eliminates the need for compensating
   transactions

---

## Scheduling

pg_cron replaces the OTP cron engine. Schedules live in PostgreSQL's
`cron.job` table, surviving BEAM restarts. Each schedule fires
`absurd.spawn_task` directly into a gabsurd queue:

```sql
SELECT cron.schedule(
  'daily-summary',
  '0 9 * * *',
  $$SELECT absurd.spawn_task('run-chute',
      '{"skill": "daily_summary", "agent_id": "...", "user_key": "..."}'::jsonb)$$
);
```

Task params carry `agent_id` and `user_key` for per-agent/per-user scoping.

---

## Observability

Yard's JSONL session files are replaced by a `yard_events` table in PostgreSQL,
JOINable with gabsurd's `absurd_checkpoints` and `absurd_runs` on `run_id`:

```sql
CREATE TABLE yard_events (
  id          BIGSERIAL PRIMARY KEY,
  run_id      UUID NOT NULL,
  event_type  TEXT NOT NULL,
  payload     JSONB NOT NULL,
  duration_ms INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Five event types: `actor_started`, `actor_completed`, `effect_yielded`,
`effect_handled`, `effect_replayed`. The `effect_replayed` event (distinct in
the type system, not a string tag) marks replayed steps for observability.

### Dashboard UI

A mist HTTP server serves a dashboard at a configurable port, started via
`yard.start_with_ui()`. Routes:

- `GET /` — Dashboard (recent runs + conversations)
- `GET /runs/:id` — Run detail with event timeline
- `GET /conversations/:id` — Conversation message log

The UI queries PostgreSQL directly — no middleware needed.

---

## Handler Resolution

gabsurd workers are generic. At claim time, each worker reads `agent_id` and
`user_key` from task params and resolves:

- **Handlers** from the handler registry (maps `agent_id` → effect handler map)
- **Agent storage** via `agent_id` (one SQLite per agent)
- **Conversation scope** via `user_key` (PostgreSQL-side data)

The worker pool is shared; context is resolved per-task. No per-user worker
pools needed.

---

## Dependencies

- **gabsurd** — Gleam bindings for Absurd (PostgreSQL-native durable workflows)
- **pig** — Agent library (`run_continue` + `stop_reason` on messages)
- **PostgreSQL** — Production data store (absurd schema + yard tables)
- **pg_cron** — PostgreSQL-native scheduling (no OTP fallback)
- **mist** — HTTP server for the dashboard UI

---

## Open Questions

- **Nested chute_exec**: When an agent calls `chute_exec` from within a
  `chute_exec` (depth 0 → 1+), parent/child suspension propagation through
  durable task trees needs design. Does not gate the core durability model.
