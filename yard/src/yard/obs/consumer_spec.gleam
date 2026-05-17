//// Consumer specification for yard observability.
////
//// A deferred consumer: a ChildSpec + the name to recover its Subject
//// after start + a start function for the unsupervised path.
////
//// Mirrors pig's ConsumerSpec pattern for consistency.

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision
import yard/obs/events.{type HostEvent}

/// A deferred consumer specification.
///
/// Stores:
/// - `spec`: A ChildSpecification for starting this consumer in a supervision tree
/// - `name`: The name to recover the Subject after start (for registration)
/// - `start_fn`: A start function for the unsupervised path
pub type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(HostEvent),
    start_fn: fn() -> Result(Subject(HostEvent), actor.StartError),
  )
}
