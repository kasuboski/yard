//// DB layer tests — typed CRUD over the Parrot-generated sql.gleam.

import birl
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import sqlight
import yard/db

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

fn now() -> Int {
  birl.to_unix(birl.utc_now())
}

// ═══════════════════════════════════════════════════════════════
// Skills
// ═══════════════════════════════════════════════════════════════

pub fn insert_skill_creates_record_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      db.insert_skill(
        conn,
        "health_check",
        "Checks system health",
        "pub fn main(env) { Ok(Nil) }",
        "[\"monitor\"]",
      )
    let assert Ok(found) = db.get_skill(conn, id)
    let assert option.Some(skill) = found
    let assert "health_check" = skill.name
    let assert "Checks system health" = skill.description
    let assert "active" = skill.status
  })
}

pub fn get_skill_by_name_test() {
  with_db(fn(conn) {
    let assert Ok(_id) =
      db.insert_skill(conn, "my_skill", "desc", "pub fn main(env) { 1 }", "[]")
    let assert Ok(found) = db.get_skill_by_name(conn, "my_skill")
    let assert option.Some(skill) = found
    let assert "my_skill" = skill.name
  })
}

pub fn get_skill_missing_returns_none_test() {
  with_db(fn(conn) {
    let assert Ok(option.None) = db.get_skill(conn, "nonexistent")
  })
}

pub fn list_skills_returns_active_only_test() {
  with_db(fn(conn) {
    let assert Ok(_id1) =
      db.insert_skill(conn, "skill_a", "desc a", "source a", "[]")
    let assert Ok(_id2) =
      db.insert_skill(conn, "skill_b", "desc b", "source b", "[]")
    let assert Ok(id3) =
      db.insert_skill(conn, "skill_c", "desc c", "source c", "[]")
    let assert Ok(Nil) = db.deactivate_skill(conn, id3)
    let assert Ok(skills) = db.list_skills(conn)
    let assert 2 = list.length(skills)
    let names = list.map(skills, fn(s) { s.name })
    let assert True = list.contains(names, "skill_a")
    let assert True = list.contains(names, "skill_b")
  })
}

pub fn update_skill_changes_description_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      db.insert_skill(conn, "my_skill", "old desc", "source", "[]")
    let assert Ok(Nil) =
      db.update_skill(conn, id, "new desc", "new source", "[\"updated\"]")
    let assert Ok(found) = db.get_skill(conn, id)
    let assert option.Some(skill) = found
    let assert "new desc" = skill.description
    let assert "new source" = skill.chute_source
    let assert "[\"updated\"]" = skill.tags
  })
}

pub fn deactivate_skill_sets_inactive_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      db.insert_skill(conn, "my_skill", "desc", "source", "[]")
    let assert Ok(Nil) = db.deactivate_skill(conn, id)
    let assert Ok(found) = db.get_skill(conn, id)
    let assert option.Some(skill) = found
    let assert "inactive" = skill.status
  })
}

// ═══════════════════════════════════════════════════════════════
// Schedules
// ═══════════════════════════════════════════════════════════════

pub fn insert_schedule_creates_record_test() {
  with_db(fn(conn) {
    let assert Ok(skill_id) =
      db.insert_skill(conn, "cron_skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.None, skill_id, "*/5 * * * *", 1000)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert skill_id = schedule.skill_id
    let assert "*/5 * * * *" = schedule.cron_expr
    let assert "active" = schedule.status
    let assert 1000 = schedule.next_fire_at
    let assert option.None = schedule.agent_id
  })
}

pub fn get_schedule_by_id_test() {
  with_db(fn(conn) {
    let assert Ok(skill_id) =
      db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.None, skill_id, "0 * * * *", 500)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert id = schedule.id
  })
}

pub fn list_active_schedules_returns_active_only_test() {
  with_db(fn(conn) {
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id1) =
      db.insert_schedule(conn, option.None, sid, "*/5 * * * *", 100)
    let assert Ok(_id2) =
      db.insert_schedule(conn, option.None, sid, "0 * * * *", 200)
    let assert Ok(Nil) = db.deactivate_schedule(conn, id1)
    let assert Ok(schedules) = db.list_active_schedules(conn)
    let assert 1 = list.length(schedules)
  })
}

