# Host Runtime Observability

How the host runtime integrates pig's observability and adds its own.

---

## Pig's Model (what we build on)

Pig has a three-layer observability stack:

```
Agent runtime
    │
    │ emits SessionEvents via
    ▼
┌─────────────────────────────────────┐
│  Dispatcher (OTP actor)             │
│                                     │
│  1. Always projects to :telemetry   │   ← lightweight, always-on metrics
│     (pig.inference.start/stop,      │
│      pig.tool.start/stop, etc)      │
│                                     │
│  2. Fans out SessionEvent to        │   ← rich events with full content
│     registered consumers            │
└──────┬──────────┬──────────┬────────┘
       │          │          │
       ▼          ▼          ▼
   Session     Terminal   Your custom
   Writer      Printer    consumer
   (JSONL)     (stdout)   (OTel, DB, etc)
```

Key properties:
- **`:telemetry` is free** — always emitted, no registration needed.
- **Dispatcher is typed** — `SessionEvent` union type with variants for every lifecycle event.
- **Consumers are pluggable** — register any `Subject(SessionEvent)` with the dispatcher.
- **Session writer replays** — JSONL files can be loaded back with `session.replay(path)`.

---

## The Runner — Where Observability Lives

The `run_loop` doesn't exist yet. It's the first component to build — a thin layer over ballast's existing `start_program_with_env` → `Yielded` → `resume` cycle.

It lives in a new project (`yard/`) and it's the **single place** where observability is wired. Every actor invocation — webhooks, cron, messages, API calls — goes through the same runner function. Observability is automatic by construction.

```
yard/src/
├── yard.gleam                # Public API: start, configure, etc
└── yard/
    ├── runner.gleam          # The run_loop — generic effect loop over ballast
    ├── handler.gleam         # EffectHandler type + registry
    └── obs/
        ├── events.gleam      # HostEvent type (5 variants, not 13)
        ├── dispatcher.gleam  # Shared OTP dispatcher
        ├── consumer_spec.gleam # ConsumerSpec — deferred consumer (spec + name + start_fn)
        ├── session.gleam     # JSONL writer consumer
        ├── terminal.gleam    # stdout printer consumer
        └── pg_events.gleam   # PostgreSQL consumer → yard_events table (production default)
```

### The runner function

