//// Hermes effect handlers — wrap Pig workspace operations and emit_event
//// into Yard's EffectHandler type for use by the runner.
////
//// EventCollector uses a cell actor (tiny OTP process holding a list)
//// to accumulate emit_event payloads during a chute_exec run.
//// The collector tracks gas_used by observing ActorCompleted events.

import ballast/value.{ErrorVal, ListVal, NilVal, OkVal, RecordVal, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import pig/workspace/kv
import pig/workspace/vfs
import sqlight
import yard/cron_engine
import yard/db
import yard/obs/events.{type HostEvent}
import yard/runner.{type EffectHandler}
import yard/skill_repo

// ═══════════════════════════════════════════════════════════════
// Event Collector — cell actor
// ═══════════════════════════════════════════════════════════════

/// Messages the cell actor understands.
pub type CollectorMessage {
  Record(String, String)
  SetGasUsed(Int)
  GetEvents(process.Subject(List(#(String, String))))
  GetGasUsed(process.Subject(Int))
  Stop
}

/// State held by the collector actor.
pub type CollectorState {
  CollectorState(events: List(#(String, String)), gas_used: Int)
}

/// A cell actor that accumulates (name, payload) pairs and tracks
/// gas_used from ActorCompleted events. Each chute_exec call creates
/// its own collector — the lifecycle is tied to a single tool invocation.
pub type EventCollector =
  process.Subject(CollectorMessage)

/// Create a new event collector (spawns a cell actor).
pub fn new_event_collector() -> EventCollector {
  let assert Ok(started) =
    actor.new(CollectorState(events: [], gas_used: 0))
    |> actor.on_message(fn(state, msg) {
      case msg {
        Record(name, payload) ->
          actor.continue(CollectorState(
            events: [#(name, payload), ..state.events],
            gas_used: state.gas_used,
          ))
        SetGasUsed(gas) ->
          actor.continue(CollectorState(events: state.events, gas_used: gas))
        GetEvents(reply) -> {
          process.send(reply, list.reverse(state.events))
          actor.continue(state)
        }
        GetGasUsed(reply) -> {
          process.send(reply, state.gas_used)
          actor.continue(state)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start()
  started.data
}

/// Record an event in the collector.
pub fn collector_record(
  collector: EventCollector,
  name: String,
  payload: String,
) -> Nil {
  process.send(collector, Record(name, payload))
}

/// Set the gas_used value (from ActorCompleted event).
pub fn collector_set_gas(collector: EventCollector, gas: Int) -> Nil {
  process.send(collector, SetGasUsed(gas))
}

/// Get all collected events in order.
pub fn collector_events(collector: EventCollector) -> List(#(String, String)) {
  process.call(collector, 1000, fn(reply) { GetEvents(reply) })
}

/// Get the gas_used value.
pub fn collector_gas_used(collector: EventCollector) -> Int {
  process.call(collector, 1000, fn(reply) { GetGasUsed(reply) })
}

/// Stop the collector actor (releases the process).
pub fn collector_stop(collector: EventCollector) -> Nil {
  process.send(collector, Stop)
}

// ═══════════════════════════════════════════════════════════════
// Yard emit adapter — intercepts events for gas tracking
// ═══════════════════════════════════════════════════════════════

/// Create an emit callback that forwards to the Yard emit and also
/// captures gas_used from ActorCompleted events into the collector.
pub fn emit_with_collector(
  yard_emit: fn(HostEvent) -> Nil,
  collector: EventCollector,
) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) {
    case event {
      events.ActorCompleted(gas_used:, ..) -> {
        collector_set_gas(collector, gas_used)
        yard_emit(event)
      }
      _ -> yard_emit(event)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// emit_event handler
// ═══════════════════════════════════════════════════════════════

/// Create an emit_event handler that captures events into the collector.
pub fn emit_event_handler(collector: EventCollector) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(name), StringVal(payload)] -> {
        collector_record(collector, name, payload)
        Ok(NilVal)
      }
      _ ->
        Ok(
          ErrorVal(StringVal(
            "emit_event: expected 2 string args (name, payload)",
          )),
        )
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Workspace handlers
// ═══════════════════════════════════════════════════════════════

/// Handler for write_file effect: writes content to VFS.
pub fn write_file_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path), StringVal(content)] ->
        case vfs.write_file(conn, path, content) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("write_file: invalid args")))
    }
  }
}

/// Handler for read_file effect: reads content from VFS.
pub fn read_file_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path)] ->
        case vfs.read_file(conn, path) {
          Ok(content) -> Ok(OkVal(StringVal(content)))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("read_file: invalid args")))
    }
  }
}

