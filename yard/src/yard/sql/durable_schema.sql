-- Durable execution schema for Yard.
--
-- These tables live in the same PostgreSQL database as the Absurd schema
-- (absurd_tasks, absurd_runs, absurd_checkpoints, absurd_events).
-- They are created AFTER the Absurd schema migration.
--
-- From DURABLE.md Component 4: Unified Data Model.

-- ─── Conversations ───────────────────────────────────────────────────
-- Multi-turn conversation message logs.
-- One row per conversation. The `messages` column stores the full
-- List(Message) as a JSONB array, updated on task completion.

CREATE TABLE IF NOT EXISTS conversations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id    TEXT NOT NULL,
  user_key    TEXT NOT NULL,
  messages    TEXT NOT NULL DEFAULT '[]',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Drop any pre-existing non-unique index with this name so existing
-- deployments pick up the unique partial index. (CREATE ... IF NOT EXISTS
-- would otherwise no-op against the old index.)
DROP INDEX IF EXISTS idx_conversations_agent_user;

CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_agent_user
  ON conversations(agent_id, user_key)
  WHERE agent_id <> '' AND user_key <> '';

-- ─── Yard Events ─────────────────────────────────────────────────────
-- Observability events, replacing JSONL session files.
-- JOINable with absurd_runs and absurd_checkpoints on run_id.

CREATE TABLE IF NOT EXISTS yard_events (
  id          BIGSERIAL PRIMARY KEY,
  run_id      UUID NOT NULL,
  event_type  TEXT NOT NULL,
  payload     JSONB NOT NULL,
  duration_ms INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Note: run_id references per-queue run tables (e.g. absurd.r_<queue>),
-- which are created dynamically by absurd.create_queue(). A global FK
-- is not possible because the run table name varies by queue.

CREATE INDEX IF NOT EXISTS idx_yard_events_run_id
  ON yard_events(run_id);

-- ─── Pig Events ──────────────────────────────────────────────────────
-- Pig's rich agent-internal events (token usage, tool calls, inference
-- timing). Stored SEPARATELY from yard_events — yard decodes
-- yard_events.payload as HostEvent and pig_events.payload as
-- SessionEvent. The two are joined at query time by run_id.
-- Never write pig rows into yard_events.

CREATE TABLE IF NOT EXISTS pig_events (
  id          BIGSERIAL PRIMARY KEY,
  run_id      UUID NOT NULL,
  event_type  TEXT NOT NULL,        -- "pig.session.started", "pig.inference.completed", ...
  payload     JSONB NOT NULL,
  duration_ms INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pig_events_run_id
  ON pig_events(run_id);
