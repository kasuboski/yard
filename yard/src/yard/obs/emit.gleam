//// Event emission utilities.
////
//// Bridges yard/obs/events.gleam and yard/obs/dispatcher.gleam.
//// This is the primary way for the runner and other code to emit
//// observability events through the dispatcher to all registered consumers.

import gleam/erlang/process.{type Subject}
import yard/obs/dispatcher
import yard/obs/events

/// Send a HostEvent to the dispatcher actor.
///
/// Takes the dispatcher Subject directly. The dispatcher will:
/// 1. Project the event to :telemetry (always)
/// 2. Fan out to all registered consumers (session writer, terminal, etc.)
pub fn to_dispatcher(
  dispatcher_subject: Subject(dispatcher.DispatcherMessage),
  event: events.HostEvent,
) -> Nil {
  process.send(dispatcher_subject, dispatcher.Event(event))
}
