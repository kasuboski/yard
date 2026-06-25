import ballast/value.{ErrorVal, ListVal, NilVal, OkVal, RecordVal, StringVal}
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import hermes_agent/effects
import pig/workspace/schema
import sqlight
import testing
import yard/pg_cron
import yard/skill_repo
import gabsurd/client
import gabsurd/queue


pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_workspace(test_fn: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = schema.init(conn)
  test_fn(conn)
}

fn with_both_dbs(
  test_fn: fn(sqlight.Connection, client.Db) -> a,
) -> a {
  let assert Ok(workspace_conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = schema.init(workspace_conn)
  testing.with_clean_db(fn(global_conn) {
    test_fn(workspace_conn, global_conn)
  })
}

// ═══════════════════════════════════════════════════════════════
// emit_event handler
// ═══════════════════════════════════════════════════════════════

pub fn emit_event_handler_returns_nil_test() {
  let collector = effects.new_event_collector()
  let handler = effects.emit_event_handler(collector)
  let result =
    handler("emit_event", [StringVal("planning"), StringVal("reading files")])
  let assert Ok(NilVal) = result
  effects.collector_stop(collector)
}

pub fn emit_event_handler_records_event_test() {
  let collector = effects.new_event_collector()
  let handler = effects.emit_event_handler(collector)
  let _ =
    handler("emit_event", [StringVal("planning"), StringVal("reading files")])
  let _ =
    handler("emit_event", [StringVal("analysis"), StringVal("found 3 issues")])
  let events = effects.collector_events(collector)
  let assert 2 = list.length(events)
  let assert [#("planning", "reading files"), #("analysis", "found 3 issues")] =
    events
  effects.collector_stop(collector)
}

pub fn emit_event_handler_rejects_bad_args_test() {
  let collector = effects.new_event_collector()
  let handler = effects.emit_event_handler(collector)
  let result = handler("emit_event", [StringVal("only_one_arg")])
  // Should return an error value so the LLM knows args were wrong
  let assert Ok(ErrorVal(StringVal(msg))) = result
  let assert True = string.contains(msg, "expected 2 string args")
  // No event recorded
  let assert [] = effects.collector_events(collector)
  effects.collector_stop(collector)
}

// ═══════════════════════════════════════════════════════════════
// Workspace effect handlers
// ═══════════════════════════════════════════════════════════════

pub fn write_file_handler_test() {
  with_workspace(fn(conn) {
    let handler = effects.write_file_handler(conn)
    let result =
      handler("write_file", [StringVal("notes.txt"), StringVal("hello")])
    let assert Ok(OkVal(NilVal)) = result
  })
}

pub fn read_file_handler_test() {
  with_workspace(fn(conn) {
    let wh = effects.write_file_handler(conn)
    let rh = effects.read_file_handler(conn)
    let _ = wh("write_file", [StringVal("notes.txt"), StringVal("hello")])
    let result = rh("read_file", [StringVal("notes.txt")])
    let assert Ok(OkVal(StringVal("hello"))) = result
  })
}

pub fn read_file_handler_missing_test() {
  with_workspace(fn(conn) {
    let handler = effects.read_file_handler(conn)
    let result = handler("read_file", [StringVal("nonexistent.txt")])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True = string.contains(msg, "not found")
  })
}

pub fn list_files_handler_test() {
  with_workspace(fn(conn) {
    let wh = effects.write_file_handler(conn)
    let lh = effects.list_files_handler(conn)
    let _ = wh("write_file", [StringVal("a.txt"), StringVal("aaa")])
    let _ = wh("write_file", [StringVal("b.txt"), StringVal("bbb")])
    let result = lh("list_files", [StringVal("/")])
    let assert Ok(OkVal(ListVal(files))) = result
    let assert True = list.length(files) >= 2
  })
}

pub fn store_handler_test() {
  with_workspace(fn(conn) {
    let handler = effects.store_handler(conn)
    let result = handler("store", [StringVal("key"), StringVal("val")])
    let assert Ok(OkVal(NilVal)) = result
  })
}

pub fn recall_handler_test() {
  with_workspace(fn(conn) {
    let sh = effects.store_handler(conn)
    let rh = effects.recall_handler(conn)
    let _ = sh("store", [StringVal("key"), StringVal("val")])
    let result = rh("recall", [StringVal("key")])
    let assert Ok(OkVal(StringVal("val"))) = result
  })
}

pub fn recall_handler_missing_test() {
  with_workspace(fn(conn) {
    let handler = effects.recall_handler(conn)
    let result = handler("recall", [StringVal("missing_key")])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True =
      string.contains(msg, "not found") || string.contains(msg, "Not found")
  })
}

pub fn all_handlers_has_six_keys_test() {
  with_workspace(fn(conn) {
    let collector = effects.new_event_collector()
    let handlers = effects.all_handlers(conn, collector)
    let keys = dict.keys(handlers)
    let assert 6 = list.length(keys)
    let assert True = list.contains(keys, "emit_event")
    let assert True = list.contains(keys, "read_file")
    let assert True = list.contains(keys, "write_file")
    let assert True = list.contains(keys, "list_files")
    let assert True = list.contains(keys, "recall")
    let assert True = list.contains(keys, "store")
    effects.collector_stop(collector)
  })
}

// ═══════════════════════════════════════════════════════════════
// Collector lifecycle
// ═══════════════════════════════════════════════════════════════

pub fn collector_gas_used_defaults_to_zero_test() {
  let collector = effects.new_event_collector()
  let assert 0 = effects.collector_gas_used(collector)
  effects.collector_stop(collector)
}

pub fn collector_gas_used_can_be_set_test() {
  let collector = effects.new_event_collector()
  effects.collector_set_gas(collector, 42)
  let assert 42 = effects.collector_gas_used(collector)
  effects.collector_stop(collector)
}

pub fn write_file_handler_invalid_args_test() {
  with_workspace(fn(conn) {
    let handler = effects.write_file_handler(conn)
    let result = handler("write_file", [StringVal("only_path")])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True = string.contains(msg, "invalid args")
  })
}

pub fn read_file_handler_invalid_args_test() {
  with_workspace(fn(conn) {
    let handler = effects.read_file_handler(conn)
    let result = handler("read_file", [])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True = string.contains(msg, "invalid args")
  })
}

pub fn store_handler_invalid_args_test() {
  with_workspace(fn(conn) {
    let handler = effects.store_handler(conn)
    let result = handler("store", [StringVal("only_key")])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True = string.contains(msg, "invalid args")
  })
}

// ═══════════════════════════════════════════════════════════════
// Skill effect handlers (global DB)
// ═══════════════════════════════════════════════════════════════

pub fn register_skill_handler_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let handler = effects.register_skill_handler(global_conn)
    let result =
      handler("register_skill", [
        StringVal("my_skill"),
        StringVal("desc"),
        StringVal("source"),
      ])
    let assert Ok(OkVal(StringVal(id))) = result
    let assert True = string.length(id) > 0
  })
}

