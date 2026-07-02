//// Pig Bridge — captures pig SessionEvents into the pig_events PostgreSQL table.
////
//// Stores pig's rich agent-internal events (token usage, tool calls,
//// inference timing) separately from yard_events. The two tables are
//// correlated at query time by run_id only.

import gabsurd/client.{type Db}
import gleam/erlang/process.{type Name, type Subject, new_name, spawn_unlinked}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import logging
import parrot/dev
import pig/ai/error.{
  type AiError, ApiError, InvalidResponse, RateLimited, Timeout,
}
import pig/ai/message.{
  type Message, type ToolCall, Assistant, System, Thinking, Tool, User,
}
import pig/ai/stop_reason
import pig/obs/consumer_spec
import pig/obs/events.{
  type HookPoint, type SessionEndReason, type SessionEvent, AfterInference,
  AfterToolCall, BeforeInference, BeforeToolCall, ErrorEnd, HookActed,
  InferenceCompleted, InferenceFailed, InferenceStarted, Interrupted,
  MaxIterationsExceeded, NormalEnd, OnComplete, OnError, OnSessionShutdown,
  OnSessionStart, SessionEnded, SessionStarted, ToolBlocked, ToolExecuted,
  ToolStarted,
}

/// Record a SessionEvent to the pig_events table.
pub fn record_session_event(
  db db: Db,
  run_id run_id: String,
  event event: SessionEvent,
) -> Result(Nil, EventStoreError) {
  let #(event_type, payload, duration_ms) = event_to_parts(event)
  let sql =
    "
    INSERT INTO pig_events (run_id, event_type, payload, duration_ms)
    VALUES ($1::uuid, $2, $3::jsonb, $4)
    "
  case
    client.exec(
      db,
      #(sql, [
        dev.ParamString(run_id),
        dev.ParamString(event_type),
        dev.ParamString(json.to_string(payload)),
        dev.ParamNullable(case duration_ms {
          Some(ms) -> Some(dev.ParamInt(ms))
          None -> None
        }),
      ]),
    )
  {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(EventStoreError(error_to_string(e)))
  }
}

/// Error type for the pig event store.
pub type EventStoreError {
  EventStoreError(String)
}

// ── State ────────────────────────────────────────────────────────────

