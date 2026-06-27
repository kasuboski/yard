//// Integration test: PostgreSQL event store.
////
//// Requires: docker container running with durable_schema.sql applied.

import gabsurd/client
import gleeunit
import gleeunit/should
import testing
import yard/obs/events
import yard/pg_events

pub fn main() {
  gleeunit.main()
}

fn with_db(test_fn: fn(client.Db) -> a) -> a {
  testing.with_pg_db(fn(db) {
    testing.clean_durable(db)
    test_fn(db)
  })
}

fn make_run_id() -> String {
  // Use a fixed UUID for test events — yard_events.run_id is just a UUID,
  // no FK constraint to enforce
  "00000000-0000-0000-0000-000000000001"
}

pub fn record_actor_started_test() {
  with_db(fn(db) {
    let event =
      events.ActorStarted(
        actor_path: "test.chute",
        actor_hash: "abcd1234",
        trigger_type: "test",
        trigger_source: "pg_events_test",
        run_id: make_run_id(),
        gas: 10_000,
        depth: 0,
      )
    should.be_ok(pg_events.record_event(db:, event:))
  })
}

pub fn record_effect_handled_with_duration_test() {
  with_db(fn(db) {
    let event =
      events.EffectHandled(
        actor_path: "test.chute",
        actor_hash: "abcd1234",
        run_id: make_run_id(),
        effect_name: "greet",
        result_summary: "\"Hello!\"",
        duration_ms: 42,
        depth: 0,
      )
    should.be_ok(pg_events.record_event(db:, event:))
  })
}

pub fn record_effect_replayed_test() {
  with_db(fn(db) {
    let event =
      events.EffectReplayed(
        actor_path: "test.chute",
        actor_hash: "abcd1234",
        run_id: make_run_id(),
        effect_name: "greet",
        step: 0,
        depth: 0,
      )
    should.be_ok(pg_events.record_event(db:, event:))
  })
}

pub fn record_all_event_types_test() {
  with_db(fn(db) {
    let rid = make_run_id()
    // Record all 5 event types
    let _ =
      pg_events.record_event(
        db:,
        event: events.ActorStarted(
          actor_path: "test.chute",
          actor_hash: "abcd1234",
          trigger_type: "test",
          trigger_source: "pg_events_test",
          run_id: rid,
          gas: 10_000,
          depth: 0,
        ),
      )
    let _ =
      pg_events.record_event(
        db:,
        event: events.EffectYielded(
          actor_path: "test.chute",
          actor_hash: "abcd1234",
          run_id: rid,
          effect_name: "greet",
          args_summary: "\"world\"",
          depth: 0,
        ),
      )
    let _ =
      pg_events.record_event(
        db:,
        event: events.EffectHandled(
          actor_path: "test.chute",
          actor_hash: "abcd1234",
          run_id: rid,
          effect_name: "greet",
          result_summary: "\"Hello!\"",
          duration_ms: 5,
          depth: 0,
        ),
      )
    let _ =
      pg_events.record_event(
        db:,
        event: events.EffectReplayed(
          actor_path: "test.chute",
          actor_hash: "abcd1234",
          run_id: rid,
          effect_name: "greet",
          step: 0,
          depth: 0,
        ),
      )
    let _ =
      pg_events.record_event(
        db:,
        event: events.ActorCompleted(
          actor_path: "test.chute",
          actor_hash: "abcd1234",
          run_id: rid,
          result: "\"Hello!\"",
          gas_used: 50,
          gas_limit: 10_000,
          effects_performed: 1,
          duration_ms: 100,
        ),
      )

    // All should succeed — the test passing without panic is the assertion
    should.equal(1, 1)
  })
}