pub fn get_skill_handler_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let reg = effects.register_skill_handler(global_conn)
    let get = effects.get_skill_handler(global_conn)
    let _ =
      reg("register_skill", [
        StringVal("my_skill"),
        StringVal("a skill"),
        StringVal("pub fn main() { 1 }"),
      ])
    let result = get("get_skill", [StringVal("my_skill")])
    let assert Ok(OkVal(RecordVal(fields))) = result
    let assert True = list.contains(fields, #("name", StringVal("my_skill")))
  })
}

pub fn list_skills_handler_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let reg = effects.register_skill_handler(global_conn)
    let ls = effects.list_skills_handler(global_conn)
    let _ =
      reg("register_skill", [
        StringVal("skill_a"),
        StringVal("a"),
        StringVal("sa"),
      ])
    let _ =
      reg("register_skill", [
        StringVal("skill_b"),
        StringVal("b"),
        StringVal("sb"),
      ])
    let result = ls("list_skills", [])
    let assert Ok(OkVal(ListVal(items))) = result
    let assert 2 = list.length(items)
  })
}

pub fn register_skill_bad_args_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let handler = effects.register_skill_handler(global_conn)
    let result = handler("register_skill", [StringVal("only_one")])
    let assert Ok(ErrorVal(StringVal(msg))) = result
    let assert True = string.contains(msg, "expected 3 string args")
  })
}

