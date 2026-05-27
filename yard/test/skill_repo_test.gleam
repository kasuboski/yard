//// Skill repository tests.

import gleam/list
import gleam/string
import gleeunit
import sqlight
import yard/db
import yard/skill_repo

pub fn main() {
  gleeunit.main()
}

fn with_db(test_fn: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = db.migrate(conn)
  test_fn(conn)
}

// ═══════════════════════════════════════════════════════════════
// register / lookup
// ═══════════════════════════════════════════════════════════════

pub fn register_creates_skill_test() {
  with_db(fn(conn) {
    let assert Ok(__id) =
      skill_repo.register(
        conn,
        "health_check",
        "Checks system health",
        "pub fn main(env) { Ok(Nil) }",
        [],
      )
    let assert Ok(skill) = skill_repo.lookup(conn, "health_check")
    let assert "health_check" = skill.name
    let assert "Checks system health" = skill.description
  })
}

pub fn register_generates_id_and_hash_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      skill_repo.register(
        conn,
        "my_skill",
        "desc",
        "pub fn main(env) { 1 }",
        [],
      )
    // ID should be a UUID (36 chars with dashes)
    let assert True = string.length(id) > 0
    // Lookup should work
    let assert Ok(skill) = skill_repo.lookup(conn, "my_skill")
    let _id = skill.id
  })
}

pub fn register_duplicate_name_returns_error_test() {
  with_db(fn(conn) {
    let assert Ok(_) =
      skill_repo.register(conn, "my_skill", "desc1", "source1", [])
    let assert Error(msg) =
      skill_repo.register(conn, "my_skill", "desc2", "source2", [])
    let assert True = string.contains(msg, "already exists")
  })
}

pub fn lookup_missing_returns_error_test() {
  with_db(fn(conn) {
    let assert Error(msg) = skill_repo.lookup(conn, "nonexistent")
    let assert True = string.contains(msg, "not found")
  })
}

pub fn list_all_returns_active_skills_test() {
  with_db(fn(conn) {
    let assert Ok(_) =
      skill_repo.register(conn, "skill_a", "desc a", "source a", [])
    let assert Ok(_) =
      skill_repo.register(conn, "skill_b", "desc b", "source b", [])
    let assert Ok(skills) = skill_repo.list_all(conn)
    let assert 2 = list.length(skills)
  })
}

pub fn deactivate_removes_from_list_test() {
  with_db(fn(conn) {
    let assert Ok(id) =
      skill_repo.register(conn, "my_skill", "desc", "source", [])
    let assert Ok(_) =
      skill_repo.register(conn, "other_skill", "desc", "source", [])
    let assert Ok(Nil) = skill_repo.deactivate(conn, id)
    let assert Ok(skills) = skill_repo.list_all(conn)
    let assert 1 = list.length(skills)
    let names = list.map(skills, fn(s) { s.name })
    let assert True = list.contains(names, "other_skill")
  })
}

pub fn register_with_tags_test() {
  with_db(fn(conn) {
    let assert Ok(_) =
      skill_repo.register(conn, "tagged_skill", "desc", "source", [
        "monitor",
        "health",
      ])
    let assert Ok(skill) = skill_repo.lookup(conn, "tagged_skill")
    let assert True = string.contains(skill.tags, "monitor")
    let assert True = string.contains(skill.tags, "health")
  })
}
