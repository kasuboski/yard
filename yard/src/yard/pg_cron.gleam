//// pg_cron scheduler — PostgreSQL-native scheduling that replaces the
//// OTP cron engine.
////
//// From DURABLE.md Component 5: pg_cron.schedule() creates entries in
//// cron.job that fire gabsurd spawn_task directly. Schedules survive
//// BEAM node restarts because they live in PostgreSQL.
////
//// The cron extension is created by the absurd schema. This module
//// provides the yard-specific scheduling layer on top.

import gleam/dynamic/decode
import gleam/json
import gabsurd/client.{type Db, type GabsurdError}
import parrot/dev

/// A cron job entry from cron.job.
pub type CronJob {
  CronJob(
    job_id: Int,
    schedule: String,
    command: String,
    job_name: String,
  )
}

/// Error from pg_cron operations.
pub type CronError {
  CronError(String)
}

/// Schedule a recurring task via pg_cron.
///
/// Creates a `cron.schedule` entry that fires `absurd.spawn_task`
/// into the specified queue. The schedule is a standard cron expression.
///
/// Parameters:
/// - `db`: Database connection
/// - `job_name`: Unique name for this schedule (used for unschedule)
/// - `schedule`: Cron expression (e.g. "0 9 * * *" for daily at 9am)
/// - `queue_name`: gabsurd queue to spawn tasks into
/// - `task_name`: gabsurd task name for the handler
/// - `params`: JSON params passed to the spawned task
pub fn schedule(
  db db: Db,
  job_name job_name: String,
  schedule schedule: String,
  queue_name queue_name: String,
  task_name task_name: String,
  params params: json.Json,
) -> Result(Nil, CronError) {
  // Build the SQL command that cron will execute.
  // It calls absurd.spawn_task to create a new task in the queue.
  let params_str = json.to_string(params)
  let command = build_spawn_command(queue_name, task_name, params_str)

  // Use cron.schedule with a job name for easy management.
  let sql =
    "SELECT cron.schedule($1, $2, $3)::text"
  case
    client.exec(db, #(
      sql,
      [
        dev.ParamString(job_name),
        dev.ParamString(schedule),
        dev.ParamString(command),
      ],
    ))
  {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(CronError(error_to_string(e)))
  }
}

/// Remove a scheduled job by name.
pub fn unschedule(
  db db: Db,
  job_name job_name: String,
) -> Result(Nil, CronError) {
  let sql =
    "SELECT cron.unschedule($1)::text"
  case client.exec(db, #(sql, [dev.ParamString(job_name)])) {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(CronError(error_to_string(e)))
  }
}

/// List all scheduled cron jobs.
pub fn list_jobs(db db: Db) -> Result(List(CronJob), CronError) {
  let sql =
    "SELECT jobid, schedule, command, jobname FROM cron.job ORDER BY jobid"
  case client.query_many(db, #(sql, [], cron_job_decoder())) {
    Ok(jobs) -> Ok(jobs)
    Error(e) -> Error(CronError(error_to_string(e)))
  }
}

/// Unschedule all jobs. Used for test cleanup.
pub fn unschedule_all(db db: Db) -> Result(Nil, CronError) {
  let sql = "SELECT cron.unschedule(jobname) FROM cron.job"
  case client.exec(db, #(sql, [])) {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(CronError(error_to_string(e)))
  }
}

// ── Internal helpers ─────────────────────────────────────────────────

fn cron_job_decoder() -> decode.Decoder(CronJob) {
  use job_id <- decode.field(0, decode.int)
  use schedule <- decode.field(1, decode.string)
  use command <- decode.field(2, decode.string)
  use job_name <- decode.field(3, decode.string)
  decode.success(CronJob(
    job_id:,
    schedule:,
    command:,
    job_name:,
  ))
}

fn build_spawn_command(
  queue_name: String,
  task_name: String,
  params_str: String,
) -> String {
  // The cron command runs inside PostgreSQL. It calls absurd's spawn_task
  // function to create a new task in the queue.
  //
  // The params are passed as a JSON literal cast to jsonb.
  "SELECT absurd.spawn_task('"
  <> queue_name
  <> "', '"
  <> task_name
  <> "', '"
  <> params_str
  <> "'::jsonb)"
}

fn error_to_string(e: GabsurdError) -> String {
  case e {
    client.QueryError(msg) -> "cron query: " <> msg
    client.UnexpectedRowCount(msg) -> "cron row count: " <> msg
    client.NotFound -> "cron: not found"
    client.ConnectionError(msg) -> "cron connection: " <> msg
  }
}