type State {
  State(db: Db, run_id: String, actor_path: String, actor_hash: String)
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a pig_events consumer actor that writes SessionEvents to pig_events.
/// Returns the Subject for registration with pig's dispatcher.
pub fn start_consumer(
  db: Db,
  run_id: String,
  actor_path: String,
  actor_hash: String,
) -> Result(Subject(SessionEvent), StartError) {
  let builder =
    actor.new(State(db:, run_id:, actor_path:, actor_hash:))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised pig_events consumer actor for use in a supervision tree.
pub fn supervised(
  db: Db,
  run_id: String,
  actor_path: String,
  actor_hash: String,
  name: Name(SessionEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(db:, run_id:, actor_path:, actor_hash:))
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

/// Build a pig ConsumerSpec for registration with pig's config.
pub fn consumer_spec(
  db: Db,
  run_id: String,
  actor_path: String,
  actor_hash: String,
) -> consumer_spec.ConsumerSpec {
  let name = new_name("yard_pig_events")
  let spec = supervised(db, run_id, actor_path, actor_hash, name)
  let start_fn = fn() { start_consumer(db, run_id, actor_path, actor_hash) }
  consumer_spec.ConsumerSpec(spec:, name:, start_fn:)
}

// ── Actor Implementation ─────────────────────────────────────────────

fn handle_message(
  state: State,
  event: SessionEvent,
) -> actor.Next(State, SessionEvent) {
  // Fire-and-forget: run the write in an unlinked process so a pool crash
  // (e.g. `pgo_pool:checkout` exiting with `noproc` during teardown, or any
  // other exit raised inside `client.exec`) dies there and never propagates
  // back to crash this consumer. Observability is best-effort — a write that
  // fails or crashes is silently dropped. Pig emits late events
  // (SessionEnded, etc.) after the caller stops the agent, so the consumer
  // must survive writes against a pool that is already torn down.
  let db = state.db
  let run_id = state.run_id
  process.spawn_unlinked(fn() {
    case record_session_event(db:, run_id:, event:) {
      Ok(_) -> Nil
      Error(_) ->
        logging.log(
          logging.Error,
          "pig_events: failed to write event to pig_events",
        )
    }
  })
  actor.continue(state)
}

// ── Event Serialization ──────────────────────────────────────────────

fn event_to_parts(event: SessionEvent) -> #(String, json.Json, Option(Int)) {
  case event {
    SessionStarted(
      agent_id:,
      agent_name:,
      model:,
      provider_name:,
      system_prompt:,
    ) -> #(
      "pig.session_started",
      session_started_payload(
        agent_id,
        agent_name,
        model,
        provider_name,
        system_prompt,
      ),
      None,
    )

    InferenceStarted(model:, message_count:) -> #(
      "pig.inference_started",
      json.object([
        #("model", json.string(model)),
        #("message_count", json.int(message_count)),
      ]),
      None,
    )

    InferenceCompleted(
      message:,
      response_id:,
      response_model:,
      stop_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages:,
    ) -> #(
      "pig.inference_completed",
      inference_completed_payload(
        message,
        response_id,
        response_model,
        stop_reason,
        input_tokens,
        output_tokens,
        duration_ms,
        input_messages,
      ),
      Some(duration_ms),
    )

    ToolStarted(tool_call:) -> #(
      "pig.tool_started",
      json.object([#("tool_call", tool_call_to_json(tool_call))]),
      None,
    )

    ToolExecuted(tool_call:, result:, duration_ms:) -> #(
      "pig.tool_executed",
      json.object([
        #("duration_ms", json.int(duration_ms)),
        #("tool_call", tool_call_to_json(tool_call)),
        #("result", json.string(result)),
      ]),
      Some(duration_ms),
    )

    ToolBlocked(tool_call:, hook_name:, reason:) -> #(
      "pig.tool_blocked",
      json.object([
        #("tool_call", tool_call_to_json(tool_call)),
        #("hook_name", json.string(hook_name)),
        #("reason", json.string(reason)),
      ]),
      None,
    )

    HookActed(hook_name:, hook_point:, action:) -> #(
      "pig.hook_acted",
      json.object([
        #("hook_name", json.string(hook_name)),
        #("hook_point", json.string(hook_point_to_string(hook_point))),
        #(
          "action",
          json.object([
            #("action_type", json.string(action.action_type)),
            #("description", json.string(action.description)),
          ]),
        ),
      ]),
      None,
    )

    InferenceFailed(error:, duration_ms:, input_messages:) -> #(
      "pig.inference_failed",
      json.object([
        #("duration_ms", json.int(duration_ms)),
        #("error", error_to_json(error)),
        #("input_messages", json.array(input_messages, message_to_json)),
      ]),
      Some(duration_ms),
    )

    SessionEnded(reason:) -> #(
      "pig.session_ended",
      json.object([#("reason", reason_to_json(reason))]),
      None,
    )
  }
}

