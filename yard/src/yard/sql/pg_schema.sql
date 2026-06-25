-- Yard Global Registry Schema (PostgreSQL)
--
-- This is the PostgreSQL version of schema.sql for the registry tables.
-- Registry tables: providers, agents, agent_handlers, skills, deployments,
-- runs, chat_sessions, chat_messages.
--
-- Schedules are NOT included here - they are moving to pg_cron.
--
-- Regenerate after changes:
--   Apply via bin/postgres.sh

-- ─── Providers ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS providers (
  id          TEXT PRIMARY KEY,
  api_key     TEXT NOT NULL,
  base_url    TEXT NOT NULL,
  model       TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─── Agents (registered Chute programs) ─────────────────────────────

CREATE TABLE IF NOT EXISTS agents (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  description   TEXT NOT NULL DEFAULT '',
  chute_source  TEXT NOT NULL,
  actor_hash    TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'draft',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agents_name ON agents(name);

CREATE TABLE IF NOT EXISTS agent_handlers (
  id              TEXT PRIMARY KEY,
  agent_id        TEXT NOT NULL REFERENCES agents(id),
  effect_name     TEXT NOT NULL,
  handler_name    TEXT NOT NULL,
  handler_config  TEXT NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_handlers_agent_id ON agent_handlers(agent_id);

-- ─── Skills (reusable Chute programs) ───────────────────────────────

CREATE TABLE IF NOT EXISTS skills (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  description   TEXT NOT NULL DEFAULT '',
  chute_source  TEXT NOT NULL,
  tags          TEXT NOT NULL DEFAULT '[]',
  status        TEXT NOT NULL DEFAULT 'active',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_skills_status ON skills(status);

-- ─── Deployments ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS deployments (
  id             TEXT PRIMARY KEY,
  agent_id       TEXT NOT NULL REFERENCES agents(id),
  actor_hash     TEXT NOT NULL,
  trigger_type   TEXT NOT NULL,
  trigger_config TEXT,
  status         TEXT NOT NULL DEFAULT 'active',
  deployed_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_deployments_agent_id ON deployments(agent_id);
CREATE INDEX IF NOT EXISTS idx_deployments_status ON deployments(status);

-- ─── Runs (execution history) ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS runs (
  id                TEXT PRIMARY KEY,
  agent_id          TEXT NOT NULL REFERENCES agents(id),
  deployment_id     TEXT REFERENCES deployments(id),
  trigger_type      TEXT NOT NULL,
  trigger_source    TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'running',
  result            TEXT,
  gas_used          INTEGER,
  effects_performed INTEGER,
  duration_ms       INTEGER,
  error_message     TEXT,
  started_at        TIMESTAMPTZ NOT NULL,
  completed_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_runs_agent_id ON runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_runs_started_at ON runs(started_at DESC);

-- ─── Chat ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS chat_sessions (
  id          TEXT PRIMARY KEY,
  user_key    TEXT,
  provider_id TEXT REFERENCES providers(id),
  status      TEXT NOT NULL DEFAULT 'active',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user_key ON chat_sessions(user_key);
CREATE INDEX IF NOT EXISTS idx_chat_sessions_status ON chat_sessions(status);

CREATE TABLE IF NOT EXISTS chat_messages (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES chat_sessions(id),
  role         TEXT NOT NULL,
  content      TEXT NOT NULL,
  tool_name    TEXT,
  tool_call_id TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session_id ON chat_messages(session_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_created_at ON chat_messages(created_at);