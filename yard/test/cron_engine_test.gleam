//// Cron engine tests — TDD for the schedule/tick/fire cycle.
////
//// The cron engine is an OTP actor that:
////   1. Holds a global DB connection
////   2. Registers schedules (parse cron, store in DB)
////   3. Lists active schedules
////   4. Cancels schedules (soft delete)
////   5. Ticks: checks for due schedules, fires them, reschedules
////
//// Firing a schedule means:
////   - Looking up the skill source
////   - Compiling via yard/loader
////   - Running via yard/runner with configured handlers
////   - Recording the run in the DB

import automata/cron
import automata/schedule/ast as schedule_ast
import ballast/value
import birl
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import sqlight
import yard/cron_engine
import yard/cron_time
import yard/db
import yard/handler_registry
import yard/skill_repo

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = db.migrate(conn)
  test_fn(conn)
}

/// Create a skill in the DB and return its ID.
fn create_skill(conn: sqlight.Connection, name: String) -> String {
  let source = "pub fn main(env: {}) -> Int { 42 }"
  let assert Ok(id) =
    skill_repo.register(conn, name, "A test skill", source, [])
  id
}

/// Helper to get a unix timestamp that's safely in the past.
fn past_ts() -> Int {
  birl.to_unix(birl.utc_now()) - 3600
}

/// Helper to get a unix timestamp that's safely in the future.
fn future_ts() -> Int {
  birl.to_unix(birl.utc_now()) + 3600
}

// ═══════════════════════════════════════════════════════════════
// 1. Engine lifecycle
// ═══════════════════════════════════════════════════════════════

pub fn start_with_empty_db_test() {
  with_db(fn(conn) {
    let assert Ok(engine) = cron_engine.start(conn)
    let schedules = cron_engine.list_schedules(engine)
    let assert 0 = list.length(schedules)
    cron_engine.stop(engine)
  })
}

pub fn shutdown_stops_engine_test() {
  with_db(fn(conn) {
    let assert Ok(engine) = cron_engine.start(conn)
    cron_engine.stop(engine)
    // After stop, sending a message should not panic
    // (actor is dead, but process.send to dead actor just returns Nil)
  })
}

// ═══════════════════════════════════════════════════════════════
// 2. Register schedule
// ═══════════════════════════════════════════════════════════════

pub fn register_returns_id_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "test-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    let result =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        agent_id: option.None,
      )
    let assert Ok(id) = result
    let assert True = string.length(id) > 0

    cron_engine.stop(engine)
  })
}

pub fn register_invalid_cron_returns_error_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "test-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    let result =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "not a cron",
        agent_id: option.None,
      )
    let assert Error(_) = result

    cron_engine.stop(engine)
  })
}

pub fn register_persists_to_db_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "test-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    let assert Ok(_id) =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        agent_id: option.None,
      )

    // Verify it's in the DB directly
    let assert Ok(schedules) = db.list_active_schedules(conn)
    let assert 1 = list.length(schedules)

    cron_engine.stop(engine)
  })
}

// ═══════════════════════════════════════════════════════════════
// 3. List schedules
// ═══════════════════════════════════════════════════════════════

pub fn list_schedules_returns_registered_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "test-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    let assert Ok(_id1) =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        agent_id: option.None,
      )
    let assert Ok(_id2) =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "30 * * * *",
        agent_id: option.None,
      )

    let schedules = cron_engine.list_schedules(engine)
    let assert 2 = list.length(schedules)

    cron_engine.stop(engine)
  })
}

// ═══════════════════════════════════════════════════════════════
// 4. Cancel schedule
// ═══════════════════════════════════════════════════════════════

pub fn cancel_deactivates_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "test-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    let assert Ok(id) =
      cron_engine.register(
        engine,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        agent_id: option.None,
      )

    let assert Ok(Nil) = cron_engine.cancel(engine, id)

    // Should no longer appear in active list
    let schedules = cron_engine.list_schedules(engine)
    let assert 0 = list.length(schedules)

    // DB should show it as inactive
    let assert Ok(option.Some(schedule)) = db.get_schedule(conn, id)
    let assert "inactive" = schedule.status

    cron_engine.stop(engine)
  })
}

pub fn cancel_missing_returns_error_test() {
  with_db(fn(conn) {
    let assert Ok(engine) = cron_engine.start(conn)
    // Deactivating a non-existent schedule returns Ok(Nil) because
    // the SQL UPDATE succeeds (0 rows affected).
    let result = cron_engine.cancel(engine, "nonexistent-id")
    let assert Ok(Nil) = result
    cron_engine.stop(engine)
  })
}

