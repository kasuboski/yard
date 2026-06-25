//// DB layer tests — PostgreSQL-backed registry CRUD.
////
//// Requires: docker container running with pg_schema.sql applied.
//// Run with: bin/postgres.sh && cd yard && gleam test

import birl
import gabsurd/client
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import testing
import yard/db

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_clean_db(test_fn)
}

fn now() -> Int {
  birl.to_unix(birl.utc_now())
}

// ═══════════════════════════════════════════════════════════════
// Skills
// ═══════════════════════════════════════════════════════════════

pub fn insert_skill_creates_record_test() {
  with_db(fn(db) {
    let assert Ok(id) =
      db.insert_skill(
        db,
        "health_check",
        "Checks system health",
        "pub fn main(env) { Ok(Nil) }",
        "[\"monitor\"]",
      )
    let assert Ok(found) = db.get_skill(db, id)
    let assert option.Some(skill) = found
    let assert "health_check" = skill.name
    let assert "Checks system health" = skill.description
    let assert "active" = skill.status
  })
}

pub fn get_skill_by_name_test() {
  with_db(fn(db) {
    let assert Ok(__id) =
      db.insert_skill(db, "my_skill", "desc", "pub fn main(env) { 1 }", "[]")
    let assert Ok(found) = db.get_skill_by_name(db, "my_skill")
    let assert option.Some(skill) = found
    let assert "my_skill" = skill.name
  })
}

pub fn get_skill_missing_returns_none_test() {
  with_db(fn(db) {
    let assert Ok(option.None) = db.get_skill(db, "nonexistent")
  })
}

pub fn list_skills_returns_active_only_test() {
  with_db(fn(db) {
    let assert Ok(__id1) =
      db.insert_skill(db, "skill_a", "desc a", "source a", "[]")
    let assert Ok(_id2) =
      db.insert_skill(db, "skill_b", "desc b", "source b", "[]")
    let assert Ok(id3) =
      db.insert_skill(db, "skill_c", "desc c", "source c", "[]")
    let assert Ok(Nil) = db.deactivate_skill(db, id3)
    let assert Ok(skills) = db.list_skills(db)
    let assert 2 = list.length(skills)
    let names = list.map(skills, fn(s) { s.name })
    let assert True = list.contains(names, "skill_a")
    let assert True = list.contains(names, "skill_b")
  })
}

pub fn update_skill_changes_description_test() {
  with_db(fn(db) {
    let assert Ok(id) =
      db.insert_skill(db, "my_skill", "old desc", "source", "[]")
    let assert Ok(Nil) =
      db.update_skill(db, id, "new desc", "new source", "[\"updated\"]")
    let assert Ok(found) = db.get_skill(db, id)
    let assert option.Some(skill) = found
    let assert "new desc" = skill.description
    let assert "new source" = skill.chute_source
    let assert "[\"updated\"]" = skill.tags
  })
}

pub fn deactivate_skill_sets_inactive_test() {
  with_db(fn(db) {
    let assert Ok(id) = db.insert_skill(db, "my_skill", "desc", "source", "[]")
    let assert Ok(Nil) = db.deactivate_skill(db, id)
    let assert Ok(found) = db.get_skill(db, id)
    let assert option.Some(skill) = found
    let assert "inactive" = skill.status
  })
}

// Runs
// ═══════════════════════════════════════════════════════════════

pub fn insert_run_creates_running_record_test() {
  with_db(fn(db) {
    let assert Ok(agent_id) =
      db.insert_agent(db, "run_agent", "desc", "source", "active")
    let ts = now()
    let assert Ok(Nil) =
      db.insert_run(
        db,
        agent_id,
        option.None,
        "tool_call",
        "chute_exec",
        "running",
        ts,
      )
    let assert Ok(runs) = db.get_actor_runs(db, agent_id, 10)
    let assert 1 = list.length(runs)
    let assert Ok(r) = list.first(runs)
    let assert "running" = r.status
    let assert "tool_call" = r.trigger_type
  })
}

pub fn complete_run_sets_status_and_metrics_test() {
  with_db(fn(db) {
    let assert Ok(agent_id) =
      db.insert_agent(db, "run_agent", "desc", "source", "active")
    let ts = now()
    let assert Ok(Nil) =
      db.insert_run(
        db,
        agent_id,
        option.None,
        "cron",
        "schedule:abc",
        "running",
        ts,
      )
    // Get the run ID
    let assert Ok(runs) = db.get_actor_runs(db, agent_id, 10)
    let assert [run, ..] = runs
    let completed_ts = now()
    let assert Ok(Nil) =
      db.complete_run(
        db,
        run.id,
        "completed",
        option.Some("ok"),
        option.Some(42),
        option.Some(100),
        option.Some(completed_ts),
      )
    let assert Ok(updated_runs) = db.get_actor_runs(db, agent_id, 10)
    let assert [updated, ..] = updated_runs
    let assert "completed" = updated.status
    let assert "ok" = updated.result
    let assert 100 = updated.duration_ms
  })
}

