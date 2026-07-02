//// Unified event trace — host (yard_events) + pig (pig_events) joined by run_id.
////
//// Verifies the run-detail query UNIONs both tables (tagged with a `src`)
//// and the template renders a Source column with pig-aware badges.
//// Requires: docker container running with durable_schema.sql applied.

import gabsurd/client
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import pig/ai/message
import pig/obs/events as pig_events_lib
import testing
import yard/obs/events
import yard/obs/pig_events
import yard/pg_events
import yard/ui/queries
import yard/ui/template

pub fn main() {
  gleeunit.main()
}

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_pg_db(fn(db) {
    testing.clean_durable(db)
    test_fn(db)
  })
}

const run_id = "00000000-0000-0000-0000-0000000000aa"

fn pig_message() -> message.Message {
  message.Assistant("hi", [], option.None, option.None)
}

/// Seed one host event and one pig event for the same run_id.
fn seed_both(db: client.Db) -> Nil {
  let _ =
    pg_events.record_event(
      db:,
      event: events.ActorStarted(
        actor_path: "actors/triage.chute",
        actor_hash: "abcd1234",
        trigger_type: "webhook",
        trigger_source: "github",
        run_id: run_id,
        gas: 10_000,
        depth: 0,
      ),
    )

  let _ =
    pig_events.record_session_event(
      db:,
      run_id: run_id,
      event: pig_events_lib.InferenceCompleted(
        message: pig_message(),
        response_id: option.None,
        response_model: option.None,
        stop_reason: option.None,
        input_tokens: option.Some(120),
        output_tokens: option.Some(8),
        duration_ms: 42,
        input_messages: [],
      ),
    )
  Nil
}

// ── Query: unified list_events ───────────────────────────────────────

/// list_events returns rows from BOTH yard_events and pig_events, each tagged
/// with its source.
pub fn list_events_unifies_host_and_pig_test() {
  with_db(fn(db) {
    seed_both(db)

    let rows = queries.list_events(db, run_id:)

    // Both rows come back
    should.equal(list.length(rows), 2)

    // Each row carries its source tag
    let sources = list.map(rows, fn(r) { r.src })
    assert list.contains(sources, "host")
    assert list.contains(sources, "pig")
  })
}

/// A pig event_type is preserved verbatim through the UNION, with its duration.
pub fn list_events_preserves_pig_event_type_test() {
  with_db(fn(db) {
    seed_both(db)

    let rows = queries.list_events(db, run_id:)
    let pig_rows = list.filter(rows, fn(r) { r.src == "pig" })
    let assert [pig_row] = pig_rows
    should.equal(pig_row.event_type, "pig.inference_completed")
    should.equal(pig_row.duration_ms, option.Some(42))
  })
}

// ── Template: Source column + pig badges ─────────────────────────────

/// The events table renders a Source column header and per-row source badges.
pub fn events_table_renders_source_column_test() {
  let rows = [
    queries.EventRow(
      src: "host",
      event_type: "actor_started",
      payload: "{}",
      duration_ms: option.None,
      created_at: "2026-01-01",
    ),
    queries.EventRow(
      src: "pig",
      event_type: "pig.inference_completed",
      payload: "{}",
      duration_ms: option.Some(42),
      created_at: "2026-01-01",
    ),
  ]
  let html = template.run_detail("r1", rows)

  // Source column header present
  assert string.contains(html, "Source")
  // Host + pig source badges present
  assert string.contains(html, "badge-src-host")
  assert string.contains(html, "badge-src-pig")
}

/// pig.inference_completed gets the "ok" badge class.
pub fn pig_events_get_ok_badge_class_test() {
  let rows = [
    queries.EventRow(
      src: "pig",
      event_type: "pig.inference_completed",
      payload: "{}",
      duration_ms: option.Some(10),
      created_at: "2026-01-01",
    ),
  ]
  let html = template.run_detail("r1", rows)

  assert string.contains(html, "badge-event-ok")
}

/// pig.inference_failed gets the error badge class.
pub fn pig_inference_failed_gets_err_badge_test() {
  let rows = [
    queries.EventRow(
      src: "pig",
      event_type: "pig.inference_failed",
      payload: "{}",
      duration_ms: option.Some(10),
      created_at: "2026-01-01",
    ),
  ]
  let html = template.run_detail("r1", rows)

  assert string.contains(html, "badge-event-err")
}
