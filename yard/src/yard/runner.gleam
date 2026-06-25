//// The runner — generic effect loop over ballast.
////
//// A thin layer over ballast's `start_program_with_env` → `Yielded` → `resume`
//// cycle. Handles every yield/resume, emits observability events, and returns
//// the final result.
////
//// This is the ONLY place where ballast's yield/resume is consumed as a loop.
//// Everything else (triggers, tests, inner programs) calls `run(config)`.
////
//// The runner has zero knowledge of specific effects or triggers.
//// Effect names are strings. Trigger types are strings. Handlers are a dict.
//// Observability is baked in — you can't forget it.
////
//// Durability is delegated to a `DurableStore` — the runner calls
//// `store.lookup`/`store.record` and never touches checkpoints or codecs.
//// Error policy: lookup is best-effort, record is a guarantee (ADR-0001).
////
//// Observability is a single callback: `emit: fn(HostEvent) -> Nil`.
//// Production closes over a dispatcher Subject via `emit_to_dispatcher()`.
//// Tests build their own (e.g. `fn(e) { process.send(subject, e) }`).

import ballast
import ballast/effect.{type EvalResult, EvalDone, EvalError, Yielded}
import ballast/value
import chute/ast.{type Program}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/string
import yard/durability.{type DurableStore}
import yard/obs/dispatcher.{type DispatcherMessage}
import yard/obs/emit
import yard/obs/events.{type HostEvent}

// ═══════════════════════════════════════════════════════════════════════
// Public Types
// ═══════════════════════════════════════════════════════════════════════

/// A handler for a named effect. Pure function.
///
/// Takes the effect name and argument list, returns a result.
/// The runner looks up handlers by effect name in the handlers dict.
pub type EffectHandler =
  fn(String, List(value.Value)) -> Result(value.Value, value.RuntimeError)

/// Configuration for a single actor run.
///
/// Every invocation — webhooks, cron, tests, inner programs — builds one
/// of these and passes it to `run()`.
pub type RunConfig {
  RunConfig(
    /// The compiled chute program (desugared AST).
    program: Program,
    /// Initial environment value (e.g. webhook payload).
    env: value.Value,
    /// Gas limit for this run.
    gas: Int,
    /// Effect handlers, keyed by effect name.
    handlers: Dict(String, EffectHandler),
    /// Emit callback for observability events.
    /// In production: sends to dispatcher. In tests: captures in a list/subject.
    emit: fn(HostEvent) -> Nil,
    /// File path of the actor source (e.g. "actors/triage.chute").
    actor_path: String,
    /// SHA-256 of canonical S-expression, first 8 hex chars.
    /// Identifies the actor version — same source always produces same hash.
    actor_hash: String,
    /// Unique ID for this invocation. Correlates all events in a trace.
    run_id: String,
    /// What triggered this run (e.g. "webhook", "cron", "test").
    trigger_type: String,
    /// Source detail (e.g. "github", "schedule:5m").
    trigger_source: String,
    /// 0 = outer actor, 1+ = inner chute (via chute_exec).
    depth: Int,
    /// Durable store for effect result replay/record.
    /// Use `durability.none()` for non-durable runs (behaves as before).
    /// Use `durability.from_checkpointer(cp)` for durable runs.
    store: DurableStore,
  )
}

// ═══════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════

/// Create an emit callback that sends events to the shared dispatcher.
///
/// Use this in production to wire the runner into the full observability
/// stack (telemetry + session writer + terminal printer).
pub fn emit_to_dispatcher(
  dispatcher: Subject(DispatcherMessage),
) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) { emit.to_dispatcher(dispatcher, event) }
}

/// Run a chute actor to completion.
///
/// Handles every yield/resume cycle. Emits ActorStarted at the beginning
/// and ActorCompleted at the end — always, even on errors.
/// Returns the final ballast value or a runtime error.
pub fn run(config: RunConfig) -> Result(value.Value, value.RuntimeError) {
  config.emit(events.ActorStarted(
    actor_path: config.actor_path,
    actor_hash: config.actor_hash,
    trigger_type: config.trigger_type,
    trigger_source: config.trigger_source,
    run_id: config.run_id,
    gas: config.gas,
    depth: config.depth,
  ))

  let start_time = events.system_time()

  let initial_result =
    ballast.start_program_with_env(config.program, config.env, config.gas)

  run_loop(config, initial_result, start_time, 0)
}

// ═══════════════════════════════════════════════════════════════════════
// Internal — Loop
// ═══════════════════════════════════════════════════════════════════════

fn run_loop(
  config: RunConfig,
  eval_result: EvalResult,
  start_time: Int,
  effects_count: Int,
) -> Result(value.Value, value.RuntimeError) {
  case eval_result {
    EvalDone(value, remaining_gas) -> {
      complete(
        config,
        start_time,
        Ok(value),
        config.gas - remaining_gas,
        effects_count,
      )
    }

    EvalError(error) -> {
      complete(config, start_time, Error(error), config.gas, effects_count)
    }

    Yielded(effect_name, args, cont, remaining_gas) -> {
      handle_yield(
        config,
        effect_name,
        args,
        cont,
        remaining_gas,
        start_time,
        effects_count,
      )
    }
  }
}

