//// Cron engine — OTP actor that reads schedules from the global DB
//// and fires due skills on tick.
////
//// The engine is tick-based: the caller decides when to check for due
//// schedules (e.g. via a timer or external scheduler). On each tick:
////   1. Load active schedules from DB
////   2. Filter those where next_fire_at <= now
////   3. For each due schedule: look up skill, compile, run, reschedule
////   4. Return the list of fired skill names
////
//// For actual skill execution, the engine uses yard/loader to compile
//// and yard/runner to execute. The tick runs skills with minimal handlers
//// (just emit_event logging).

import automata/cron
import automata/cron/validator
import automata/schedule/ast as schedule_ast
import ballast/value
import birl
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gluid
import logging
import sqlight
import yard/db
import yard/loader
import yard/obs/events
import yard/runner

// ═══════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════

/// Messages the cron engine actor understands.
pub type EngineMsg {
  Register(
    skill_id: String,
    cron_expr: String,
    agent_id: option.Option(String),
    reply_to: process.Subject(Result(String, Nil)),
  )
  ListSchedules(reply_to: process.Subject(List(db.Schedule)))
  Cancel(id: String, reply_to: process.Subject(Result(Nil, Nil)))
  Tick(reply_to: process.Subject(List(String)))
  Reload(reply_to: process.Subject(Nil))
  Stop
}

/// Internal engine state.
pub type EngineState {
  EngineState(conn: sqlight.Connection)
}

/// The cron engine actor handle.
pub type CronEngine =
  process.Subject(EngineMsg)

// ═══════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════

/// Start the cron engine with a global DB connection.
pub fn start(conn: sqlight.Connection) -> Result(CronEngine, Nil) {
  let engine =
    actor.new(EngineState(conn: conn))
    |> actor.on_message(fn(state, msg) {
      case msg {
        Register(skill_id:, cron_expr:, agent_id:, reply_to:) ->
          handle_register(state, skill_id, cron_expr, agent_id, reply_to)

        ListSchedules(reply_to:) -> handle_list(state, reply_to)

        Cancel(id:, reply_to:) -> handle_cancel(state, id, reply_to)

        Tick(reply_to:) -> handle_tick(state, reply_to)

        Reload(reply_to:) -> handle_reload(state, reply_to)

        Stop -> actor.stop()
      }
    })
    |> actor.start()
  case engine {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error(Nil)
  }
}

/// Stop the cron engine.
pub fn stop(engine: CronEngine) -> Nil {
  process.send(engine, Stop)
}

/// Register a new schedule.
pub fn register(
  engine: CronEngine,
  skill_id skill_id: String,
  cron_expr cron_expr: String,
  agent_id agent_id: option.Option(String),
) -> Result(String, Nil) {
  process.call(engine, 5000, fn(reply_to) {
    Register(skill_id:, cron_expr:, agent_id:, reply_to:)
  })
}

/// List all active schedules.
pub fn list_schedules(engine: CronEngine) -> List(db.Schedule) {
  process.call(engine, 5000, fn(reply_to) { ListSchedules(reply_to:) })
}

/// Cancel (deactivate) a schedule.
pub fn cancel(engine: CronEngine, id: String) -> Result(Nil, Nil) {
  process.call(engine, 5000, fn(reply_to) { Cancel(id:, reply_to:) })
}

/// Tick the engine: fire all due schedules and return fired skill names.
pub fn tick(engine: CronEngine) -> List(String) {
  process.call(engine, 50_000, fn(reply_to) { Tick(reply_to:) })
}

/// Reload engine state from DB (useful after external changes).
pub fn reload(engine: CronEngine) -> Nil {
  process.call(engine, 5000, fn(reply_to) { Reload(reply_to:) })
}

