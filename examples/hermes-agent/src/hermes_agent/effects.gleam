//// Hermes effect handlers — wrap Pig workspace operations and emit_event
//// into Yard's EffectHandler type for use by the runner.
////
//// EventCollector uses a cell actor (tiny OTP process holding a list)
//// to accumulate emit_event payloads during a chute_exec run.
//// The collector tracks gas_used by observing ActorCompleted events.

import ballast/value.{ErrorVal, NilVal, OkVal, StringVal}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/string
import pig/workspace/kv
import pig/workspace/vfs
import sqlight
import yard/obs/events.{type HostEvent}
import yard/runner.{type EffectHandler}

// ═══════════════════════════════════════════════════════════════
// Event Collector — cell actor
// ═══════════════════════════════════════════════════════════════

/// Messages the cell actor understands.
pub type CollectorMessage {
  Record(String, String)
  SetGasUsed(Int)
  GetEvents(process.Subject(List(#(String, String))))
  GetGasUsed(process.Subject(Int))
  Stop
}

/// State held by the collector actor.
pub type CollectorState {
  CollectorState(events: List(#(String, String)), gas_used: Int)
}

/// A cell actor that accumulates (name, payload) pairs and tracks
/// gas_used from ActorCompleted events. Each chute_exec call creates
/// its own collector — the lifecycle is tied to a single tool invocation.
pub type EventCollector =
  process.Subject(CollectorMessage)

/// Create a new event collector (spawns a cell actor).
pub fn new_event_collector() -> EventCollector {
  let assert Ok(started) =
    actor.new(CollectorState(events: [], gas_used: 0))
    |> actor.on_message(fn(state, msg) {
      case msg {
        Record(name, payload) ->
          actor.continue(CollectorState(
            events: [#(name, payload), ..state.events],
            gas_used: state.gas_used,
          ))
        SetGasUsed(gas) ->
          actor.continue(CollectorState(
            events: state.events,
            gas_used: gas,
          ))
        GetEvents(reply) -> {
          process.send(reply, list.reverse(state.events))
          actor.continue(state)
        }
        GetGasUsed(reply) -> {
          process.send(reply, state.gas_used)
          actor.continue(state)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start()
  started.data
}

/// Record an event in the collector.
pub fn collector_record(
  collector: EventCollector,
  name: String,
  payload: String,
) -> Nil {
  process.send(collector, Record(name, payload))
}

/// Set the gas_used value (from ActorCompleted event).
pub fn collector_set_gas(collector: EventCollector, gas: Int) -> Nil {
  process.send(collector, SetGasUsed(gas))
}

/// Get all collected events in order.
pub fn collector_events(collector: EventCollector) -> List(#(String, String)) {
  process.call(collector, 1000, fn(reply) { GetEvents(reply) })
}

/// Get the gas_used value.
pub fn collector_gas_used(collector: EventCollector) -> Int {
  process.call(collector, 1000, fn(reply) { GetGasUsed(reply) })
}

/// Stop the collector actor (releases the process).
pub fn collector_stop(collector: EventCollector) -> Nil {
  process.send(collector, Stop)
}

// ═══════════════════════════════════════════════════════════════
// Yard emit adapter — intercepts events for gas tracking
// ═══════════════════════════════════════════════════════════════

/// Create an emit callback that forwards to the Yard emit and also
/// captures gas_used from ActorCompleted events into the collector.
pub fn emit_with_collector(
  yard_emit: fn(HostEvent) -> Nil,
  collector: EventCollector,
) -> fn(HostEvent) -> Nil {
  fn(event: HostEvent) {
    case event {
      events.ActorCompleted(gas_used:, ..) -> {
        collector_set_gas(collector, gas_used)
        yard_emit(event)
      }
      _ -> yard_emit(event)
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// emit_event handler
// ═══════════════════════════════════════════════════════════════

/// Create an emit_event handler that captures events into the collector.
pub fn emit_event_handler(collector: EventCollector) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(name), StringVal(payload)] -> {
        collector_record(collector, name, payload)
        Ok(NilVal)
      }
      _ ->
        Ok(ErrorVal(StringVal(
          "emit_event: expected 2 string args (name, payload)",
        )))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Workspace handlers
// ═══════════════════════════════════════════════════════════════

/// Handler for write_file effect: writes content to VFS.
pub fn write_file_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path), StringVal(content)] ->
        case vfs.write_file(conn, path, content) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("write_file: invalid args")))
    }
  }
}

/// Handler for read_file effect: reads content from VFS.
pub fn read_file_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path)] ->
        case vfs.read_file(conn, path) {
          Ok(content) -> Ok(OkVal(StringVal(content)))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("read_file: invalid args")))
    }
  }
}

/// Handler for list_files effect: lists directory contents from VFS.
pub fn list_files_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(path)] ->
        case vfs.list_directory(conn, path) {
          Ok(entries) ->
            Ok(OkVal(value.ListVal(list.map(entries, fn(e) { StringVal(e) }))))
          Error(err) -> Ok(ErrorVal(StringVal(vfs_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("list_files: invalid args")))
    }
  }
}

/// Handler for store effect: stores a key-value pair in KV.
pub fn store_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(key), StringVal(val)] ->
        case kv.remember(conn, key, val) {
          Ok(Nil) -> Ok(OkVal(NilVal))
          Error(err) -> Ok(ErrorVal(StringVal(kv_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("store: invalid args")))
    }
  }
}

/// Handler for recall effect: recalls a value from KV.
pub fn recall_handler(conn: sqlight.Connection) -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(key)] ->
        case kv.recall(conn, key) {
          Ok(val) -> Ok(OkVal(StringVal(val)))
          Error(err) -> Ok(ErrorVal(StringVal(kv_error(err))))
        }
      _ -> Ok(ErrorVal(StringVal("recall: invalid args")))
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Handler registry
// ═══════════════════════════════════════════════════════════════

/// Build the complete set of Hermes effect handlers.
pub fn all_handlers(
  conn: sqlight.Connection,
  collector: EventCollector,
) -> dict.Dict(String, EffectHandler) {
  dict.from_list([
    #("emit_event", emit_event_handler(collector)),
    #("read_file", read_file_handler(conn)),
    #("write_file", write_file_handler(conn)),
    #("list_files", list_files_handler(conn)),
    #("recall", recall_handler(conn)),
    #("store", store_handler(conn)),
  ])
}

// ═══════════════════════════════════════════════════════════════
// Error formatting
// ═══════════════════════════════════════════════════════════════

fn vfs_error(err: vfs.Error) -> String {
  case err {
    vfs.NotFound(path) -> "File not found: " <> path
    vfs.NotEmpty(path) -> "Directory not empty: " <> path
    vfs.InvalidPath(path) -> "Invalid path: " <> path
    vfs.AlreadyExists(path) -> "Already exists: " <> path
    vfs.SqlError(e) -> "SQL error: " <> sqlight_error(e)
  }
}

fn kv_error(err: kv.Error) -> String {
  case err {
    kv.NotFound(key) -> "Key not found: " <> key
    kv.SqlError(e) -> "SQL error: " <> sqlight_error(e)
  }
}

fn sqlight_error(err: sqlight.Error) -> String {
  string.inspect(err)
}
