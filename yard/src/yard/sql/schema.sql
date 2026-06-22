-- Yard Global Schema
-- SQLite DDL
--
-- This file is the source of truth for Yard's global database.
-- Parrot (sqlc) reads this + queries.sql to generate src/yard/sql.gleam.
--
-- What belongs here: platform-level registry tables (agents, skills,
-- schedules, deployments, runs, chat). NOT per-agent data (VFS/KV lives
-- in pig/workspace, one SQLite DB per agent).
--
-- Regenerate after changes:
--   mise run yard:gen

-- -- LLM Providers ---------------------------------------------

CREATE TABLE IF NOT EXISTS providers (
  id TEXT PRIMARY KEY,
  api_key TEXT NOT NULL,
  base_url TEXT NOT NULL,
  model TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- -- Agents (registered Chute programs) ------------------------

CREATE TABLE IF NOT EXISTS agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  chute_source TEXT NOT NULL,
  actor_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_handlers (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  effect_name TEXT NOT NULL,
  handler_name TEXT NOT NULL,
  handler_config TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);

-- -- Skills (reusable Chute programs) --------------------------

CREATE TABLE IF NOT EXISTS skills (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  chute_source TEXT NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- -- Schedules (cron-based skill triggers) ---------------------

CREATE TABLE IF NOT EXISTS schedules (
  id TEXT PRIMARY KEY,
  agent_id TEXT REFERENCES agents(id),
  skill_id TEXT NOT NULL REFERENCES skills(id),
  cron_expr TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  last_fired_at INTEGER,
  next_fire_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- -- Deployments -----------------------------------------------

CREATE TABLE IF NOT EXISTS deployments (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  actor_hash TEXT NOT NULL,
  trigger_type TEXT NOT NULL,
  trigger_config TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  deployed_at INTEGER NOT NULL
);

-- -- Runs (execution history) ----------------------------------

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  deployment_id TEXT REFERENCES deployments(id),
  trigger_type TEXT NOT NULL,
  trigger_source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  result TEXT,
  gas_used INTEGER,
  effects_performed INTEGER,
  duration_ms INTEGER,
  error_message TEXT,
  started_at INTEGER NOT NULL,
  completed_at INTEGER
);

-- -- Chat ------------------------------------------------------

CREATE TABLE IF NOT EXISTS chat_sessions (
  id TEXT PRIMARY KEY,
  user_key TEXT,
  provider_id TEXT REFERENCES providers(id),
  status TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES chat_sessions(id),
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  tool_name TEXT,
  tool_call_id TEXT,
  created_at INTEGER NOT NULL
);