/// Handler for list_files effect: lists directory contents from VFS.
pub fn list_files_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path)] ->
        case vfs.list_directory(conn, path) {
          Ok(entries) ->
            Ok(OkVal(value.ListVal(list.map(entries, fn(e) { StringVal(e) }))))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("list_files: invalid args")))
    }
  }
}

/// Handler for store effect: stores a key-value pair in KV.
pub fn store_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(key), StringVal(val)] ->
        case kv.remember(conn, key, val) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(err) -> Ok(ErrorVal(StringVal(kv_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("store: invalid args")))
    }
  }
}

/// Handler for recall effect: recalls a value from KV.
pub fn recall_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(key)] ->
        case kv.recall(conn, key) {
          Ok(val) -> Ok(OkVal(StringVal(val)))
          Error(err) -> Ok(ErrorVal(StringVal(kv_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("recall: invalid args")))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Handler registry
// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
// Skill handlers (global DB)
// ═══════════════════════════════════════════════════════════════

/// Handler for register_skill effect: registers a skill in the global DB.
pub fn register_skill_handler(
  global_conn: sqlight.Connection,
) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(name), StringVal(description), StringVal(source)] ->
        case skill_repo.register(global_conn, name, description, source, []) {
          Ok(id) -> Ok(OkVal(StringVal(id)))
          Error(msg) -> Ok(ErrorVal(StringVal(msg)))
        }
      _ ->
        Ok(
          ErrorVal(StringVal(
            "register_skill: expected 3 string args (name, description, source)",
          )),
        )
    }
  }
}

/// Handler for get_skill effect: looks up a skill by name.
pub fn get_skill_handler(global_conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(name)] ->
        case skill_repo.lookup(global_conn, name) {
          Ok(skill) ->
            Ok(
              OkVal(
                RecordVal([
                  #("id", StringVal(skill.id)),
                  #("name", StringVal(skill.name)),
                  #("description", StringVal(skill.description)),
                  #("chute_source", StringVal(skill.chute_source)),
                  #("status", StringVal(skill.status)),
                ]),
              ),
            )
          Error(msg) -> Ok(ErrorVal(StringVal(msg)))
        }
      _ -> Ok(ErrorVal(StringVal("get_skill: expected 1 string arg (name)")))
    }
  }
}