pub fn update_schedule_fire_sets_timestamps_test() {
  with_db(fn(conn) {
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.None, sid, "*/5 * * * *", 100)
    let assert Ok(Nil) =
      db.update_schedule_fire(conn, id, option.Some(100), 200)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert option.Some(100) = schedule.last_fired_at
    let assert 200 = schedule.next_fire_at
  })
}

pub fn deactivate_schedule_test() {
  with_db(fn(conn) {
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.None, sid, "*/5 * * * *", 100)
    let assert Ok(Nil) = db.deactivate_schedule(conn, id)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert "inactive" = schedule.status
  })
}

pub fn list_active_schedules_ordered_by_next_fire_test() {
  with_db(fn(conn) {
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(_id1) = db.insert_schedule(conn, option.None, sid, "a", 300)
    let assert Ok(_id2) = db.insert_schedule(conn, option.None, sid, "b", 100)
    let assert Ok(_id3) = db.insert_schedule(conn, option.None, sid, "c", 200)
    let assert Ok(schedules) = db.list_active_schedules(conn)
    let fire_times = list.map(schedules, fn(s) { s.next_fire_at })
    let assert [100, 200, 300] = fire_times
  })
}

pub fn schedule_with_null_agent_id_test() {
  with_db(fn(conn) {
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.None, sid, "*/5 * * * *", 100)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert option.None = schedule.agent_id
  })
}

pub fn schedule_with_agent_id_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(conn, "test_agent", "an agent", "source", "active")
    let assert Ok(sid) = db.insert_skill(conn, "skill", "desc", "source", "[]")
    let assert Ok(id) =
      db.insert_schedule(conn, option.Some(agent_id), sid, "*/5 * * * *", 100)
    let assert Ok(found) = db.get_schedule(conn, id)
    let assert option.Some(schedule) = found
    let assert option.Some(aid) = schedule.agent_id
    let assert agent_id = aid
  })
}

// ═══════════════════════════════════════════════════════════════
// Runs
// ═══════════════════════════════════════════════════════════════

pub fn insert_run_creates_running_record_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(conn, "run_agent", "desc", "source", "active")
    let ts = now()
    let assert Ok(Nil) =
      db.insert_run(
        conn,
        agent_id,
        option.None,
        "tool_call",
        "chute_exec",
        "running",
        ts,
      )
    let assert Ok(runs) = db.get_actor_runs(conn, agent_id, 10)
    let assert 1 = list.length(runs)
    let assert Ok(r) = list.first(runs)
    let assert "running" = r.status
    let assert "tool_call" = r.trigger_type
  })
}

pub fn complete_run_sets_status_and_metrics_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(conn, "run_agent", "desc", "source", "active")
    let ts = now()
    let assert Ok(Nil) =
      db.insert_run(
        conn,
        agent_id,
        option.None,
        "cron",
        "schedule:abc",
        "running",
        ts,
      )
    // Get the run ID
    let assert Ok(runs) = db.get_actor_runs(conn, agent_id, 10)
    let assert [run, ..] = runs
    let completed_ts = now()
    let assert Ok(Nil) =
      db.complete_run(
        conn,
        run.id,
        "completed",
        option.Some("ok"),
        option.Some(42),
        option.Some(100),
        option.Some(completed_ts),
      )
    let assert Ok(updated_runs) = db.get_actor_runs(conn, agent_id, 10)
    let assert [updated, ..] = updated_runs
    let assert "completed" = updated.status
    let assert "ok" = updated.result
    let assert 100 = updated.duration_ms
  })
}

pub fn get_actor_runs_ordered_by_started_at_desc_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(conn, "run_agent", "desc", "source", "active")
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "a", "running", 100)
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "b", "running", 300)
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "c", "running", 200)
    let assert Ok(runs) = db.get_actor_runs(conn, agent_id, 10)
    let times = list.map(runs, fn(r) { r.started_at })
    let assert [300, 200, 100] = times
  })
}

