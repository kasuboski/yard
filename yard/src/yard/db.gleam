//// Database initialization and typed CRUD for Yard's global store.
////
//// PostgreSQL-backed global registry: providers, agents, agent_handlers,
//// skills, deployments, runs, chat_sessions, chat_messages.
////
//// Uses gabsurd/client.Db for PostgreSQL access with parrot/dev params.
////
//// Two-DB architecture:
////   - Global DB (this module): agents, skills, runs, chat in PostgreSQL
////   - Per-agent workspace: VFS + KV (pig/workspace, one SQLite per agent)
////
//// NOTE: migrate() is a no-op now - schema is applied via bin/postgres.sh

import gleam/dynamic/decode as dyn_decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gluid
import logging
import parrot/dev
import gabsurd/client.{type Db, type GabsurdError, NotFound}

// ═══════════════════════════════════════════════════════════════
// Public Types (matching original schema.sql structure)
// ═══════════════════════════════════════════════════════════════

pub type Provider {
  Provider(id: String, api_key: String, base_url: String, model: String)
}

pub type Agent {
  Agent(
    id: String,
    name: String,
    description: String,
    chute_source: String,
    actor_hash: String,
    status: String,
  )
}

/// Type for list_agents result (subset of Agent fields)
pub type ListAgents {
  ListAgents(id: String, name: String, status: String, actor_hash: String)
}

pub type AgentHandler {
  AgentHandler(effect_name: String, handler_name: String)
}

pub type Skill {
  Skill(
    id: String,
    name: String,
    description: String,
    chute_source: String,
    tags: String,
    status: String,
  )
}

pub type Run {
  Run(
    id: String,
    status: String,
    trigger_type: String,
    trigger_source: String,
    result: String,
    duration_ms: Int,
    started_at: Int,
  )
}

pub type ChatMessage {
  ChatMessage(id: String, content: String, role: String, created_at: Int)
}

// ═══════════════════════════════════════════════════════════════
// Error handling
// ═══════════════════════════════════════════════════════════════

fn error_to_string(e: GabsurdError) -> String {
  case e {
    client.QueryError(msg) -> "query: " <> msg
    client.UnexpectedRowCount(msg) -> "row count: " <> msg
    NotFound -> "not found"
    client.ConnectionError(msg) -> "connection: " <> msg
  }
}

/// Generate a new UUID (lowercase v4).
fn new_id() -> String {
  gluid.guidv4() |> string.lowercase()
}

