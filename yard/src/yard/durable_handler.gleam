//// Gabsurd worker handler for durable Chute execution.
////
//// This module provides the Handler that gabsurd workers use to execute
//// Chute programs with durable checkpointing. It wires together:
//// - gabsurd context (DB, task params, checkpoints)
//// - yard's runner with the gabsurd checkpointer
//// - yard's handler_registry for effect resolution
////
//// From DURABLE.md Component 6: Handler Registry & Worker Context.

import ballast/value
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gabsurd/context.{type Context}
import gabsurd/worker.{type Handler, type HandlerResult}
import yard/gabsurd_checkpointer
import yard/loader
import yard/obs/events
import yard/runner
import yard/value_codec

/// Parameters passed in a gabsurd task for running a Chute program.
pub type TaskParams {
  TaskParams(
    agent_id: String,
    user_key: String,
    actor_source: String,
    env_json: String,
  )
}

/// Create a gabsurd worker handler for running Chute programs.
///
/// The handler function receives a gabsurd Context. At execution time,
/// it reads agent_id + user_key from task params, resolves handlers from
/// the registry, and runs the Chute program with durability.
pub fn chute_handler(
  run_fn run_fn: fn(Context) -> HandlerResult,
) -> Handler {
  worker.Handler(
    task_name: "run-chute",
    execute: run_fn,
    on_error: option.None,
  )
}

/// Execute a Chute program inside a gabsurd task.
///
/// This is the core handler function. It:
/// 1. Parses task params (agent_id, user_key, actor_source, env_json)
/// 2. Creates a gabsurd-backed Checkpointer from the context
/// 3. Runs the Chute program through yard.runner with durability
///
/// Note: handler resolution must be passed in via `handlers` — this function
/// does not resolve handlers itself. The caller (worker setup code) resolves
/// handlers from agent_id before calling this.
pub fn execute_chute(
  ctx ctx: Context,
  handlers handlers: dict.Dict(String, runner.EffectHandler),
  actor_source actor_source: String,
  emit emit: fn(events.HostEvent) -> Nil,
) -> HandlerResult {
  let assert Ok(actor) = loader.load(actor_source, "agent.chute")

  let cp = gabsurd_checkpointer.from_context(ctx)

  let config =
    runner.RunConfig(
      program: actor.program,
      env: value.NilVal,
      gas: 10_000,
      handlers:,
      emit:,
      actor_path: actor.actor_path,
      actor_hash: actor.actor_hash,
      run_id: context.task_name(ctx),
      trigger_type: "gabsurd",
      trigger_source: "task:" <> context.task_name(ctx),
      depth: 0,
      checkpointer: option.Some(cp),
    )

  case runner.run(config) {
    Ok(result) ->
      worker.Complete(json.object([
        #("ok", json.bool(True)),
        #("result", value_codec.encode(result)),
      ]))
    Error(error) ->
      worker.Complete(json.object([
        #("ok", json.bool(False)),
        #("error", json.string(value.error_to_string(error))),
      ]))
  }
}

/// Parse task params from the gabsurd task's JSON params string.
pub fn parse_params(params_json: String) -> TaskParams {
  let fallback = TaskParams(
    agent_id: "",
    user_key: "",
    actor_source: "",
    env_json: "null",
  )
  case json.parse(params_json, params_decoder()) {
    Ok(p) -> p
    Error(_) -> fallback
  }
}

fn params_decoder() -> decode.Decoder(TaskParams) {
  use agent_id <- decode.field("agent_id", decode.string)
  use user_key <- decode.field("user_key", decode.string)
  use actor_source <- decode.field("actor_source", decode.string)
  use env_json <- decode.optional_field("env_json", "null", decode.string)
  decode.success(TaskParams(
    agent_id:,
    user_key:,
    actor_source:,
    env_json:,
  ))
}
