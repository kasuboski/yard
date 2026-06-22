//// chute_exec — the Pig tool that runs Chute source code in Ballast via Yard.
////
//// This is the core bridge between Pig (agent) and Yard (runner).
//// The LLM generates Chute programs as tool calls; this module
//// executes them in Ballast's sandboxed evaluator.

import ballast/value.{type Value}
import birl
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gluid
import jscheam/schema
import pig/ai/tool_definition.{ToolDefinition}
import pig/tool.{type Tool, type ToolError, Tool, ToolError}
import sqlight
import yard/db
import yard/loader
import yard/obs/events.{type HostEvent}
import yard/runner.{RunConfig}

import hermes_agent/effects
import hermes_agent/value_bridge

/// Gas limit for each chute_exec run.
const gas_limit = 10_000

/// Configuration for a chute_exec invocation.
/// Closes over workspace connection, emit callback, and optional global DB.
pub type ChuteExecConfig {
  ChuteExecConfig(
    conn: sqlight.Connection,
    emit: fn(HostEvent) -> Nil,
    /// Optional global DB connection for run tracking.
    /// If present, each run is recorded in the runs table.
    global_conn: option.Option(sqlight.Connection),
    /// Optional agent ID for run tracking.
    agent_id: option.Option(String),
  )
}

/// Create a new config from a workspace connection and emit callback.
pub fn config(
  conn: sqlight.Connection,
  emit: fn(HostEvent) -> Nil,
) -> ChuteExecConfig {
  ChuteExecConfig(conn:, emit:, global_conn: option.None, agent_id: option.None)
}

/// Create a config with no Yard observability (silent).
pub fn silent_config(conn: sqlight.Connection) -> ChuteExecConfig {
  ChuteExecConfig(
    conn:,
    emit: fn(_) { Nil },
    global_conn: option.None,
    agent_id: option.None,
  )
}

/// Add run tracking to a config.
pub fn with_run_tracking(
  cfg: ChuteExecConfig,
  global_conn: sqlight.Connection,
  agent_id: String,
) -> ChuteExecConfig {
  ChuteExecConfig(
    ..cfg,
    global_conn: option.Some(global_conn),
    agent_id: option.Some(agent_id),
  )
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

  // Generate run ID for tracking
  let run_id = gluid.guidv4() |> string.lowercase()
  let start_ts = birl.to_unix(birl.utc_now())

  // Record run start in global DB if tracking is enabled
  let tracking_agent_id = case cfg.agent_id {
    option.Some(id) -> id
    option.None -> "hermes_chute_exec"
  }
  case cfg.global_conn {
    option.Some(gconn) -> {
      let _ =
        db.insert_run_with_id(
          gconn,
          run_id,
          tracking_agent_id,
          "tool_call",
          "chute_exec",
          "running",
          start_ts,
        )
      Nil
    }
    option.None -> Nil
  }

  // Parse, run, collect results, then stop the collector
  let response = case loader.load(source, "hermes/chute_exec.chute") {
    Error(msg) -> {
      // Record error in global DB
      complete_tracked_run(
        cfg.global_conn,
        run_id,
        "error",
        option.Some(msg),
        0,
      )
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
    }
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
          run_id: run_id,
          trigger_type: "tool_call",
          trigger_source: "chute_exec",
          depth: 0,
          checkpointer: option.None,

      case runner.run(run_config) {
        Ok(result) -> {
          let events = effects.collector_events(collector)
          let gas_used = effects.collector_gas_used(collector)
          let duration = birl.to_unix(birl.utc_now()) - start_ts
          complete_tracked_run(
            cfg.global_conn,
            run_id,
            "completed",
            option.None,
            duration,
          )
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
        Error(err) -> {
          let duration = birl.to_unix(birl.utc_now()) - start_ts
          complete_tracked_run(
            cfg.global_conn,
            run_id,
            "error",
            option.Some(value.error_to_string(err)),
            duration,
          )
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
  }

  // Stop the collector actor to release the process
  effects.collector_stop(collector)

  response
}

/// Complete a tracked run in the global DB (if tracking is enabled).
fn complete_tracked_run(
  global_conn: option.Option(sqlight.Connection),
  run_id: String,
  status: String,
  error_message: option.Option(String),
  duration_ms: Int,
) -> Nil {
  case global_conn {
    option.Some(conn) -> {
      let now = birl.to_unix(birl.utc_now())
      let result = case status {
        "completed" -> option.Some("ok")
        _ -> error_message
      }
      let _ =
        db.complete_run(
          conn,
          run_id,
          status,
          result,
          option.None,
          option.Some(duration_ms),
          option.Some(now),
        )
      Nil
    }
    option.None -> Nil
  }
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
      Error(Nil) -> Error(ToolError(message: "Failed to execute Chute program"))
    }
  }

  Tool(definition:, handler:)
}
