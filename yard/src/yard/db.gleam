//// Database initialization and typed CRUD for Yard's global store.
////
//// Opens SQLite, runs migrations (from schema.sql), and provides typed
//// query functions using Parrot-generated codegen. Parrot generates the
//// SQL, params, and decoders — this module wraps them with sqlight execution.
////
//// Two-DB architecture:
////   - Global DB (this module): agents, skills, schedules, runs, chat
////   - Per-agent workspace: VFS + KV (pig/workspace, one DB per agent)

import birl
import gleam/bit_array
import gleam/dynamic/decode as dyn_decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gluid
import logging
import parrot/dev.{type Param}
import sqlight
import yard/sql

// ═══════════════════════════════════════════════════════════════
// Public Types
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

pub type Schedule {
  Schedule(
    id: String,
    agent_id: Option(String),
    skill_id: String,
    cron_expr: String,
    status: String,
    last_fired_at: Option(Int),
    next_fire_at: Int,
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
// Param Conversion
// ═══════════════════════════════════════════════════════════════

fn param_to_value(p: Param) -> sqlight.Value {
  case p {
    dev.ParamString(s) -> sqlight.text(s)
    dev.ParamInt(i) -> sqlight.int(i)
    dev.ParamFloat(f) -> sqlight.float(f)
    dev.ParamBool(b) -> sqlight.bool(b)
    dev.ParamBitArray(b) -> sqlight.text(bit_array_to_string(b))
    dev.ParamNullable(opt) ->
      case opt {
        Some(p) -> param_to_value(p)
        None -> sqlight.null()
      }
    dev.ParamList(_) -> sqlight.null()
    dev.ParamDynamic(_) -> sqlight.null()
    dev.ParamTimestamp(_) -> sqlight.null()
    dev.ParamDate(_) -> sqlight.null()
  }
}

fn bit_array_to_string(ba: BitArray) -> String {
  case bit_array.to_string(ba) {
    Ok(s) -> s
    Error(_) -> ""
  }
}

fn params_to_values(params: List(Param)) -> List(sqlight.Value) {
  list.map(params, param_to_value)
}

// ═══════════════════════════════════════════════════════════════
// Database Open & Migrate
// ═══════════════════════════════════════════════════════════════

/// Open a SQLite database at the given path.
/// Use "file::memory:" for in-memory databases (tests).
pub fn open(path: String) -> Result(sqlight.Connection, sqlight.Error) {
  case sqlight.open(path) {
    Ok(conn) -> {
      // Enable foreign key enforcement — SQLite disables it by default.
      case sqlight.exec("PRAGMA foreign_keys = ON", on: conn) {
        Ok(Nil) -> Ok(conn)
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

/// Run all migrations to create the global schema.
/// Safe to call multiple times (uses IF NOT EXISTS).
pub fn migrate(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  let sql =
    "
    CREATE TABLE IF NOT EXISTS providers (
      id TEXT PRIMARY KEY,
      api_key TEXT NOT NULL,
      base_url TEXT NOT NULL,
      model TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

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

    CREATE TABLE IF NOT EXISTS deployments (
      id TEXT PRIMARY KEY,
      agent_id TEXT NOT NULL REFERENCES agents(id),
      actor_hash TEXT NOT NULL,
      trigger_type TEXT NOT NULL,
      trigger_config TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      deployed_at INTEGER NOT NULL
    );

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
  "
  sqlight.exec(sql, on: conn)
}

/// Generate a new UUID (lowercase v4).
fn new_id() -> String {
  gluid.guidv4() |> string.lowercase()
}

/// Current unix timestamp in milliseconds.
fn now_ts() -> Int {
  birl.to_unix_milli(birl.utc_now())
}

// ═══════════════════════════════════════════════════════════════
// Provider Queries
// ═══════════════════════════════════════════════════════════════

/// Get the current provider, if one exists.
pub fn get_provider(conn: sqlight.Connection) -> Result(Option(Provider), Nil) {
  let #(sql_str, params, decoder) = sql.get_provider()
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Provider(
          id: row.id,
          api_key: row.api_key,
          base_url: row.base_url,
          model: row.model,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Save a provider, replacing any existing one.
pub fn save_provider(
  conn: sqlight.Connection,
  api_key: String,
  base_url: String,
  model: String,
) -> Result(Provider, Nil) {
  let now = now_ts()

  // Wrap delete + insert in a transaction for atomicity
  let _ = sqlight.exec("BEGIN TRANSACTION", on: conn)

  // Delete any existing provider
  let #(del_sql, _del_params) = sql.save_provider()
  case sqlight.exec(del_sql, on: conn) {
    Error(e) -> {
      let _ = sqlight.exec("ROLLBACK", on: conn)
      logging.log(
        logging.Error,
        "db.save_provider delete failed: " <> string.inspect(e),
      )
      Error(Nil)
    }
    Ok(_) -> {
      // Insert new provider
      let #(ins_sql, ins_params) =
        sql.insert_provider(
          id: "default",
          api_key: api_key,
          base_url: base_url,
          model: model,
          created_at: now,
          updated_at: now,
        )

      case
        sqlight.query(
          ins_sql,
          on: conn,
          with: params_to_values(ins_params),
          expecting: dyn_decode.success(Nil),
        )
      {
        Ok(_) -> {
          let _ = sqlight.exec("COMMIT", on: conn)
          Ok(Provider("default", api_key, base_url, model))
        }
        Error(e) -> {
          let _ = sqlight.exec("ROLLBACK", on: conn)
          logging.log(
            logging.Error,
            "db.save_provider insert failed: " <> string.inspect(e),
          )
          Error(Nil)
        }
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Agent Queries
// ═══════════════════════════════════════════════════════════════

/// List all agents (id, name, status, actor_hash).
pub fn list_agents(
  conn: sqlight.Connection,
) -> Result(List(sql.ListAgents), Nil) {
  let #(sql_str, params, decoder) = sql.list_agents()
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.replace_error(Nil)
}

/// Get an agent by ID.
pub fn get_agent(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(Agent), Nil) {
  let #(sql_str, params, decoder) = sql.get_agent(id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Agent(
          id: row.id,
          name: row.name,
          description: row.description,
          chute_source: row.chute_source,
          actor_hash: row.actor_hash,
          status: row.status,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Get an agent by name.
pub fn get_agent_by_name(
  conn: sqlight.Connection,
  name: String,
) -> Result(Option(Agent), Nil) {
  let #(sql_str, params, decoder) = sql.get_agent_by_name(name:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Agent(
          id: row.id,
          name: row.name,
          description: row.description,
          chute_source: row.chute_source,
          actor_hash: row.actor_hash,
          status: row.status,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Insert a new agent. Returns the generated ID.
/// Computes actor_hash from the chute source via loader.
pub fn insert_agent(
  conn: sqlight.Connection,
  name: String,
  description: String,
  chute_source: String,
  status: String,
) -> Result(String, Nil) {
  let id = new_id()
  let now = now_ts()
  // Compute actor hash from source
  let hash = actor_hash(chute_source)
  let #(sql_str, params) =
    sql.insert_agent(
      id: id,
      name: name,
      description: description,
      chute_source: chute_source,
      actor_hash: hash,
      status: status,
      created_at: now,
      updated_at: now,
    )
  case
    sqlight.query(
      sql_str,
      on: conn,
      with: params_to_values(params),
      expecting: dyn_decode.success(Nil),
    )
  {
    Ok(_) -> Ok(id)
    Error(e) -> {
      logging.log(
        logging.Error,
        "db.insert_agent failed: " <> string.inspect(e),
      )
      Error(Nil)
    }
  }
}

/// Get handler bindings for an agent.
pub fn get_agent_handlers(
  conn: sqlight.Connection,
  agent_id: String,
) -> Result(List(AgentHandler), Nil) {
  let #(sql_str, params, decoder) = sql.get_agent_handlers(agent_id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.map(rows, fn(row) {
      AgentHandler(effect_name: row.effect_name, handler_name: row.handler_name)
    })
  })
  |> result.replace_error(Nil)
}

/// Insert an agent handler binding.
pub fn insert_agent_handler(
  conn: sqlight.Connection,
  agent_id: String,
  effect_name: String,
  handler_name: String,
) -> Result(Nil, Nil) {
  let id = new_id()
  let now = now_ts()
  let #(sql_str, params) =
    sql.insert_agent_handler(
      id: id,
      agent_id: agent_id,
      effect_name: effect_name,
      handler_name: handler_name,
      created_at: now,
    )
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Skill Queries
// ═══════════════════════════════════════════════════════════════

/// List all active skills.
pub fn list_skills(conn: sqlight.Connection) -> Result(List(Skill), Nil) {
  let #(sql_str, params, decoder) = sql.list_skills()
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.map(rows, fn(row) {
      Skill(
        id: row.id,
        name: row.name,
        description: row.description,
        chute_source: "",
        tags: row.tags,
        status: row.status,
      )
    })
  })
  |> result.replace_error(Nil)
}

/// Get a skill by ID.
pub fn get_skill(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(Skill), Nil) {
  let #(sql_str, params, decoder) = sql.get_skill(id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Skill(
          id: row.id,
          name: row.name,
          description: row.description,
          chute_source: row.chute_source,
          tags: row.tags,
          status: row.status,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Get a skill by name.
pub fn get_skill_by_name(
  conn: sqlight.Connection,
  name: String,
) -> Result(Option(Skill), Nil) {
  let #(sql_str, params, decoder) = sql.get_skill_by_name(name:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Skill(
          id: row.id,
          name: row.name,
          description: row.description,
          chute_source: row.chute_source,
          tags: row.tags,
          status: row.status,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Insert a new skill. Returns the generated ID.
pub fn insert_skill(
  conn: sqlight.Connection,
  name name: String,
  description description: String,
  chute_source chute_source: String,
  tags tags: String,
) -> Result(String, Nil) {
  let id = new_id()
  let now = now_ts()
  let _hash = actor_hash(chute_source)
  let #(sql_str, params) =
    sql.insert_skill(
      id: id,
      name: name,
      description: description,
      chute_source: chute_source,
      tags: tags,
      status: "active",
      created_at: now,
      updated_at: now,
    )
  case
    sqlight.query(
      sql_str,
      on: conn,
      with: params_to_values(params),
      expecting: dyn_decode.success(Nil),
    )
  {
    Ok(_) -> Ok(id)
    Error(e) -> {
      logging.log(
        logging.Error,
        "db.insert_skill failed: " <> string.inspect(e),
      )
      Error(Nil)
    }
  }
}

/// Update a skill's description, source, and tags.
pub fn update_skill(
  conn: sqlight.Connection,
  id: String,
  description description: String,
  source chute_source: String,
  tags tags: String,
) -> Result(Nil, Nil) {
  let now = now_ts()
  let #(sql_str, params) =
    sql.update_skill(
      description: description,
      chute_source: chute_source,
      tags: tags,
      updated_at: now,
      id: id,
    )
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

/// Deactivate a skill (soft delete).
pub fn deactivate_skill(
  conn: sqlight.Connection,
  id: String,
) -> Result(Nil, Nil) {
  let now = now_ts()
  let #(sql_str, params) = sql.deactivate_skill(updated_at: now, id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Schedule Queries
// ═══════════════════════════════════════════════════════════════

/// List all active schedules, ordered by next_fire_at ASC.
pub fn list_active_schedules(
  conn: sqlight.Connection,
) -> Result(List(Schedule), Nil) {
  let #(sql_str, params, decoder) = sql.list_active_schedules()
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.map(rows, fn(row) {
      Schedule(
        id: row.id,
        agent_id: row.agent_id,
        skill_id: row.skill_id,
        cron_expr: row.cron_expr,
        status: row.status,
        last_fired_at: row.last_fired_at,
        next_fire_at: row.next_fire_at,
      )
    })
  })
  |> result.replace_error(Nil)
}

/// Get a schedule by ID.
pub fn get_schedule(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(Schedule), Nil) {
  let #(sql_str, params, decoder) = sql.get_schedule(id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [row] ->
        Some(Schedule(
          id: row.id,
          agent_id: row.agent_id,
          skill_id: row.skill_id,
          cron_expr: row.cron_expr,
          status: row.status,
          last_fired_at: row.last_fired_at,
          next_fire_at: row.next_fire_at,
        ))
      _ -> None
    }
  })
  |> result.replace_error(Nil)
}

/// Insert a new schedule. Returns the generated ID.
pub fn insert_schedule(
  conn: sqlight.Connection,
  agent_id agent_id: Option(String),
  skill_id skill_id: String,
  cron_expr cron_expr: String,
  next_fire_at next_fire_at: Int,
) -> Result(String, Nil) {
  let id = new_id()
  let now = now_ts()
  let #(sql_str, params) =
    sql.insert_schedule(
      id: id,
      agent_id: agent_id,
      skill_id: skill_id,
      cron_expr: cron_expr,
      status: "active",
      next_fire_at: next_fire_at,
      created_at: now,
      updated_at: now,
    )
  case
    sqlight.query(
      sql_str,
      on: conn,
      with: params_to_values(params),
      expecting: dyn_decode.success(Nil),
    )
  {
    Ok(_) -> Ok(id)
    Error(e) -> {
      logging.log(
        logging.Error,
        "db.insert_schedule failed: " <> string.inspect(e),
      )
      Error(Nil)
    }
  }
}

/// Update a schedule's fire timestamps.
pub fn update_schedule_fire(
  conn: sqlight.Connection,
  id: String,
  last_fired_at last_fired_at: Option(Int),
  next_fire_at next_fire_at: Int,
) -> Result(Nil, Nil) {
  let now = now_ts()
  let #(sql_str, params) =
    sql.update_schedule_fire(
      last_fired_at: last_fired_at,
      next_fire_at: next_fire_at,
      updated_at: now,
      id: id,
    )
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

/// Deactivate a schedule (soft delete).
pub fn deactivate_schedule(
  conn: sqlight.Connection,
  id: String,
) -> Result(Nil, Nil) {
  let now = now_ts()
  let #(sql_str, params) = sql.deactivate_schedule(updated_at: now, id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Run Queries
// ═══════════════════════════════════════════════════════════════

/// Get recent runs for an agent, ordered by started_at DESC.
pub fn get_actor_runs(
  conn: sqlight.Connection,
  agent_id: String,
  limit: Int,
) -> Result(List(Run), Nil) {
  let #(sql_str, params, decoder) = sql.get_actor_runs(agent_id:, limit:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.map(rows, fn(row) {
      Run(
        id: row.id,
        status: row.status,
        trigger_type: row.trigger_type,
        trigger_source: "",
        result: row.result,
        duration_ms: row.duration_ms,
        started_at: row.started_at,
      )
    })
  })
  |> result.replace_error(Nil)
}

/// Insert a new run record.
pub fn insert_run(
  conn: sqlight.Connection,
  agent_id agent_id: String,
  deployment_id deployment_id: Option(String),
  trigger_type trigger_type: String,
  trigger_source trigger_source: String,
  status status: String,
  started_at started_at: Int,
) -> Result(Nil, Nil) {
  let id = new_id()
  do_insert_run(
    conn,
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
  conn: sqlight.Connection,
  id: String,
  agent_id: String,
  trigger_type: String,
  trigger_source: String,
  status: String,
  started_at: Int,
) -> Result(Nil, Nil) {
  do_insert_run(
    conn,
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
  conn: sqlight.Connection,
  id: String,
  agent_id: String,
  deployment_id: Option(String),
  trigger_type: String,
  trigger_source: String,
  status: String,
  started_at: Int,
) -> Result(Nil, Nil) {
  let #(sql_str, params) =
    sql.insert_run(
      id: id,
      agent_id: agent_id,
      deployment_id: deployment_id,
      trigger_type: trigger_type,
      trigger_source: trigger_source,
      status: status,
      started_at: started_at,
    )
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

/// Complete a run with status, result, and metrics.
pub fn complete_run(
  conn: sqlight.Connection,
  id: String,
  status status: String,
  result result: Option(String),
  gas_used gas_used: Option(Int),
  duration_ms duration_ms: Option(Int),
  completed_at completed_at: Option(Int),
) -> Result(Nil, Nil) {
  let #(sql_str, params) =
    sql.complete_run(
      status: status,
      result: result,
      gas_used: gas_used,
      duration_ms: duration_ms,
      completed_at: completed_at,
      id: id,
    )
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Chat Queries
// ═══════════════════════════════════════════════════════════════

/// Get or create the active chat session for a specific user.
/// Uses user_key to isolate sessions per user (e.g. "telegram:123456").
pub fn get_or_create_session_for_user(
  conn: sqlight.Connection,
  user_key: String,
) -> Result(String, Nil) {
  let #(sql_str, params, decoder) =
    sql.get_session_by_user_key(option.Some(user_key))
  let existing =
    sqlight.query(
      sql_str,
      on: conn,
      with: params_to_values(params),
      expecting: decoder,
    )
    |> result.map(fn(rows) { list.map(rows, fn(r) { r.id }) })
    |> result.unwrap([])

  case existing {
    [session_id] -> Ok(session_id)
    _ -> {
      let id = new_id()
      let now = now_ts()
      let #(ins_sql, ins_params) =
        sql.create_session_with_user_key(
          id:,
          user_key: option.Some(user_key),
          created_at: now,
          updated_at: now,
        )
      sqlight.query(
        ins_sql,
        on: conn,
        with: params_to_values(ins_params),
        expecting: dyn_decode.success(Nil),
      )
      |> result.map(fn(_) { id })
      |> result.replace_error(Nil)
    }
  }
}

/// Mark a chat session as completed.
pub fn complete_session(
  conn: sqlight.Connection,
  session_id: String,
) -> Result(Nil, Nil) {
  let now = now_ts()
  let #(sql_str, params) = sql.complete_session(updated_at: now, id: session_id)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

/// Get the most recent N messages for a session.
/// Returns messages in chronological order (oldest first),
/// useful for seeding Pig agent history via with_initial_history().
pub fn get_recent_messages(
  conn: sqlight.Connection,
  session_id: String,
  limit: Int,
) -> Result(List(ChatMessage), Nil) {
  let #(sql_str, params, decoder) = sql.get_recent_messages(session_id:, limit:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    // Query returns DESC order, reverse to get chronological ASC
    let rows = list.reverse(rows)
    list.map(rows, fn(row) {
      ChatMessage(
        id: row.id,
        content: row.content,
        role: row.role,
        created_at: row.created_at,
      )
    })
  })
  |> result.replace_error(Nil)
}

/// Get or create the active chat session.
pub fn get_or_create_session(conn: sqlight.Connection) -> Result(String, Nil) {
  let #(sql_str, params, decoder) = sql.get_active_session()
  let existing =
    sqlight.query(
      sql_str,
      on: conn,
      with: params_to_values(params),
      expecting: decoder,
    )
    |> result.map(fn(rows) { list.map(rows, fn(r) { r.id }) })
    |> result.unwrap([])

  case existing {
    [session_id] -> Ok(session_id)
    _ -> {
      let id = new_id()
      let now = now_ts()
      let #(ins_sql, ins_params) =
        sql.create_session(id:, created_at: now, updated_at: now)
      sqlight.query(
        ins_sql,
        on: conn,
        with: params_to_values(ins_params),
        expecting: dyn_decode.success(Nil),
      )
      |> result.map(fn(_) { id })
      |> result.replace_error(Nil)
    }
  }
}

/// Save a chat message to a session.
pub fn save_chat_message(
  conn: sqlight.Connection,
  session_id: String,
  role: String,
  content: String,
) -> Result(Nil, Nil) {
  let id = new_id()
  let now = now_ts()
  let #(sql_str, msg_params) =
    sql.save_chat_message(id:, session_id:, role:, content:, created_at: now)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(msg_params),
    expecting: dyn_decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Nil)
}

/// Get all messages for a session, ordered by created_at ASC.
pub fn get_chat_messages(
  conn: sqlight.Connection,
  session_id: String,
) -> Result(List(ChatMessage), Nil) {
  let #(sql_str, params, decoder) = sql.get_chat_messages(session_id:)
  sqlight.query(
    sql_str,
    on: conn,
    with: params_to_values(params),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.map(rows, fn(row) {
      ChatMessage(
        id: row.id,
        content: row.content,
        role: row.role,
        created_at: row.created_at,
      )
    })
  })
  |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════
// Internal — Hash computation
// ═══════════════════════════════════════════════════════════════

/// Compute the actor hash from chute source.
/// Same as yard/loader but inline to avoid circular dependency.
@external(erlang, "yard_obs_ffi", "sha256_first8")
fn actor_hash(source: String) -> String
