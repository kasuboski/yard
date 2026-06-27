//// Shared test helpers for hermes-agent PostgreSQL-backed tests.
////
//// Each test gets its own connection pool, runs against TRUNCATEd tables,
//// then closes the pool to free connections.

import gabsurd/client.{type Db}
import gleam/erlang/process

const db_url = "postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd"

/// Run a test with a clean DB. Creates a pool, TRUNCATEs registry tables,
/// runs the test, then closes the pool to free connections.
pub fn with_clean_db(test_fn: fn(Db) -> a) -> a {
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  clean_registry(db)
  let result = test_fn(db)
  process.send_exit(started.pid)
  result
}

/// Check if Postgres is reachable and return a pool if so.
/// Returns both the Db and Pid so callers can close the pool after use.
pub fn try_db() -> Result(#(Db, process.Pid), Nil) {
  case client.start(db_url) {
    Ok(started) -> {
      let db = started.data
      case client.exec(db, #("SELECT 1", [])) {
        Ok(_) -> Ok(#(db, started.pid))
        Error(_) -> {
          process.send_exit(started.pid)
          Error(Nil)
        }
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Truncate registry tables for a clean test state.
pub fn clean_registry(db: Db) -> Nil {
  // Core registry tables
  let _ =
    client.exec(
      db,
      #(
        "TRUNCATE TABLE agent_handlers, agents, skills, deployments, runs, chat_messages, chat_sessions, providers, conversations RESTART IDENTITY CASCADE",
        [],
      ),
    )
  // Yard events table (may not exist in all environments)
  let _ =
    client.exec(
      db,
      #("TRUNCATE TABLE yard_events RESTART IDENTITY CASCADE", []),
    )
  Nil
}