fn session_started_payload(
  agent_id: Option(String),
  agent_name: Option(String),
  model: String,
  provider_name: Option(String),
  system_prompt: Option(String),
) -> json.Json {
  let fields = [#("model", json.string(model))]
  let with_agent_id = case agent_id {
    Some(v) -> list.append(fields, [#("agent_id", json.string(v))])
    None -> fields
  }
  let with_agent_name = case agent_name {
    Some(v) -> list.append(with_agent_id, [#("agent_name", json.string(v))])
    None -> with_agent_id
  }
  let with_provider = case provider_name {
    Some(v) ->
      list.append(with_agent_name, [#("provider_name", json.string(v))])
    None -> with_agent_name
  }
  let with_system = case system_prompt {
    Some(v) -> list.append(with_provider, [#("system_prompt", json.string(v))])
    None -> with_provider
  }
  json.object(with_system)
}

fn inference_completed_payload(
  message: Message,
  response_id: Option(String),
  response_model: Option(String),
  stop_reason: Option(stop_reason.StopReason),
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  duration_ms: Int,
  input_messages: List(Message),
) -> json.Json {
  let fields = [
    #("duration_ms", json.int(duration_ms)),
    #("message", message_to_json(message)),
    #("input_messages", json.array(input_messages, message_to_json)),
  ]
  let with_response_id = case response_id {
    Some(v) -> list.append(fields, [#("response_id", json.string(v))])
    None -> fields
  }
  let with_response_model = case response_model {
    Some(v) ->
      list.append(with_response_id, [#("response_model", json.string(v))])
    None -> with_response_id
  }
  let with_stop_reason = case stop_reason {
    Some(v) ->
      list.append(with_response_model, [
        #("stop_reason", stop_reason.to_json(v)),
      ])
    None -> with_response_model
  }
  let with_input_tokens = case input_tokens {
    Some(v) -> list.append(with_stop_reason, [#("input_tokens", json.int(v))])
    None -> with_stop_reason
  }
  let with_output_tokens = case output_tokens {
    Some(v) -> list.append(with_input_tokens, [#("output_tokens", json.int(v))])
    None -> with_input_tokens
  }
  json.object(with_output_tokens)
}

fn message_to_json(msg: Message) -> json.Json {
  case msg {
    User(content:) -> {
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ])
    }
    System(content:) -> {
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ])
    }
    Assistant(content:, tool_calls:, thinking:, stop_reason:) -> {
      let base_fields = [
        #("role", json.string("assistant")),
        #("content", json.string(content)),
        #("tool_calls", json.array(tool_calls, tool_call_to_json)),
      ]
      let fields_with_thinking = case thinking {
        Some(t) -> {
          case t {
            Thinking(content:) -> {
              list.append(base_fields, [
                #("thinking", json.object([#("content", json.string(content))])),
              ])
            }
          }
        }
        None -> base_fields
      }
      let fields_with_stop_reason = case stop_reason {
        Some(sr) ->
          list.append(fields_with_thinking, [
            #("stop_reason", stop_reason.to_json(sr)),
          ])
        None -> fields_with_thinking
      }
      json.object(fields_with_stop_reason)
    }
    Tool(tool_call_id:, content:) -> {
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string(content)),
      ])
    }
  }
}

fn tool_call_to_json(tc: ToolCall) -> json.Json {
  json.object([
    #("id", json.string(tc.id)),
    #("name", json.string(tc.name)),
    #("arguments", json.string(tc.arguments_json)),
  ])
}

fn error_to_json(err: AiError) -> json.Json {
  case err {
    ApiError(message:) -> {
      json.object([
        #("type", json.string("api_error")),
        #("message", json.string(message)),
      ])
    }
    RateLimited -> {
      json.object([#("type", json.string("rate_limited"))])
    }
    Timeout -> {
      json.object([#("type", json.string("timeout"))])
    }
    InvalidResponse(detail:) -> {
      json.object([
        #("type", json.string("invalid_response")),
        #("detail", json.string(detail)),
      ])
    }
  }
}

fn reason_to_json(reason: SessionEndReason) -> json.Json {
  case reason {
    NormalEnd -> {
      json.object([#("type", json.string("normal_end"))])
    }
    ErrorEnd(e) -> {
      json.object([
        #("type", json.string("error")),
        #("error", error_to_json(e)),
      ])
    }
    MaxIterationsExceeded(n) -> {
      json.object([
        #("type", json.string("max_iterations_exceeded")),
        #("max_iterations", json.int(n)),
      ])
    }
    Interrupted -> {
      json.object([#("type", json.string("interrupted"))])
    }
  }
}

fn hook_point_to_string(hook: HookPoint) -> String {
  case hook {
    BeforeToolCall -> "before_tool_call"
    AfterToolCall -> "after_tool_call"
    BeforeInference -> "before_inference"
    AfterInference -> "after_inference"
    OnError -> "on_error"
    OnComplete -> "on_complete"
    OnSessionStart -> "on_session_start"
    OnSessionShutdown -> "on_session_shutdown"
  }
}

fn error_to_string(e: client.GabsurdError) -> String {
  case e {
    client.QueryError(msg) -> "query: " <> msg
    client.UnexpectedRowCount(msg) -> "row count: " <> msg
    client.NotFound -> "not found"
    client.ConnectionError(msg) -> "connection: " <> msg
  }
}
