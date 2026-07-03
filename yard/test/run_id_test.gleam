//// run_id generation tests.

import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import yard/run_id

pub fn main() {
  gleeunit.main()
}

/// generate() returns a UUID v4 in standard 36-char text form
/// (8-4-4-4-12 hex digits).
pub fn generate_returns_uuid_v4_string_test() {
  let id = run_id.generate()

  // Standard UUID text length: 32 hex chars + 4 hyphens = 36.
  should.equal(string.length(id), 36)

  // Version nibble (char at index 14) is '4' for UUID v4.
  should.equal(string.slice(id, 14, 1), "4")

  // Variant nibble (char at index 19) is 8, 9, a, or b.
  let variant = string.slice(id, 19, 1)
  should.be_true(
    variant == "8" || variant == "9" || variant == "a" || variant == "b",
  )
}

/// generate() produces unique values across repeated calls.
pub fn generate_is_unique_test() {
  let ids = [
    run_id.generate(),
    run_id.generate(),
    run_id.generate(),
    run_id.generate(),
    run_id.generate(),
  ]

  // No duplicates in the batch.
  should.equal(list.length(ids), list.length(list.unique(ids)))
}
