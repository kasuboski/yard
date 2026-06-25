//// Observability UI — dashboard HTML generator.
////
//// Served by yard/ui/server.gleam when yard starts.
//// Queries yard_events, conversations, and runs tables.

import gabsurd/client.{type Db}
import gleam/dynamic/decode
import gleam/option.{type Option}
import parrot/dev

// ── Query types ──────────────────────────────────────────────────────

pub type RunSummary {
  RunSummary(
    run_id: String,
    agent_id: String,
    status: String,
    trigger_source: String,
    started_at: String,
  )
}

pub type EventRow {
  EventRow(
    event_type: String,
    payload: String,
    duration_ms: Option(Int),
    created_at: String,
  )
}

pub type ConversationRow {
  ConversationRow(
    id: String,
    agent_id: String,
    user_key: String,
    updated_at: String,
  )
}

// ── Queries ──────────────────────────────────────────────────────────

/// List recent runs from the runs table.
pub fn list_runs(db db: Db) -> List(RunSummary) {
  let sql =
    "SELECT id::text, agent_id, status, trigger_source, started_at::text
     FROM runs
     ORDER BY started_at DESC LIMIT 50"
  case client.query_many(db, #(sql, [], run_summary_decoder())) {
    Ok(rows) -> rows
    Error(_) -> []
  }
}

/// List events for a specific run.
pub fn list_events(db db: Db, run_id run_id: String) -> List(EventRow) {
  let sql =
    "SELECT event_type, payload::text, duration_ms, created_at::text
     FROM yard_events
     WHERE run_id::text = $1
     ORDER BY created_at ASC"
  case
    client.query_many(db, #(sql, [dev.ParamString(run_id)], event_row_decoder()))
  {
    Ok(rows) -> rows
    Error(_) -> []
  }
}

/// List conversations.
pub fn list_conversations(db db: Db) -> List(ConversationRow) {
  let sql =
    "SELECT id::text, agent_id, user_key, updated_at::text
     FROM conversations
     ORDER BY updated_at DESC LIMIT 50"
  case client.query_many(db, #(sql, [], conversation_row_decoder())) {
    Ok(rows) -> rows
    Error(_) -> []
  }
}

fn messages_decoder() -> decode.Decoder(String) {
  use messages <- decode.field(0, decode.string)
  decode.success(messages)
}

/// Get a conversation's messages.
pub fn get_conversation(db db: Db, id id: String) -> String {
  let sql = "SELECT messages FROM conversations WHERE id::text = $1"
  case client.query_one(db, #(sql, [dev.ParamString(id)], messages_decoder())) {
    Ok(messages) -> messages
    Error(_) -> "[]"
  }
}

// ── Decoders ─────────────────────────────────────────────────────────

fn run_summary_decoder() -> decode.Decoder(RunSummary) {
  use run_id <- decode.field(0, decode.string)
  use agent_id <- decode.field(1, decode.string)
  use status <- decode.field(2, decode.string)
  use trigger_source <- decode.field(3, decode.string)
  use started_at <- decode.field(4, decode.string)
  decode.success(RunSummary(
    run_id:,
    agent_id:,
    status:,
    trigger_source:,
    started_at:,
  ))
}

fn event_row_decoder() -> decode.Decoder(EventRow) {
  use event_type <- decode.field(0, decode.string)
  use payload <- decode.field(1, decode.string)
  use duration_ms <- decode.field(2, decode.optional(decode.int))
  use created_at <- decode.field(3, decode.string)
  decode.success(EventRow(event_type:, payload:, duration_ms:, created_at:))
}

fn conversation_row_decoder() -> decode.Decoder(ConversationRow) {
  use id <- decode.field(0, decode.string)
  use agent_id <- decode.field(1, decode.string)
  use user_key <- decode.field(2, decode.string)
  use updated_at <- decode.field(3, decode.string)
  decode.success(ConversationRow(id:, agent_id:, user_key:, updated_at:))
}
