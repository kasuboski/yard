Mono repo for Ballast and Chute.

Chute is a language tailored for LLM generation. Read knowledge/chute.md to learn more.
Ballast is the runtime for Chute. It takes in the Chute code provides the capabilities for the effects defined in Chute and executes the code. Read knowledge/ballast.md to learn more.

Both projects use gleam with the erlang target. mise and mise.toml provide the environment setup.

Development flow:
- `mise run pre-commit` — **MUST pass before every commit. No exceptions.** Runs check, format, build, and test across both projects.

Top-level commands (run across both projects in parallel):
- `mise run check` — type-check both projects
- `mise run format` — verify formatting for both projects
- `mise run build` — build both projects
- `mise run test` — run all tests (223 chute + 76 ballast)

Per-project commands:
- `mise run chute:check` / `mise run ballast:check`
- `mise run chute:format` / `mise run ballast:format`
- `mise run chute:build` / `mise run ballast:build`
- `mise run chute:test` / `mise run ballast:test`
