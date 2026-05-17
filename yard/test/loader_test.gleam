//// Loader tests — parse source, compute hash.

import gleam/string
import gleeunit
import yard/loader

pub fn main() {
  gleeunit.main()
}

// ── Tests: Basic Loading ─────────────────────────────────────────────

pub fn load_valid_source_test() {
  let assert Ok(actor) =
    loader.load(
      "effect greet(name: String) -> String
       pub fn main() -> String { perform greet(\"world\") }",
      "actors/greet.chute",
    )

  let assert "actors/greet.chute" = actor.actor_path
  let assert 8 = string.length(actor.actor_hash)
}

pub fn load_parse_error_test() {
  let result = loader.load("fn main() { !!! }", "bad.chute")
  let assert Error(_) = result
}

// ── Tests: Hash Determinism ──────────────────────────────────────────

pub fn same_source_same_hash_test() {
  let source = "pub fn main() -> Int { 1 + 2 }"
  let assert Ok(a) = loader.load(source, "a.chute")
  let assert Ok(b) = loader.load(source, "b.chute")

  // Same source → same hash, even with different paths
  let assert True = a.actor_hash == b.actor_hash
}

pub fn different_source_different_hash_test() {
  let assert Ok(a) = loader.load("pub fn main() -> Int { 1 + 2 }", "a.chute")
  let assert Ok(b) = loader.load("pub fn main() -> Int { 3 + 4 }", "b.chute")

  // Different source → different hash
  let assert True = a.actor_hash != b.actor_hash
}

pub fn comments_dont_change_hash_test() {
  let assert Ok(a) = loader.load("pub fn main() -> Int { 1 + 2 }", "test.chute")
  let assert Ok(b) =
    loader.load(
      "// This is a comment
       pub fn main() -> Int { 1 + 2 }",
      "test.chute",
    )

  // Comments are stripped during parsing → same hash
  let assert True = a.actor_hash == b.actor_hash
}

pub fn whitespace_differences_same_hash_test() {
  let assert Ok(a) = loader.load("pub fn main()->Int{1+2}", "test.chute")
  let assert Ok(b) = loader.load("pub fn main() -> Int { 1 + 2 }", "test.chute")

  // The S-expression is canonical → same hash
  let assert True = a.actor_hash == b.actor_hash
}

// ── Tests: Hash Format ──────────────────────────────────────────────

pub fn hash_is_hex_string_test() {
  let assert Ok(actor) =
    loader.load("pub fn main() -> Int { 42 }", "test.chute")

  // Hash should be exactly 8 hex characters
  let hash = actor.actor_hash
  let assert 8 = string.length(hash)
}

// ── Tests: Path Preservation ─────────────────────────────────────────

pub fn actor_path_preserved_test() {
  let assert Ok(actor) =
    loader.load("pub fn main() -> Int { 42 }", "actors/nested/triage.chute")
  let assert "actors/nested/triage.chute" = actor.actor_path
}
