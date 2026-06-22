//// PostgreSQL conversation store — bridges yard's ConversationStore
//// abstraction to a PostgreSQL `conversations` table.
////
//// From DURABLE.md Component 3: each conversation persists its full
//// message log as JSONB. The table is created by durable_schema.sql.

import gleam/dynamic/decode
import gleam/option
import parrot/dev
import gabsurd/client.{type Db}
import yard/conversation.{
  type ConversationStore, type ConversationError, ConversationError,
}

/// Create a ConversationStore backed by a PostgreSQL connection.
pub fn from_db(db db: Db) -> ConversationStore {
  conversation.ConversationStore(
    load: fn(conversation_id: String) {
      load_from_pg(db, conversation_id)
    },
    save: fn(conversation_id: String, messages_json: String) {
      save_to_pg(db, conversation_id, messages_json)
    },
  )
}

fn messages_decoder() -> decode.Decoder(String) {
  use messages <- decode.field(0, decode.string)
  decode.success(messages)
}

fn load_from_pg(
  db: Db,
  conversation_id: String,
) -> Result(option.Option(String), ConversationError) {
  let sql =
    "SELECT messages FROM conversations WHERE id = $1::uuid"
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
    client.exec(db, #(sql, [
      dev.ParamString(conversation_id),
      dev.ParamString(messages_json),
    ]))
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
