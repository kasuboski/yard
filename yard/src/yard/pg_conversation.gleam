//// PostgreSQL conversation store — bridges yard's ConversationStore
//// abstraction to a PostgreSQL `conversations` table.
////
//// From DURABLE.md Component 3: each conversation persists its full
//// message log as JSONB. The table is created by durable_schema.sql.

import gabsurd/client.{type Db}
import gleam/dynamic/decode
import gleam/option
import gleam/string
import gluid
import parrot/dev
import yard/conversation.{
  type ConversationError, type ConversationStore, ConversationError,
}

/// Create a ConversationStore backed by a PostgreSQL connection.
///
/// The store is keyed by conversation_id (a UUID). Use
/// `get_or_create_for_user` to obtain a conversation_id for a given
/// agent + user before calling load/save.
pub fn from_db(db db: Db) -> ConversationStore {
  conversation.ConversationStore(
    load: fn(conversation_id: String) { load_from_pg(db, conversation_id) },
    save: fn(conversation_id: String, messages_json: String) {
      save_to_pg(db, conversation_id, messages_json)
    },
  )
}

/// Find or create a conversation for a given agent + user.
///
/// Returns the conversation_id (UUID). If a conversation already exists
/// for this agent_id + user_key, returns its ID. Otherwise inserts a
/// new row with an empty message log.
pub fn get_or_create_for_user(
  db db: Db,
  agent_id agent_id: String,
  user_key user_key: String,
) -> Result(String, ConversationError) {
  let sql =
    "SELECT id::text FROM conversations
     WHERE agent_id = $1 AND user_key = $2
     ORDER BY updated_at DESC LIMIT 1"
  case
    client.query_one(db, #(
      sql,
      [
        dev.ParamString(agent_id),
        dev.ParamString(user_key),
      ],
      conversation_id_decoder(),
    ))
  {
    Ok(id) -> Ok(id)
    Error(client.NotFound) -> create_new_for_user(db:, agent_id:, user_key:)
    Error(e) -> Error(ConversationError(error_to_string(e)))
  }
}

/// Create a brand-new conversation for a given agent + user.
/// Always inserts a new row (does NOT look up existing).
/// Used by session.reset() to start a fresh conversation.
pub fn create_new_for_user(
  db db: Db,
  agent_id agent_id: String,
  user_key user_key: String,
) -> Result(String, ConversationError) {
  let id = gluid.guidv4() |> string.lowercase()
  let sql =
    "INSERT INTO conversations (id, agent_id, user_key, messages)
     VALUES ($1::uuid, $2, $3, '[]')"
  case
    client.exec(
      db,
      #(sql, [
        dev.ParamString(id),
        dev.ParamString(agent_id),
        dev.ParamString(user_key),
      ]),
    )
  {
    Ok(Nil) -> Ok(id)
    Error(e) -> Error(ConversationError(error_to_string(e)))
  }
}

fn conversation_id_decoder() -> decode.Decoder(String) {
  use id <- decode.field(0, decode.string)
  decode.success(id)
}

fn messages_decoder() -> decode.Decoder(String) {
  use messages <- decode.field(0, decode.string)
  decode.success(messages)
}

fn load_from_pg(
  db: Db,
  conversation_id: String,
) -> Result(option.Option(String), ConversationError) {
  let sql = "SELECT messages FROM conversations WHERE id = $1::uuid"
  case
    client.query_one(db, #(
      sql,
      [dev.ParamString(conversation_id)],
      messages_decoder(),
    ))
  {
    Ok(row) -> Ok(option.Some(row))
    Error(client.NotFound) -> Ok(option.None)
    Error(e) -> Error(ConversationError(error_to_string(e)))
  }
}

/// Save messages to a conversation (upsert).
/// If the conversation row already exists (created via get_or_create_for_user),
/// only messages and updated_at are changed. If it doesn't exist yet
/// (direct save), a row is inserted with empty agent_id/user_key.
fn save_to_pg(
  db: Db,
  conversation_id: String,
  messages_json: String,
) -> Result(Nil, ConversationError) {
  let sql =
    "
    INSERT INTO conversations (id, agent_id, user_key, messages)
    VALUES ($1::uuid, '', '', $2::text)
    ON CONFLICT (id) DO UPDATE
      SET messages = $2::text, updated_at = now()
    "
  case
    client.exec(
      db,
      #(sql, [
        dev.ParamString(conversation_id),
        dev.ParamString(messages_json),
      ]),
    )
  {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> Error(ConversationError(error_to_string(e)))
  }
}

fn error_to_string(e: client.GabsurdError) -> String {
  case e {
    client.QueryError(msg) -> "query: " <> msg
    client.UnexpectedRowCount(msg) -> "row count: " <> msg
    client.NotFound -> "not found"
    client.ConnectionError(msg) -> "connection: " <> msg
  }
}
