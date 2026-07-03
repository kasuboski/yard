//// run_id generation — unique-per-invocation correlation key.
////
//// Each agent invocation (webhook, cron, message, API call, agent turn) gets
//// a fresh run_id so its host events (yard_events) and pig agent-internal
//// events (pig_events) can be joined into a single trace. The id is generated
//// client-side (UUID v4) so it is unique even if the database is unavailable —
//// no DB round trip, no collision-prone static fallback.

import youid/uuid

/// Generate a fresh, unique run_id (UUID v4 in standard text form).
///
/// Client-side generation deliberately avoids a database round trip: a
/// run_id must exist before any event is written, and it must be unique
/// even under transient database degradation. UUID v4 provides that
/// without coordination.
pub fn generate() -> String {
  uuid.v4()
  |> uuid.to_string
}