pub fn get_actor_runs_ordered_by_started_at_desc_test() {
  with_db(fn(db) {
    let assert Ok(agent_id) =
      db.insert_agent(db, "run_agent", "desc", "source", "active")
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "a", "running", 100)
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "b", "running", 300)
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "c", "running", 200)
    let assert Ok(runs) = db.get_actor_runs(db, agent_id, 10)
    let times = list.map(runs, fn(r) { r.started_at })
    // Should be DESC (300, 200, 100)
    let assert [first, second, third] = times
    let assert True = first >= second
    let assert True = second >= third
  })
}

pub fn get_actor_runs_respects_limit_test() {
  with_db(fn(db) {
    let assert Ok(agent_id) =
      db.insert_agent(db, "run_agent", "desc", "source", "active")
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "a", "running", 100)
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "b", "running", 200)
    let assert Ok(Nil) =
      db.insert_run(db, agent_id, option.None, "tool", "c", "running", 300)
    let assert Ok(runs) = db.get_actor_runs(db, agent_id, 2)
    let assert 2 = list.length(runs)
  })
}

// ═══════════════════════════════════════════════════════════════
// Agents
// ═══════════════════════════════════════════════════════════════

pub fn insert_and_get_agent_test() {
  with_db(fn(db) {
    let assert Ok(id) =
      db.insert_agent(
        db,
        "my_agent",
        "does things",
        "pub fn main() { 1 }",
        "active",
      )
    let assert Ok(found) = db.get_agent(db, id)
    let assert option.Some(agent) = found
    let assert "my_agent" = agent.name
    let assert "does things" = agent.description
    let assert "active" = agent.status
  })
}

pub fn get_agent_by_name_test() {
  with_db(fn(db) {
    let assert Ok(_id) =
      db.insert_agent(db, "my_agent", "does things", "source", "active")
    let assert Ok(found) = db.get_agent_by_name(db, "my_agent")
    let assert option.Some(agent) = found
    let assert "my_agent" = agent.name
  })
}

pub fn list_agents_returns_all_test() {
  with_db(fn(db) {
    let assert Ok(_id1) =
      db.insert_agent(db, "agent_a", "desc a", "source a", "active")
    let assert Ok(_id2) =
      db.insert_agent(db, "agent_b", "desc b", "source b", "draft")
    let assert Ok(agents) = db.list_agents(db)
    let assert 2 = list.length(agents)
  })
}

// ═══════════════════════════════════════════════════════════════
// Providers
// ═══════════════════════════════════════════════════════════════

pub fn save_and_get_provider_test() {
  with_db(fn(db) {
    let assert Ok(provider) =
      db.save_provider(db, "sk-test", "https://api.example.com", "gpt-4")
    let assert "default" = provider.id
    let assert "sk-test" = provider.api_key
    let assert "gpt-4" = provider.model
  })
}

pub fn get_provider_when_none_returns_none_test() {
  with_db(fn(db) {
    let assert Ok(option.None) = db.get_provider(db)
  })
}

pub fn save_provider_replaces_existing_test() {
  with_db(fn(db) {
    let assert Ok(_p1) =
      db.save_provider(db, "sk-old", "https://old.example.com", "gpt-3")
    let assert Ok(p2) =
      db.save_provider(db, "sk-new", "https://new.example.com", "gpt-4")
    let assert "sk-new" = p2.api_key
    let assert "gpt-4" = p2.model
    let assert Ok(option.Some(found)) = db.get_provider(db)
    let assert "sk-new" = found.api_key
    let assert "gpt-4" = found.model
  })
}

// ═══════════════════════════════════════════════════════════════
// Chat
// ═══════════════════════════════════════════════════════════════

pub fn get_or_create_session_creates_new_test() {
  with_db(fn(db) {
    let assert Ok(session_id) = db.get_or_create_session(db)
    let assert True = string.length(session_id) > 0
  })
}

pub fn get_or_create_session_returns_existing_test() {
  with_db(fn(db) {
    let assert Ok(id1) = db.get_or_create_session(db)
    let assert Ok(id2) = db.get_or_create_session(db)
    let assert True = id1 == id2
  })
}

pub fn save_and_get_chat_messages_test() {
  with_db(fn(db) {
    let assert Ok(session_id) = db.get_or_create_session(db)
    let assert Ok(Nil) = db.save_chat_message(db, session_id, "user", "Hello!")
    let assert Ok(Nil) =
      db.save_chat_message(db, session_id, "assistant", "Hi there!")
    let assert Ok(messages) = db.get_chat_messages(db, session_id)
    let assert 2 = list.length(messages)
    let msgs: List(db.ChatMessage) = messages
    let assert Ok(first) = list.first(msgs)
    let assert "Hello!" = first.content
    let assert [_first, second, ..] = msgs
    let assert "Hi there!" = second.content
  })
}