pub fn get_actor_runs_respects_limit_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(conn, "run_agent", "desc", "source", "active")
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "a", "running", 100)
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "b", "running", 200)
    let assert Ok(Nil) =
      db.insert_run(conn, agent_id, option.None, "tool", "c", "running", 300)
    let assert Ok(runs) = db.get_actor_runs(conn, agent_id, 2)
    let assert 2 = list.length(runs)
  })
}

// ═══════════════════════════════════════════════════════════════
// Agents
// ═══════════════════════════════════════════════════════════════

pub fn insert_and_get_agent_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      db.insert_agent(
        conn,
        "my_agent",
        "does things",
        "pub fn main() { 1 }",
        "active",
      )
    let assert Ok(found) = db.get_agent(conn, id)
    let assert option.Some(agent) = found
    let assert "my_agent" = agent.name
    let assert "does things" = agent.description
    let assert "active" = agent.status
  })
}

pub fn get_agent_by_name_test() {
  with_db(fn(conn) {
    let assert Ok(_id) =
      db.insert_agent(conn, "my_agent", "does things", "source", "active")
    let assert Ok(found) = db.get_agent_by_name(conn, "my_agent")
    let assert option.Some(agent) = found
    let assert "my_agent" = agent.name
  })
}

pub fn list_agents_returns_all_test() {
  with_db(fn(conn) {
    let assert Ok(_id1) =
      db.insert_agent(conn, "agent_a", "desc a", "source a", "active")
    let assert Ok(_id2) =
      db.insert_agent(conn, "agent_b", "desc b", "source b", "draft")
    let assert Ok(agents) = db.list_agents(conn)
    let assert 2 = list.length(agents)
  })
}

// ═══════════════════════════════════════════════════════════════
// Providers
// ═══════════════════════════════════════════════════════════════

pub fn save_and_get_provider_test() {
  with_db(fn(conn) {
    let assert Ok(provider) =
      db.save_provider(conn, "sk-test", "https://api.example.com", "gpt-4")
    let assert "default" = provider.id
    let assert "sk-test" = provider.api_key
    let assert "gpt-4" = provider.model
  })
}

pub fn get_provider_when_none_returns_none_test() {
  with_db(fn(conn) {
    let assert Ok(option.None) = db.get_provider(conn)
  })
}

pub fn save_provider_replaces_existing_test() {
  with_db(fn(conn) {
    let assert Ok(_p1) =
      db.save_provider(conn, "sk-old", "https://old.example.com", "gpt-3")
    let assert Ok(p2) =
      db.save_provider(conn, "sk-new", "https://new.example.com", "gpt-4")
    let assert "sk-new" = p2.api_key
    let assert "gpt-4" = p2.model
  })
}

// ═══════════════════════════════════════════════════════════════
// Chat
// ═══════════════════════════════════════════════════════════════

pub fn get_or_create_session_creates_new_test() {
  with_db(fn(conn) {
    let assert Ok(session_id) = db.get_or_create_session(conn)
    let assert True = string.length(session_id) > 0
  })
}

pub fn get_or_create_session_returns_existing_test() {
  with_db(fn(conn) {
    let assert Ok(id1) = db.get_or_create_session(conn)
    let assert Ok(id2) = db.get_or_create_session(conn)
    let assert id1 = id2
  })
}

pub fn save_and_get_chat_messages_test() {
  with_db(fn(conn) {
    let assert Ok(session_id) = db.get_or_create_session(conn)
    let assert Ok(Nil) =
      db.save_chat_message(conn, session_id, "user", "Hello!")
    let assert Ok(Nil) =
      db.save_chat_message(conn, session_id, "assistant", "Hi there!")
    let assert Ok(messages) = db.get_chat_messages(conn, session_id)
    let assert 2 = list.length(messages)
    let msgs: List(db.ChatMessage) = messages
    let assert Ok(first) = list.first(msgs)
    let assert "Hello!" = first.content
    let assert [_first, second, ..] = msgs
    let assert "Hi there!" = second.content
  })
}
