//// Handler registry tests — TDD for the per-schedule handler resolution system.
////
//// The handler registry maps handler names (strings) to builder functions
//// that produce EffectHandler closures. When the cron engine fires a
//// schedule, it loads the agent's handler bindings from agent_handlers,
//// resolves each (effect_name → handler_name) via the registry, and
//// builds the handler dict for that specific invocation.
////
//// This is the same pattern issue_triage uses (building handlers per
//// invocation), but generalized through a registry instead of hardcoded.

import ballast/value
import gabsurd/client
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import sqlight
import testing
import yard/db
import yard/handler_registry
import yard/runner

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_clean_db(test_fn)
}

/// A simple handler that echoes back the effect name + args joined.
fn echo_builder(_ctx: handler_registry.HandlerContext) -> runner.EffectHandler {
  fn(name, args) {
    let parts = [
      name,
      ..list.map(args, fn(a) {
        case a {
          value.StringVal(s) -> s
          other -> value.value_to_string(other)
        }
      })
    ]
    Ok(value.OkVal(value.StringVal(string.join(parts, " "))))
  }
}

/// A handler that reports whether workspace_conn was provided.
fn workspace_probe_builder(
  ctx: handler_registry.HandlerContext,
) -> runner.EffectHandler {
  fn(_name, _args) {
    let has_ws = case ctx.workspace_conn {
      option.Some(_) -> "has_workspace"
      option.None -> "no_workspace"
    }
    Ok(value.OkVal(value.StringVal(has_ws)))
  }
}

// ═══════════════════════════════════════════════════════════════
// Basic registration and resolution
// ═══════════════════════════════════════════════════════════════

pub fn new_registry_is_empty_test() {
  let reg = handler_registry.new()
  let assert Error(Nil) =
    handler_registry.resolve_one(
      reg,
      "nonexistent",
      handler_registry.make_context(option.None, fn(_) { Nil }),
    )
}

pub fn resolve_one_returns_handler_test() {
  let reg =
    handler_registry.register(handler_registry.new(), "echo", echo_builder)
  let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
  let assert Ok(handler) = handler_registry.resolve_one(reg, "echo", ctx)

  let assert Ok(value.OkVal(value.StringVal("foo arg1 arg2"))) =
    handler("foo", [value.StringVal("arg1"), value.StringVal("arg2")])
}

pub fn resolve_one_returns_error_for_unknown_handler_test() {
  let reg = handler_registry.new()
  let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
  let assert Error(Nil) = handler_registry.resolve_one(reg, "unknown", ctx)
}

// ═══════════════════════════════════════════════════════════════
// Context passthrough
// ═══════════════════════════════════════════════════════════════

pub fn handler_receives_context_without_workspace_test() {
  let reg =
    handler_registry.register(
      handler_registry.new(),
      "workspace_probe",
      workspace_probe_builder,
    )
  let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
  let assert Ok(handler) =
    handler_registry.resolve_one(reg, "workspace_probe", ctx)

  let assert Ok(value.OkVal(value.StringVal("no_workspace"))) = handler("x", [])
}

pub fn handler_receives_context_with_workspace_test() {
  let reg =
    handler_registry.register(
      handler_registry.new(),
      "workspace_probe",
      workspace_probe_builder,
    )
  // Create a real SQLite connection for workspace
  let assert Ok(ws_conn) = sqlight.open("file::memory:")
  let ctx = handler_registry.make_context(option.Some(ws_conn), fn(_) { Nil })
  let assert Ok(handler) =
    handler_registry.resolve_one(reg, "workspace_probe", ctx)

  let assert Ok(value.OkVal(value.StringVal("has_workspace"))) =
    handler("x", [])
}

// ═══════════════════════════════════════════════════════════════
// Per-agent resolution from agent_handlers table
// ═══════════════════════════════════════════════════════════════

pub fn resolve_for_agent_loads_bindings_from_db_test() {
  with_db(fn(db) {
    let reg =
      handler_registry.register(handler_registry.new(), "echo", echo_builder)

    // Create an agent with handler bindings
    let assert Ok(agent_id) =
      db.insert_agent(db, "test_agent", "test", "source", "active")
    let assert Ok(Nil) = db.insert_agent_handler(db, agent_id, "echo", "echo")

    let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, db, agent_id, ctx)

    let assert 1 = dict.size(handlers)
    let assert Ok(echo_handler) = dict.get(handlers, "echo")
    let assert Ok(value.OkVal(value.StringVal("echo x y"))) =
      echo_handler("echo", [value.StringVal("x"), value.StringVal("y")])
  })
}

pub fn resolve_for_agent_multiple_bindings_test() {
  with_db(fn(db) {
    let reg =
      handler_registry.register(handler_registry.new(), "echo", echo_builder)

    let assert Ok(agent_id) =
      db.insert_agent(db, "test_agent", "test", "source", "active")
    let assert Ok(Nil) = db.insert_agent_handler(db, agent_id, "echo", "echo")
    let assert Ok(Nil) = db.insert_agent_handler(db, agent_id, "greet", "echo")

    let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, db, agent_id, ctx)

    let assert 2 = dict.size(handlers)
    let assert Ok(_) = dict.get(handlers, "echo")
    let assert Ok(_) = dict.get(handlers, "greet")
  })
}

pub fn resolve_for_agent_skips_unknown_handlers_test() {
  with_db(fn(db) {
    let reg = handler_registry.new()

    let assert Ok(agent_id) =
      db.insert_agent(db, "test_agent", "test", "source", "active")
    let assert Ok(Nil) =
      db.insert_agent_handler(db, agent_id, "fetch", "http_get")

    let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, db, agent_id, ctx)

    // Unknown handler should be skipped
    let assert 0 = dict.size(handlers)
  })
}

pub fn resolve_for_agent_empty_bindings_test() {
  with_db(fn(db) {
    let reg = handler_registry.new()

    let assert Ok(agent_id) =
      db.insert_agent(db, "test_agent", "test", "source", "active")

    let ctx = handler_registry.make_context(option.None, fn(_) { Nil })
    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, db, agent_id, ctx)

    let assert 0 = dict.size(handlers)
  })
}
