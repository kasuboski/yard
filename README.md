# Chute & Ballast

A token-efficient, sandboxed scripting language designed for LLM agents, and its host runtime.

**Chute** is the language — a Gleam-like pipeline syntax optimized for left-to-right LLM token generation, with algebraic effects that separate pure computation from I/O. Unbounded loops are banned, guaranteeing halting.

**Ballast** is the runtime — a pure functional, CPS-based tree-walking evaluator that implements a yield/resume protocol. The host provides effect handlers; Ballast never touches the outside world directly.

**Yard** is the host runtime layer — a generic effect loop over Ballast with built-in observability (structured events, JSONL session logging, `:telemetry`), actor loading, and a pluggable trigger system.

```
┌─────────────┐     parse/desugar      ┌─────────────┐     yield/resume     ┌─────────────┐
│  Chute      │ ────────────────────→  │  Ballast    │ ◄──────────────────→ │  Yard       │
│  (language) │                        │  (evaluator)│                      │  (host loop)│
└─────────────┘                        └─────────────┘                      └─────────────┘
```

## Why?

LLMs generate code linearly — top to bottom, left to right. Most languages fight this with nested scopes, early returns, and pyramids of doom. Chute embraces linear generation:

- **Pipeline-first (`|>`)** — data flows top-to-bottom through transformations
- **No unbounded loops** — iteration is via `list.map`, `list.filter`, `list.fold` only
- **Effects are declared, not imported** — `effect fetch_url(url: String) -> Result(String, Error)` at the top of the file; the host decides what actually happens
- **Structural records** — JSON-like `{ name: String, age: Int }` types, no nominal class hierarchies
- **Guaranteed halting** — gas counter + syntactic loop ban = bounded execution

## Example

```gleam
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    env.order_total
    |> perform charge_card()
    |> result.try(fn(tx_id) {
        let _ = perform send_receipt(env.user_id, tx_id)
        Ok(tx_id)
    })
}
```

When Ballast hits `perform charge_card(...)`, it yields to the host. The host calls the payment API, then resumes Ballast with the result. To the LLM, it looks synchronous. To the runtime, it's a pure function.

## How It Works

### Chute — The Language

Chute is a pipeline-first language designed so LLMs can generate correct programs token-by-token without backtracking. Every program is a sequence of top-down transformations — no nested scopes, no early returns, no pyramids of doom.

**Effects are the key design decision.** A Chute program declares its external interactions at the top of the file as effect signatures:

```gleam
effect charge_card(amount: Float) -> Result(String, Error)
```

This is a *capability declaration*, not an import. The program says what it *wants* to do, but has no idea how it happens. There's no HTTP client, no file system, no network stack inside Chute. The only way to trigger I/O is `perform`:

```gleam
perform charge_card(99.95)   // yields to the host, waits for a result
```

Before execution, the host does a static capability check — it scans the declared effects against its registry of allowed capabilities. If the program declares an effect the host doesn't recognize (e.g., an LLM hallucinated `effect delete_database()`), execution is refused before it starts.

**Halting is guaranteed by construction.** There are no `while` loops, no `for` loops, no general recursion. The only way to iterate is through stdlib functions (`list.map`, `list.filter`, `list.fold`). Combined with a gas counter in the evaluator, this means every program terminates in bounded time.

The source is parsed into an AST, desugared (pipelines become nested calls, etc.), and can be serialized to S-expressions for storage or transport. The parser, desugarer, and type checker live in the `chute/` package.

### Ballast — The Sandbox

Ballast is a pure functional evaluator. It has zero I/O — no file access, no network calls, no process spawning. It can't even print to stdout. The only thing it does is evaluate expressions.

**The sandbox boundary is the `perform` keyword.** When Ballast encounters `perform charge_card(99.95)`, it doesn't call an API. Instead it returns:

```
Yielded("charge_card", [FloatVal(99.95)], <continuation>, remaining_gas)
```

This is a value — a data structure describing the intent. Ballast pauses and hands it to the host. The host does the real work (calls Stripe, etc.), then calls `ballast.resume(continuation, result)`. Ballast picks up exactly where it left off, binding the host's result and continuing evaluation.

This yield/resume cycle is implemented with continuation-passing style (CPS). Every expression evaluation takes a continuation function as a parameter, so when a `perform` is hit at any nesting depth, the entire remaining computation is captured as a closure. No threads, no processes, no coroutine library — just functions.

**Gas prevents runaway compute.** Every `eval` call decrements a counter. Default budget: 10,000 steps. If it hits zero, evaluation stops immediately with `GasExhausted`. Even something like `list.fold` over a huge list can't burn unbounded resources.