pub fn all_handlers_with_global_has_nine_keys_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    let collector = effects.new_event_collector()
    let handlers =
      effects.all_handlers_with_global(workspace_conn, global_conn, collector)
    let keys = dict.keys(handlers)
    // 6 base + 3 skills + 2 agents + tell_user + learn = 13
    let assert 13 = list.length(keys)
    let assert True = list.contains(keys, "register_skill")
    let assert True = list.contains(keys, "get_skill")
    let assert True = list.contains(keys, "list_skills")
    effects.collector_stop(collector)
  })
}

// ═══════════════════════════════════════════════════════════════
// Agent handlers (global DB)
// ═══════════════════════════════════════════════════════════════

pub fn list_agents_handler_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let handler = effects.list_agents_handler(global_conn)
    // Initially empty
    let result = handler("list_agents", [])
    let assert Ok(OkVal(ListVal(items))) = result
    let assert 0 = list.length(items)
  })
}

pub fn register_agent_handler_test() {
  with_both_dbs(fn(_workspace_conn, global_conn) {
    let reg = effects.register_agent_handler(global_conn)
    let ls = effects.list_agents_handler(global_conn)
    let result =
      reg("register_agent", [
        StringVal("my_agent"),
        StringVal("an agent"),
        StringVal("pub fn main() { 1 }"),
      ])
    let assert Ok(OkVal(StringVal(id))) = result
    let assert True = string.length(id) > 0
    // Verify it shows up in list
    let list_result = ls("list_agents", [])
    let assert Ok(OkVal(ListVal(items))) = list_result
    let assert 1 = list.length(items)
  })
}

// ═══════════════════════════════════════════════════════════════
// Conversation handlers
// ═══════════════════════════════════════════════════════════════

