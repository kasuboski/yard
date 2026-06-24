//// Host event types and telemetry projection.
////
//// Five HostEvent variants cover all runner observability:
//// - ActorStarted / ActorCompleted — lifecycle
//// - EffectYielded / EffectHandled — per-effect timing
//// - EffectReplayed — per-effect replay (durable runner)
////
//// Effects and triggers are data (string fields), not type variants.
//// Adding new effects or triggers requires zero changes here.
////
//// Telemetry is always projected — every HostEvent maps to one of five
//// telemetry event names under the `yard.*` namespace.

import gleam/dict.{type Dict}
import gleam/int

// ── FFI Bindings ─────────────────────────────────────────────────────

@external(erlang, "yard_obs_ffi", "execute")
fn ffi_execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Nil

@external(erlang, "yard_obs_ffi", "system_time")
fn ffi_system_time() -> Int

/// Get the current system time in milliseconds.
pub fn system_time() -> Int {
  ffi_system_time()
}

// ── HostEvent Type ───────────────────────────────────────────────────

/// Observability events emitted by the runner during actor execution.
/// Four variants cover the complete lifecycle of any actor, regardless
/// of trigger type or effect names.
pub type HostEvent {
  /// A chute actor started running.
  ActorStarted(
    actor_path: String,
    actor_hash: String,
    trigger_type: String,
    trigger_source: String,
    run_id: String,
    gas: Int,
    depth: Int,
  )

  /// A chute actor finished running (success or error).
  ActorCompleted(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    result: String,
    gas_used: Int,
    gas_limit: Int,
    effects_performed: Int,
    duration_ms: Int,
  )

  /// Ballast yielded an effect. Covers ALL effects for ALL actors.
  EffectYielded(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    args_summary: String,
    depth: Int,
  )

  /// The effect handler returned a result.
  EffectHandled(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    result_summary: String,
    duration_ms: Int,
    depth: Int,
  )

  /// An effect was replayed from a checkpoint (durable runner).
  /// Emitted instead of EffectYielded + EffectHandled when a stored
  /// checkpoint value is fed to Ballast on retry.
  EffectReplayed(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    step: Int,
    depth: Int,
  )
}

// ── Telemetry Name Constants ─────────────────────────────────────────

pub fn actor_started_name() -> List(String) {
  ["yard", "actor", "started"]
}

pub fn actor_completed_name() -> List(String) {
  ["yard", "actor", "completed"]
}

pub fn effect_yielded_name() -> List(String) {
  ["yard", "effect", "yielded"]
}

pub fn effect_handled_name() -> List(String) {
  ["yard", "effect", "handled"]
}

pub fn effect_replayed_name() -> List(String) {
  ["yard", "effect", "replayed"]
}

/// All yard telemetry event names.
pub fn all_event_names() -> List(List(String)) {
  [
    actor_started_name(),
    actor_completed_name(),
    effect_yielded_name(),
    effect_handled_name(),
    effect_replayed_name(),
  ]
}

// ── Telemetry Projection ─────────────────────────────────────────────
// Every HostEvent is projected to :telemetry with lightweight metrics.
// The dispatcher calls this automatically — consumers never need to.

/// Project a HostEvent to :telemetry.
/// Called by the dispatcher for every event.
pub fn emit_telemetry(event: HostEvent) -> Nil {
  case event {
    ActorStarted(
      actor_path:,
      actor_hash:,
      trigger_type:,
      trigger_source:,
      run_id:,
      gas:,
      depth:,
    ) -> {
      let measurements =
        dict.from_list([#("system_time", ffi_system_time()), #("gas", gas)])
      let metadata =
        dict.from_list([
          #("actor_path", actor_path),
          #("actor_hash", actor_hash),
          #("trigger_type", trigger_type),
          #("trigger_source", trigger_source),
          #("run_id", run_id),
          #("depth", int_to_string(depth)),
        ])
      ffi_execute(actor_started_name(), measurements, metadata)
    }

    ActorCompleted(
      actor_path:,
      actor_hash:,
      run_id:,
      result:,
      gas_used:,
      gas_limit:,
      effects_performed:,
      duration_ms:,
    ) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
          #("gas_used", gas_used),
          #("gas_limit", gas_limit),
          #("effects_performed", effects_performed),
        ])
      let metadata =
        dict.from_list([
          #("actor_path", actor_path),
          #("actor_hash", actor_hash),
          #("run_id", run_id),
          #("result", result),
        ])
      ffi_execute(actor_completed_name(), measurements, metadata)
    }

    EffectYielded(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      args_summary: _,
      depth:,
    ) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("actor_path", actor_path),
          #("actor_hash", actor_hash),
          #("run_id", run_id),
          #("effect_name", effect_name),
          #("depth", int_to_string(depth)),
        ])
      ffi_execute(effect_yielded_name(), measurements, metadata)
    }

    EffectHandled(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      result_summary: _,
      duration_ms:,
      depth:,
    ) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("actor_path", actor_path),
          #("actor_hash", actor_hash),
          #("run_id", run_id),
          #("effect_name", effect_name),
          #("depth", int_to_string(depth)),
        ])
      ffi_execute(effect_handled_name(), measurements, metadata)
    }

    EffectReplayed(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      step:,
      depth:,
    ) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("actor_path", actor_path),
          #("actor_hash", actor_hash),
          #("run_id", run_id),
          #("effect_name", effect_name),
          #("step", int_to_string(step)),
          #("depth", int_to_string(depth)),
        ])
      ffi_execute(effect_replayed_name(), measurements, metadata)
    }
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

fn int_to_string(i: Int) -> String {
  int.to_string(i)
}