```gleam
// yard/src/yard/runner.gleam

import ballast
import ballast/effect.{type EvalResult}
import ballast/value
import gleam/dict.{type Dict}

/// A handler for a named effect. Pure function.
pub type EffectHandler =
  fn(String, List(value.Value)) -> Result(value.Value, value.RuntimeError)

/// Configuration for a single run.
pub type RunConfig {
  RunConfig(
    program: chute/ast.Program,
    env: value.Value,
    gas: Int,
    handlers: Dict(String, EffectHandler),
    obs: Subject(DispatcherMessage),   // dispatcher to emit events to
    actor_path: String,                // e.g. "actors/triage.chute"
    actor_hash: String,                // e.g. "a3f7c2e9" — SHA-256 of S-expression, first 8 chars
    run_id: String,                    // unique per invocation
    trigger_type: String,              // e.g. "webhook", "cron", "message"
    trigger_source: String,            // e.g. "github", "schedule:5m"
    depth: Int,                        // 0 = outer actor, 1+ = inner chute
  )
}

/// Run a chute actor to completion. Handles every yield/resume cycle.
/// Returns the final ballast value or a runtime error.
///
/// This is the ONLY place where ballast's yield/resume is consumed
/// as a loop. Everything else (tests, triggers, inner programs) calls this.
pub fn run(config: RunConfig) -> Result(value.Value, value.RuntimeError) {
  // Emit ActorStarted
  emit(config.obs, ActorStarted(
    actor_path: config.actor_path,
    actor_hash: config.actor_hash,
    trigger_type: config.trigger_type,
    trigger_source: config.trigger_source,
    run_id: config.run_id,
    gas: config.gas,
    depth: config.depth,
  ))

  let start_time = system_time()

  case ballast.start_program_with_env(config.program, config.env, config.gas) {
    EvalDone(value, remaining_gas) -> {
      emit(config.obs, ActorCompleted(
        actor_path: config.actor_path,
        actor_hash: config.actor_hash,
        run_id: config.run_id,
        result: summarize_value(value),
        gas_used: config.gas - remaining_gas,
        gas_limit: config.gas,
        effects_performed: 0,
        duration_ms: system_time() - start_time,
      ))
      Ok(value)
    }

    EvalError(error) -> {
      emit(config.obs, ActorCompleted(
        actor_path: config.actor_path,
        actor_hash: config.actor_hash,
        run_id: config.run_id,
        result: "Error(" <> error_to_string(error) <> ")",
        gas_used: config.gas,
        gas_limit: config.gas,
        effects_performed: 0,
        duration_ms: system_time() - start_time,
      ))
      Error(error)
    }

    Yielded(effect_name, args, cont, remaining_gas) -> {
      handle_yielded(config, effect_name, args, cont, remaining_gas, start_time, 1)
    }
  }
}

/// Handle a single yield: emit event, dispatch to handler, emit result, loop.
fn handle_yielded(config, effect_name, args, cont, gas, start_time, count) {
  emit(config.obs, EffectYielded(
    actor_path: config.actor_path,
    actor_hash: config.actor_hash,
    run_id: config.run_id,
    effect_name:,
    args_summary: summarize_args(args),
    depth: config.depth,
  ))

  let effect_start = system_time()

  case dict.get(config.handlers, effect_name) {
    Ok(handler) -> {
      case handler(effect_name, args) {
        Ok(result) -> {
          emit(config.obs, EffectHandled(
            actor_path: config.actor_path,
            actor_hash: config.actor_hash,
            run_id: config.run_id,
            effect_name:,
            result_summary: summarize_value(result),
            duration_ms: system_time() - effect_start,
            depth: config.depth,
          ))

          // Resume ballast and continue the loop
          case ballast.resume(cont, result) {
            EvalDone(value, remaining_gas) -> {
              emit(config.obs, ActorCompleted(
                actor_path: config.actor_path,
                actor_hash: config.actor_hash,
                run_id: config.run_id,
                result: summarize_value(value),
                gas_used: config.gas - remaining_gas,
                gas_limit: config.gas,
                effects_performed: count,
                duration_ms: system_time() - start_time,
              ))
              Ok(value)
            }
            EvalError(error) -> {
              emit(config.obs, ActorCompleted(
                actor_path: config.actor_path,
                actor_hash: config.actor_hash,
                run_id: config.run_id,
                result: "Error(" <> error_to_string(error) <> ")",
                gas_used: config.gas - gas,
                gas_limit: config.gas,
                effects_performed: count,
                duration_ms: system_time() - start_time,
              ))
              Error(error)
            }
            Yielded(next_effect, next_args, next_cont, remaining_gas) -> {
              handle_yielded(
                config, next_effect, next_args, next_cont,
                remaining_gas, start_time, count + 1,
              )
            }
          }
        }
        Error(error) -> Error(error)
      }
    }
    Error(_) -> Error(value.RuntimeError("Unknown effect: " <> effect_name))
  }
}
```

**The runner has zero knowledge of specific effects or triggers.** It's a generic loop. `effect_name` is a string. `trigger_type` is a string. Observability is baked in — you can't forget it.

### Everything calls the runner

```
Webhook handler ──→ yard.runner.run(config) ──→ Result
Cron scheduler ──→ yard.runner.run(config) ──→ Result
Message router ──→ yard.runner.run(config) ──→ Result
chute_exec tool ──→ yard.runner.run(config) ──→ Result (inner, depth=1)
Tests           ──→ yard.runner.run(config) ──→ Result (fake handlers)
```

The trigger is just config fields. The handlers are just a dict. The runner doesn't care.

---

## Host Events — Five Variants

