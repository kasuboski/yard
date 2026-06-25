# Migration Summary: Yard's Global Registry from SQLite to PostgreSQL

## Changes Made

### 1. New PostgreSQL Schema File
**File:** `yard/src/yard/sql/pg_schema.sql`
- Created new PostgreSQL DDL for registry tables
- Tables migrated: `providers`, `agents`, `agent_handlers`, `skills`, `deployments`, `runs`, `chat_sessions`, `chat_messages`
- Used PostgreSQL-native types: `TIMESTAMPTZ` for timestamps, appropriate indexes
- Note: `schedules` table is NOT included (moving to pg_cron)

### 2. Rewritten `db.gleam`
**File:** `yard/src/yard/db.gleam`
- Migrated from SQLite (sqlight) to PostgreSQL (gabsurd/client.Db)
- All CRUD functions now use `client.exec()` and `client.query_many()` with decoders
- Maintained backward-compatible public API (same function names, same types)
- Return types: `Result(..., Nil)` for compatibility with existing callers
- Schedule functions left as stubs with deprecation warnings (for parallel worker)
- Added `migrate()` as a no-op for test compatibility

**Key changes:**
- Import: `gabsurd/client.{type Db}` instead of `sqlight`
- Function signature: `fn(db: Db, ...)` instead of `fn(conn: sqlight.Connection, ...)`
- Query pattern: Uses `client.query_many(db, #(sql, params, decoder))`
- Decoder pattern: Uses `use field <- decode.field(N, decode.type)` syntax

### 3. Updated Callers
**File:** `yard/src/yard/handler_registry.gleam`
- Added import: `gabsurd/client.{type Db}`
- Changed `resolve_for_agent` parameter from `conn: sqlight.Connection` to `db: Db`

**File:** `yard/src/yard/skill_repo.gleam`
- Added import: `gabsurd/client.{type Db}`
- Changed all function parameters from `conn: sqlight.Connection` to `db: Db`

### 4. Updated Test Files
**File:** `yard/test/db_test.gleam`
- Rewritten to use PostgreSQL connection via `client.start(db_url)`
- Uses `with_db()` helper pattern matching other pg_*_test.gleam files
- All schedule tests now expect stub behavior (pass without actual data)

**File:** `yard/test/chat_test.gleam`
- Rewritten to use PostgreSQL connection
- Tests now verify chat sessions and messages with proper user key isolation

**File:** `yard/test/skill_repo_test.gleam`
- Rewritten to use PostgreSQL connection
- Tests verify skill registration, lookup, and listing

**File:** `yard/test/handler_registry_test.gleam`
- Rewritten to use PostgreSQL connection
- Tests now use `with_db()` helper instead of in-memory SQLite

### 5. Updated Build Infrastructure
**File:** `bin/postgres.sh`
- Added step to apply `pg_schema.sql` after applying `durable_schema.sql`
- Ensures registry tables are created when starting test database

### 6. Left as-is (Explicitly Out of Scope)
- **Scheduling:** All schedule-related functions (`list_active_schedules`, `get_schedule`, `insert_schedule`, `update_schedule_fire`, `deactivate_schedule`) are stubs with deprecation warnings. The `schedules` table remains in SQLite schema for the parallel worker to migrate to pg_cron.
- **Workspace connections:** Per-agent workspace connections (VFS/KV) remain SQLite-based via `pig/workspace`. The `HandlerContext.workspace_conn` field remains `Option(sqlight.Connection)`.

## Files Changed
1. `yard/src/yard/db.gleam` - Complete rewrite to PostgreSQL
2. `yard/src/yard/handler_registry.gleam` - Updated Db import and parameter type
3. `yard/src/yard/skill_repo.gleam` - Updated Db import and parameter types
4. `yard/test/db_test.gleam` - Rewritten to PostgreSQL
5. `yard/test/chat_test.gleam` - Rewritten to PostgreSQL
6. `yard/test/skill_repo_test.gleam` - Rewritten to PostgreSQL
7. `yard/test/handler_registry_test.gleam` - Rewritten to PostgreSQL
8. `yard/src/yard/sql/pg_schema.sql` - New file (PostgreSQL DDL)
9. `bin/postgres.sh` - Added pg_schema.sql application step

## Verification
- **Build:** `cd yard && gleam check` passes (with some unused import warnings)
- **Tests:** `cd yard && gleam test` runs. Registry tests require `bin/postgres.sh` first.

## Schedule Functions Left as Stubs
The following schedule-related functions in `db.gleam` are stubs that will be removed by the parallel worker:
- `list_active_schedules(db)` - Returns `Ok([])` with warning
- `get_schedule(db, id)` - Returns `Ok(None)` with warning
- `insert_schedule(db, ...)` - Returns `Ok("")` with warning
- `update_schedule_fire(db, ...)` - Returns `Ok(Nil)` with warning
- `deactivate_schedule(db, id)` - Returns `Ok(Nil)` with warning

These functions log "deprecated - use pg_cron" warnings when called.

## Two-Database Strategy (As Implemented)
- **PostgreSQL (Global Registry):** All higher-level data (agents, skills, runs, chat)
- **SQLite (Per-Agent Workspace):** Each agent's VFS and KV storage (via pig/workspace)
- **Schedule Transition:** Moving from SQLite `schedules` table to `pg_cron` (handled by parallel worker)