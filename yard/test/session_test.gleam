//// Session writer tests — JSONL formatting and file IO.

import gleam/list
import gleam/string
import gleeunit
import simplifile
import yard/obs/events.{type HostEvent}
import yard/obs/session

pub fn main() {
  gleeunit.main()
}

// ── Tests: format_event (pure) ───────────────────────────────────────

pub fn format_actor_started_test() {
  let event: HostEvent =
    events.ActorStarted(
      actor_path: "actors/triage.chute",
      actor_hash: "a3f7c2e9",
      trigger_type: "webhook",
      trigger_source: "github",
      run_id: "r_001",
      gas: 50_000,
      depth: 0,
    )

  let json = session.format_event(event)
  let assert True = string.contains(json, "\"event\":\"actor_started\"")
  let assert True =
    string.contains(json, "\"actor_path\":\"actors/triage.chute\"")
  let assert True = string.contains(json, "\"actor_hash\":\"a3f7c2e9\"")
  let assert True = string.contains(json, "\"trigger_type\":\"webhook\"")
  let assert True = string.contains(json, "\"trigger_source\":\"github\"")
  let assert True = string.contains(json, "\"run_id\":\"r_001\"")
  let assert True = string.contains(json, "\"gas\":50000")
  let assert True = string.contains(json, "\"depth\":0")
}

pub fn format_actor_completed_test() {
  let event: HostEvent =
    events.ActorCompleted(
      actor_path: "actors/triage.chute",
      actor_hash: "a3f7c2e9",
      run_id: "r_001",
      result: "Nil",
      gas_used: 65,
      gas_limit: 50_000,
      effects_performed: 3,
      duration_ms: 6200,
    )

  let json = session.format_event(event)
  let assert True = string.contains(json, "\"event\":\"actor_completed\"")
  let assert True = string.contains(json, "\"result\":\"Nil\"")
  let assert True = string.contains(json, "\"gas_used\":65")
  let assert True = string.contains(json, "\"effects_performed\":3")
  let assert True = string.contains(json, "\"duration_ms\":6200")
}

pub fn format_effect_yielded_test() {
  let event: HostEvent =
    events.EffectYielded(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      run_id: "r_001",
      effect_name: "clone_repo",
      args_summary: "\"owner/repo\"",
      depth: 0,
    )

  let json = session.format_event(event)
  let assert True = string.contains(json, "\"event\":\"effect_yielded\"")
  let assert True = string.contains(json, "\"effect_name\":\"clone_repo\"")
  let assert True = string.contains(json, "args_summary")
}

pub fn format_effect_handled_test() {
  let event: HostEvent =
    events.EffectHandled(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      run_id: "r_001",
      effect_name: "clone_repo",
      result_summary: "Ok(Nil)",
      duration_ms: 348,
      depth: 0,
    )

  let json = session.format_event(event)
  let assert True = string.contains(json, "\"event\":\"effect_handled\"")
  let assert True = string.contains(json, "\"effect_name\":\"clone_repo\"")
  let assert True = string.contains(json, "\"duration_ms\":348")
}

pub fn format_event_has_timestamp_test() {
  let event: HostEvent =
    events.ActorStarted(
      actor_path: "t.chute",
      actor_hash: "AABB1122",
      trigger_type: "test",
      trigger_source: "session_test",
      run_id: "r_ts",
      gas: 100,
      depth: 0,
    )

  let json = session.format_event(event)
  // Should have a "ts" field with ISO timestamp
  let assert True = string.contains(json, "\"ts\":\"")
}

pub fn format_event_is_valid_json_test() {
  // All four event types should produce valid JSON
  let events = [
    events.ActorStarted(
      actor_path: "t",
      actor_hash: "AB",
      trigger_type: "t",
      trigger_source: "s",
      run_id: "r",
      gas: 1,
      depth: 0,
    ),
    events.ActorCompleted(
      actor_path: "t",
      actor_hash: "AB",
      run_id: "r",
      result: "x",
      gas_used: 1,
      gas_limit: 2,
      effects_performed: 0,
      duration_ms: 1,
    ),
    events.EffectYielded(
      actor_path: "t",
      actor_hash: "AB",
      run_id: "r",
      effect_name: "e",
      args_summary: "a",
      depth: 0,
    ),
    events.EffectHandled(
      actor_path: "t",
      actor_hash: "AB",
      run_id: "r",
      effect_name: "e",
      result_summary: "r",
      duration_ms: 1,
      depth: 0,
    ),
  ]

  events
  |> list.each(fn(event) {
    let json = session.format_event(event)
    // Valid JSON starts with { and ends with }
    let assert True = string.starts_with(json, "{")
    let assert True = string.ends_with(json, "}")
  })
}

// ── Tests: session writer actor ──────────────────────────────────────

pub fn session_writer_starts_test() {
  let path = "/tmp/yard_session_test_" <> session.iso_timestamp() <> ".jsonl"
  let assert Ok(_writer) = session.start(path)
}

pub fn session_writer_records_sync_test() {
  let path = "/tmp/yard_session_sync_" <> session.iso_timestamp() <> ".jsonl"
  let assert Ok(writer) = session.start(path)

  let event: HostEvent =
    events.ActorStarted(
      actor_path: "sync.chute",
      actor_hash: "SYNC1234",
      trigger_type: "test",
      trigger_source: "sync_test",
      run_id: "r_sync",
      gas: 100,
      depth: 0,
    )

  session.record_sync(writer, event)

  // Read the file back and verify
  let assert Ok(content) = simplifile.read(path)
  let assert True = string.contains(content, "\"event\":\"actor_started\"")
  let assert True = string.contains(content, "\"run_id\":\"r_sync\"")

  session.stop(writer)
}

pub fn session_consumer_starts_test() {
  let path =
    "/tmp/yard_session_consumer_" <> session.iso_timestamp() <> ".jsonl"
  let assert Ok(_subject) = session.start_consumer(path)
}

// ── Tests: timestamp ─────────────────────────────────────────────────

pub fn iso_timestamp_format_test() {
  let ts = session.iso_timestamp()
  // ISO 8601 format: YYYY-MM-DDTHH:MM:SS.mmm
  let assert True = string.length(ts) > 20
  let assert True = string.contains(ts, "T")
  let assert True = string.contains(ts, "-")
  let assert True = string.contains(ts, ":")
  let assert True = string.contains(ts, ".")
}