```gleam
// yard/src/yard/obs/events.gleam

pub type HostEvent {
  /// A chute actor started running.
  ActorStarted(
    actor_path: String,      // "actors/triage.chute" — where it lives
    actor_hash: String,      // "a3f7c2e9" — what code it is (version identity)
    trigger_type: String,    // "webhook", "cron", "message", "api", "test"
    trigger_source: String,  // "github", "schedule:5m", "actors/review.chute"
    run_id: String,          // unique correlation ID for this invocation
    gas: Int,
    depth: Int,              // 0 = outer actor, 1+ = inner chute
  )

  /// A chute actor finished running.
  ActorCompleted(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    result: String,
    gas_used: Int,
    gas_limit: Int,
    effects_performed: Int,
    duration_ms: Int,
  )

  /// Ballast yielded an effect. Covers ALL effects for ALL actors.
  EffectYielded(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    args_summary: String,
    depth: Int,
  )

  /// The effect handler returned a result.
  EffectHandled(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    result_summary: String,
    duration_ms: Int,
    depth: Int,
  )

  /// An effect was replayed from a checkpoint (durable runner).
  /// Emitted instead of EffectYielded + EffectHandled when a stored
  /// checkpoint value is fed to Ballast on retry.
  EffectReplayed(
    actor_path: String,
    actor_hash: String,
    run_id: String,
    effect_name: String,
    step: Int,
    depth: Int,
  )
}
```

Five variants. That's it. Every effect, every trigger, every actor is covered. `trigger_type` and `effect_name` are data fields — adding new ones requires zero code changes. (`PigEvent` was an earlier design for bridging pig agent events into the host stream; it is not currently a `HostEvent` variant — see [The Pig Bridge](#the-pig-bridge).)

### Actor identity: `actor_path` vs `actor_hash`

Every event carries both `actor_path` and `actor_hash`. They answer different questions:

| Field | Answers | Example | Changes when... |
|---|---|---|---|
| `actor_path` | *Where* is this actor? | `"actors/triage.chute"` | File is moved/renamed |
| `actor_hash` | *What* code is this? | `"a3f7c2e9"` | Actor source code changes |

The hash is computed from the **S-expression output**, not the raw source. The S-expression is canonical — comments stripped, ExprGroup unwrapped, empty blocks normalized, whitespace eliminated. Two sources that differ only in comments or formatting produce the same hash.

```gleam
// yard/src/yard/loader.gleam

/// Load an actor: parse, desugar, compute hash, return ready-to-run program.
pub type LoadedActor {
  LoadedActor(
    program: ast.Program,
    actor_path: String,
    actor_hash: String,
  )
}

pub fn load(actor_path: String) -> Result(LoadedActor, String) {
  case ballast.prepare(read_file(actor_path)) {
    Error(msg) -> Error(msg)
    Ok(program) -> {
      let sexp = chute.to_sexp(program)
      let hash = sha256_first8(sexp)    // "a3f7c2e9"
      Ok(LoadedActor(program:, actor_path:, actor_hash: hash))
    }
  }
}
```

**What this enables:**

- **Version queries**: "Show me all runs of triage v2" → filter `actor_hash == "a3f7c2e9"`
- **Change detection**: Dashboard shows when a triage run used different code than the previous run
- **Caching**: Same hash = same program. Skip recompilation if already compiled.
- **Audit**: If someone edits `triage.chute`, subsequent runs have a different hash. You can see exactly when the change took effect.
- **Cross-environment**: Same actor deployed to staging and production produces the same hash.

**8 characters (32 bits)** is enough — this isn't a security hash, it's an identity tag. Collisions are astronomically unlikely across a handful of actors. If you want more certainty, use 12 or 16 chars.

---

## Scaling: Many Actors, Many Triggers, Concurrent Runs

### The `run_id` solves correlation

When 50 actors run concurrently, events from all of them flow through the same dispatcher. The `run_id` lets consumers filter:

```jsonl
{"run_id":"r_001","event":"actor_started","actor":"triage.chute","trigger":"webhook","source":"github"}
{"run_id":"r_002","event":"actor_started","actor":"review.chute","trigger":"cron","source":"schedule:5m"}
{"run_id":"r_001","event":"effect_yielded","effect":"clone_repo"}
{"run_id":"r_002","event":"effect_yielded","effect":"list_open_prs"}
{"run_id":"r_001","event":"effect_handled","effect":"clone_repo","duration_ms":348}
{"run_id":"r_002","event":"effect_handled","effect":"list_open_prs","duration_ms":12}
```

Consumers filter by `run_id` to reconstruct a single actor's trace. The dispatcher is a single shared OTP process — it's just message passing, BEAM handles the concurrency.

### Triggers are not event types — they're metadata

