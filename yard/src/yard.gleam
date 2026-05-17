//// Yard — host runtime for chute actors.
////
//// Public API: start the observability stack, configure consumers,
//// and run actors through the shared dispatcher.
////
//// Architecture:
////
////   Triggers ──→ yard.runner.run(config) ──→ Result
////                    │
////                    │ emit via
////                    ▼
////              ┌──────────────┐
////              │  Dispatcher  │    ← shared OTP actor
////              │  (fan out)   │
////              └──┬──────┬────┘
////                 │      │
////         ┌───────▼┐  ┌──▼──────────┐
////         │ Session │  │ Terminal    │    ← consumers
////         │ Writer  │  │ Printer     │
////         │ (JSONL) │  │ (stdout)    │
////         └─────────┘  └─────────────┘

import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import yard/obs/consumer_spec.{type ConsumerSpec}
import yard/obs/dispatcher

// ── Public Types ─────────────────────────────────────────────────────

/// Handle to a running yard system.
///
/// Wraps the dispatcher Subject and supervisor Pid.
/// Pass the dispatcher to `runner.emit_to_dispatcher()` when building RunConfig.
pub type Yard {
  Yard(
    dispatcher: process.Subject(dispatcher.DispatcherMessage),
    sup_pid: process.Pid,
  )
}

// ── Public API ───────────────────────────────────────────────────────

/// Start the yard observability stack.
///
/// Spawns a OneForAll supervisor containing:
/// - The dispatcher (receives events, projects telemetry, fans out)
/// - All registered consumers (session writer, terminal printer, etc.)
///
/// Returns a `Yard` handle with the dispatcher Subject for building RunConfigs.
pub fn start(consumers: List(ConsumerSpec)) -> Result(Yard, actor.StartError) {
  let dispatcher_name = process.new_name("yard_dispatcher")

  // Build event subtree: dispatcher + consumers
  // OneForAll ensures that if the dispatcher restarts, consumers restart too
  let event_tree =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.add(dispatcher.supervised(dispatcher_name))
    |> list.fold(consumers, _, fn(builder, entry) {
      static_supervisor.add(builder, entry.spec)
    })

  case static_supervisor.start(event_tree) {
    Ok(started) -> {
      let dispatcher_subject = process.named_subject(dispatcher_name)

      // Register all consumers with the dispatcher
      list.each(consumers, fn(entry) {
        let consumer_subject = process.named_subject(entry.name)
        process.send(
          dispatcher_subject,
          dispatcher.RegisterConsumer(consumer_subject),
        )
      })

      Ok(Yard(dispatcher: dispatcher_subject, sup_pid: started.pid))
    }
    Error(e) -> Error(e)
  }
}

/// Stop the yard system.
///
/// Sends an exit signal to the supervisor. OTP cascades shutdown
/// to all children (dispatcher + consumers).
pub fn stop(yard: Yard) -> Nil {
  process.send_exit(yard.sup_pid)
}