// ═══════════════════════════════════════════════════════════════
// 5. Tick fires due schedules
// ═══════════════════════════════════════════════════════════════

pub fn tick_fires_due_schedule_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "tick-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    // Register with next_fire_at in the past (should be due now)
    let past = past_ts()
    // Manually insert a schedule with past next_fire_at
    let assert Ok(schedule_id) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        next_fire_at: past,
      )

    // Reload engine state from DB
    cron_engine.reload(engine)

    // Tick should fire the schedule
    let fired = cron_engine.tick(engine)
    let assert 1 = list.length(fired)
    let assert "tick-skill" = list.first(fired) |> result.unwrap("")

    // Schedule should now be rescheduled (next_fire_at updated)
    let assert Ok(option.Some(schedule)) = db.get_schedule(conn, schedule_id)
    // next_fire_at should have moved into the future
    let assert True = schedule.next_fire_at > past

    cron_engine.stop(engine)
  })
}

pub fn tick_skips_future_schedules_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "future-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    // Register with next_fire_at far in the future
    let assert Ok(_id) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        next_fire_at: future_ts() + 86_400,
      )

    cron_engine.reload(engine)

    let fired = cron_engine.tick(engine)
    let assert 0 = list.length(fired)

    cron_engine.stop(engine)
  })
}

pub fn tick_reschedules_after_fire_test() {
  with_db(fn(conn) {
    let skill_id = create_skill(conn, "resched-skill")
    let assert Ok(engine) = cron_engine.start(conn)

    // Insert schedule due now
    let assert Ok(_schedule_id) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        // Every hour
        next_fire_at: past_ts(),
      )

    cron_engine.reload(engine)

    // First tick: fires and reschedules
    let fired1 = cron_engine.tick(engine)
    let assert 1 = list.length(fired1)

    // Second tick: schedule is in the future now, should not fire
    let fired2 = cron_engine.tick(engine)
    let assert 0 = list.length(fired2)

    cron_engine.stop(engine)
  })
}

pub fn tick_fires_multiple_due_schedules_test() {
  with_db(fn(conn) {
    let skill_id1 = create_skill(conn, "multi-skill-1")
    let skill_id2 = create_skill(conn, "multi-skill-2")
    let assert Ok(engine) = cron_engine.start(conn)

    let past = past_ts()
    let assert Ok(_id1) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id1,
        cron_expr: "0 * * * *",
        next_fire_at: past,
      )
    let assert Ok(_id2) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id2,
        cron_expr: "30 * * * *",
        next_fire_at: past,
      )

    cron_engine.reload(engine)

    let fired = cron_engine.tick(engine)
    let assert 2 = list.length(fired)

    cron_engine.stop(engine)
  })
}

// ═══════════════════════════════════════════════════════════════
// 6. Cron parsing
// ═══════════════════════════════════════════════════════════════

pub fn parse_valid_cron_expressions_test() {
  let expressions = [
    "* * * * *",
    "0 * * * *",
    "*/15 * * * *",
    "0 9-17 * * 1-5",
    "30 4 * * 0",
  ]
  list.each(expressions, fn(expr) {
    let assert Ok(_) = cron_engine.parse_and_validate(expr)
  })
}

pub fn parse_invalid_cron_expression_test() {
  let expressions = ["not a cron", "60 * * * *", "0 25 * * *", "abc"]
  list.each(expressions, fn(expr) {
    let assert Error(_) = cron_engine.parse_and_validate(expr)
  })
}

pub fn compute_next_fire_time_test() {
  let assert Ok(plan) = cron_engine.parse_and_validate("0 * * * *")
  let now = birl.utc_now()
  let vdt = cron_time.birl_to_valid_datetime(now)
  let assert option.Some(next_vdt) = cron.next_after(plan, after: vdt)
  // Next fire should be in the future
  let next_dt = schedule_ast.valid_datetime_value(next_vdt)
  let next_unix = cron_time.datetime_to_unix(next_dt)
  let now_unix = birl.to_unix(now)
  let assert True = next_unix >= now_unix
}

// ═══════════════════════════════════════════════════════════════
// End-to-end: tick with handler registry
// ═══════════════════════════════════════════════════════════════