fn handle_yield(
  config: RunConfig,
  effect_name: String,
  args: List(value.Value),
  cont: effect.Continuation,
  gas_remaining: Int,
  start_time: Int,
  effects_count: Int,
) -> Result(value.Value, value.RuntimeError) {
  // Replay path: lookup is best-effort (ADR-0001).
  // Ok(Some(v)) → replay; Ok(None) or Error(_) → fresh execution.
  case config.store.lookup(effects_count, effect_name) {
    Ok(option.Some(stored_value)) -> {
      config.emit(events.EffectReplayed(
        actor_path: config.actor_path,
        actor_hash: config.actor_hash,
        run_id: config.run_id,
        effect_name:,
        step: effects_count,
        depth: config.depth,
      ))
      let resumed = ballast.resume(cont, stored_value)
      run_loop(config, resumed, start_time, effects_count + 1)
    }
    _ -> {
      // No stored value, or store unreadable — fresh execution
      run_fresh_yield(
        config,
        effect_name,
        args,
        cont,
        gas_remaining,
        start_time,
        effects_count,
      )
    }
  }
}

/// Run the handler fresh, then record the result (strict — ADR-0001).
fn run_fresh_yield(
  config: RunConfig,
  effect_name: String,
  args: List(value.Value),
  cont: effect.Continuation,
  gas_remaining: Int,
  start_time: Int,
  effects_count: Int,
) -> Result(value.Value, value.RuntimeError) {
  config.emit(events.EffectYielded(
    actor_path: config.actor_path,
    actor_hash: config.actor_hash,
    run_id: config.run_id,
    effect_name:,
    args_summary: summarize_args(args),
    depth: config.depth,
  ))

  let effect_start = events.system_time()

  case dict.get(config.handlers, effect_name) {
    Error(_) -> {
      let error = value.RuntimeError("Unknown effect: " <> effect_name)
      complete(
        config,
        start_time,
        Error(error),
        config.gas - gas_remaining,
        effects_count + 1,
      )
    }

    Ok(handler) -> {
      case handler(effect_name, args) {
        Error(error) -> {
          complete(
            config,
            start_time,
            Error(error),
            config.gas - gas_remaining,
            effects_count + 1,
          )
        }

        Ok(handler_result) -> {
          let effect_duration = events.system_time() - effect_start

          config.emit(events.EffectHandled(
            actor_path: config.actor_path,
            actor_hash: config.actor_hash,
            run_id: config.run_id,
            effect_name:,
            result_summary: summarize_value(handler_result),
            duration_ms: effect_duration,
            depth: config.depth,
          ))

          // Record is a guarantee (ADR-0001): a store failure surfaces.
          case config.store.record(effects_count, effect_name, handler_result) {
            Ok(Nil) -> {
              let resumed = ballast.resume(cont, handler_result)
              run_loop(config, resumed, start_time, effects_count + 1)
            }
            Error(e) -> {
              let error =
                value.RuntimeError(
                  "durability: " <> durability.error_to_string(e),
                )
              complete(
                config,
                start_time,
                Error(error),
                config.gas - gas_remaining,
                effects_count + 1,
              )
            }
          }
        }
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Internal — Completion
// ═══════════════════════════════════════════════════════════════════════

fn complete(
  config: RunConfig,
  start_time: Int,
  result: Result(value.Value, value.RuntimeError),
  gas_used: Int,
  effects_performed: Int,
) -> Result(value.Value, value.RuntimeError) {
  let result_string = case result {
    Ok(v) -> summarize_value(v)
    Error(e) -> "Error(" <> value.error_to_string(e) <> ")"
  }

  config.emit(events.ActorCompleted(
    actor_path: config.actor_path,
    actor_hash: config.actor_hash,
    run_id: config.run_id,
    result: result_string,
    gas_used:,
    gas_limit: config.gas,
    effects_performed:,
    duration_ms: events.system_time() - start_time,
  ))

  result
}

// ═══════════════════════════════════════════════════════════════════════
// Internal — Value Summarization
// ═══════════════════════════════════════════════════════════════════════

/// Create a short summary of a ballast value for event data.
pub fn summarize_value(v: value.Value) -> String {
  let s = value.value_to_string(v)
  truncate(s, 80)
}

/// Create a short summary of an argument list.
pub fn summarize_args(args: List(value.Value)) -> String {
  args
  |> list.map(summarize_value)
  |> string.join(", ")
}

fn truncate(s: String, max_len: Int) -> String {
  case string.length(s) > max_len {
    True -> {
      let prefix = string.slice(s, 0, max_len - 3)
      prefix <> "..."
    }
    False -> s
  }
}
