//// JSONL session writer — records HostEvents to a file.
////
//// OTP actor that receives HostEvents and appends them as JSONL lines.
//// Two modes:
////   - `record()` — fire-and-forget, never blocks the runner.
////   - `record_sync()` — synchronous call, blocks until written. For testing.
////
//// Also provides `format_event()` as a pure function for testing without IO.

import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import simplifile
import yard/obs/events.{type HostEvent}

// ── FFI Bindings ─────────────────────────────────────────────────────

@external(erlang, "yard_obs_session_ffi", "iso_timestamp")
fn ffi_iso_timestamp() -> String

/// Get current ISO 8601 timestamp.
pub fn iso_timestamp() -> String {
  ffi_iso_timestamp()
}

// ── Actor Types ──────────────────────────────────────────────────────

/// Opaque handle to the session writer actor.
pub opaque type SessionWriter {
  SessionWriter(subject: Subject(WriterMessage))
}

/// Internal actor messages.
type WriterMessage {
  WriteEvent(HostEvent)
  WriteEventSync(event: HostEvent, reply_subject: Subject(Nil))
  Stop
}

/// Actor state holds the file path.
type State {
  State(path: String)
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a new session writer actor that appends events to the given file.
pub fn start(path: String) -> Result(SessionWriter, StartError) {
  let builder =
    actor.new(State(path: path))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(SessionWriter(started.data))
    Error(e) -> Error(e)
  }
}

/// Stop the session writer actor.
pub fn stop(writer: SessionWriter) -> Nil {
  let SessionWriter(subject) = writer
  process.send(subject, Stop)
}

/// Record a host event. Fire-and-forget: does not block.
pub fn record(writer: SessionWriter, event: HostEvent) -> Nil {
  let SessionWriter(subject) = writer
  process.send(subject, WriteEvent(event))
}

/// Record a host event synchronously. Blocks until written to disk.
/// Use in tests for deterministic assertions.
pub fn record_sync(writer: SessionWriter, event: HostEvent) -> Nil {
  let SessionWriter(subject) = writer
  let reply_subject = process.new_subject()
  process.send(subject, WriteEventSync(event:, reply_subject:))
  let assert Ok(_) = process.receive(reply_subject, 5000)
  Nil
}

/// Start a session consumer actor that accepts HostEvent directly.
/// Used by the dispatcher to fan out events. Returns the Subject for registration.
pub fn start_consumer(path: String) -> Result(Subject(HostEvent), StartError) {
  let builder =
    actor.new(State(path: path))
    |> actor.on_message(handle_consumer_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised session consumer actor for use in a supervision tree.
pub fn supervised(
  path: String,
  name: Name(HostEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(path: path))
      |> actor.on_message(handle_consumer_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

// ── JSON Serialization ───────────────────────────────────────────────

/// Format a HostEvent as a JSON string (pure function, no side effects).
pub fn format_event(event: HostEvent) -> String {
  let ts = iso_timestamp()

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
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("actor_started")),
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("trigger_type", json.string(trigger_type)),
        #("trigger_source", json.string(trigger_source)),
        #("run_id", json.string(run_id)),
        #("gas", json.int(gas)),
        #("depth", json.int(depth)),
      ])
      |> json.to_string()
    }

    events.ActorCompleted(
      actor_path:,
      actor_hash:,
      run_id:,
      result:,
      gas_used:,
      gas_limit:,
      effects_performed:,
      duration_ms:,
    ) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("actor_completed")),
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("run_id", json.string(run_id)),
        #("result", json.string(result)),
        #("gas_used", json.int(gas_used)),
        #("gas_limit", json.int(gas_limit)),
        #("effects_performed", json.int(effects_performed)),
        #("duration_ms", json.int(duration_ms)),
      ])
      |> json.to_string()
    }

    events.EffectYielded(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      args_summary:,
      depth:,
    ) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("effect_yielded")),
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("run_id", json.string(run_id)),
        #("effect_name", json.string(effect_name)),
        #("args_summary", json.string(args_summary)),
        #("depth", json.int(depth)),
      ])
      |> json.to_string()
    }

    events.EffectHandled(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      result_summary:,
      duration_ms:,
      depth:,
    ) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("effect_handled")),
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("run_id", json.string(run_id)),
        #("effect_name", json.string(effect_name)),
        #("result_summary", json.string(result_summary)),
        #("duration_ms", json.int(duration_ms)),
        #("depth", json.int(depth)),
      ])
      |> json.to_string()
    }

    events.EffectReplayed(
      actor_path:,
      actor_hash:,
      run_id:,
      effect_name:,
      step_name:,
      depth:,
    ) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("effect_replayed")),
        #("actor_path", json.string(actor_path)),
        #("actor_hash", json.string(actor_hash)),
        #("run_id", json.string(run_id)),
        #("effect_name", json.string(effect_name)),
        #("step_name", json.string(step_name)),
        #("depth", json.int(depth)),
      ])
      |> json.to_string()
    }
  }
}

// ── Actor Implementation ─────────────────────────────────────────────

fn handle_message(
  state: State,
  message: WriterMessage,
) -> actor.Next(State, WriterMessage) {
  case message {
    WriteEvent(event) -> {
      let json_str = format_event(event)
      let _ = simplifile.append(state.path, json_str <> "\n")
      actor.continue(state)
    }
    WriteEventSync(event:, reply_subject:) -> {
      let json_str = format_event(event)
      let _ = simplifile.append(state.path, json_str <> "\n")
      process.send(reply_subject, Nil)
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn handle_consumer_message(
  state: State,
  event: HostEvent,
) -> actor.Next(State, HostEvent) {
  let json_str = format_event(event)
  case simplifile.append(state.path, json_str <> "\n") {
    Ok(_) -> actor.continue(state)
    Error(_) -> {
      // Stop on write failure so the supervisor can restart
      actor.stop()
    }
  }
}
