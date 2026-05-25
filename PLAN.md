# Hermes Implementation Plan — TDD Milestones

## Strategy

**Defer**: Full social chat UI, specialist execution (`ask_role`/`spawn_subagent`), `shell_exec`
**Build now**: DB layer, skills, crons, run tracking, new effects, conversation loop test

**Key insight — Pig already IS the conversation loop**:
Pig's `Agent` is an OTP actor that holds `history: List(Message)`. Every call
to `pig.run(agent, prompt)` appends to history and loops (provider → tools →
provider → ... → text response). Multi-turn is just calling `pig.run()` multiple
times on the same agent. For testing, `pig.test_harness()` gives a fake provider.

**Where code lives**:
| Layer | Location | Why |
|-------|----------|-----|
| DB wrapper (skills, schedules, runs, agents CRUD) | `yard/src/yard/db.gleam` | Generic — any Yard consumer needs this |
| Cron engine | `yard/src/yard/cron_engine.gleam` | Generic — runs skills on schedule via Yard's runner |
| Skill/agent repos | `yard/src/yard/skill_repo.gleam`, `agent_repo.gleam` | Domain wrappers over db.gleam |
| Effect handlers | `hermes_agent/effects.gleam` | Agent-specific wiring |
| Conversation loop test | `hermes_agent/test/conversation_test.gleam` | Proves multi-turn with fake provider |

---

## Milestone 1: Yard DB Layer

*Restore and extend `db.gleam` from the feature branch. Typed CRUD for all tables.*

### Files
- **Write**: `yard/src/yard/db.gleam`
- **Write**: `yard/test/db_test.gleam`

### TDD — Write these tests first

```
db_test.gleam — all use file::memory: SQLite

Helper:
  with_db(fn(conn) -> a)  — opens in-memory, migrates, runs test

Skills (6 tests):
  1. insert_skill_creates_record_test
  2. get_skill_by_name_test
  3. get_skill_missing_returns_none_test
  4. list_skills_returns_active_only_test
  5. update_skill_changes_description_test
  6. deactivate_skill_sets_inactive_test

Schedules (7 tests):
  7. insert_schedule_creates_record_test
  8. get_schedule_by_id_test
  9. list_active_schedules_returns_active_only_test
  10. update_schedule_fire_sets_timestamps_test
  11. deactivate_schedule_test
  12. list_active_schedules_ordered_by_next_fire_test
  13. schedule_with_null_agent_id_test

Runs (4 tests):
  14. insert_run_creates_running_record_test
  15. complete_run_sets_status_and_metrics_test
  16. get_actor_runs_ordered_by_started_at_desc_test
  17. get_actor_runs_respects_limit_test

Agents (3 tests):
  18. insert_and_get_agent_test
  19. get_agent_by_name_test
  20. list_agents_returns_all_test
```

---

## Milestone 2: Skill Registration & Discovery

*Register Chute programs as named skills. Retrieve by name for execution or scheduling.*

### Files
- **Write**: `yard/src/yard/skill_repo.gleam`
- **Write**: `yard/test/skill_repo_test.gleam`
- **Modify**: `hermes_agent/effects.gleam` — add `register_skill`, `get_skill`, `list_skills`
- **Modify**: `hermes_agent/effects_test.gleam`

### TDD

```
skill_repo_test.gleam:
  1. register_creates_skill_test
  2. register_generates_uuid_and_hash_test
  3. register_duplicate_name_returns_error_test
  4. lookup_missing_returns_error_test
  5. list_all_returns_active_skills_test
  6. deactivate_removes_from_list_test

effects_test.gleam additions:
  7. register_skill_handler_test
  8. get_skill_handler_test
  9. list_skills_handler_test
  10. register_skill_bad_args_test
```

### New effects
| Effect | Signature |
|--------|-----------|
| `register_skill` | `(name, description, source) -> Result(String, String)` |
| `get_skill` | `(name) -> Result({id, name, source, ...}, String)` |
| `list_skills` | `() -> Result(List(...), String)` |

---

## Milestone 3: Run Tracking

*Record every chute_exec invocation in the global DB.*

### Files
- **Modify**: `hermes_agent/chute_exec.gleam` — insert/complete run around execution
- **Write**: `hermes_agent/test/run_tracking_test.gleam`

### TDD

```
run_tracking_test.gleam:
  1. successful_run_recorded_test
  2. failed_run_recorded_test
  3. run_includes_duration_test
  4. no_tracking_without_global_conn_test
  5. multiple_runs_tracked_test
```

---

## Milestone 4: Cron Engine

*BEAM actor that reads schedules from DB and fires skills on time.*

### Files
- **Write**: `yard/src/yard/cron_engine.gleam`
- **Write**: `yard/test/cron_engine_test.gleam`
- **Modify**: `hermes_agent/effects.gleam` — add `schedule_cron`, `list_crons`, `cancel_cron`
- **Modify**: `yard/gleam.toml` — add `automata` dependency

### TDD

```
cron_engine_test.gleam:
  1. start_with_empty_db_test
  2. register_returns_id_test
  3. register_invalid_cron_returns_error_test
  4. list_schedules_returns_registered_test
  5. cancel_deactivates_test
  6. tick_fires_due_schedule_test
  7. tick_reschedules_after_fire_test
  8. shutdown_stops_engine_test

effects_test.gleam additions:
  9. schedule_cron_handler_test
  10. schedule_cron_bad_args_test
  11. list_crons_handler_test
  12. cancel_cron_handler_test
```

