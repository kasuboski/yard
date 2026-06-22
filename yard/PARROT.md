# Parrot (SQL Codegen) Setup

## What is Parrot?

[Parrot](https://hex.pm/packages/parrot) wraps [sqlc](https://sqlc.dev/) to generate type-safe Gleam code from SQL schema and query files.

Yard uses Parrot to manage its global database (agents, skills, schedules, deployments, runs, chat). The generated `sql.gleam` provides typed query functions, decoders, and parameter bindings.

## Quick Start

**Always use the mise task to regenerate:**

```sh
mise run yard:gen
```

This handles creating a temp SQLite DB, running parrot, and cleaning up. Run this after editing `schema.sql` or `queries.sql`.

## What to edit

| File | Edit? | Description |
|------|-------|-------------|
| `src/yard/sql/schema.sql` | **Yes** | Table definitions (source of truth) |
| `src/yard/sql/queries.sql` | **Yes** | Named queries with sqlc annotations |
| `src/yard/sql.gleam` | **No** | Auto-generated — do not edit |

## What gets checked into git

| Path | Checked in? | Why |
|------|-------------|-----|
| `src/yard/sql/schema.sql` | **Yes** | Source of truth for the schema |
| `src/yard/sql/queries.sql` | **Yes** | Source of truth for queries |
| `src/yard/sql.gleam` | **Yes** | Generated but checked in so `gleam build` works without parrot installed |
| `build/.parrot/` | **No** | Contains auto-downloaded sqlc binary + intermediate files (gitignored) |

## Gotchas

- **Always use `mise run yard:gen`** — it handles the temp DB lifecycle. Running `gleam run -m parrot` directly requires a live SQLite DB with the schema applied; the mise task creates one for you.
- **No unicode in SQL comments** — sqlc's SQLite parser rejects box-drawing characters. Use ASCII dashes only.
- **`:one` and `:many` work without RETURNING** — sqlc infers the return type from SELECT columns for SQLite.
