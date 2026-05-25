import ballast/value.{ErrorVal, ListVal, NilVal, OkVal, StringVal}
import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import hermes_agent/effects
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
