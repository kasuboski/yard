//// Skill repository tests — PostgreSQL-backed skill CRUD.
////
//// Requires: docker container running with pg_schema.sql applied.
//// Run with: bin/postgres.sh && cd yard && gleam test

import gabsurd/client
import gleam/list
import gleam/string
import testing
import yard/skill_repo

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_clean_db(test_fn)
}

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

pub fn register_creates_skill_test() {
  with_db(fn(db) {
    let assert Ok(_id) =
      skill_repo.register(
        db,
        "health_check",
        "Checks system health",
        "pub fn main(env) { Ok(Nil) }",
        [],
      )
    let assert Ok(skill) = skill_repo.lookup(db, "health_check")
    let assert "health_check" = skill.name
    let assert "Checks system health" = skill.description
    let assert "active" = skill.status
  })
}

pub fn register_fails_on_duplicate_name_test() {
  with_db(fn(db) {
    let assert Ok(_id1) =
      skill_repo.register(db, "my_skill", "desc1", "source1", [])
    let assert Error(msg) =
      skill_repo.register(db, "my_skill", "desc2", "source2", [])
    let assert True = string.contains(msg, "already exists")
  })
}

pub fn lookup_returns_skill_by_name_test() {
  with_db(fn(db) {
    let assert Ok(_id) =
      skill_repo.register(db, "my_skill", "desc", "source", [])
    let assert Ok(skill) = skill_repo.lookup(db, "my_skill")
    let assert "my_skill" = skill.name
  })
}

pub fn lookup_returns_error_on_missing_test() {
  with_db(fn(db) {
    let assert Error(msg) = skill_repo.lookup(db, "nonexistent")
    let assert True = string.contains(msg, "not found")
  })
}

pub fn list_all_returns_active_skills_test() {
  with_db(fn(db) {
    let assert Ok(_id_a) =
      skill_repo.register(db, "skill_a", "desc a", "source a", [])
    let assert Ok(_id_b) =
      skill_repo.register(db, "skill_b", "desc b", "source b", [])
    let assert Ok(skills) = skill_repo.list_all(db)
    let assert 2 = list.length(skills)
  })
}

pub fn deactivate_removes_from_list_all_test() {
  with_db(fn(db) {
    let assert Ok(id) =
      skill_repo.register(db, "my_skill", "desc", "source", [])
    let assert Ok(_other_id) =
      skill_repo.register(db, "other_skill", "desc", "source", [])
    let assert Ok(Nil) = skill_repo.deactivate(db, id)
    let assert Ok(skills) = skill_repo.list_all(db)
    let assert 1 = list.length(skills)
    let assert [skill, ..] = skills
    let assert "other_skill" = skill.name
  })
}

pub fn register_with_tags_test() {
  with_db(fn(db) {
    let assert Ok(_id) =
      skill_repo.register(db, "tagged_skill", "desc", "source", [
        "monitoring",
        "health",
      ])
    let assert Ok(skill) = skill_repo.lookup(db, "tagged_skill")
    let assert "[\"monitoring\",\"health\"]" = skill.tags
  })
}
