//// Issue Tracker Sync — Tests
////
//// Tests the sync actor using yard's runner with fake handlers.
//// No IO, no network, no LLM — the entire actor runs in microseconds.
////
//// Test scenarios:
//// 1. No changes  — agent says NO_CHANGES, update_issue never yielded
//// 2. Changes     — agent reports diff, update_issue gets the diff
//// 3. Fetch fail  — let try short-circuits, later effects never called
//// 4. Linked fail — same short-circuit at fetch_linked
//// 5. Agent fail  — same short-circuit at run_agent
//// 6. Unknown effect — runner returns error for unregistered handler
//// 7. Actor loads and hashes correctly
//// 8. Hash is deterministic
//// 9. Observability events carry full identity

import ballast/value.{
  type Value, ErrorVal, IntVal, ListVal, NilVal, OkVal, RuntimeError, StringVal,
}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import issue_triage.{extract_issue_numbers, sync_actor_source, sync_env}
import yard/loader
import yard/obs/events.{
  type HostEvent, ActorCompleted, ActorStarted, EffectYielded,
}
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════════
// Test Helpers
// ═══════════════════════════════════════════════════════════════════════

/// A sample tracking issue body with a markdown table.
const tracking_issue_body = "
## Immediate Priority

| Issue | Summary | Effort | Status |
|-------|---------|--------|--------|
| #127 | Fix: Double Body.Close() in metadata fetch/parse | Small | ✅ Closed — PR #147 |
| #134 | Fix: N+1 queries in series reconciliation | Medium | Open |
| #140 | Refactor: Slim down Storage interface | Medium | Open — started in PR #155 |
"

/// Linked issue state where nothing has changed.
const linked_state_unchanged = "#127: closed, title: \"Fix: Double Body.Close() in metadata fetch/parse\"\n"
  <> "#134: open, title: \"Fix: N+1 queries in series reconciliation\"\n"
  <> "#140: open, title: \"Refactor: Slim down Storage interface\""

/// Linked issue state where #134 was closed by PR #172.
const linked_state_134_closed = "#127: closed, title: \"Fix: Double Body.Close() in metadata fetch/parse\"\n"
  <> "#134: closed, title: \"Fix: N+1 queries in series reconciliation\"\n"
  <> "#140: open, title: \"Refactor: Slim down Storage interface\""

/// Build a test env for kasuboski/mediaz#126.
fn test_env() -> Value {
  sync_env("kasuboski/mediaz", 126, [127, 134, 140])
}

/// Drain all events from a test subject (non-blocking).
fn drain_events(
  subject: process.Subject(HostEvent),
  acc: List(HostEvent),
) -> List(HostEvent) {
  case process.receive(subject, 1) {
    Ok(event) -> drain_events(subject, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

/// Create a test emit callback that sends events to a subject.
fn test_emitter(subject: process.Subject(HostEvent)) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) { process.send(subject, event) }
}

/// Extract the sequence of effect names from a list of HostEvents.
fn effect_names(events: List(HostEvent)) -> List(String) {
  events
  |> list.filter(fn(e) {
    case e {
      EffectYielded(..) -> True
      _ -> False
    }
  })
  |> list.map(fn(e) {
    case e {
      EffectYielded(effect_name:, ..) -> effect_name
      _ -> ""
    }
  })
}

/// Load the sync actor and build a RunConfig for testing.
fn make_test_config(
  handlers: dict.Dict(String, EffectHandler),
  env: Value,
  emit: fn(HostEvent) -> Nil,
) -> RunConfig {
  let assert Ok(actor) = loader.load(sync_actor_source, "actors/sync.chute")
  RunConfig(
    program: actor.program,
    env:,
    gas: 50_000,
    handlers:,
    emit:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id: "r_sync_test",
    trigger_type: "test",
    trigger_source: "test",
    depth: 0,
  )
}

// ═══════════════════════════════════════════════════════════════════════
// Fake Handlers
// ═══════════════════════════════════════════════════════════════════════

fn fake_fetch_issue(body: String) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(_repo), IntVal(_number)] -> Ok(OkVal(StringVal(body)))
      _ -> Error(RuntimeError("Invalid args for fetch_issue"))
    }
  }
}

