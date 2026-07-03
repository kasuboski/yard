//// Integration test: Pig Bridge PostgreSQL event store.
////
//// Requires: docker container running with durable_schema.sql applied.

import gabsurd/client
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import parrot/dev
import pig/ai/error
import pig/ai/message
import pig/ai/stop_reason
import pig/obs/events
import testing
import yard/obs/pig_events

pub fn main() {
  gleeunit.main()
}

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_pg_db(fn(db) {
    testing.clean_durable(db)
    test_fn(db)
  })
}

/// Read back the event_type column for a run_id, ordered as written.
fn list_event_types(db: client.Db, run_id: String) -> List(String) {
  let sql =
    "SELECT event_type FROM pig_events WHERE run_id::text = $1 ORDER BY created_at ASC"
  case
    client.query_many(db, #(
      sql,
      [dev.ParamString(run_id)],
      event_type_decoder(),
    ))
  {
    Ok(rows) -> rows
    Error(_) -> []
  }
}

fn event_type_decoder() -> decode.Decoder(String) {
  use event_type <- decode.field(0, decode.string)
  decode.success(event_type)
}

fn make_run_id() -> String {
  "00000000-0000-0000-0000-000000000001"
}

pub fn record_session_started_test() {
  with_db(fn(db) {
    let event =
      events.SessionStarted(
        agent_id: option.Some("agent-1"),
        agent_name: option.Some("Test Agent"),
        model: "gpt-4",
        provider_name: option.Some("openai"),
        system_prompt: option.Some("You are helpful."),
      )
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: make_run_id(),
      event:,
    ))
  })
}

pub fn record_inference_completed_with_duration_test() {
  with_db(fn(db) {
    let event =
      events.InferenceCompleted(
        message: message.Assistant(
          content: "Hello!",
          tool_calls: [],
          thinking: option.None,
          stop_reason: option.Some(stop_reason.Stop),
        ),
        response_id: option.Some("resp-123"),
        response_model: option.Some("gpt-4"),
        stop_reason: option.Some(stop_reason.Stop),
        input_tokens: option.Some(10),
        output_tokens: option.Some(5),
        duration_ms: 42,
        input_messages: [message.User(content: "Hi")],
      )
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: make_run_id(),
      event:,
    ))
  })
}

pub fn record_tool_executed_test() {
  with_db(fn(db) {
    let tool_call =
      message.ToolCall(
        id: "call-1",
        name: "search",
        arguments_json: "{\"query\":\"test\"}",
      )
    let event =
      events.ToolExecuted(
        tool_call:,
        result: "found 3 results",
        duration_ms: 15,
      )
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: make_run_id(),
      event:,
    ))
  })
}

pub fn record_all_session_event_types_test() {
  with_db(fn(db) {
    let rid = make_run_id()
    let tool_call =
      message.ToolCall(
        id: "call-1",
        name: "search",
        arguments_json: "{\"query\":\"test\"}",
      )

    // Every variant must serialize + insert successfully. Asserting each
    // Ok (rather than discarding with `let _`) so a regression in
    // event_to_parts for any variant is caught.
    let expected_types = [
      "pig.session_started",
      "pig.inference_started",
      "pig.inference_completed",
      "pig.tool_started",
      "pig.tool_executed",
      "pig.tool_blocked",
      "pig.hook_acted",
      "pig.inference_failed",
      "pig.session_ended",
    ]

    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.SessionStarted(
        agent_id: option.None,
        agent_name: option.None,
        model: "gpt-4",
        provider_name: option.None,
        system_prompt: option.None,
      ),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.InferenceStarted(model: "gpt-4", message_count: 2),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.InferenceCompleted(
        message: message.Assistant(
          content: "Done",
          tool_calls: [],
          thinking: option.None,
          stop_reason: option.None,
        ),
        response_id: option.None,
        response_model: option.None,
        stop_reason: option.None,
        input_tokens: option.None,
        output_tokens: option.None,
        duration_ms: 100,
        input_messages: [],
      ),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.ToolStarted(tool_call:),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.ToolExecuted(tool_call:, result: "ok", duration_ms: 10),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.ToolBlocked(
        tool_call:,
        hook_name: "safety",
        reason: "blocked",
      ),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.HookActed(
        hook_name: "audit",
        hook_point: events.BeforeToolCall,
        action: events.HookActionDetail(
          action_type: "log",
          description: "logged tool call",
        ),
      ),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.InferenceFailed(
        error: error.ApiError(message: "rate limit"),
        duration_ms: 50,
        input_messages: [message.User(content: "Hi")],
      ),
    ))
    should.be_ok(pig_events.record_session_event(
      db:,
      run_id: rid,
      event: events.SessionEnded(reason: events.NormalEnd),
    ))

    // Read back the event_type column and assert every expected type landed.
    let recorded = list_event_types(db, rid)
    should.equal(list.length(recorded), list.length(expected_types))
    list.each(expected_types, fn(t) {
      should.be_true(list.contains(recorded, t))
    })
  })
}