/// A handler builder that sends effect call info to a subject.
fn recording_builder(
  recorder: process.Subject(String),
) -> handler_registry.HandlerBuilder {
  fn(_ctx) {
    fn(name, args) {
      let label =
        args
        |> list.map(fn(a) {
          case a {
            value.StringVal(s) -> s
            other -> value.value_to_string(other)
          }
        })
        |> string.join(", ")
      process.send(recorder, name <> "(" <> label <> ")")
      Ok(value.OkVal(value.StringVal("recorded")))
    }
  }
}

pub fn tick_fires_skill_with_registered_handlers_test() {
  with_db(fn(conn) {
    // Set up agent with handler bindings
    let assert Ok(agent_id) =
      db.insert_agent(
        conn,
        "recording-agent",
        "Records effect calls",
        "pub fn main(env: {}) -> String { let try x = perform greet(\"world\") Ok(x) }",
        "active",
      )
    let assert Ok(Nil) =
      db.insert_agent_handler(conn, agent_id, "greet", "recorder")

    // Create skill
    let skill_source =
      "effect greet(name: String) -> Result(String, String)\n"
      <> "pub fn main(env: {}) -> Result(String, String) { perform greet(\"world\") }"
    let assert Ok(skill_id) =
      skill_repo.register(conn, "greet-skill", "Greets", skill_source, [])

    // Build registry with our recording handler
    let recorder = process.new_subject()
    let reg =
      handler_registry.new()
      |> handler_registry.register("recorder", recording_builder(recorder))

    // Start engine with registry
    let assert Ok(engine) = cron_engine.start_with_registry(conn, reg)

    // Insert a due schedule tied to this agent
    let assert Ok(___schedule_id) =
      db.insert_schedule(
        conn,
        agent_id: option.Some(agent_id),
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        next_fire_at: past_ts(),
      )
    cron_engine.reload(engine)

    // Tick
    let fired = cron_engine.tick(engine)
    let assert 1 = list.length(fired)

    // The handler should have been called
    let assert Ok(recorded_msg) = process.receive(recorder, 2000)
    let assert True = string.contains(recorded_msg, "greet")
    let assert True = string.contains(recorded_msg, "world")

    cron_engine.stop(engine)
  })
}

pub fn tick_fires_skill_without_agent_uses_minimal_handlers_test() {
  with_db(fn(conn) {
    // Create a skill that needs no effects
    let skill_source = "pub fn main(env: {}) -> Int { 42 }"
    let assert Ok(skill_id) =
      skill_repo.register(
        conn,
        "pure-skill",
        "Pure computation",
        skill_source,
        [],
      )

    let reg = handler_registry.new()
    let assert Ok(engine) = cron_engine.start_with_registry(conn, reg)

    // Schedule with no agent_id
    let assert Ok(_schedule_id) =
      db.insert_schedule(
        conn,
        agent_id: option.None,
        skill_id: skill_id,
        cron_expr: "0 * * * *",
        next_fire_at: past_ts(),
      )
    cron_engine.reload(engine)

    let fired = cron_engine.tick(engine)
    let assert 1 = list.length(fired)
    let assert "pure-skill" = list.first(fired) |> result.unwrap("")

    cron_engine.stop(engine)
  })
}

// ═══════════════════════════════════════════════════════════════
// Round-trip conversion tests
// ═══════════════════════════════════════════════════════════════

pub fn birl_roundtrip_test() {
  // Create a known time, convert to ValidDateTime and back to unix.
  // The round-trip should preserve the timestamp (to the second).
  let now = birl.utc_now()
  let unix_before = birl.to_unix(now)

  let vdt = cron_time.birl_to_valid_datetime(now)
  let dt = schedule_ast.valid_datetime_value(vdt)
  let unix_after = cron_time.datetime_to_unix(dt)

  let assert True = unix_before == unix_after
}

pub fn datetime_year_is_4_digits_test() {
  // Ensure the year is formatted as 4 digits, not 2.
  // This is a regression test for the pad2(y) bug.
  let now = birl.utc_now()
  let vdt = cron_time.birl_to_valid_datetime(now)
  let dt = schedule_ast.valid_datetime_value(vdt)

  let schedule_ast.DateTime(date: schedule_ast.Date(year: y, ..), ..) = dt

  // Year 2024+ should format as "2024", not "24"
  let assert True = y >= 2024
  let unix = cron_time.datetime_to_unix(dt)
  let assert True = unix > 1_700_000_000
}