fn fake_fetch_linked(state: String) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(_repo), ListVal(_numbers)] -> Ok(OkVal(StringVal(state)))
      _ -> Error(RuntimeError("Invalid args for fetch_linked"))
    }
  }
}

fn fake_run_agent(response: String) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(_context), StringVal(_task)] -> Ok(OkVal(StringVal(response)))
      _ -> Error(RuntimeError("Invalid args for run_agent"))
    }
  }
}

fn failing_handler(_effect_name: String, error_msg: String) -> EffectHandler {
  fn(_name, _args) { Ok(ErrorVal(StringVal(error_msg))) }
}

/// Track whether update_issue was called and with what args.
fn tracking_update_handler(
  subject: process.Subject(#(String, Int, String)),
) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(repo), IntVal(number), StringVal(body)] -> {
        process.send(subject, #(repo, number, body))
        Ok(OkVal(NilVal))
      }
      _ -> Error(RuntimeError("Invalid args for update_issue"))
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// ── Test 1: No Changes — agent says NO_CHANGES, update never yielded ──

pub fn sync_no_changes_test() {
  let subject = process.new_subject()

  let handlers =
    dict.from_list([
      #("fetch_issue", fake_fetch_issue(tracking_issue_body)),
      #("fetch_linked", fake_fetch_linked(linked_state_unchanged)),
      #("run_agent", fake_run_agent("NO_CHANGES")),
      // update_issue is NOT in the handlers dict — if it gets yielded,
    // the runner will return an UnknownEffect error
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))
  let assert Ok(OkVal(NilVal)) = runner.run(config)

  let events = drain_events(subject, [])
  // Started, Yielded fetch_issue, Handled, Yielded fetch_linked, Handled,
  // Yielded run_agent, Handled, Completed = 8 events
  let assert 8 = list.length(events)
  let assert ["fetch_issue", "fetch_linked", "run_agent"] = effect_names(events)
}

// ── Test 2: Changes Detected — update_issue gets the diff ─────────────

pub fn sync_changes_detected_test() {
  let subject = process.new_subject()
  let update_subject = process.new_subject()

  let diff = "## 1 change detected\n\n| #134 | Open | ✅ Closed — PR #172 |"

  let handlers =
    dict.from_list([
      #("fetch_issue", fake_fetch_issue(tracking_issue_body)),
      #("fetch_linked", fake_fetch_linked(linked_state_134_closed)),
      #("run_agent", fake_run_agent(diff)),
      #("update_issue", tracking_update_handler(update_subject)),
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))
  let assert Ok(OkVal(NilVal)) = runner.run(config)

  // Verify update_issue was called with the right args
  let assert Ok(#(repo, number, body)) = process.receive(update_subject, 100)
  let assert "kasuboski/mediaz" = repo
  let assert 126 = number
  let assert True = string.contains(body, "#134")

  // 4 effects yielded (including update_issue)
  let events = drain_events(subject, [])
  let assert ["fetch_issue", "fetch_linked", "run_agent", "update_issue"] =
    effect_names(events)
}

// ── Test 3: Fetch Issue Failure Propagates ────────────────────────────

pub fn sync_fetch_issue_failure_test() {
  let subject = process.new_subject()

  let handlers =
    dict.from_list([
      #(
        "fetch_issue",
        failing_handler("fetch_issue", "GitHub API returned 403"),
      ),
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))

  let assert Ok(ErrorVal(StringVal("GitHub API returned 403"))) =
    runner.run(config)

  let events = drain_events(subject, [])
  // Started, Yielded fetch_issue, Handled, Completed = 4 events
  let assert 4 = list.length(events)
  let assert ["fetch_issue"] = effect_names(events)
}

// ── Test 4: Fetch Linked Failure Propagates ───────────────────────────

pub fn sync_fetch_linked_failure_test() {
  let subject = process.new_subject()

  let handlers =
    dict.from_list([
      #("fetch_issue", fake_fetch_issue(tracking_issue_body)),
      #("fetch_linked", failing_handler("fetch_linked", "rate limited")),
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))

  let assert Ok(ErrorVal(StringVal("rate limited"))) = runner.run(config)

  let events = drain_events(subject, [])
  // fetch_issue succeeds, fetch_linked fails → 6 events
  let assert 6 = list.length(events)
  let assert ["fetch_issue", "fetch_linked"] = effect_names(events)
}

// ── Test 5: Agent Failure Propagates ──────────────────────────────────

pub fn sync_agent_failure_test() {
  let subject = process.new_subject()

  let handlers =
    dict.from_list([
      #("fetch_issue", fake_fetch_issue(tracking_issue_body)),
      #("fetch_linked", fake_fetch_linked(linked_state_unchanged)),
      #("run_agent", failing_handler("run_agent", "Agent timed out")),
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))

  let assert Ok(ErrorVal(StringVal("Agent timed out"))) = runner.run(config)

  let events = drain_events(subject, [])
  let assert ["fetch_issue", "fetch_linked", "run_agent"] = effect_names(events)
}

// ── Test 6: Unknown Effect Causes Error ───────────────────────────────

pub fn sync_unknown_effect_test() {
  let subject = process.new_subject()

  // Empty handlers — no handler for fetch_issue
  let handlers = dict.new()

  let config = make_test_config(handlers, test_env(), test_emitter(subject))

  let assert Error(RuntimeError("Unknown effect: fetch_issue")) =
    runner.run(config)

  let events = drain_events(subject, [])
  let assert 3 = list.length(events)
}

// ── Test 7: Actor Source Loads Correctly ──────────────────────────────

pub fn sync_actor_loads_test() {
  let assert Ok(actor) = loader.load(sync_actor_source, "actors/sync.chute")
  let assert "actors/sync.chute" = actor.actor_path
  let assert 8 = string.length(actor.actor_hash)
}

// ── Test 8: Hash Is Deterministic ─────────────────────────────────────

pub fn sync_actor_hash_deterministic_test() {
  let assert Ok(a) = loader.load(sync_actor_source, "actors/sync.chute")
  let assert Ok(b) = loader.load(sync_actor_source, "actors/sync.chute")
  let assert True = a.actor_hash == b.actor_hash
}

// ── Test 9: Observability Events Carry Identity ───────────────────────

pub fn events_carry_actor_identity_test() {
  let subject = process.new_subject()

  let handlers =
    dict.from_list([
      #("fetch_issue", fake_fetch_issue(tracking_issue_body)),
      #("fetch_linked", fake_fetch_linked(linked_state_unchanged)),
      #("run_agent", fake_run_agent("NO_CHANGES")),
    ])

  let config = make_test_config(handlers, test_env(), test_emitter(subject))
  let assert Ok(_) = runner.run(config)

  let events = drain_events(subject, [])
  let assert [
    ActorStarted(
      actor_path: "actors/sync.chute",
      actor_hash: hash,
      run_id: "r_sync_test",
      trigger_type: "test",
      trigger_source: "test",
      ..,
    ),
    _,
    _,
    _,
    _,
    _,
    _,
    ActorCompleted(
      actor_path: "actors/sync.chute",
      actor_hash: hash2,
      run_id: "r_sync_test",
      ..,
    ),
  ] = events
  let assert True = hash == hash2
}

// ═══════════════════════════════════════════════════════════════════════
// Extract Issue Numbers Tests
// ═══════════════════════════════════════════════════════════════════════

pub fn extract_numbers_basic_test() {
  let body = "See #127, #134, and #140 for details"
  let assert [127, 134, 140] = extract_issue_numbers(body)
}

pub fn extract_numbers_deduplicates_test() {
  let body = "#127 and #127 again and #127 thrice"
  let assert [127] = extract_issue_numbers(body)
}

pub fn extract_numbers_sorted_test() {
  let body = "#140, #127, #134"
  let assert [127, 134, 140] = extract_issue_numbers(body)
}

pub fn extract_numbers_empty_test() {
  let body = "No issue references here"
  let assert [] = extract_issue_numbers(body)
}

pub fn extract_numbers_in_table_test() {
  let body =
    "| #127 | Fix something | Small | ✅ Closed — PR #147 |\n"
    <> "| #134 | Fix another | Medium | Open |"
  let nums = extract_issue_numbers(body)
  let assert True = list.contains(nums, 127)
  let assert True = list.contains(nums, 134)
  let assert True = list.contains(nums, 147)
}
