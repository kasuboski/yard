Mono repo for Ballast, Chute, and Yard.

Chute is a language tailored for LLM generation. Read knowledge/chute.md to learn more.
Ballast is the runtime for Chute. It takes in the Chute code provides the capabilities for the effects defined in Chute and executes the code. Read knowledge/ballast.md to learn more.
Yard is the host runtime that manages agent deployment, scheduling, and observability. It uses **Parrot** (sqlc wrapper) for type-safe SQL codegen — see `yard/PARROT.md` for setup and regeneration.

Both projects use gleam with the erlang target. mise and mise.toml provide the environment setup.

Development flow:
- `mise run pre-commit` — **MUST pass before every commit. No exceptions.** Runs check, format, build, and test across all projects.

Top-level commands (run across all projects in parallel):
- `mise run check` — type-check all projects
- `mise run format` — verify formatting for all projects
- `mise run build` — build all projects
- `mise run test` — run all tests

Per-project commands:
- `mise run chute:check` / `mise run ballast:check` / `mise run yard:check`
- `mise run chute:format` / `mise run ballast:format` / `mise run yard:format`
- `mise run chute:build` / `mise run ballast:build` / `mise run yard:build`
- `mise run chute:test` / `mise run ballast:test` / `mise run yard:test`

SQL codegen:
- `mise run yard:gen` — regenerate `yard/src/yard/sql.gleam` from SQL sources (see `yard/PARROT.md`)

## Code Search

Use `semble search` to find code by describing what it does or naming a symbol/identifier, instead of grep:

​```bash
semble search "authentication flow" ./my-project
semble search "save_pretrained" ./my-project
semble search "save model to disk" ./my-project --top-k 10
​```

Use `semble find-related` to discover code similar to a known location (pass `file_path` and `line` from a prior search result):

​```bash
semble find-related src/auth.py 42 ./my-project
​```

`path` defaults to the current directory when omitted; git URLs are accepted.

If `semble` is not on `$PATH`, use `uvx --from "semble[mcp]" semble` in its place.

## Workflow

1. Start with `semble search` to find relevant chunks.
2. Inspect full files only when the returned chunk is not enough context.
3. Optionally use `semble find-related` with a promising result's `file_path` and `line` to discover related implementations.
4. Use grep only when you need exhaustive literal matches or quick confirmation of an exact string.
