//// Run tracking tests — verify chute_exec records runs in global DB.

import ballast/value
import gabsurd/client
import gleam/list
import gleeunit
import hermes_agent/chute_exec
import pig/workspace/schema
import sqlight
import testing
import yard/db

pub fn main() {
  gleeunit.main()
}

fn with_both_dbs(test_fn: fn(sqlight.Connection, client.Db) -> a) -> a {
  let assert Ok(workspace_conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = schema.init(workspace_conn)
  testing.with_clean_db(fn(global_conn) { test_fn(workspace_conn, global_conn) })
}

pub fn successful_run_recorded_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    // Register an agent for tracking
    let assert Ok(agent_id) =
      db.insert_agent(global_conn, "test_agent", "test", "source", "active")
    let cfg =
      chute_exec.silent_config(workspace_conn)
      |> chute_exec.with_run_tracking(global_conn, agent_id)

    let result =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 42 }",
        value.RecordVal([]),
      )
    let assert Ok(_json) = result

    // Check run was recorded
    let assert Ok(runs) = db.get_actor_runs(global_conn, agent_id, 10)
    let assert 1 = list.length(runs)
    let assert Ok(run) = list.first(runs)
    let assert "completed" = run.status
    let assert "tool_call" = run.trigger_type
  })
}

pub fn failed_run_recorded_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    let assert Ok(agent_id) =
      db.insert_agent(global_conn, "test_agent", "test", "source", "active")
    let cfg =
      chute_exec.silent_config(workspace_conn)
      |> chute_exec.with_run_tracking(global_conn, agent_id)

    let result =
      chute_exec.run(
        cfg,
        "effect unknown(x: Int) -> Int\n\npub fn main(env: {}) -> Int { perform unknown(1) }",
        value.RecordVal([]),
      )
    let assert Ok(_json) = result

    let assert Ok(runs) = db.get_actor_runs(global_conn, agent_id, 10)
    let assert 1 = list.length(runs)
    let assert Ok(run) = list.first(runs)
    let assert "error" = run.status
  })
}

pub fn run_includes_duration_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    let assert Ok(agent_id) =
      db.insert_agent(global_conn, "test_agent", "test", "source", "active")
    let cfg =
      chute_exec.silent_config(workspace_conn)
      |> chute_exec.with_run_tracking(global_conn, agent_id)

    let _ =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 42 }",
        value.RecordVal([]),
      )

    let assert Ok(runs) = db.get_actor_runs(global_conn, agent_id, 10)
    let assert Ok(run) = list.first(runs)
    // Duration should be >= 0 (might be 0 for very fast programs)
    let assert True = run.duration_ms >= 0
  })
}

pub fn no_tracking_without_global_conn_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    // Use silent_config (no run tracking)
    let cfg = chute_exec.silent_config(workspace_conn)
    let _ =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 42 }",
        value.RecordVal([]),
      )

    // No runs recorded
    let assert Ok(runs) =
      db.get_actor_runs(global_conn, "hermes_chute_exec", 10)
    let assert 0 = list.length(runs)
  })
}

pub fn multiple_runs_tracked_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    let assert Ok(agent_id) =
      db.insert_agent(global_conn, "test_agent", "test", "source", "active")
    let cfg =
      chute_exec.silent_config(workspace_conn)
      |> chute_exec.with_run_tracking(global_conn, agent_id)

    let _ =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 1 }",
        value.RecordVal([]),
      )
    let _ =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 2 }",
        value.RecordVal([]),
      )
    let _ =
      chute_exec.run(
        cfg,
        "pub fn main(env: {}) -> Int { 3 }",
        value.RecordVal([]),
      )

    let assert Ok(runs) = db.get_actor_runs(global_conn, agent_id, 10)
    let assert 3 = list.length(runs)
  })
}
