//// pg_cron scheduler tests — replaces OTP cron_engine with PostgreSQL-native scheduling.
////
//// From DURABLE.md Component 5 + Phase 4.
//// pg_cron.schedule() creates entries in cron.job that fire gabsurd spawn_task
//// directly, surviving BEAM restarts.

import gleam/int
import gleam/json
import gleam/string
import gluid
import gleeunit
import gleeunit/should
import gabsurd/client
import gabsurd/queue
import yard/pg_cron
import testing


pub fn main() {
  gleeunit.main()
}

fn with_db(test_fn: fn(client.Db, String) -> a) -> a {
  let queue_name = "cron_test_" <> int.to_string(client.unique_integer())
  testing.with_pg_db(fn(db) {
    let assert Ok(Nil) = queue.create(db, queue_name)
    let result = test_fn(db, queue_name)
    let _ = queue.drop(db, queue_name)
    let _ = unschedule_all(db)
    result
  })
}

/// Clean up all test cron schedules
fn unschedule_all(db: client.Db) -> Nil {
  let _ = pg_cron.unschedule_all(db)
  Nil
}

fn unique_job_name() -> String {
  "yard_test_" <> string.lowercase(gluid.guidv4())
}

/// Schedule a recurring task — should create a cron.job entry.
pub fn schedule_creates_cron_job_test() {
  with_db(fn(db, queue_name) {
    let job_name = unique_job_name()
    let result = pg_cron.schedule(
      db,
      job_name:,
      schedule: "* * * * *",
      queue_name:,
      task_name: "test-cron-task",
      params: json.object([#("msg", json.string("hello"))]),
    )

    should.be_ok(result)

    // Verify the job exists in cron.job
    let assert Ok(jobs) = pg_cron.list_jobs(db)
    let has_job = list.any(jobs, fn(j) { j.job_name == job_name })
    should.equal(has_job, True)
  })
}

/// Unschedule removes the cron.job entry.
pub fn unschedule_removes_cron_job_test() {
  with_db(fn(db, queue_name) {
    let job_name = unique_job_name()
    let _ = pg_cron.schedule(
      db,
      job_name:,
      schedule: "*/5 * * * *",
      queue_name:,
      task_name: "test-cron-task",
      params: json.object([]),
    )

    let result = pg_cron.unschedule(db, job_name:)
    should.be_ok(result)

    // Verify the job is gone
    let assert Ok(jobs) = pg_cron.list_jobs(db)
    let has_job = list.any(jobs, fn(j) { j.job_name == job_name })
    should.equal(has_job, False)
  })
}

/// List jobs returns all scheduled cron jobs (at least the ones we created).
pub fn list_jobs_returns_schedules_test() {
  with_db(fn(db, queue_name) {
    let job1 = unique_job_name()
    let job2 = unique_job_name()

    let _ = pg_cron.schedule(
      db,
      job_name: job1,
      schedule: "0 9 * * *",
      queue_name:,
      task_name: "morning-task",
      params: json.object([]),
    )
    let _ = pg_cron.schedule(
      db,
      job_name: job2,
      schedule: "0 17 * * *",
      queue_name:,
      task_name: "evening-task",
      params: json.object([]),
    )

    let assert Ok(jobs) = pg_cron.list_jobs(db)
    let our_jobs = list.filter(jobs, fn(j) {
      j.job_name == job1 || j.job_name == job2
    })
    should.equal(list.length(our_jobs), 2)
  })
}

import gleam/list
