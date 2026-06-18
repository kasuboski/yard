# Durable Execution for Yard

## Overview

Yard runs Chute programs via Ballast's CPS evaluator. Today, if the BEAM node crashes mid-execution, the run is lost — no resume, no retry, no recovery. This document describes how to add durable execution to Yard using [gabsurd](../gabsurd), the Gleam bindings for [Absurd](https://github.com/earendil-works/absurd), a PostgreSQL-native durable workflow engine.

The design covers two levels of durability:

1. **Chute/Ballast effect execution** — checkpointing each effect handler result so a crashed Ballast run can be replayed and resumed
2. **Pig agent loops** — checkpointing each LLM response and tool result so a crashed agent conversation can be resumed without re-calling the LLM

Both levels run inside gabsurd tasks, use PostgreSQL as the durable store, and are transparent to the Chute program and the LLM.

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
  │    ├─ LLM inference → checkpoint "msg:N" (stores LLM response)
  │    ├─ Tool call: chute_exec → run Ballast program:
  │    │    ├─ Effect yielded → handler runs → checkpoint "{idx}:{effect_name}"
  │    │    ├─ Effect yielded → handler runs → checkpoint "{idx}:{effect_name}"
  │    │    └─ Program complete → checkpoint tool result as "msg:N+1"
  │    ├─ LLM inference → checkpoint "msg:N+2"
  │    └─ ... until stop_reason = Stop
  ├─ Save full message log to conversations table
  ├─ Return final assistant message
  └─ Task completed
```

### On Crash / Retry

If the BEAM node crashes at any point, the gabsurd worker retries the task:

1. **Load checkpoints** — walk the ordered checkpoint list, rebuilding the message log and Ballast effect results
2. **Determine entry point** — look at the last checkpointed message:
   - `User` / `Tool` → call the LLM provider
   - `Assistant` with `stop_reason = ToolUse` → execute the tool calls
   - `Assistant` with `stop_reason = Stop` → done, return immediately
   - `Assistant` with `stop_reason = Length` / `Error` → apply retry policy
3. **Resume** — execute the next step and continue the loop

LLM responses are never re-generated. They are loaded from PostgreSQL. Only **new** steps after the last checkpoint actually execute.

---

## Component 1: Ballast Effect Checkpointing

### Seam: `yard/runner.gleam` → `handle_yield()`

The integration point is the runner's `handle_yield` function. Today it dispatches the effect handler and feeds the result back to Ballast. With durability, it wraps this dispatch with gabsurd checkpoint operations.

### Checkpoint Naming

Each effect yield is checkpointed as `"{effects_count}:{effect_name}"`:

```
"0:charge_card"
"1:send_email"
"2:update_ledger"
```

- The index guarantees uniqueness (composite PK: `task_id + checkpoint_name`)
- The effect name gives human-readable observability
- Ordered by `updated_at ASC` (gabsurd's checkpoint ordering)

### Replay Mechanism

Ballast continuations are opaque BEAM closures — they cannot be serialized. Instead, we use **replay-based recovery**:

1. Load ordered checkpoints from gabsurd (all effect results from previous attempt)
2. Re-execute the Ballast program from the beginning
3. At each `handle_yield`, instead of calling the handler, feed the stored result
4. When we reach the checkpoint after the last stored result, call the handler normally
5. Continue execution and checkpoint new results

This works because Ballast is **pure between effects** — the CPS evaluator is deterministic given the same inputs. The effect results are the only source of non-determinism, and those are stored.

### Changes to `handle_yield()`

The change is localized to `handle_yield()` in `yard/runner.gleam`:

```
fn handle_yield(run_state, effect, effects_count) {
  let step_name = int.to_string(effects_count) <> ":" <> effect_name(effect)

  // Check if we already have a checkpoint for this step (replay)
  case checkpoint.load(ctx, step_name) {
    Ok(stored_value) -> {
      // Replay: feed stored result, skip handler execution
      emit_replay_event(run_state, step_name)
      resume_with(run_state, stored_value)
    }
    Error(Nil) -> {
      // Fresh execution: run handler, checkpoint result
      let result = handler(run_state, effect)
      checkpoint.save(ctx, step_name, result)
      resume_with(run_state, result)
    }
  }
}
```

Estimated: ~60-80 lines of change in `runner.gleam`.

### Replay Gas Accounting

Replaying N-1 pure CPS steps consumes gas that the original execution already paid for.

**Decision: exempt replay steps from gas counting.** No separate replay budget. Gas is consumed by handler execution, which does not occur during replay, so replay is effectively free. The theoretical risk of an infinite replay loop is bounded because replay replays a finite, already-executed step sequence terminating at a checkpoint.

### Handler Idempotency Requirement

Because handlers may execute more than once (crash after handler succeeds but before checkpoint writes), all handlers must be **idempotent**:

- Use **set semantics** — compute the full replacement value, not append/increment
- Handlers that mutate the agent's own SQLite storage must tolerate being called twice with the same inputs
- The checkpoint is written AFTER the handler succeeds, so on retry the handler runs once and the checkpoint catches up

---

## Component 2: Pig Agent Loop Durability

### The Message-Log Pattern

The Pig agent loop runs inside a single gabsurd task. Each message (user, assistant, tool result) is checkpointed as it's produced. On retry, the message log is rebuilt from checkpoints.

This is the same pattern used by [Absurd's pi-ai-agent example](https://earendil-works.github.io/absurd/patterns/pi-ai-agent/).

### Checkpoint Structure

Each message is checkpointed with name `"msg:{N}"` and value is the JSON-serialized `Message`:

```
"msg:0" → {"role": "user", "content": "Charge $99"}
"msg:1" → {"role": "assistant", "content": "", "tool_calls": [...], "stop_reason": "tool_use"}
"msg:2" → {"role": "tool", "tool_call_id": "call_abc", "content": "{\"ok\": \"tx_456\"}"}
"msg:3" → {"role": "assistant", "content": "Done! Charged $99.", "tool_calls": [], "stop_reason": "stop"}
```

### Entry Point Resolution

After loading checkpoints, the last message determines what happens next:

| Last message | `stop_reason` | Action |
|---|---|---|
| `User(...)` | — | Call the LLM provider |
| `Tool(...)` | — | Call the LLM provider |
| `Assistant(...)` | `Stop` | Done — return immediately |
| `Assistant(...)` | `ToolUse` | Execute the pending tool calls |
| `Assistant(...)` | `Length` | Apply retry policy (re-call provider or fail) |
| `Assistant(...)` | `Error` | Fail the task |

This is the same decision logic as Pig's `update.gleam` → `handle_provider_responded`, just applied to the checkpointed message instead of a live provider response.

### Pig API Dependency

This requires one new function in Pig: `run_continue(agent, timeout)`. See [PIG-FR.md](PIG-FR.md) for the full feature request.

---

## Component 3: Conversation Lifecycle

### One Task Per Turn

A gabsurd task is **one-shot** — the worker claims it, runs the handler function, and when the function returns the task is complete. There is no "suspend until next message" primitive. This means a single long-lived task for an entire multi-turn conversation doesn't work.

Instead, each user turn creates a new gabsurd task:

```
Turn 1:
  User: "Charge $99"
  → spawn_task("run-agent-turn", {conversation_id, user_message: "Charge $99"})
  → worker loads history = [] from conversations table
  → runs Pig loop → LLM responds → tool call → result → LLM: "Done!"
  → saves [User, Assistant, Tool, Assistant] to conversations table
  → task completes