/// Parse and validate a cron expression. Public for reuse.
pub fn parse_and_validate(expr: String) -> Result(validator.ValidCron, Nil) {
  case cron.parse(expr) {
    Ok(raw) ->
      case cron.validate(raw) {
        Ok(spec) -> Ok(spec)
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

// ═══════════════════════════════════════════════════════════════
// Message handlers
// ═══════════════════════════════════════════════════════════════

fn handle_register(
  state: EngineState,
  skill_id: String,
  cron_expr: String,
  agent_id: option.Option(String),
  reply_to: process.Subject(Result(String, Nil)),
) -> actor.Next(EngineState, EngineMsg) {
  let result =
    parse_and_validate(cron_expr)
    |> result.try(fn(spec) {
      // Compute next fire time
      let now = birl.utc_now()
      let vdt = birl_to_valid_datetime(now)
      let next_fire = case cron.next_after(spec, after: vdt) {
        option.Some(next_vdt) -> {
          let dt = schedule_ast.valid_datetime_value(next_vdt)
          datetime_to_unix(dt)
        }
        option.None ->
          // Fallback: 1 hour from now
          birl.to_unix(now) + 3600
      }
      db.insert_schedule(
        state.conn,
        agent_id: agent_id,
        skill_id: skill_id,
        cron_expr: cron_expr,
        next_fire_at: next_fire,
      )
    })
  process.send(reply_to, result)
  actor.continue(state)
}

fn handle_list(
  state: EngineState,
  reply_to: process.Subject(List(db.Schedule)),
) -> actor.Next(EngineState, EngineMsg) {
  let schedules = case db.list_active_schedules(state.conn) {
    Ok(s) -> s
    Error(_) -> []
  }
  process.send(reply_to, schedules)
  actor.continue(state)
}

fn handle_cancel(
  state: EngineState,
  id: String,
  reply_to: process.Subject(Result(Nil, Nil)),
) -> actor.Next(EngineState, EngineMsg) {
  let result = db.deactivate_schedule(state.conn, id)
  process.send(reply_to, result)
  actor.continue(state)
}

fn handle_tick(
  state: EngineState,
  reply_to: process.Subject(List(String)),
) -> actor.Next(EngineState, EngineMsg) {
  let now_ts = birl.utc_now() |> birl.to_unix()

  let schedules = case db.list_active_schedules(state.conn) {
    Ok(s) -> s
    Error(_) -> []
  }

  let fired =
    schedules
    |> list.filter(fn(s) { s.next_fire_at <= now_ts })
    |> list.filter_map(fn(s) { fire_schedule(state, s) })

  process.send(reply_to, fired)
  actor.continue(state)
}

fn handle_reload(
  state: EngineState,
  reply_to: process.Subject(Nil),
) -> actor.Next(EngineState, EngineMsg) {
  // Currently stateless (reads from DB each tick), but keeping
  // the message for future caching.
  process.send(reply_to, Nil)
  actor.continue(state)
}

// ═══════════════════════════════════════════════════════════════
// Schedule firing
// ═══════════════════════════════════════════════════════════════

/// Fire a due schedule: look up skill, compile, run, reschedule.
/// Returns Ok(skill_name) on success, Error(Nil) on failure.
fn fire_schedule(
  state: EngineState,
  schedule: db.Schedule,
) -> Result(String, Nil) {
  // Look up the skill to get its source and name
  let skill_maybe = case db.get_skill(state.conn, schedule.skill_id) {
    Ok(option.Some(s)) -> Ok(s)
    Ok(option.None) | Error(_) -> Error(Nil)
  }

  let result =
    result.try(skill_maybe, fn(skill: db.Skill) {
      // Compile the skill
      let load_result = loader.load(skill.chute_source, "cron/" <> skill.name)
      case load_result {
        Error(msg) -> {
          logging.log(
            logging.Error,
            "cron_engine: failed to compile skill '"
              <> skill.name
              <> "': "
              <> msg,
          )
          Error(Nil)
        }
        Ok(loaded) -> {
          // Run with minimal handlers
          let handlers =
            dict.from_list([
              #("emit_event", fn(_name, _args) { Ok(value.NilVal) }),
            ])
          let emit = fn(_event: events.HostEvent) { Nil }
          let run_id = gluid.guidv4() |> string.lowercase()
          let config =
            runner.RunConfig(
              program: loaded.program,
              env: value.NilVal,
              gas: 1000,
              handlers: handlers,
              emit: emit,
              actor_path: loaded.actor_path,
              actor_hash: loaded.actor_hash,
              run_id: run_id,
              trigger_type: "cron",
              trigger_source: "schedule:" <> schedule.id,
              depth: 0,
            )
          let _run_result = runner.run(config)
          // Whether it succeeds or fails, we still reschedule
          Ok(skill.name)
        }
      }
    })

  // Reschedule regardless of run success
  let reschedule_result = reschedule(state, schedule)
  case reschedule_result {
    Ok(_) -> Nil
    Error(_) ->
      logging.log(
        logging.Warning,
        "cron_engine: failed to reschedule '" <> schedule.id <> "'",
      )
  }

  result
}

/// Reschedule a schedule: compute the next fire time and update DB.
fn reschedule(state: EngineState, schedule: db.Schedule) -> Result(Nil, Nil) {
  case parse_and_validate(schedule.cron_expr) {
    Ok(spec) -> {
      let now = birl.utc_now()
      let vdt = birl_to_valid_datetime(now)
      let next_fire = case cron.next_after(spec, after: vdt) {
        option.Some(next_vdt) -> {
          let dt = schedule_ast.valid_datetime_value(next_vdt)
          datetime_to_unix(dt)
        }
        option.None -> birl.to_unix(now) + 3600
      }
      let now_ts = birl.to_unix(now)
      db.update_schedule_fire(
        state.conn,
        schedule.id,
        last_fired_at: option.Some(now_ts),
        next_fire_at: next_fire,
      )
    }
    Error(_) -> Error(Nil)
  }
}

// ═══════════════════════════════════════════════════════════════
// Time conversion helpers
// ═══════════════════════════════════════════════════════════════

/// Convert a birl Time to automata ValidDateTime.
fn birl_to_valid_datetime(t: birl.Time) -> schedule_ast.ValidDateTime {
  let birl.Day(year: y, month: m, date: d) = birl.get_day(t)
  let birl.TimeOfDay(hour: h, minute: min, second: s, ..) =
    birl.get_time_of_day(t)
  let assert Ok(vdt) =
    schedule_ast.try_valid_datetime(
      year: y,
      month: m,
      day: d,
      hour: h,
      minute: min,
      second: s,
    )
  vdt
}

/// Convert an automata DateTime to a unix timestamp.
fn datetime_to_unix(dt: schedule_ast.DateTime) -> Int {
  let schedule_ast.DateTime(
    date: schedule_ast.Date(year: y, month: m, day: d),
    time: schedule_ast.Time(hour: h, minute: min, second: s),
  ) = dt
  // birl.from_naive expects time without Z suffix
  let birl_str =
    pad2(y)
    <> "-"
    <> pad2(m)
    <> "-"
    <> pad2(d)
    <> "T"
    <> pad2(h)
    <> ":"
    <> pad2(min)
    <> ":"
    <> pad2(s)
  case birl.from_naive(birl_str) {
    Ok(t) -> birl.to_unix(t)
    Error(_) -> 0
  }
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}