/// Handler for list_skills effect: lists all active skills.
pub fn list_skills_handler(global_conn: sqlight.Connection) -> EffectHandler {
  fn(_name, _args) {
    case skill_repo.list_all(global_conn) {
      Ok(skills) -> {
        let items =
          list.map(skills, fn(s) {
            RecordVal([
              #("id", StringVal(s.id)),
              #("name", StringVal(s.name)),
              #("description", StringVal(s.description)),
              #("status", StringVal(s.status)),
            ])
          })
        Ok(OkVal(ListVal(items)))
      }
      Error(msg) -> Ok(ErrorVal(StringVal(msg)))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Handler registry
// ═══════════════════════════════════════════════════════════════

/// Build the complete set of Hermes effect handlers.
/// Takes workspace conn (for VFS/KV) and optional global conn (for skills).
pub fn all_handlers(
  conn: sqlight.Connection,
  collector: EventCollector,
) -> dict.Dict(String, EffectHandler) {
  let base = [
    #("emit_event", emit_event_handler(collector)),
    #("read_file", read_file_handler(conn)),
    #("write_file", write_file_handler(conn)),
    #("list_files", list_files_handler(conn)),
    #("recall", recall_handler(conn)),
    #("store", store_handler(conn)),
  ]
  dict.from_list(base)
}

/// Build handlers with skill support (requires global DB).
pub fn all_handlers_with_global(
  conn: sqlight.Connection,
  global_conn: sqlight.Connection,
  collector: EventCollector,
) -> dict.Dict(String, EffectHandler) {
  let base = [
    #("emit_event", emit_event_handler(collector)),
    #("read_file", read_file_handler(conn)),
    #("write_file", write_file_handler(conn)),
    #("list_files", list_files_handler(conn)),
    #("recall", recall_handler(conn)),
    #("store", store_handler(conn)),
    #("register_skill", register_skill_handler(global_conn)),
    #("get_skill", get_skill_handler(global_conn)),
    #("list_skills", list_skills_handler(global_conn)),
    #("list_agents", list_agents_handler(global_conn)),
    #("register_agent", register_agent_handler(global_conn)),
    #("tell_user", tell_user_handler(collector)),
    #("learn", learn_handler(conn)),
  ]
  dict.from_list(base)
}

/// Build handlers with cron support (requires engine + global DB).
pub fn all_handlers_with_cron(
  conn: sqlight.Connection,
  global_conn: sqlight.Connection,
  collector: EventCollector,
  engine: cron_engine.CronEngine,
) -> dict.Dict(String, EffectHandler) {
  let base = [
    #("emit_event", emit_event_handler(collector)),
    #("read_file", read_file_handler(conn)),
    #("write_file", write_file_handler(conn)),
    #("list_files", list_files_handler(conn)),
    #("recall", recall_handler(conn)),
    #("store", store_handler(conn)),
    #("register_skill", register_skill_handler(global_conn)),
    #("get_skill", get_skill_handler(global_conn)),
    #("list_skills", list_skills_handler(global_conn)),
    #("list_agents", list_agents_handler(global_conn)),
    #("register_agent", register_agent_handler(global_conn)),
    #("tell_user", tell_user_handler(collector)),
    #("learn", learn_handler(conn)),
    #("schedule_cron", schedule_cron_handler(engine, global_conn)),
    #("list_crons", list_crons_handler(engine)),
    #("cancel_cron", cancel_cron_handler(engine)),
  ]
  dict.from_list(base)
}

// ═══════════════════════════════════════════════════════════════
// Agent handlers (global DB)
// ═══════════════════════════════════════════════════════════════

/// Handler for list_agents effect: lists all registered agents.
pub fn list_agents_handler(global_conn: sqlight.Connection) -> EffectHandler {
  fn(_name, _args) {
    case db.list_agents(global_conn) {
      Ok(agents) -> {
        let items =
          list.map(agents, fn(a) {
            RecordVal([
              #("id", StringVal(a.id)),
              #("name", StringVal(a.name)),
              #("status", StringVal(a.status)),
              #("actor_hash", StringVal(a.actor_hash)),
            ])
          })
        Ok(OkVal(ListVal(items)))
      }
      Error(_) -> Ok(ErrorVal(StringVal("Database error listing agents")))
    }
  }
}

/// Handler for register_agent effect: registers a new agent.
pub fn register_agent_handler(
  global_conn: sqlight.Connection,
) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(name), StringVal(description), StringVal(source)] ->
        case db.insert_agent(global_conn, name, description, source, "active") {
          Ok(id) -> Ok(OkVal(StringVal(id)))
          Error(_) -> Ok(ErrorVal(StringVal("Failed to register agent")))
        }
      _ ->
        Ok(
          ErrorVal(StringVal(
            "register_agent: expected 3 string args (name, description, source)",
          )),
        )
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Conversation handlers
// ═══════════════════════════════════════════════════════════════

/// Handler for tell_user effect: records a message for the user.
pub fn tell_user_handler(collector: EventCollector) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(message)] -> {
        collector_record(collector, "tell_user", message)
        Ok(NilVal)
      }
      _ -> Ok(ErrorVal(StringVal("tell_user: expected 1 string arg (message)")))
    }
  }
}

