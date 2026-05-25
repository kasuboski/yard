//// Handler registry — maps handler names to builder functions.
////
//// The cron engine uses this to resolve per-agent handler bindings
//// from the `agent_handlers` table into actual EffectHandler closures.
////
//// Pattern:
////   1. Each agent has handler bindings in agent_handlers:
////      (effect_name="fetch_issue", handler_name="http_get_handler")
////   2. The registry maps handler_name → builder function:
////      "http_get_handler" → fn(ctx) { fn(name, args) { ... } }
////   3. When resolving, each binding produces an EffectHandler keyed
////      by its effect_name, so the chute actor sees the right names.
////
//// This is the generalized version of what issue_triage does by hand:
//// building a handler dict per invocation from domain-specific handlers.

import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import logging
import sqlight
import yard/db
import yard/obs/events.{type HostEvent}
import yard/runner.{type EffectHandler}

// ═══════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════

/// A builder function that receives context and produces an EffectHandler.
/// The context provides workspace (VFS/KV) connections, emit callback,
/// and any config the builder needs.
pub type HandlerBuilder =
  fn(HandlerContext) -> EffectHandler

/// Context passed to handler builders. Provides shared resources.
pub type HandlerContext {
  HandlerContext(
    /// Workspace DB connection (for VFS/KV handlers).
    /// None when no workspace is available.
    workspace_conn: option.Option(sqlight.Connection),
    /// Emit callback for observability events.
    emit: fn(HostEvent) -> Nil,
  )
}

/// The registry: maps handler names (strings) to builder functions.
pub type HandlerRegistry {
  HandlerRegistry(bindings: dict.Dict(String, HandlerBuilder))
}

// ═══════════════════════════════════════════════════════════════
// Constructors
// ═══════════════════════════════════════════════════════════════

/// Create an empty handler registry.
pub fn new() -> HandlerRegistry {
  HandlerRegistry(bindings: dict.new())
}

/// Create a handler context with the given resources.
pub fn make_context(
  workspace_conn workspace_conn: option.Option(sqlight.Connection),
  emit emit: fn(HostEvent) -> Nil,
) -> HandlerContext {
  HandlerContext(workspace_conn:, emit:)
}

// ═══════════════════════════════════════════════════════════════
// Registration
// ═══════════════════════════════════════════════════════════════

/// Register a handler builder under a name.
/// The name is what appears in agent_handlers.handler_name.
pub fn register(
  registry: HandlerRegistry,
  name: String,
  builder: HandlerBuilder,
) -> HandlerRegistry {
  HandlerRegistry(bindings: dict.insert(registry.bindings, name, builder))
}

// ═══════════════════════════════════════════════════════════════
// Resolution
// ═══════════════════════════════════════════════════════════════

/// Resolve a single handler by name. Returns Error(Nil) if not found.
pub fn resolve_one(
  registry: HandlerRegistry,
  handler_name: String,
  ctx: HandlerContext,
) -> Result(EffectHandler, Nil) {
  case dict.get(registry.bindings, handler_name) {
    Ok(builder) -> Ok(builder(ctx))
    Error(_) -> Error(Nil)
  }
}

/// Resolve all handlers for an agent from the agent_handlers table.
///
/// Loads the agent's handler bindings, resolves each handler_name
/// through the registry, and returns a dict keyed by effect_name.
/// Bindings whose handler_name isn't in the registry are silently skipped
/// (logged as a warning).
pub fn resolve_for_agent(
  registry: HandlerRegistry,
  conn: sqlight.Connection,
  agent_id: String,
  ctx: HandlerContext,
) -> Result(dict.Dict(String, EffectHandler), Nil) {
  case db.get_agent_handlers(conn, agent_id) {
    Ok(bindings) -> {
      let handlers =
        bindings
        |> list.filter_map(fn(binding) {
          case resolve_one(registry, binding.handler_name, ctx) {
            Ok(handler) -> Ok(#(binding.effect_name, handler))
            Error(_) -> {
              logging.log(
                logging.Warning,
                "handler_registry: unknown handler '"
                  <> binding.handler_name
                  <> "' for effect '"
                  <> binding.effect_name
                  <> "'",
              )
              Error(Nil)
            }
          }
        })
      Ok(dict.from_list(handlers))
    }
    Error(_) -> Error(Nil)
  }
}