The previous design had `WebhookReceived` as a hardcoded variant. But triggers can be anything:

| Trigger | `trigger_type` | `trigger_source` |
|---|---|---|
| GitHub webhook | `"webhook"` | `"github"` |
| Slack slash command | `"webhook"` | `"slack"` |
| Cron (every 5 min) | `"cron"` | `"schedule:5m"` |
| Another actor sending a message | `"message"` | `"actors/review.chute"` |
| Manual API call | `"api"` | `"cli"` |
| Test invocation | `"test"` | `"triage_opened_issue_test"` |

The runner doesn't care. The trigger code builds a `RunConfig` with these fields. The runner emits them. Consumers read them.

### Trigger code is thin

Each trigger type is a small adapter that:
1. Receives the external stimulus (HTTP request, cron tick, message)
2. Builds a `RunConfig` with the right actor, env, and handlers
3. Calls `yard.runner.run(config)`
4. Returns the result to the stimulus source

```gleam
// yard/src/yard/trigger/webhook.gleam

pub fn handle(request, actor_path, handlers, obs) {
  let assert Ok(actor) = yard.loader.load(actor_path)
  let env = parse_webhook_to_env(request.body)
  let run_id = "r_" <> uuid.v4()

  let config = RunConfig(
    program: actor.program,
    env:,
    gas: 50_000,
    handlers:,
    obs:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id:,
    trigger_type: "webhook",
    trigger_source: request.headers["x-github-event"],
    depth: 0,
  )

  case yard.runner.run(config) {
    Ok(_) -> response(200, "OK")
    Error(error) -> response(500, error_to_string(error))
  }
}

// yard/src/yard/trigger/cron.gleam

pub fn tick(actor_path, handlers, obs) {
  let assert Ok(actor) = yard.loader.load(actor_path)
  let run_id = "r_" <> uuid.v4()

  let config = RunConfig(
    program: actor.program,
    env: NilVal,       // cron has no payload
    gas: 100_000,
    handlers:,
    obs:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id:,
    trigger_type: "cron",
    trigger_source: "schedule:5m",
    depth: 0,
  )

  case yard.runner.run(config) {
    Ok(value) -> io.println("Cron done: " <> summarize_value(value))
    Error(error) -> io.println("Cron error: " <> error_to_string(error))
  }
}
```

### The dispatcher is shared, not per-actor

One dispatcher process for the whole system. All runners emit to it. This is fine — it's just Erlang message passing. The dispatcher doesn't do IO; it fans out to consumers. Consumers do IO (write files, print to terminal, send to OTel).

```
┌─────────┐ ┌─────────┐ ┌─────────┐
│ Runner 1 │ │ Runner 2 │ │ Runner 3 │    ← concurrent BEAM processes
│(triage)  │ │(review)  │ │(deploy)  │
└────┬─────┘ └────┬─────┘ └────┬─────┘
     │             │             │
     └─────────────┼─────────────┘
                   │
                   ▼
         ┌─────────────────┐
         │  Dispatcher     │    ← single shared OTP actor
         │  (fan out)      │
         └──┬──────┬───────┘
            │      │
    ┌───────▼┐  ┌──▼──────────┐  ┌──▼──────────┐
    │ Session │  │ Terminal    │  │ pg_events   │    ← consumers (also OTP actors)
    │ Writer  │  │ Printer     │  │ → Postgres  │
    │(JSONL)  │  │ (stdout)    │  │ yard_events │
    └─────────┘  └─────────────┘  └─────────────┘
```

If the dispatcher becomes a bottleneck (unlikely at normal webhook volumes), you can shard by `run_id` prefix. But BEAM message passing is fast — pig uses the same pattern for agent events.

---

## The Pig Bridge