pub fn tell_user_handler_test() {
  with_workspace(fn(_conn) {
    let collector = effects.new_event_collector()
    let handler = effects.tell_user_handler(collector)
    let result = handler("tell_user", [StringVal("Working on it...")])
    let assert Ok(NilVal) = result
    let events = effects.collector_events(collector)
    let assert [#("tell_user", "Working on it...")] = events
    effects.collector_stop(collector)
  })
}

pub fn learn_handler_test() {
  with_workspace(fn(conn) {
    let handler = effects.learn_handler(conn)
    let result =
      handler("learn", [StringVal("preference"), StringVal("dark mode")])
    let assert Ok(OkVal(NilVal)) = result
    // Verify we can recall with the prefixed key
    let recall_handler = effects.recall_handler(conn)
    let recall_result =
      recall_handler("recall", [StringVal("hermes_learned:preference")])
    let assert Ok(OkVal(StringVal("dark mode"))) = recall_result
  })
}

pub fn all_handlers_with_global_has_13_keys_test() {
  with_both_dbs(fn(workspace_conn, global_conn) {
    let collector = effects.new_event_collector()
    let handlers =
      effects.all_handlers_with_global(workspace_conn, global_conn, collector)
    let keys = dict.keys(handlers)
    let assert 13 = list.length(keys)
    let assert True = list.contains(keys, "tell_user")
    let assert True = list.contains(keys, "learn")
    let assert True = list.contains(keys, "list_agents")
    let assert True = list.contains(keys, "register_agent")
    effects.collector_stop(collector)
  })
}

// ═══════════════════════════════════════════════════════════════
// Cron handlers (pg_cron)
// ═══════════════════════════════════════════════════════════════

fn with_pg_db(test_fn: fn(client.Db, String) -> a) -> a {
  let queue_name = "hermes_test_" <> int.to_string(client.unique_integer())
  case testing.try_db() {
    Ok(db) -> {
      let assert Ok(Nil) = queue.create(db, queue_name)
      let result = test_fn(db, queue_name)
      let _ = queue.drop(db, queue_name)
      let _ = pg_cron.unschedule_all(db)
      result
    }
    Error(_) -> {
      // No Postgres available — skip gracefully
      // In a real test setup, we'd use should.skip() but gleeunit doesn't have it
      panic as "PostgreSQL not available for cron tests (expected if gabsurd not running)"
    }
  }
}

pub fn schedule_cron_handler_test() {
  // This test requires PostgreSQL with gabsurd extension
  // Skip if gabsurd is not available (expected in dev environment)
  case testing.try_db() {
    Ok(_) -> {
      with_both_dbs(fn(_workspace_conn, global_conn) {
        with_pg_db(fn(pg_db, queue_name) {
          let handler = effects.schedule_cron_handler(pg_db, queue_name, global_conn)

          // First register a skill so we can schedule it
          let _ =
            skill_repo.register(
              global_conn,
              "cron-skill",
              "A skill",
              "pub fn main(env: {}) -> Int { 42 }",
              [],
            )

          let result =
            handler("schedule_cron", [StringVal("0 * * * *"), StringVal("cron-skill")])
          let assert Ok(OkVal(StringVal(job_name))) = result
          let assert True = string.length(job_name) > 0
          let assert True = string.starts_with(job_name, "hermes_")

          // Verify it shows up in list
          let ls = effects.list_crons_handler(pg_db)
          let list_result = ls("list_crons", [])
          let assert Ok(OkVal(ListVal(items))) = list_result
          let assert 1 = list.length(items)
        })
      })
      Nil
    }
    Error(_) -> Nil // Skip gracefully if gabsurd not available
  }
}

pub fn schedule_cron_bad_args_test() {
  // This test requires PostgreSQL with gabsurd extension
  case testing.try_db() {
    Ok(_) -> {
      with_both_dbs(fn(_workspace_conn, global_conn) {
        with_pg_db(fn(pg_db, queue_name) {
          let handler = effects.schedule_cron_handler(pg_db, queue_name, global_conn)

          let result = handler("schedule_cron", [StringVal("only one")])
          let assert Ok(ErrorVal(StringVal(msg))) = result
          let assert True = string.contains(msg, "expected 2")
        })
      })
      Nil
    }
    Error(_) -> Nil // Skip gracefully
  }
}

pub fn list_crons_handler_empty_test() {
  // This test requires PostgreSQL with gabsurd extension
  case testing.try_db() {
    Ok(_) -> {
      with_pg_db(fn(pg_db, _queue_name) {
        let handler = effects.list_crons_handler(pg_db)

        let result = handler("list_crons", [])
        let assert Ok(OkVal(ListVal(items))) = result
        let assert 0 = list.length(items)
      })
      Nil
    }
    Error(_) -> Nil // Skip gracefully
  }
}

pub fn cancel_cron_handler_test() {
  // This test requires PostgreSQL with gabsurd extension
  case testing.try_db() {
    Ok(_) -> {
      with_both_dbs(fn(_workspace_conn, global_conn) {
        with_pg_db(fn(pg_db, queue_name) {
          let schedule_handler = effects.schedule_cron_handler(pg_db, queue_name, global_conn)
          let cancel_handler = effects.cancel_cron_handler(pg_db)
          let list_handler = effects.list_crons_handler(pg_db)

          // Register a skill and schedule it
          let _ =
            skill_repo.register(
              global_conn,
              "cancel-skill",
              "A skill",
              "pub fn main(env: {}) -> Int { 42 }",
              [],
            )
          let assert Ok(OkVal(StringVal(job_name))) =
            schedule_handler("schedule_cron", [
              StringVal("0 * * * *"),
              StringVal("cancel-skill"),
            ])

          // Cancel it
          let cancel_result = cancel_handler("cancel_cron", [StringVal(job_name)])
          let assert Ok(OkVal(NilVal)) = cancel_result

          // Verify it's gone from list
          let list_result = list_handler("list_crons", [])
          let assert Ok(OkVal(ListVal(items))) = list_result
          let assert 0 = list.length(items)
        })
      })
      Nil
    }
    Error(_) -> Nil // Skip gracefully
  }
}

pub fn all_handlers_with_cron_has_16_keys_test() {
  // This test requires PostgreSQL with gabsurd extension
  case testing.try_db() {
    Ok(_) -> {
      with_both_dbs(fn(workspace_conn, global_conn) {
        with_pg_db(fn(pg_db, queue_name) {
          let collector = effects.new_event_collector()
          let handlers =
            effects.all_handlers_with_cron(
              workspace_conn,
              global_conn,
              collector,
              pg_db,
              queue_name,
            )
          let keys = dict.keys(handlers)
          // 13 base + schedule_cron + list_crons + cancel_cron = 16
          let assert 16 = list.length(keys)
          let assert True = list.contains(keys, "schedule_cron")
          let assert True = list.contains(keys, "list_crons")
          let assert True = list.contains(keys, "cancel_cron")
          effects.collector_stop(collector)
        })
      })
      Nil
    }
    Error(_) -> Nil // Skip gracefully
  }
}
