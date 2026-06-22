//// Terminal pretty printer for HostEvents.
////
//// OTP actor that receives HostEvents and prints formatted output.
//// Pure `format_event()` function for testing without side effects.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import yard/obs/events.{type HostEvent}

// ── State ────────────────────────────────────────────────────────────

type State {
  State
}

// ── Format Function (Pure, Testable) ────────────────────────────────

/// Format a HostEvent as a human-readable string.
/// Pure function, no side effects — easy to test.
pub fn format_event(event: HostEvent) -> String {
  case event {
    events.ActorStarted(
      actor_path:,
      actor_hash:,
      trigger_type:,
      trigger_source:,
      run_id:,
      gas:,
      depth:,
    ) -> {
      "[START] "
      <> actor_path
      <> " | hash: "
      <> actor_hash
      <> " | trigger: "
      <> trigger_type
      <> "/"
      <> trigger_source
      <> " | run: "
      <> run_id
      <> " | gas: "
      <> int.to_string(gas)
      <> " | depth: "
      <> int.to_string(depth)
    }

    events.ActorCompleted(
      actor_path:,
      actor_hash:,
      run_id:,
      result:,
      gas_used:,
      gas_limit: _,
      effects_performed:,
      duration_ms:,
    ) -> {
      let dur_str = int.to_string(duration_ms) <> "ms"
      "[DONE] "
      <> actor_path
      <> " | hash: "
      <> actor_hash
      <> " | run: "
      <> run_id
      <> " | "
      <> dur_str
      <> " | effects: "
      <> int.to_string(effects_performed)
      <> " | gas: "
      <> int.to_string(gas_used)
      <> " | result: "
      <> result
    }

    events.EffectYielded(
      actor_path: _,
      actor_hash: _,
      run_id: _,
      effect_name:,
      args_summary:,
      depth:,
    ) -> {
      let depth_str = case depth {
        0 -> ""
        _ -> " | depth: " <> int.to_string(depth)
      }
      "[YIELD] " <> effect_name <> "(" <> args_summary <> ")" <> depth_str
    }

    events.EffectHandled(
      actor_path: _,
      actor_hash: _,
      run_id: _,
      effect_name:,
      result_summary:,
      duration_ms:,
      depth:,
    ) -> {
      let dur_str = int.to_string(duration_ms) <> "ms"
      let depth_str = case depth {
        0 -> ""
        _ -> " | depth: " <> int.to_string(depth)
      }
      "[HANDLE] "
      <> effect_name
      <> " -> "
      <> result_summary
      <> " | "
      <> dur_str
      <> depth_str
    }

    events.EffectReplayed(
      actor_path: _,
      actor_hash: _,
      run_id: _,
      effect_name:,
      step_name:,
      depth:,
    ) -> {
      let depth_str = case depth {
        0 -> ""
        _ -> " | depth: " <> int.to_string(depth)
      }
      "[REPLAY] " <> effect_name <> " (" <> step_name <> ")" <> depth_str
    }
  }
}

// ── Actor Initialization ────────────────────────────────────────────

/// Start the terminal printer actor.
pub fn start() -> Result(Subject(HostEvent), StartError) {
  let builder =
    actor.new(State)
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Start a terminal consumer that accepts HostEvent directly.
/// Used by the dispatcher to fan out events.
pub fn start_consumer() -> Result(Subject(HostEvent), StartError) {
  start()
}

/// Create a supervised terminal consumer actor for use in a supervision tree.
pub fn supervised(
  name: Name(HostEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State)
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

fn handle_message(
  state: State,
  event: HostEvent,
) -> actor.Next(State, HostEvent) {
  let formatted = format_event(event)
  io.println(formatted)
  actor.continue(state)
}