/// Handler for learn effect: stores a fact with a "hermes_learned:" prefix.
pub fn learn_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(key), StringVal(fact)] -> {
        let prefixed_key = "hermes_learned:" <> key
        case kv.remember(conn, prefixed_key, fact) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(err) -> Ok(ErrorVal(StringVal(kv_error(err))))
        }
      }
      _ -> Ok(ErrorVal(StringVal("learn: expected 2 string args (key, fact)")))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Cron handlers (global DB via cron engine)
// ═══════════════════════════════════════════════════════════════

/// Handler for schedule_cron effect: registers a cron schedule.
/// Uses global_conn to look up skill by name, then registers via engine.
pub fn schedule_cron_handler(
  engine: cron_engine.CronEngine,
  global_conn: sqlight.Connection,
) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(cron_expr), StringVal(skill_name)] ->
        case skill_repo.lookup(global_conn, skill_name) {
          Ok(skill) ->
            case
              cron_engine.register(
                engine,
                skill_id: skill.id,
                cron_expr: cron_expr,
                agent_id: option.None,
              )
            {
              Ok(id) -> Ok(OkVal(StringVal(id)))
              Error(_) ->
                Ok(ErrorVal(StringVal("schedule_cron: failed to register")))
            }
          Error(msg) -> Ok(ErrorVal(StringVal(msg)))
        }
      _ ->
        Ok(
          ErrorVal(StringVal(
            "schedule_cron: expected 2 string args (cron_expr, skill_name)",
          )),
        )
    }
  }
}

/// Handler for list_crons effect: lists all active schedules.
pub fn list_crons_handler(engine: cron_engine.CronEngine) -> EffectHandler {
  fn(_name, _args) {
    let schedules = cron_engine.list_schedules(engine)
    let items =
      list.map(schedules, fn(s) {
        RecordVal([
          #("id", StringVal(s.id)),
          #("cron_expr", StringVal(s.cron_expr)),
          #("skill_id", StringVal(s.skill_id)),
          #("status", StringVal(s.status)),
          #("next_fire_at", StringVal(int.to_string(s.next_fire_at))),
        ])
      })
    Ok(OkVal(ListVal(items)))
  }
}

/// Handler for cancel_cron effect: cancels a schedule.
pub fn cancel_cron_handler(engine: cron_engine.CronEngine) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(id)] ->
        case cron_engine.cancel(engine, id) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(_) -> Ok(ErrorVal(StringVal("cancel_cron: failed to cancel")))
        }
      _ -> Ok(ErrorVal(StringVal("cancel_cron: expected 1 string arg (id)")))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Error formatting
// ═══════════════════════════════════════════════════════════════

fn vfs_error(err: vfs.Error) -> String {
  case err {
    vfs.NotFound(path) -> "File not found: " <> path
    vfs.NotEmpty(path) -> "Directory not empty: " <> path
    vfs.InvalidPath(path) -> "Invalid path: " <> path
    vfs.AlreadyExists(path) -> "Already exists: " <> path
    vfs.SqlError(e) -> "SQL error: " <> sqlight_error(e)
  }
}

fn kv_error(err: kv.Error) -> String {
  case err {
    kv.NotFound(key) -> "Key not found: " <> key
    kv.SqlError(e) -> "SQL error: " <> sqlight_error(e)
  }
}

fn sqlight_error(err: sqlight.Error) -> String {
  string.inspect(err)
}
