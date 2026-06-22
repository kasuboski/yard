import ballast/value
import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit
import hermes_agent/chute_exec
import pig/workspace/schema
import sqlight

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

/// Parse a json.Json to string, then re-parse as Dynamic for assertions.
fn to_dynamic(j: json.Json) -> decode.Dynamic {
  let assert Ok(d) = json.parse(from: json.to_string(j), using: decode.dynamic)
  d
}

// ═══════════════════════════════════════════════════════════════
// chute_exec tool
// ═══════════════════════════════════════════════════════════════

/// Simple program returning a value
pub fn chute_exec_simple_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let result =
      chute_exec.run(
        config,
        "pub fn main(env: {}) -> Int { 42 }",
        value.RecordVal([]),
      )
    let assert Ok(response) = result
    let d = to_dynamic(response)
    let assert Ok(42) =
      decode.run(d, decode.field("ok", decode.int, decode.success))
  })
}

/// Response includes gas_used as a non-negative integer
pub fn chute_exec_includes_gas_used_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let result =
      chute_exec.run(
        config,
        "pub fn main(env: {}) -> Int { 42 }",
        value.RecordVal([]),
      )
    let assert Ok(response) = result
    let d = to_dynamic(response)
    let assert Ok(gas) =
      decode.run(d, decode.field("gas_used", decode.int, decode.success))
    let assert True = gas >= 0
  })
}

/// emit_event program returns events in response
pub fn chute_exec_with_emit_event_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let source =
      "effect emit_event(name: String, payload: String) -> Nil\n\npub fn main(env: {}) -> Result(Int, String) { let _ = perform emit_event(\"planning\", \"reading files\") Ok(42) }"
    let result = chute_exec.run(config, source, value.RecordVal([]))
    let assert Ok(response) = result
    let json_str = json.to_string(response)
    let assert True = string.contains(json_str, "planning")
    let assert True = string.contains(json_str, "reading files")
  })
}

/// chute_exec with workspace effects
pub fn chute_exec_with_workspace_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let source =
      "effect write_file(path: String, content: String) -> Result(Nil, String)\n\neffect read_file(path: String) -> Result(String, String)\n\npub fn main(env: {}) -> Result(String, String) { let try _ = perform write_file(\"test.txt\", \"hello\") let try content = perform read_file(\"test.txt\") Ok(content) }"
    let result = chute_exec.run(config, source, value.RecordVal([]))
    let assert Ok(response) = result
    let d = to_dynamic(response)
    // The chute program returns Result(String, String), so Ballast yields
    // OkVal(StringVal("hello")). ballast_to_json wraps that as {"ok": "hello"}.
    // Then chute_exec.run wraps again: {"ok": {"ok": "hello"}, ...}
    let assert Ok(ok_val) =
      decode.run(
        d,
        decode.field(
          "ok",
          decode.field("ok", decode.string, decode.success),
          decode.success,
        ),
      )
    let assert "hello" = ok_val
  })
}

/// Parse error returns structured error
pub fn chute_exec_parse_error_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let result =
      chute_exec.run(config, "this is not valid chute!!!", value.RecordVal([]))
    let assert Ok(response) = result
    let d = to_dynamic(response)
    let assert Ok(error_type) =
      decode.run(
        d,
        decode.field(
          "error",
          decode.field("type", decode.string, decode.success),
          decode.success,
        ),
      )
    let assert "parse" = error_type
  })
}

/// Runtime error returns structured error
pub fn chute_exec_runtime_error_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let source =
      "effect unknown_effect(x: Int) -> Int\n\npub fn main(env: {}) -> Int { perform unknown_effect(1) }"
    let result = chute_exec.run(config, source, value.RecordVal([]))
    let assert Ok(response) = result
    let d = to_dynamic(response)
    let assert Ok(error_type) =
      decode.run(
        d,
        decode.field(
          "error",
          decode.field("type", decode.string, decode.success),
          decode.success,
        ),
      )
    let assert "runtime" = error_type
  })
}

/// Empty source returns an error (runtime: no main function)
pub fn chute_exec_empty_source_test() {
  with_workspace(fn(conn) {
    let config = chute_exec.silent_config(conn)
    let result = chute_exec.run(config, "", value.RecordVal([]))
    let assert Ok(response) = result
    let d = to_dynamic(response)
    let assert Ok(error_type) =
      decode.run(
        d,
        decode.field(
          "error",
          decode.field("type", decode.string, decode.success),
          decode.success,
        ),
      )
    // Empty source parses but has no main function — runtime error
    let assert "runtime" = error_type
  })
}