/// Migration is now a no-op - schema is applied via bin/postgres.sh.
/// This function is kept for backward compatibility with old tests.
pub fn migrate(_db: Db) -> Result(Nil, Nil) {
  Ok(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Provider Queries
// ═══════════════════════════════════════════════════════════════

fn provider_decoder() -> dyn_decode.Decoder(Provider) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  use api_key <- dyn_decode.field(1, dyn_decode.string)
  use base_url <- dyn_decode.field(2, dyn_decode.string)
  use model <- dyn_decode.field(3, dyn_decode.string)
  dyn_decode.success(Provider(id:, api_key:, base_url:, model:))
}

/// Get the current provider, if one exists.
pub fn get_provider(db: Db) -> Result(Option(Provider), Nil) {
  let sql =
    "SELECT id, api_key, base_url, model FROM providers WHERE id = 'default'"
  case client.query_many(db, #(sql, [], provider_decoder())) {
    Ok([provider]) -> Ok(Some(provider))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) -> {
      logging.log(logging.Error, "db.get_provider failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Save a provider, replacing any existing one.
pub fn save_provider(
  db: Db,
  api_key: String,
  base_url: String,
  model: String,
) -> Result(Provider, Nil) {
  let sql =
    "
    INSERT INTO providers (id, api_key, base_url, model)
    VALUES ('default', $1, $2, $3)
    ON CONFLICT (id) DO UPDATE
    SET api_key = EXCLUDED.api_key,
        base_url = EXCLUDED.base_url,
        model = EXCLUDED.model
    "
  case client.exec(db, #(sql, [
    dev.ParamString(api_key),
    dev.ParamString(base_url),
    dev.ParamString(model),
  ])) {
    Ok(_) -> Ok(Provider("default", api_key, base_url, model))
    Error(e) -> {
      logging.log(
        logging.Error,
        "db.save_provider failed: " <> error_to_string(e),
      )
      Error(Nil)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Agent Queries
// ═══════════════════════════════════════════════════════════════

fn agent_decoder() -> dyn_decode.Decoder(Agent) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  use name <- dyn_decode.field(1, dyn_decode.string)
  use description <- dyn_decode.field(2, dyn_decode.string)
  use chute_source <- dyn_decode.field(3, dyn_decode.string)
  use actor_hash <- dyn_decode.field(4, dyn_decode.string)
  use status <- dyn_decode.field(5, dyn_decode.string)
  dyn_decode.success(Agent(
    id:,
    name:,
    description:,
    chute_source:,
    actor_hash:,
    status:,
  ))
}

fn list_agents_decoder() -> dyn_decode.Decoder(ListAgents) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  use name <- dyn_decode.field(1, dyn_decode.string)
  use status <- dyn_decode.field(2, dyn_decode.string)
  use actor_hash <- dyn_decode.field(3, dyn_decode.string)
  dyn_decode.success(ListAgents(id:, name:, status:, actor_hash:))
}

/// List all agents (id, name, status, actor_hash).
pub fn list_agents(db: Db) -> Result(List(ListAgents), Nil) {
  let sql =
    "
    SELECT id, name, status, actor_hash
    FROM agents
    ORDER BY updated_at DESC
    "
  case client.query_many(db, #(sql, [], list_agents_decoder())) {
    Ok(agents) -> Ok(agents)
    Error(e) -> {
      logging.log(logging.Error, "db.list_agents failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get an agent by ID.
pub fn get_agent(db: Db, id: String) -> Result(Option(Agent), Nil) {
  let sql =
    "
    SELECT id, name, description, chute_source, actor_hash, status
    FROM agents
    WHERE id = $1
    "
  case client.query_many(db, #(sql, [dev.ParamString(id)], agent_decoder())) {
    Ok([agent]) -> Ok(Some(agent))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) -> {
      logging.log(logging.Error, "db.get_agent failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get an agent by name.
pub fn get_agent_by_name(db: Db, name: String) -> Result(Option(Agent), Nil) {
  let sql =
    "
    SELECT id, name, description, chute_source, actor_hash, status
    FROM agents
    WHERE name = $1
    "
  case client.query_many(db, #(sql, [dev.ParamString(name)], agent_decoder())) {
    Ok([agent]) -> Ok(Some(agent))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) -> {
      logging.log(logging.Error, "db.get_agent_by_name failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Insert a new agent. Returns the generated ID.
/// Computes actor_hash from the chute source via loader.
pub fn insert_agent(
  db: Db,
  name: String,
  description: String,
  chute_source: String,
  status: String,
) -> Result(String, Nil) {
  let id = new_id()
  let hash = actor_hash(chute_source)
  let sql =
    "
    INSERT INTO agents (id, name, description, chute_source, actor_hash, status)
    VALUES ($1, $2, $3, $4, $5, $6)
    "
  case client.exec(db, #(sql, [
    dev.ParamString(id),
    dev.ParamString(name),
    dev.ParamString(description),
    dev.ParamString(chute_source),
    dev.ParamString(hash),
    dev.ParamString(status),
  ])) {
    Ok(_) -> Ok(id)
    Error(e) -> {
      logging.log(logging.Error, "db.insert_agent failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get handler bindings for an agent.
pub fn get_agent_handlers(
  db: Db,
  agent_id: String,
) -> Result(List(AgentHandler), Nil) {
  let sql =
    "
    SELECT effect_name, handler_name
    FROM agent_handlers
    WHERE agent_id = $1
    "
  let decoder = {
    use effect_name <- dyn_decode.field(0, dyn_decode.string)
    use handler_name <- dyn_decode.field(1, dyn_decode.string)
    dyn_decode.success(AgentHandler(effect_name:, handler_name:))
  }
  case client.query_many(db, #(sql, [dev.ParamString(agent_id)], decoder)) {
    Ok(handlers) -> Ok(handlers)
    Error(e) -> {
      logging.log(logging.Error, "db.get_agent_handlers failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Insert an agent handler binding.
pub fn insert_agent_handler(
  db: Db,
  agent_id: String,
  effect_name: String,
  handler_name: String,
) -> Result(Nil, Nil) {
  let id = new_id()
  let sql =
    "
    INSERT INTO agent_handlers (id, agent_id, effect_name, handler_name)
    VALUES ($1, $2, $3, $4)
    "
  case client.exec(db, #(sql, [
    dev.ParamString(id),
    dev.ParamString(agent_id),
    dev.ParamString(effect_name),
    dev.ParamString(handler_name),
  ])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.insert_agent_handler failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Skill Queries
// ═══════════════════════════════════════════════════════════════

fn skill_decoder() -> dyn_decode.Decoder(Skill) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  use name <- dyn_decode.field(1, dyn_decode.string)
  use description <- dyn_decode.field(2, dyn_decode.string)
  use chute_source <- dyn_decode.field(3, dyn_decode.string)
  use tags <- dyn_decode.field(4, dyn_decode.string)
  use status <- dyn_decode.field(5, dyn_decode.string)
  dyn_decode.success(Skill(
    id:,
    name:,
    description:,
    chute_source:,
    tags:,
    status:,
  ))
}

fn list_skills_decoder() -> dyn_decode.Decoder(Skill) {
  // list_skills returns full Skill objects
  skill_decoder()
}

/// List all active skills.
pub fn list_skills(db: Db) -> Result(List(Skill), Nil) {
  let sql =
    "
    SELECT id, name, description, chute_source, tags, status
    FROM skills
    WHERE status = 'active'
    ORDER BY updated_at DESC
    "
  case client.query_many(db, #(sql, [], list_skills_decoder())) {
    Ok(skills) -> Ok(skills)
    Error(e) -> {
      logging.log(logging.Error, "db.list_skills failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get a skill by ID.
pub fn get_skill(db: Db, id: String) -> Result(Option(Skill), Nil) {
  let sql =
    "
    SELECT id, name, description, chute_source, tags, status
    FROM skills
    WHERE id = $1
    "
  case client.query_many(db, #(sql, [dev.ParamString(id)], skill_decoder())) {
    Ok([skill]) -> Ok(Some(skill))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) -> {
      logging.log(logging.Error, "db.get_skill failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get a skill by name.
pub fn get_skill_by_name(db: Db, name: String) -> Result(Option(Skill), Nil) {
  let sql =
    "
    SELECT id, name, description, chute_source, tags, status
    FROM skills
    WHERE name = $1
    "
  case client.query_many(db, #(sql, [dev.ParamString(name)], skill_decoder())) {
    Ok([skill]) -> Ok(Some(skill))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) -> {
      logging.log(logging.Error, "db.get_skill_by_name failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Insert a new skill. Returns the generated ID.
pub fn insert_skill(
  db: Db,
  name name: String,
  description description: String,
  chute_source chute_source: String,
  tags tags: String,
) -> Result(String, Nil) {
  let id = new_id()
  let _hash = actor_hash(chute_source)
  let sql =
    "
    INSERT INTO skills (id, name, description, chute_source, tags, status)
    VALUES ($1, $2, $3, $4, $5, 'active')
    "
  case client.exec(db, #(sql, [
    dev.ParamString(id),
    dev.ParamString(name),
    dev.ParamString(description),
    dev.ParamString(chute_source),
    dev.ParamString(tags),
  ])) {
    Ok(_) -> Ok(id)
    Error(e) -> {
      logging.log(logging.Error, "db.insert_skill failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Update a skill's description, source, and tags.
pub fn update_skill(
  db: Db,
  id: String,
  description description: String,
  source chute_source: String,
  tags tags: String,
) -> Result(Nil, Nil) {
  let sql =
    "
    UPDATE skills
    SET description = $1, chute_source = $2, tags = $3, updated_at = now()
    WHERE id = $4
    "
  case client.exec(db, #(sql, [
    dev.ParamString(description),
    dev.ParamString(chute_source),
    dev.ParamString(tags),
    dev.ParamString(id),
  ])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.update_skill failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Deactivate a skill (soft delete).
pub fn deactivate_skill(db: Db, id: String) -> Result(Nil, Nil) {
  let sql =
    "
    UPDATE skills
    SET status = 'inactive', updated_at = now()
    WHERE id = $1
    "
  case client.exec(db, #(sql, [dev.ParamString(id)])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.deactivate_skill failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Run Queries
// ═══════════════════════════════════════════════════════════════

/// Get recent runs for an agent, ordered by started_at DESC.
pub fn get_actor_runs(
  db: Db,
  agent_id: String,
  limit: Int,
) -> Result(List(Run), Nil) {
  let sql =
    "
    SELECT
      id,
      status,
      trigger_type,
      trigger_source,
      COALESCE(result, '') as result,
      COALESCE(duration_ms, 0) as duration_ms,
      CAST(EXTRACT(EPOCH FROM started_at) * 1000 AS BIGINT) as started_at
    FROM runs
    WHERE agent_id = $1
    ORDER BY started_at DESC
    LIMIT $2
    "
  let decoder = {
    use id <- dyn_decode.field(0, dyn_decode.string)
    use status <- dyn_decode.field(1, dyn_decode.string)
    use trigger_type <- dyn_decode.field(2, dyn_decode.string)
    use trigger_source <- dyn_decode.field(3, dyn_decode.string)
    use result <- dyn_decode.field(4, dyn_decode.string)
    use duration_ms <- dyn_decode.field(5, dyn_decode.int)
    use started_at <- dyn_decode.field(6, dyn_decode.int)
    dyn_decode.success(
      Run(
        id:, status:, trigger_type:, trigger_source:, result:, duration_ms:, started_at:,
      )
    )
  }
  case client.query_many(db, #(sql, [
    dev.ParamString(agent_id),
    dev.ParamInt(limit),
  ], decoder)) {
    Ok(runs) -> Ok(runs)
    Error(e) -> {
      logging.log(logging.Error, "db.get_actor_runs failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Insert a new run record.
pub fn insert_run(
  db: Db,
  agent_id agent_id: String,
  deployment_id deployment_id: Option(String),
  trigger_type trigger_type: String,
  trigger_source trigger_source: String,
  status status: String,
  started_at started_at: Int,
) -> Result(Nil, Nil) {
  let id = new_id()
  do_insert_run(
    db,
    id,
    agent_id,
    deployment_id,
    trigger_type,
    trigger_source,
    status,
    started_at,
  )
}

/// Insert a new run record with a specific ID (for run tracking).
pub fn insert_run_with_id(
  db: Db,
  id: String,
  agent_id: String,
  trigger_type: String,
  trigger_source: String,
  status: String,
  started_at: Int,
) -> Result(Nil, Nil) {
  do_insert_run(
    db,
    id,
    agent_id,
    option.None,
    trigger_type,
    trigger_source,
    status,
    started_at,
  )
}

fn do_insert_run(
  db: Db,
  id: String,
  agent_id: String,
  deployment_id: Option(String),
  trigger_type: String,
  trigger_source: String,
  status: String,
  started_at: Int,
) -> Result(Nil, Nil) {
  let sql =
    "
    INSERT INTO runs (id, agent_id, deployment_id, trigger_type, trigger_source, status, started_at)
    VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7 / 1000.0))
    "
  case client.exec(db, #(sql, [
    dev.ParamString(id),
    dev.ParamString(agent_id),
    dev.ParamNullable(case deployment_id {
      Some(d) -> Some(dev.ParamString(d))
      None -> None
    }),
    dev.ParamString(trigger_type),
    dev.ParamString(trigger_source),
    dev.ParamString(status),
    dev.ParamInt(started_at),
  ])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.insert_run failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Complete a run with status, result, and metrics.
pub fn complete_run(
  db: Db,
  id: String,
  status status: String,
  result result: Option(String),
  gas_used gas_used: Option(Int),
  duration_ms duration_ms: Option(Int),
  completed_at completed_at: Option(Int),
) -> Result(Nil, Nil) {
  let sql =
    "
    UPDATE runs
    SET status = $1,
        result = $2,
        gas_used = $3,
        duration_ms = $4,
        completed_at = to_timestamp($5 / 1000.0)
    WHERE id = $6
    "
  case client.exec(db, #(sql, [
    dev.ParamString(status),
    dev.ParamNullable(case result {
      Some(r) -> Some(dev.ParamString(r))
      None -> None
    }),
    dev.ParamNullable(case gas_used {
      Some(g) -> Some(dev.ParamInt(g))
      None -> None
    }),
    dev.ParamNullable(case duration_ms {
      Some(d) -> Some(dev.ParamInt(d))
      None -> None
    }),
    dev.ParamNullable(case completed_at {
      Some(c) -> Some(dev.ParamInt(c))
      None -> None
    }),
    dev.ParamString(id),
  ])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.complete_run failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Chat Queries
// ═══════════════════════════════════════════════════════════════

fn chat_message_decoder() -> dyn_decode.Decoder(ChatMessage) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  use content <- dyn_decode.field(1, dyn_decode.string)
  use role <- dyn_decode.field(2, dyn_decode.string)
  use created_at <- dyn_decode.field(3, dyn_decode.int)
  dyn_decode.success(ChatMessage(id:, content:, role:, created_at:))
}

fn session_id_decoder() -> dyn_decode.Decoder(String) {
  use id <- dyn_decode.field(0, dyn_decode.string)
  dyn_decode.success(id)
}

/// Get or create the active chat session for a specific user.
/// Uses user_key to isolate sessions per user (e.g. "telegram:123456").
pub fn get_or_create_session_for_user(
  db: Db,
  user_key: String,
) -> Result(String, Nil) {
  let sql =
    "
    SELECT id
    FROM chat_sessions
    WHERE user_key = $1 AND status = 'active'
    LIMIT 1
    "
  case client.query_many(db, #(sql, [dev.ParamString(user_key)], session_id_decoder())) {
    Ok([session_id]) -> Ok(session_id)
    Ok([]) -> {
      // Create new session
      let id = new_id()
      let ins_sql =
        "
        INSERT INTO chat_sessions (id, user_key, status)
        VALUES ($1, $2, 'active')
        "
      case client.exec(db, #(ins_sql, [
        dev.ParamString(id),
        dev.ParamString(user_key),
      ])) {
        Ok(_) -> Ok(id)
        Error(e) -> {
          logging.log(logging.Error, "db.get_or_create_session_for_user insert failed: " <> error_to_string(e))
          Error(Nil)
        }
      }
    }
    Ok(_) -> Ok("")
    Error(e) -> {
      logging.log(logging.Error, "db.get_or_create_session_for_user failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Mark a chat session as completed.
pub fn complete_session(db: Db, session_id: String) -> Result(Nil, Nil) {
  let sql =
    "
    UPDATE chat_sessions
    SET status = 'completed', updated_at = now()
    WHERE id = $1
    "
  case client.exec(db, #(sql, [dev.ParamString(session_id)])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.complete_session failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get the most recent N messages for a session.
/// Returns messages in chronological order (oldest first),
/// useful for seeding Pig agent history via with_initial_history().
pub fn get_recent_messages(
  db: Db,
  session_id: String,
  limit: Int,
) -> Result(List(ChatMessage), Nil) {
  let sql =
    "
    SELECT id, content, role, CAST(EXTRACT(EPOCH FROM created_at) * 1000 AS BIGINT) as created_at
    FROM chat_messages
    WHERE session_id = $1
    ORDER BY created_at DESC
    LIMIT $2
    "
  case client.query_many(db, #(sql, [
    dev.ParamString(session_id),
    dev.ParamInt(limit),
  ], chat_message_decoder())) {
    Ok(rows) -> {
      // Query returns DESC order, reverse to get chronological ASC
      let rows = list.reverse(rows)
      Ok(rows)
    }
    Error(e) -> {
      logging.log(logging.Error, "db.get_recent_messages failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get or create the active chat session.
pub fn get_or_create_session(db: Db) -> Result(String, Nil) {
  let sql =
    "
    SELECT id
    FROM chat_sessions
    WHERE status = 'active'
    ORDER BY created_at DESC
    LIMIT 1
    "
  case client.query_many(db, #(sql, [], session_id_decoder())) {
    Ok([session_id]) -> Ok(session_id)
    Ok([]) -> {
      // Create new session
      let id = new_id()
      let ins_sql =
        "
        INSERT INTO chat_sessions (id, status)
        VALUES ($1, 'active')
        "
      case client.exec(db, #(ins_sql, [dev.ParamString(id)])) {
        Ok(_) -> Ok(id)
        Error(e) -> {
          logging.log(logging.Error, "db.get_or_create_session insert failed: " <> error_to_string(e))
          Error(Nil)
        }
      }
    }
    Ok(_) -> Ok("")
    Error(e) -> {
      logging.log(logging.Error, "db.get_or_create_session failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Save a chat message to a session.
pub fn save_chat_message(
  db: Db,
  session_id: String,
  role: String,
  content: String,
) -> Result(Nil, Nil) {
  let id = new_id()
  let sql =
    "
    INSERT INTO chat_messages (id, session_id, role, content)
    VALUES ($1, $2, $3, $4)
    "
  case client.exec(db, #(sql, [
    dev.ParamString(id),
    dev.ParamString(session_id),
    dev.ParamString(role),
    dev.ParamString(content),
  ])) {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      logging.log(logging.Error, "db.save_chat_message failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

/// Get all messages for a session, ordered by created_at ASC.
pub fn get_chat_messages(
  db: Db,
  session_id: String,
) -> Result(List(ChatMessage), Nil) {
  let sql =
    "
    SELECT id, content, role, CAST(EXTRACT(EPOCH FROM created_at) * 1000 AS BIGINT) as created_at
    FROM chat_messages
    WHERE session_id = $1
    ORDER BY created_at ASC
    "
  case client.query_many(db, #(sql, [dev.ParamString(session_id)], chat_message_decoder())) {
    Ok(messages) -> Ok(messages)
    Error(e) -> {
      logging.log(logging.Error, "db.get_chat_messages failed: " <> error_to_string(e))
      Error(Nil)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Internal — Hash computation
// ═══════════════════════════════════════════════════════════════

/// Compute the actor hash from chute source.
/// Same as yard/loader but inline to avoid circular dependency.
@external(erlang, "yard_obs_ffi", "sha256_first8")
fn actor_hash(source: String) -> String