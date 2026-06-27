//// Shared test helpers for PostgreSQL-backed tests.
////
//// Each test gets its own connection pool, runs against a TRUNCATEd set of
//// tables, then closes the pool. This keeps Postgres clean between runs.
////
//// For async gabsurd tests (durable tasks, checkpointers) use with_pg_db
//// which does NOT close the pool — those tests spawn background workers
//// that outlive the test function.

import gabsurd/client.{type Db}
import gleam/erlang/process

const db_url = "postgresql://gabsurd:gabsurd@127.0.0.1:5432/gabsurd"

/// Run a test with a clean DB. Creates a pool, TRUNCATEs registry tables,
/// runs the test, then closes the pool to free connections.
/// Use this for simple CRUD tests (db_test, chat_test, skill_repo_test, etc.)
pub fn with_clean_db(test_fn: fn(Db) -> a) -> a {
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  clean_registry(db)
  let result = test_fn(db)
  process.send_exit(started.pid)
  result
}

/// Run a test with a Postgres pool. Does NOT close the pool after — for
/// async tests (gabsurd tasks, durable handlers) where background workers
/// may outlive the test function.
pub fn with_pg_db(test_fn: fn(Db) -> a) -> a {
  let assert Ok(started) = client.start(db_url)
  let db = started.data
  test_fn(db)
}

/// Truncate all registry tables so tests start from a clean state.
pub fn clean_registry(db: Db) -> Nil {
  let _ =
    client.exec(
      db,
      #(
        "TRUNCATE TABLE agent_handlers, agents, skills, deployments, runs, chat_messages, chat_sessions, providers RESTART IDENTITY CASCADE",
        [],
      ),
    )
  Nil
}

/// Truncate durable tables (conversations, yard_events).
pub fn clean_durable(db: Db) -> Nil {
  let _ =
    client.exec(
      db,
      #(
        "TRUNCATE TABLE yard_events, conversations RESTART IDENTITY CASCADE",
        [],
      ),
    )
  Nil
}