> **Current state:** Yard no longer defines a `PigEvent` variant on `HostEvent`. Pig agents keep their own observability stack (pig's dispatcher + pig consumers), and yard observes the host side (`ActorStarted`/`EffectYielded`/`EffectHandled`/`ActorCompleted`) around the `run_agent` call. The forwarding pattern below is retained as design context for reconnecting the two streams; it is not wired up today.

When the `run_agent` handler starts a pig agent, it can register a forwarding consumer with pig's dispatcher. Pig events would be wrapped with the host's `run_id` for correlation:

```gleam
// Inside the run_agent effect handler:

fn run_agent_handler(handlers, obs, actor_path, run_id) -> EffectHandler {
  fn(_name, args) {
    // ... extract request fields ...

    // Forwarding consumer: pig → host
    let forwarder = actor.new(...)
      |> actor.on_message(fn(state, pig_event) {
        process.send(obs, Event(PigEvent(
          actor_path:,
          actor_hash:,
          run_id:,
          event: pig_event,
        )))
        actor.continue(state)
      })

    let consumer_specs = [forwarder_spec]
    let assert Ok(agent) = pig.supervisor.start_supervised(config, consumer_specs)

    case pig.supervisor.run(agent, task) {
      Ok(result) -> Ok(StringVal(result.content))
      Error(e) -> Ok(ErrorVal(StringVal(error_to_string(e))))
    }
  }
}
```

---

## The inner runner (chute_exec)

The same `yard.runner.run` function handles inner chute programs too. The `chute_exec` pig tool handler builds a `RunConfig` with `depth: 1` and workspace-scoped handlers:

```gleam
// Inside the chute_exec pig tool handler:

fn chute_exec_handler(workspace_root, outer_obs, actor_path, actor_hash, run_id) {
  fn(source, env) {
    case chute.parse(source) {
      Error(msg) -> Error("Parse error: " <> msg)
      Ok(program) -> {
        let program = chute.desugar(program)
        let inner_hash = sha256_first8(chute.to_sexp(program))
        let config = RunConfig(
          program:,
          env: json_to_ballast_value(env),
          gas: 5_000,
          handlers: workspace_handlers(workspace_root),
          obs: outer_obs,
          actor_path:,
          actor_hash: inner_hash,   // hash of the inner program the LLM wrote
          run_id:,    // same run_id — correlated with the outer run
          trigger_type: "chute_exec",
          trigger_source: "agent",
          depth: 1,
        )
        case yard.runner.run(config) {
          Ok(value) -> Ok(ballast_value_to_json(value))
          Error(error) -> Error(error_to_string(error))
        }
      }
    }
  }
}
```

Same runner. Same events. Same `run_id`. The `depth` field distinguishes outer effects from inner effects. Consumers see both in one stream.

---

## JSONL Output Example — Concurrent Runs

Two actors running at the same time, events interleaved:

```jsonl
{"ts":"10:23:01.000","run_id":"r_001","event":"actor_started","actor":"triage.chute","actor_hash":"a3f7c2e9","trigger_type":"webhook","trigger_source":"github","gas":50000,"depth":0}
{"ts":"10:23:01.001","run_id":"r_002","event":"actor_started","actor":"review.chute","actor_hash":"b8d1e4f2","trigger_type":"cron","trigger_source":"schedule:5m","gas":100000,"depth":0}
{"ts":"10:23:01.002","run_id":"r_001","event":"effect_yielded","effect":"clone_repo","depth":0}
{"ts":"10:23:01.010","run_id":"r_002","event":"effect_yielded","effect":"list_open_prs","depth":0}
{"ts":"10:23:01.350","run_id":"r_001","event":"effect_handled","effect":"clone_repo","result":"Ok(StringVal)","duration_ms":348,"depth":0}
{"ts":"10:23:01.355","run_id":"r_001","event":"effect_yielded","effect":"run_agent","depth":0}
{"ts":"10:23:01.400","run_id":"r_002","event":"effect_handled","effect":"list_open_prs","result":"Ok(ListVal)","duration_ms":390,"depth":0}
{"ts":"10:23:01.402","run_id":"r_002","event":"effect_yielded","effect":"run_agent","depth":0}
{"ts":"10:23:04.520","run_id":"r_001","event":"effect_yielded","effect":"read_file","actor_hash":"5c9a1b3d","depth":1}
{"ts":"10:23:04.528","run_id":"r_001","event":"effect_handled","effect":"read_file","actor_hash":"5c9a1b3d","result":"Ok(StringVal)","duration_ms":8,"depth":1}
{"ts":"10:23:06.811","run_id":"r_001","event":"effect_handled","effect":"run_agent","result":"Ok(StringVal)","duration_ms":5459,"depth":0}
{"ts":"10:23:06.812","run_id":"r_001","event":"effect_yielded","effect":"post_comment","depth":0}
{"ts":"10:23:07.200","run_id":"r_001","event":"effect_handled","effect":"post_comment","result":"Ok(OkVal)","duration_ms":388,"depth":0}
{"ts":"10:23:07.201","run_id":"r_001","event":"actor_completed","actor":"triage.chute","actor_hash":"a3f7c2e9","result":"Ok(Nil)","gas_used":65,"effects_performed":3,"duration_ms":6200}
{"ts":"10:23:09.100","run_id":"r_002","event":"effect_handled","effect":"run_agent","result":"Ok(StringVal)","duration_ms":7698,"depth":0}
{"ts":"10:23:09.102","run_id":"r_002","event":"actor_completed","actor":"review.chute","actor_hash":"b8d1e4f2","result":"Ok(Nil)","gas_used":42,"effects_performed":2,"duration_ms":8100}
```

Filter by `run_id` to see a single actor's trace. Filter by `actor_hash` to see all runs of a specific actor version. Filter by `depth` to separate outer from inner effects. Filter by `trigger_type` to see all cron-triggered runs. All from one event stream.

---

## Telemetry Projection

Five event names cover everything:

```
yard.actor.started     [actor_path, actor_hash, trigger_type, trigger_source, run_id, gas, depth]
yard.actor.completed   [actor_path, actor_hash, run_id, duration, gas_used, gas_limit, effects_performed]
yard.effect.yielded    [actor_path, actor_hash, run_id, effect_name, depth]
yard.effect.handled    [actor_path, actor_hash, run_id, effect_name, depth, duration]
yard.effect.replayed   [actor_path, actor_hash, run_id, effect_name, step, depth]
```

The `effect_name` and `trigger_type` are metadata, not part of the event name. Attach once, filter in your handler:

```gleam
// Dashboard: all slow effects across all actors
telemetry.attach("slow-effects", ["yard", "effect", "handled"], fn(_, meas, meta, _) {
  case meas.duration > 1000 {
    True -> dashboard.increment("slow_effect", tags: ["effect:" <> meta.effect_name, "actor:" <> meta.actor_hash])
    False -> Nil
  }
})

// Alert: any actor that fails
telemetry.attach("failure-alert", ["yard", "actor", "completed"], fn(_, _meas, meta, _) {
  case meta.result {
    "Error(" <> _ -> slack.alert(meta.actor_path <> " (" <> meta.actor_hash <> ") failed: " <> meta.result)
    _ -> Nil
  }
})

// Metrics: per-trigger execution counts
telemetry.attach("trigger-metrics", ["yard", "actor", "completed"], fn(_, meas, meta, _) {
  statsd.increment("yard.actor.completed", tags: [
    "trigger:" <> meta.trigger_type,
    "actor:" <> meta.actor_path,
    "version:" <> meta.actor_hash,
  ], value: meas.duration)
})
```

---

## Handler-Specific Telemetry

Things that happen inside handler functions — not in the runner loop — are ad-hoc `:telemetry` calls inside the handler:

| Concern | Where | How |
|---|---|---|
| Path safety violation | Inside `read_file` handler | `telemetry.execute(["yard", "workspace", "path_violation"], ...)` |
| Chute compile failure | Inside `chute_exec` tool handler | Pig's `ToolException` event + optional `:telemetry` |
| GitHub API rate limit | Inside `post_comment` handler | `telemetry.execute(["yard", "github", "rate_limited"], ...)` |
| Token usage per agent | Pig's `pig.inference.stop` | Already emitted by pig, just listen |

**Rule**: Runner loop → `HostEvent` (automatic, covers everything). Handler internals → ad-hoc `:telemetry` (opt-in, for specific concerns).

---

## Tests Get Observability Free

Since tests call `yard.runner.run` with the same config (just fake handlers), they emit the same events. You can assert on the event sequence:

```gleam
pub fn triage_emits_correct_events_test() {
  let obs = test_dispatcher.start()    // in-memory, captures events
  let config = RunConfig(
    program: triage_actor.program,
    env: opened_env,
    gas: 50_000,
    handlers: test_handlers,
    obs: obs.subject,
    actor_path: triage_actor.actor_path,
    actor_hash: triage_actor.actor_hash,
    run_id: "r_test_001",
    trigger_type: "test",
    trigger_source: "triage_opened_issue_test",
    depth: 0,
  )

  let assert Ok(OkVal(NilVal)) = yard.runner.run(config)

  let events = test_dispatcher.events(obs)
  let assert [
    ActorStarted(run_id: "r_test_001", ..),
    EffectYielded(effect_name: "clone_repo", ..),
    EffectHandled(effect_name: "clone_repo", ..),
    EffectYielded(effect_name: "run_agent", ..),
    EffectHandled(effect_name: "run_agent", ..),
    EffectYielded(effect_name: "post_comment", ..),
    EffectHandled(effect_name: "post_comment", ..),
    ActorCompleted(effects_performed: 3, ..),
  ] = events
}
```

Or keep it simple — tests don't need to assert on events at all. The runner emits them as a side effect. Tests just assert on the return value, same as before.

---

## PostgreSQL Events Consumer (pg_events)

The production replacement for the JSONL session writer. `obs/pg_events.gleam` is an OTP consumer that accepts `HostEvent`s directly (same interface as `obs/session.gleam` and `obs/terminal.gleam`) and writes each one to the `yard_events` table in PostgreSQL. Because every consumer receives the same `HostEvent`, registering it is a one-liner and needs no runner changes.

**Schema** (in `yard/src/yard/sql/durable_schema.sql`):

```sql
CREATE TABLE IF NOT EXISTS yard_events (
  id          BIGSERIAL PRIMARY KEY,
  run_id      UUID NOT NULL,
  event_type  TEXT NOT NULL,
  payload     JSONB NOT NULL,
  duration_ms INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_yard_events_run_id ON yard_events(run_id);
```

`run_id` is JOINable with gabsurd's `absurd_runs` and `absurd_checkpoints` (a global FK isn't possible because the per-queue run table name is dynamic).