Turn 2:
  User: "Now refund it"
  → spawn_task("run-agent-turn", {conversation_id, user_message: "Now refund it"})
  → worker loads history = [User, Assistant, Tool, Assistant] from conversations table
  → appends User("Now refund it")
  → runs Pig loop → LLM sees full history → responds
  → saves updated message log to conversations table
  → task completes

Turn 2 crashes after LLM responds but before saving:
  → gabsurd retries the SAME task
  → worker loads history from conversations table (still Turn 1 state)
  → loads checkpoints from this task's previous attempt
  → checkpoints are ahead of table (have User msg + LLM response)
  → resume from checkpoint state (skips the LLM call)
  → completes → saves to conversations table
  → task completes
```

### Conversations Table

Conversation state persists in a PostgreSQL table, updated only on task completion:

```sql
CREATE TABLE conversations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id    TEXT NOT NULL,
  user_key    TEXT NOT NULL,
  messages    JSONB NOT NULL DEFAULT '[]',  -- full message log
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_conversations_agent_user ON conversations(agent_id, user_key);
```

The `messages` column stores the complete `List(Message)` as a JSONB array. Each message includes role, content, tool calls, tool results, and stop reason. This is the same format produced by Pig's `message_to_json` and consumed by `decode_message`.

### Conversations Table vs Checkpoints

| | Conversations Table | gabsurd Checkpoints |
|---|---|---|
| Scope | Entire conversation (all turns) | Single task (single turn) |
| Updated | On task completion | On each step within a turn |
| On crash | Reflects last completed turn | Reflects last completed step of in-progress turn |
| Used for | Seeding next turn's Pig agent | Resuming crashed turn |
| Lifecycle | Persistent across turns | Per-task, cleaned up by gabsurd |

On retry, checkpoints are always ahead of the conversations table. The worker loads from both and uses whichever is further ahead.

### Pig Agent is Ephemeral

The Pig agent is created fresh for each turn:

```gleam
fn execute_turn(ctx) {
  // Load conversation history
  let history = conversations.load(ctx.params.conversation_id)

  // Check for per-task checkpoints (crash recovery)
  let messages = load_from_checkpoints(ctx)
    |> option.unwrap(history)

  // Create ephemeral Pig agent seeded with history
  let agent = pig.new(provider)
    |> pig.with_tools(tools)
    |> pig.with_system_prompt(system_prompt)
    |> pig.with_initial_history(messages)
    |> pig.start()

  // Run one turn
  let result = case messages {
    [] -> pig.run(agent, ctx.params.user_message, 30_000)
    _  -> pig.run_continue(agent, 30_000)
  }

  // Persist updated conversation on success
  conversations.save(ctx.params.conversation_id, agent.history)

  result
}
```

The agent holds no durable state. It's a vehicle for executing one turn of the conversation loop, seeded from and persisted back to the conversations table.

---

## Component 4: Unified Data Model (PostgreSQL)

### New Dependency: PostgreSQL + Absurd Schema

Yard currently uses SQLite for everything (per-user workspace.db, hermes_global.db). Under the durable design, the higher-level data moves to PostgreSQL with the Absurd schema, while each agent keeps its own SQLite database for its private storage:

```
absurd_tasks       — task definitions, params, state
absurd_runs        — execution attempts, timing
absurd_checkpoints — step-level checkpointed values
absurd_events      — lifecycle events
conversations      — multi-turn conversation message logs
yard_events        — Yard observability (replaces JSONL)
```

### yard_events Table

Yard's JSONL observability is replaced by a `yard_events` table in the same PostgreSQL database:

```sql
CREATE TABLE yard_events (
  id          BIGSERIAL PRIMARY KEY,
  run_id      UUID NOT NULL REFERENCES absurd_runs(id),
  event_type  TEXT NOT NULL,  -- 'actor_started', 'effect_yielded', 'effect_handled', 'actor_completed'
  payload     JSONB NOT NULL,
  duration_ms INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_yard_events_run_id ON yard_events(run_id);
```

This is JOINable with gabsurd's `absurd_checkpoints` and `absurd_runs` on `run_id`, giving a unified queryable view of task lifecycle, checkpoints, and per-effect timing.

### run_id Correlation

The gabsurd `run_id` is the yard `run_id`. There is one identity, not two correlated IDs. Every Yard event and every gabsurd checkpoint for a given execution share the same `run_id`.

### Dev Mode

For local development, JSONL remains available as an optional observability consumer (tail-friendly, no PG required). But production deployments use PostgreSQL.

---

## Component 5: Cron Scheduling with pg_cron

Yard's current cron engine is an OTP actor that fires skills on a timer — fire-and-forget, no retry, no deduplication, no durability.

With PostgreSQL in the stack, **pg_cron** replaces the custom cron engine:

```sql
-- Schedule a daily skill execution
SELECT cron.schedule(
  'daily-summary',
  '0 9 * * *',
  $$SELECT absurd.spawn_task('run-chute', '{"skill": "daily_summary", "agent_id": "...", "user_key": "..."}'::jsonb)$$
);
```

- **Durable**: pg_cron survives BEAM node restarts (scheduled in PostgreSQL, not in OTP)
- **Observable**: `cron.job` table shows all schedules
- **Integrated**: fires `spawn_task` directly, gabsurd workers handle execution
- **Per-agent/per-user**: task params carry `agent_id` and `user_key`

---

## Component 6: Handler Registry & Worker Context

### Per-Agent / Per-User Scoping

gabsurd workers are generic — they claim tasks and execute handlers. The handler resolution happens **at claim time** from task params:

```gleam
fn execute(ctx) {
  let agent_id = ctx.params.agent_id
  let user_key = ctx.params.user_key
  
  // Resolve handlers + the agent's OWN SQLite storage (one DB per agent)
  let handlers    = handler_registry.get(agent_id)
  let agent_store = agent_storage.open(agent_id)
  
  // user_key scopes PostgreSQL-side data (conversation, higher-level state)
  yard.run(program, handlers, agent_store, ctx)
}
```

SQLite is keyed by `agent_id` (agent-private storage); `user_key` scopes the PostgreSQL-side data (conversation history, higher-level state). This preserves Yard's per-agent/per-user scoping without requiring per-user worker pools. The worker pool is shared; context is resolved per-task.

### Handler Registry Unification

Today Yard has separate handler registries per agent. With gabsurd, the registry becomes a lookup from `agent_id` → `handler_map` that workers consult when they claim a task. This is a thin wrapper, not a fundamental change.

---

## Two-Database Strategy

The split axis is **agent-private storage vs. everything higher-level**, not durability-vs-workspace. Each agent gets its own SQLite for its own storage; everything above the agent (platform, conversations, app state, durability) lives in PostgreSQL.

### SQLite: The Agent's Own Storage (one DB per agent)
- Each agent gets its own SQLite database for its private storage
- Agent-scoped VFS and KV stores the agent uses as its own working state
- Owned entirely by the agent; not queryable from the platform layer

### PostgreSQL: Everything Higher-Level
- gabsurd schema (tasks, runs, checkpoints, events)
- yard_events table (observability, replaces JSONL)
- pg_cron schedules (`cron.job`)
- `conversations` (multi-turn message logs)
- Higher-level application state — documents, settings, caches, and user-session "working memory" that previously lived in SQLite move **up** to PostgreSQL
- Agent configuration (tool registries, system prompts)
- The current global SQLite tables (`providers`, `agents`, `skills`, `schedules`, `runs`, `chat_*`) migrate to PostgreSQL

### Consistency

The two databases can partially succeed (checkpoint written but agent-storage write fails, or vice versa). This is handled by:

1. **Idempotent handlers** — handlers that write to the agent's SQLite use set semantics, so re-execution produces the same result
2. **Checkpoint-after-write** — checkpoints are saved after the handler succeeds, so on retry the handler runs once and the checkpoint catches up
3. **No sagas needed** — the combination of idempotency and checkpoint ordering eliminates the need for compensating transactions

---

## Implementation Plan

### Phase 1: Foundation
- [ ] Add PostgreSQL + Absurd schema to the project (migration, config)
- [ ] Create `conversations` table
- [ ] Create `yard_events` table
- [ ] Wire gabsurd dependency into Yard

### Phase 2: Ballast Effect Checkpointing
- [ ] Modify `handle_yield()` in `runner.gleam` to checkpoint effect results
- [ ] Implement replay logic: load checkpoints, skip handlers, feed stored results
- [ ] Add `yard_events` emission (replaces JSONL)
- [ ] Test: crash mid-execution, verify resume

### Phase 3: Pig Agent Durability
- [ ] Depends on [PIG-FR.md](PIG-FR.md) changes being merged
- [ ] Create gabsurd task handler for "run-agent-turn"
- [ ] Implement conversation load/save against conversations table
- [ ] Implement message-log checkpointing (each message as a step)
- [ ] Implement entry point resolution from last checkpointed message
- [ ] Handle first-turn (pig.run) vs continuation (pig.run_continue) dispatch
- [ ] Test: crash after LLM response, verify resume without re-calling LLM
- [ ] Test: crash mid-turn, verify conversations table reflects last completed turn

### Phase 4: Cron & Scheduling
- [ ] Replace OTP cron engine with pg_cron
- [ ] Migrate existing cron schedules to `cron.job` table
- [ ] Wire cron.job → spawn_task → gabsurd worker

### Phase 5: Observability UI
- [ ] Build unified query view joining yard_events + absurd_checkpoints + absurd_runs
- [ ] Implement run inspection: step-by-step replay with timing
- [ ] Implement task list with status, attempts, last checkpoint

---

## Constraints & Risks

### Replay Determinism

Ballast's CPS evaluator is deterministic between effects. This is the foundation of replay-based recovery. **Confirmed language invariant (2025-06): Chute is deterministic by design — all nondeterminism is exposed as an effect.** There is no path to implicit non-determinism in Chute (no `random()`, `timestamp()`, `uuid()` as bare language primitives); any such operation is an effect that yields to the handler and is checkpointed. Consequently:
- Every Chute program is durable-compatible by construction.
- The replay-then-resume model is sound.
- There is no need to "exclude some programs from durability."

### Gas Accounting on Replay

**Decision: exempt replay steps from gas counting** (no separate replay budget) since no handler execution occurs. See "Replay Gas Accounting" above.

### Nested chute_exec

When a Pig agent calls `chute_exec` from within a `chute_exec` (depth 0 → 1+), the nested execution is a sub-task in gabsurd. **Parent/child suspension propagation still needs design** (open) — likely the parent task suspends while the child runs, then resumes when the child completes. This does not gate the core durability work.


### pg_cron Availability

pg_cron is a PostgreSQL extension. **Decision: assumed available in all target environments** (resolved 2025-06). No OTP fallback retained.

### LLM Non-Determinism

The Pig agent loop IS durable via the message-log pattern — LLM responses are stored, not re-generated. The LLM only runs for new messages after the last checkpoint. This is not a risk; it's the core of the design.
