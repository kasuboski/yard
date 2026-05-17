//// Terminal printer tests — format_event (pure, no side effects).

import gleam/string
import gleeunit
import yard/obs/events.{type HostEvent}
import yard/obs/terminal

pub fn main() {
  gleeunit.main()
}

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

  let formatted = terminal.format_event(event)
  let assert True = string.contains(formatted, "[START]")
  let assert True = string.contains(formatted, "actors/triage.chute")
  let assert True = string.contains(formatted, "a3f7c2e9")
  let assert True = string.contains(formatted, "webhook/github")
  let assert True = string.contains(formatted, "r_001")
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

  let formatted = terminal.format_event(event)
  let assert True = string.contains(formatted, "[DONE]")
  let assert True = string.contains(formatted, "6200ms")
  let assert True = string.contains(formatted, "effects: 3")
  let assert True = string.contains(formatted, "gas: 65")
}

pub fn format_effect_yielded_test() {
  let event: HostEvent =
    events.EffectYielded(
      actor_path: "t.chute",
      actor_hash: "AABB",
      run_id: "r_001",
      effect_name: "clone_repo",
      args_summary: "\"owner/repo\"",
      depth: 0,
    )

  let formatted = terminal.format_event(event)
  let assert True = string.contains(formatted, "[YIELD]")
  let assert True = string.contains(formatted, "clone_repo")
  let assert True = string.contains(formatted, "\"owner/repo\"")
}

pub fn format_effect_handled_test() {
  let event: HostEvent =
    events.EffectHandled(
      actor_path: "t.chute",
      actor_hash: "AABB",
      run_id: "r_001",
      effect_name: "clone_repo",
      result_summary: "Ok(Nil)",
      duration_ms: 348,
      depth: 0,
    )

  let formatted = terminal.format_event(event)
  let assert True = string.contains(formatted, "[HANDLE]")
  let assert True = string.contains(formatted, "clone_repo")
  let assert True = string.contains(formatted, "348ms")
}

pub fn format_depth_shown_for_inner_test() {
  let event: HostEvent =
    events.EffectYielded(
      actor_path: "t.chute",
      actor_hash: "AABB",
      run_id: "r_001",
      effect_name: "read_file",
      args_summary: "\"main.gleam\"",
      depth: 1,
    )

  let formatted = terminal.format_event(event)
  let assert True = string.contains(formatted, "depth: 1")
}

pub fn format_depth_hidden_for_outer_test() {
  let event: HostEvent =
    events.EffectYielded(
      actor_path: "t.chute",
      actor_hash: "AABB",
      run_id: "r_001",
      effect_name: "read_file",
      args_summary: "\"main.gleam\"",
      depth: 0,
    )

  let formatted = terminal.format_event(event)
  let assert False = string.contains(formatted, "depth:")
}