**API** (`yard/obs/pg_events.gleam`):

```gleam
// Start an unsupervised consumer, get back the Subject to register
pub fn start_consumer(db: Db) -> Result(Subject(HostEvent), StartError)

// Or hand a ChildSpecification to your supervision tree
pub fn supervised(db: Db, name: Name(HostEvent)) -> ChildSpecification(Nil)
```

Internally each message calls `pg_events.record_event(db:, event:)`, which maps the `HostEvent` to `(event_type, payload JSON, duration_ms)` and `INSERT`s it. Writes are fire-and-forget: a failure is logged at `Error` level but does not crash the consumer — observability is best-effort and must not take down the pipeline.

**Wiring it in** — register via the same `ConsumerSpec` mechanism every other consumer uses:

```gleam
import yard/obs/pg_events

let assert Ok(yard_pg) = pg_events.start_consumer(global_conn)
// then register `yard_pg` with the dispatcher,
// or pass a ConsumerSpec into yard.start(consumers)
```

The `examples/hermes-agent` app uses this in production — it starts a `pg_events` consumer against the shared global connection so every run is queryable alongside `absurd_runs`.

---

## Summary

| Question | Answer |
|---|---|
| Where does `run_loop` live? | `yard/src/yard/runner.gleam` — new project, thin layer over ballast |
| Who calls it? | Everything — triggers, tests, inner programs. All go through `yard.runner.run(config)` |
| How do new effects get events? | Automatically. `EffectYielded`/`EffectHandled` carry `effect_name` as data |
| How do new triggers work? | Set `trigger_type`/`trigger_source` in config. Runner emits them as metadata |
| How do concurrent runs correlate? | `run_id` — unique per invocation, carried by every event |
| How do you identify actor versions? | `actor_hash` — SHA-256 of canonical S-expression, first 8 chars |
| How many HostEvent variants? | Five: `ActorStarted`, `ActorCompleted`, `EffectYielded`, `EffectHandled`, `EffectReplayed` |
| How many telemetry event names? | Five: `yard.actor.started`, `yard.actor.completed`, `yard.effect.yielded`, `yard.effect.handled`, `yard.effect.replayed` |
| Production event store? | `obs/pg_events.gleam` → `yard_events` Postgres table (JOINable on `run_id`) |