**Compile-once, run-many.** `ballast.prepare(source)` parses and desugars once, returning a `Program` that can be executed repeatedly with different environments — useful when the same actor runs on a schedule with fresh data each time.

### Yard — The Host Loop

Yard is the glue between Ballast's sandbox and the real world. It provides a single function — `yard.runner.run(config)` — that loops over Ballast's yield/resume cycle, dispatching each effect to a handler function provided by the host application.

```
run(config):
  1. Start Ballast with the actor program and input env
  2. Ballast yields an effect → Yard looks up the handler by name
  3. Handler does real work (HTTP call, DB query, etc.) → returns a Value
  4. Yard resumes Ballast with that value
  5. Repeat until Ballast returns Done or Error
```

**Observability is automatic, not opt-in.** Every run emits structured events — `ActorStarted`, `EffectYielded`, `EffectHandled`, `ActorCompleted` — regardless of trigger type. These flow through an OTP dispatcher to registered consumers (JSONL session writer, stdout printer, OpenTelemetry exporter, etc.). You can't forget to log a run because the runner always does it.

**Actor identity is content-addressed.** Each actor is hashed (SHA-256 of its canonical S-expression, first 8 chars) so you can tell when code changes between runs. Two actors with the same hash are the same program, even if deployed to different environments.

**Triggers are just config.** Webhooks, cron ticks, message queue events — each is a thin adapter that builds a `RunConfig` with the right actor, env, and handlers, then calls `yard.runner.run(config)`. Adding a new trigger type doesn't require code changes in Yard.

### examples/issue-triage

A working example application: a GitHub issue triage agent that periodically syncs tracking issues. It uses all three components — a Chute actor defines the sync logic, Ballast evaluates it, and Yard provides effect handlers that call the GitHub API and run an LLM agent via pig. 14 tests cover the full sync pipeline.

## Getting Started

### Prerequisites

- [mise](https://mise.jdx.dev/) (manages Gleam, Erlang, rebar3)
- An Erlang/OTP installation (or let mise handle it)

### Build & Test

```bash
# Install toolchain
mise install

# Run everything (the CI gate)
mise run pre-commit

# Or run individually
mise run check     # type-check all projects
mise run format    # verify formatting
mise run build     # build all projects
mise run test      # run all tests

# Per-project
mise run chute:test
mise run ballast:test
mise run yard:test
```

`mise run pre-commit` **must pass before every commit.** No exceptions.

### Per-Project Commands

Each project supports `:check`, `:format`, `:build`, and `:test`:
```bash
mise run chute:check    # chute only
mise run ballast:test   # ballast only
mise run yard:build     # yard only
```

## Language Reference

### Types

Primitives: `Int`, `Float`, `String`, `Bool`

Structural: `{ name: String, age: Int }` — anonymous records, no type declarations needed

Wrappers: `List(T)`, `Option(T)`, `Result(T, E)`

### Control Flow

No `while`, no `for`, no general recursion. Iteration via stdlib only:
```gleam
list.map([1, 2, 3], fn(x) { x * 2 })
list.filter([1, 2, 3], fn(x) { x > 1 })
list.fold([1, 2, 3], 0, fn(acc, x) { acc + x })
```

Pattern matching with `case`:
```gleam
case result {
    Ok(value) -> do_something(value)
    Error(msg) -> handle_error(msg)
}
```

### Effects

Declare at the top, invoke with `perform`:
```gleam
effect fetch_url(url: String) -> Result(String, Error)

pub fn main(env: { url: String }) -> Result(String, Error) {
    perform fetch_url(env.url)
}
```

Batch effects via thunks:
```gleam
let tasks = [
    fn() { perform do_a() },
    fn() { perform do_b() },
]
perform task.dispatch_all(tasks)
```

### Error Handling

No exceptions. Everything returns `Result`. Use `result.try` and `result.map`:
```gleam
Ok(42)
|> result.try(fn(x) { Ok(x + 1) })
|> result.map(fn(x) { x * 2 })
```

Or `let try` for inline unwrapping:
```gleam
let try value = perform risky_operation()
Ok(value)
```

## Architecture Deep Dives

- **`knowledge/chute.md`** — Language design principles, effect model, transport format
- **`knowledge/ballast.md`** — Evaluator architecture, CPS design, stdlib reference, gas system
- **`knowledge/syntax.md`** — Formal EBNF grammar and lexical rules
- **`knowledge/observability.md`** — Host event model, dispatcher, JSONL format, telemetry
- **`knowledge/projectnaming.md`** — Naming philosophy (why "Chute" and "Ballast")

## Tech Stack

- **[Gleam](https://gleam.run/)** — type-safe language on the BEAM (Erlang VM)
- **Erlang/OTP** — runtime, processes, supervisors
- **mise** — task runner and toolchain manager
