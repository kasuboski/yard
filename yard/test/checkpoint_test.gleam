//// Checkpoint store tests — the durability abstraction the runner uses.
////
//// In production this is backed by gabsurd's PostgreSQL checkpoint API.
//// For testing we use an in-memory implementation.

import gleam/option
import gleeunit
import gleeunit/should
import yard/checkpoint

pub fn main() {
  gleeunit.main()
}

// ── In-memory checkpointer ───────────────────────────────────────────

pub fn save_then_load_returns_value_test() {
  let cp = checkpoint.in_memory()
  let _ = checkpoint.save(cp, "0:greet", "{\"type\":\"string\",\"value\":\"hi\"}")
  let result = checkpoint.load(cp, "0:greet")
  should.equal(result, Ok(option.Some("{\"type\":\"string\",\"value\":\"hi\"}")))
}

pub fn load_missing_returns_none_test() {
  let cp = checkpoint.in_memory()
  let result = checkpoint.load(cp, "0:greet")
  should.equal(result, Ok(option.None))
}

pub fn save_overwrites_previous_test() {
  let cp = checkpoint.in_memory()
  let _ = checkpoint.save(cp, "0:greet", "first")
  let _ = checkpoint.save(cp, "0:greet", "second")
  let result = checkpoint.load(cp, "0:greet")
  should.equal(result, Ok(option.Some("second")))
}

pub fn multiple_checkpoints_coexist_test() {
  let cp = checkpoint.in_memory()
  let _ = checkpoint.save(cp, "0:greet", "hello")
  let _ = checkpoint.save(cp, "1:count", "42")
  let _ = checkpoint.save(cp, "2:save", "done")
  should.equal(checkpoint.load(cp, "0:greet"), Ok(option.Some("hello")))
  should.equal(checkpoint.load(cp, "1:count"), Ok(option.Some("42")))
  should.equal(checkpoint.load(cp, "2:save"), Ok(option.Some("done")))
}

pub fn empty_step_name_works_test() {
  let cp = checkpoint.in_memory()
  let _ = checkpoint.save(cp, "", "data")
  should.equal(checkpoint.load(cp, ""), Ok(option.Some("data")))
}