### New effects
| Effect | Signature |
|--------|-----------|
| `schedule_cron` | `(cron_expr, skill_name) -> Result(String, String)` |
| `list_crons` | `() -> List(Schedule)` |
| `cancel_cron` | `(id) -> Result(Nil, String)` |

---

## Milestone 5: Multi-Turn Conversation Loop

*Prove Pig's agent holds conversation across turns. Test with a fake provider.*

Pig's agent actor already holds `history: List(Message)` across `run()` calls.
We don't build a loop — we prove the existing mechanism works end-to-end
with Hermes's tools and effects wired in.

### Files
- **Write**: `hermes_agent/test/conversation_test.gleam`

### The fake provider

The test uses a `Provider` function that returns canned responses with
tool calls. This simulates the LLM deciding to call `chute_exec`:

```gleam
// Fake provider: first call returns a tool call, second returns text
let responses = [
  message.Assistant("", [ToolCall("tc1", "chute_exec", source_json)], None),
  message.Assistant("Done! I wrote the file.", [], None),
]
let response_index = process.new_subject() // mutable counter
// provider fn reads from responses[index], increments index
```

### TDD

```
conversation_test.gleam — uses pig.test_harness() or custom fake provider

1. single_turn_no_tools_test
   - Start agent with fake provider that returns "Hello!" immediately
   - pig.run(agent, "Hi") → Assistant("Hello!")
   - Assert history has 2 messages (User + Assistant)

2. single_turn_with_tool_call_test
   - Fake provider returns assistant with tool call → chute_exec
   - Tool runs, result fed back to provider
   - Second provider call returns text
   - Assert history has 4 messages (User, Asst+tool, Tool, Asst text)

3. multi_turn_preserves_history_test
   - Turn 1: "What files exist?" → fake returns text "You have 3 files"
   - Turn 2: "Tell me more" → fake returns text "They are..."
   - After turn 2, pig internal history should have 4 messages
   - Proves history persists between run() calls

4. multi_turn_with_tools_across_turns_test
   - Turn 1: fake returns tool call → chute_exec writes a file
   - Turn 2: fake returns tool call → chute_exec reads that file
   - Proves workspace state (VFS) persists across turns (same workspace conn)

5. kv_persists_across_turns_test
   - Turn 1: chute_exec stores key "name" = "Alice"
   - Turn 2: chute_exec recalls "name" → "Alice"
   - Proves KV memory persists across turns

6. error_recovery_across_turns_test
   - Turn 1: chute_exec with bad source → error in tool result
   - Turn 2: chute_exec with good source → success
   - Proves error in one turn doesn't corrupt the next
```

### Why this milestone matters
This is the "conversation loop building block" — but it's not something
we build, it's something we *prove*. Pig already does the heavy lifting.
The test shows that hermes-agent's wiring (workspace, effects, tools)
works correctly across multiple turns of a conversation.

---

## Milestone 6: Agent Registry + New Effects

*Register agents, add tell_user and learn effects.*

### Files
- **Write**: `yard/src/yard/agent_repo.gleam`
- **Write**: `yard/test/agent_repo_test.gleam`
- **Modify**: `hermes_agent/effects.gleam` — add `tell_user`, `learn`, `list_agents`, `register_agent`
- **Modify**: `hermes_agent/effects_test.gleam`

### TDD

```
agent_repo_test.gleam:
  1. register_creates_agent_test
  2. register_stores_handler_bindings_test
  3. lookup_by_name_test
  4. list_all_test
  5. get_handlers_returns_bindings_test

effects_test.gleam additions:
  6. tell_user_handler_test — records event with name "tell_user"
  7. learn_handler_test — stores with "hermes_learned:" prefix
  8. list_agents_handler_test
  9. register_agent_handler_test
```

### New effects
| Effect | Signature |
|--------|-----------|
| `tell_user` | `(message) -> Nil` |
| `learn` | `(key, fact) -> Result(Nil, String)` |
| `list_agents` | `() -> List(AgentInfo)` |
| `register_agent` | `(name, description, source, handlers) -> Result(String, String)` |

---

## Execution Order

```
M1 (DB Layer)
  ↓
M2 (Skills) + M3 (Runs)    ← parallel
  ↓
M4 (Cron Engine)            ← needs M1 + M2
  ↓
M5 (Conversation Loop)      ← needs M3, proves the whole stack
  ↓
M6 (Agent Registry + Effects) ← needs M1
```

## Summary

| # | Milestone | New Tests | Depends on |
|---|-----------|-----------|------------|
| 1 | DB Layer | ~20 | Parrot (done) |
| 2 | Skills | ~10 | M1 |
| 3 | Run Tracking | ~5 | M1 |
| 4 | Cron Engine | ~12 | M1, M2 |
| 5 | Conversation Loop | ~6 | M3 |
| 6 | Agent Registry + Effects | ~9 | M1 |
| **Total** | | **~62** | |

After all milestones: 12 effect handlers (up from 6), ~107 total tests,
full conversation loop proved, skills + crons working, run tracking in global DB.
