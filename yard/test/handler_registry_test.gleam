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
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import sqlight
import yard/db
import yard/handler_registry
import yard/runner

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
// 1. Registry basics
// ═══════════════════════════════════════════════════════════════

pub fn new_registry_is_empty_test() {
  let reg = handler_registry.new()
  let assert 0 = dict.size(reg.bindings)
}

pub fn register_adds_builder_test() {
  let reg =
    handler_registry.new()
    |> handler_registry.register("echo", echo_builder)
  let assert 1 = dict.size(reg.bindings)
}

pub fn register_multiple_builders_test() {
  let reg =
    handler_registry.new()
    |> handler_registry.register("echo", echo_builder)
    |> handler_registry.register("ws_probe", workspace_probe_builder)
  let assert 2 = dict.size(reg.bindings)
}

pub fn resolve_unknown_handler_returns_error_test() {
  let reg = handler_registry.new()
  let ctx =
    handler_registry.make_context(workspace_conn: option.None, emit: fn(_) {
      Nil
    })
  let result = handler_registry.resolve_one(reg, "nonexistent", ctx)
  let assert Error(_) = result
}

// ═══════════════════════════════════════════════════════════════
// 2. Resolve handlers for an agent
// ═══════════════════════════════════════════════════════════════

pub fn resolve_agent_handlers_from_db_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(
        conn,
        "test-agent",
        "An agent",
        "pub fn main(env) { 42 }",
        "active",
      )

    let assert Ok(Nil) = db.insert_agent_handler(conn, agent_id, "echo", "echo")
    let assert Ok(Nil) =
      db.insert_agent_handler(conn, agent_id, "greet", "echo")

    let reg =
      handler_registry.new()
      |> handler_registry.register("echo", echo_builder)

    let ctx =
      handler_registry.make_context(workspace_conn: option.None, emit: fn(_) {
        Nil
      })

    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, conn, agent_id, ctx)
    let assert 2 = dict.size(handlers)

    // Test the echo handler
    let assert Ok(h) = dict.get(handlers, "echo")
    let assert Ok(value.OkVal(value.StringVal(r1))) =
      h("echo", [value.StringVal("hello")])
    let assert "echo hello" = r1

    // Test the greet handler (same builder, different effect name)
    let assert Ok(h2) = dict.get(handlers, "greet")
    let assert Ok(value.OkVal(value.StringVal(r2))) =
      h2("greet", [value.StringVal("world")])
    let assert "greet world" = r2
  })
}

pub fn resolve_agent_with_missing_builder_skips_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(
        conn,
        "partial-agent",
        "An agent",
        "pub fn main(env) { 42 }",
        "active",
      )

    let assert Ok(Nil) = db.insert_agent_handler(conn, agent_id, "echo", "echo")
    let assert Ok(Nil) =
      db.insert_agent_handler(conn, agent_id, "fetch", "http_get")

    let reg =
      handler_registry.new()
      |> handler_registry.register("echo", echo_builder)

    let ctx =
      handler_registry.make_context(workspace_conn: option.None, emit: fn(_) {
        Nil
      })

    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, conn, agent_id, ctx)
    // Only echo resolved; fetch/http_get skipped
    let assert 1 = dict.size(handlers)
  })
}

pub fn resolve_agent_with_no_handlers_returns_empty_test() {
  with_db(fn(conn) {
    let assert Ok(agent_id) =
      db.insert_agent(
        conn,
        "bare-agent",
        "No handlers",
        "pub fn main(env) { 42 }",
        "active",
      )

    let reg =
      handler_registry.new()
      |> handler_registry.register("echo", echo_builder)

    let ctx =
      handler_registry.make_context(workspace_conn: option.None, emit: fn(_) {
        Nil
      })

    let assert Ok(handlers) =
      handler_registry.resolve_for_agent(reg, conn, agent_id, ctx)
    let assert 0 = dict.size(handlers)
  })
}

// ═══════════════════════════════════════════════════════════════
// 3. Handler context
// ═══════════════════════════════════════════════════════════════

pub fn handler_receives_workspace_context_test() {
  // Provide a workspace connection
  let assert Ok(ws_conn) = sqlight.open("file::memory:")

  let reg =
    handler_registry.new()
    |> handler_registry.register("ws_probe", workspace_probe_builder)

  let ctx =
    handler_registry.make_context(
      workspace_conn: option.Some(ws_conn),
      emit: fn(_) { Nil },
    )

  let assert Ok(built) = handler_registry.resolve_one(reg, "ws_probe", ctx)
  let assert Ok(value.OkVal(value.StringVal("has_workspace"))) =
    built("ws_probe", [])
}

pub fn handler_receives_no_workspace_context_test() {
  let reg =
    handler_registry.new()
    |> handler_registry.register("ws_probe", workspace_probe_builder)

  let ctx =
    handler_registry.make_context(workspace_conn: option.None, emit: fn(_) {
      Nil
    })

  let assert Ok(built) = handler_registry.resolve_one(reg, "ws_probe", ctx)
  let assert Ok(value.OkVal(value.StringVal("no_workspace"))) =
    built("ws_probe", [])
}
