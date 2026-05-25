//// chute_exec — the Pig tool that runs Chute source code in Ballast via Yard.
////
//// This is the core bridge between Pig (agent) and Yard (runner).
//// The LLM generates Chute programs as tool calls; this module
//// executes them in Ballast's sandboxed evaluator.

import ballast/value.{type Value}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import jscheam/schema
import pig/ai/tool_definition.{ToolDefinition}
import pig/tool.{type Tool, type ToolError, Tool, ToolError}
import sqlight
import yard/loader
import yard/obs/events.{type HostEvent}
import yard/runner.{RunConfig}

import hermes_agent/effects
import hermes_agent/value_bridge

/// Gas limit for each chute_exec run.
const gas_limit = 10_000

/// Configuration for a chute_exec invocation.
/// Closes over workspace connection, emit callback, and settings.
pub type ChuteExecConfig {
  ChuteExecConfig(conn: sqlight.Connection, emit: fn(HostEvent) -> Nil)
}

/// Create a new config from a workspace connection and emit callback.
pub fn config(
  conn: sqlight.Connection,
  emit: fn(HostEvent) -> Nil,
) -> ChuteExecConfig {
  ChuteExecConfig(conn:, emit:)
}

/// Create a config with no Yard observability (silent).
pub fn silent_config(conn: sqlight.Connection) -> ChuteExecConfig {
  ChuteExecConfig(conn:, emit: fn(_) { Nil })
}

/// Run a Chute program and return the result as JSON.
///
/// This is the core function — it:
/// 1. Parses the Chute source
/// 2. Loads it as a Yard actor
/// 3. Builds RunConfig with Hermes effect handlers
/// 4. Runs it in Ballast
/// 5. Captures emit_event payloads and gas_used
/// 6. Returns structured JSON response
pub fn run(
  cfg: ChuteExecConfig,
  source: String,
  env: Value,
) -> Result(json.Json, Nil) {
  // Create an event collector for this run
  let collector = effects.new_event_collector()

  // Build emit callback that forwards to Yard and captures gas
  let emit = effects.emit_with_collector(cfg.emit, collector)

  // Build effect handlers
  let handlers = effects.all_handlers(cfg.conn, collector)

  // Parse, run, collect results, then stop the collector
  let response = case loader.load(source, "hermes/chute_exec.chute") {
    Error(msg) ->
      Ok(
        json.object([
          #(
            "error",
            json.object([
              #("message", json.string(msg)),
              #("type", json.string("parse")),
            ]),
          ),
        ]),
      )
    Ok(actor) -> {
      let run_config =
        RunConfig(
          program: actor.program,
          env:,
          gas: gas_limit,
          handlers:,
          emit:,
          actor_path: actor.actor_path,
          actor_hash: actor.actor_hash,
          run_id: "hermes_chute_exec",
          trigger_type: "tool_call",
          trigger_source: "chute_exec",
          depth: 0,
        )

      case runner.run(run_config) {
        Ok(result) -> {
          let events = effects.collector_events(collector)
          let gas_used = effects.collector_gas_used(collector)
          Ok(
            json.object([
              #("ok", value_bridge.ballast_to_json(result)),
              #("gas_used", json.int(gas_used)),
              #(
                "events",
                json.preprocessed_array(
                  list.map(events, fn(event) {
                    let #(name, payload) = event
                    json.object([
                      #("name", json.string(name)),
                      #("payload", json.string(payload)),
                    ])
                  }),
                ),
              ),
            ]),
          )
        }
        Error(err) ->
          Ok(
            json.object([
              #(
                "error",
                json.object([
                  #("message", json.string(value.error_to_string(err))),
                  #("type", json.string("runtime")),
                ]),
              ),
            ]),
          )
      }
    }
  }

  // Stop the collector actor to release the process
  effects.collector_stop(collector)

  response
}

/// Create a Pig Tool definition for chute_exec.
/// This wraps our `run` function as a tool the LLM can call.
pub fn tool(cfg: ChuteExecConfig) -> Tool {
  let definition =
    ToolDefinition(
      name: "chute_exec",
      description: "Execute a Chute program in a sandboxed evaluator (gas limit: "
        <> int.to_string(gas_limit)
        <> "). Write Chute source code to perform tasks like reading/writing files, emitting thought events, and recalling/storing data.",
      parameters: schema.object([
        schema.prop("source", schema.string()),
        schema.description(
          schema.optional(schema.prop(
            "env",
            schema.allow_additional_props(schema.object([])),
          )),
          "JSON object passed as the env parameter to main()",
        ),
      ]),
    )

  let handler = fn(args: dynamic.Dynamic) -> Result(json.Json, ToolError) {
    use source <- result.try(
      decode.run(
        args,
        decode.field("source", decode.string, fn(source) {
          decode.success(source)
        }),
      )
      |> result.replace_error(ToolError(
        message: "Missing or invalid 'source' parameter",
      )),
    )

    let env_dynamic =
      decode.run(
        args,
        decode.field("env", decode.dynamic, fn(env) { decode.success(env) }),
      )
      |> result.unwrap(dynamic.properties([]))
    let env_value =
      value_bridge.dynamic_to_value(env_dynamic)
      |> result.unwrap(value.RecordVal([]))

    case run(cfg, source, env_value) {
      Ok(json_response) -> Ok(json_response)
      Error(Nil) ->
        Error(ToolError(message: "Failed to execute Chute program"))
    }
  }

  Tool(definition:, handler:)
}
