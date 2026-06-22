//// Skill repository — domain layer over db.gleam for skill CRUD.
////
//// Provides register/lookup/list/deactivate operations for skills.
//// Skills are reusable Chute programs stored in the global DB.

import gleam/json
import gleam/list
import gleam/option
import sqlight
import yard/db

// ═══════════════════════════════════════════════════════════════
// Public Types
// ═══════════════════════════════════════════════════════════════

/// A skill with its full source code.
pub type Skill {
  Skill(
    id: String,
    name: String,
    description: String,
    chute_source: String,
    tags: String,
    status: String,
  )
}

// ═══════════════════════════════════════════════════════════════
// Conversions
// ═══════════════════════════════════════════════════════════════

fn db_skill_to_skill(s: db.Skill) -> Skill {
  Skill(
    id: s.id,
    name: s.name,
    description: s.description,
    chute_source: s.chute_source,
    tags: s.tags,
    status: s.status,
  )
}

// ═══════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════

/// Register a new skill. Returns the generated ID.
/// Fails if a skill with the same name already exists.
pub fn register(
  conn: sqlight.Connection,
  name: String,
  description: String,
  source: String,
  tags: List(String),
) -> Result(String, String) {
  // Check for duplicate name
  case db.get_skill_by_name(conn, name) {
    Ok(option.Some(_)) ->
      Error("Skill with name '" <> name <> "' already exists")
    Ok(option.None) -> {
      let tags_json =
        tags
        |> list.map(json.string)
        |> json.array(fn(x) { x })
        |> json.to_string

      case db.insert_skill(conn, name, description, source, tags_json) {
        Ok(id) -> Ok(id)
        Error(_) -> Error("Failed to insert skill")
      }
    }
    Error(_) -> Error("Database error checking skill name")
  }
}

/// Look up a skill by name. Returns the full skill with source.
pub fn lookup(conn: sqlight.Connection, name: String) -> Result(Skill, String) {
  case db.get_skill_by_name(conn, name) {
    Ok(option.Some(skill)) -> Ok(db_skill_to_skill(skill))
    Ok(option.None) -> Error("Skill '" <> name <> "' not found")
    Error(_) -> Error("Database error looking up skill")
  }
}

/// List all active skills.
pub fn list_all(conn: sqlight.Connection) -> Result(List(Skill), String) {
  case db.list_skills(conn) {
    Ok(skills) -> Ok(list.map(skills, db_skill_to_skill))
    Error(_) -> Error("Database error listing skills")
  }
}

/// Deactivate a skill by ID.
pub fn deactivate(conn: sqlight.Connection, id: String) -> Result(Nil, String) {
  case db.deactivate_skill(conn, id) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error("Database error deactivating skill")
  }
}
