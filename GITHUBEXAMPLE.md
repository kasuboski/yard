# GitHub Issue Triage — Host Runtime Design

A concrete example showing how chute, ballast, and pig combine to build a host runtime
that triages GitHub issues via webhook. A chute actor orchestrates the deterministic workflow.
A pig agent handles the intelligent analysis. Test handlers let you verify the whole thing
in microseconds with zero IO.

---

## The Scenario

1. A GitHub webhook fires when an issue is opened.
2. The host runtime receives the webhook, loads the `triage.chute` actor.
3. The actor clones the repo, runs an AI triage agent, posts the report as a comment.
4. The AI agent explores the workspace by writing chute programs via the `chute_exec` tool.

---

## Architecture Overview

```
GitHub webhook POST
    │
    ▼
┌──────────────────────────────────────────────────┐
│  Host Runtime (orchestrator BEAM process)         │
│                                                   │
│  1. Parse webhook payload                         │
│  2. Load actor: actors/triage.chute               │
│  3. Start chute runner with payload as env        │
└────────────┬─────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────┐
│  Chute Runner (effect loop over ballast)          │
│                                                   │
│  Evaluates triage.chute through ballast.          │
│  Ballast yields effects. Runner dispatches each   │
│  to registered handlers. Loops until EvalDone.    │
└────────────┬─────────────────────────────────────┘
             │
   ┌─────────┼─────────────────────────┐
   │         │                         │
   ▼         ▼                         ▼
 clone_repo  run_agent             post_comment
   │         │                         │
   │    ┌────┘                    GitHub API
   │    │
   │    ▼
   │  ┌──────────────────────────────────────────┐
   │  │  Pig Agent                               │
   │  │                                          │
   │  │  System prompt: "You are a triage        │
   │  │  agent. Analyze this issue..."           │
   │  │                                          │
   │  │  Tools available:                        │
   │  │    - chute_exec (write & run chute)      │
   │  │    - workspace tools (optional)          │
   │  │                                          │
   │  │  Skills loaded: triage/SKILL.md           │
   │  └──────────┬───────────────────────────────┘
   │             │
   │             │  LLM decides it needs to explore
   │             │  the repo. Calls chute_exec tool:
   │             │
   │             ▼
   │  ┌──────────────────────────────────────────┐
   │  │  Inner Chute Program (written by LLM)    │
   │  │                                          │
   │  │  effect read_file(path: String)          │
   │  │    -> Result(String, Error)              │
   │  │  effect list_dir(path: String)           │
   │  │    -> Result(List(String), Error)        │
   │  │                                          │
   │  │  pub fn main(env) {                      │
   │  │    env.path                              │
   │  │    |> perform list_dir()                 │
   │  │    |> result.try(fn(files) { ... })      │
   │  │  }                                       │
   │  └──────────┬───────────────────────────────┘
   │             │
   │             │  Inner chute runner handles effects
   │             │  against the workspace:
   │             │
   │             ├── list_dir → fs read from workspace
   │             ├── read_file → fs read from workspace
   │             │
   │             │  Returns typed result to LLM
   │             │
   │             ▼
   │  LLM continues reasoning, writes more chute
   │  programs, eventually returns markdown report.
   │
   ▼
  Runner resumes ballast with agent result string.
  Ballast continues to post_comment effect.
  Runner handles it via GitHub API.
  Ballast completes with Ok(Nil).
```

---

## Why Chute Instead of Bash

The inspiration is flue's agent harness — it gives the LLM direct shell access via `local()`. Chute replaces bash with a sandboxed, typed, capability-declared scripting language.

| Flue: Bash access | Chute: Typed queries |
|---|---|
| Shell injection risks | Effects declared upfront (auditable) |
| Unbounded execution (while loops) | Guaranteed halting (no loops, gas limits) |
| No capability audit trail | Full audit trail of every effect |
| LLM can do anything the process can | Path sandboxing built in |
| | Type checker serves as firewall |

---

## The Actor — `actors/triage.chute`

The deterministic orchestrator — the "what" of the workflow, never the "how":

```gleam
// 1. Verbs — declared capabilities
effect clone_repo(url: String, ref: String) -> Result(Workspace, Error)
effect run_agent(request: AgentRequest) -> Result(String, Error)
effect post_comment(repo: String, issue: Int, body: String) -> Result(Nil, Error)

// 2. Nouns — standardized entrypoint
pub fn main(env: {
  action: String,
  issue: { number: Int, title: String, body: String, labels: List(String) },
  repository: { full_name: String, clone_url: String }
}) -> Result(Nil, Error) {

  case env.action == "opened" {
    True -> {
      env.repository.clone_url
      |> perform clone_repo("main")
      |> result.try(fn(ws) {
        perform run_agent({
          workspace: ws,
          task: "Analyze this issue for severity and reproducibility",
          model: "anthropic/claude-opus-4-7",
          skills: ["triage"],
        })
      })
      |> result.try(fn(report) {
        perform post_comment(
          env.repository.full_name,
          env.issue.number,
          report,
        )
      })
    }
    False -> Ok(Nil)
  }
}
```

Key properties:
- **Pure computation + declared intents.** It doesn't decide *how* to triage — it says *what* needs to happen and in *what order*.
- **`run_agent` returns `String`.** pig.run() already returns the assistant's final message text. The agent's skill tells it to format as markdown. The chute program passes the string directly to `post_comment`.
- **`result.try` short-circuits.** If clone fails, the agent never runs. If the agent fails, no comment is posted.

---

## Two Layers

The runtime has two nested effect loops:

### Outer layer — chute actor + host runner

Deterministic workflow: parse webhook → clone repo → run agent → post comment.

| Component | Role |
|---|---|
| `triage.chute` | Declares effects, chains them with pipelines |
| ballast eval | CPS tree-walking evaluator, yields on `perform` |
| effect handlers | Host-provided implementations for each effect |

### Inner layer — pig agent + chute tool

Intelligent reasoning: LLM explores workspace via `chute_exec` tool.

| Component | Role |
|---|---|
| pig agent | LLM session with skills and tools |
| `chute_exec` tool | Pig tool that compiles + runs chute programs |
| workspace | Cloned repo files, accessed via inner effect handlers |

---

## The Chute Runner

The core host component — a simple loop over ballast's existing yield/resume protocol:

```gleam
// The runner's contract
pub type EffectHandler =
  fn(String, List(ballast.Value)) -> Result(ballast.Value, ballast.RuntimeError)

// The effect loop
fn run_loop(
  program: chute.Program,
  env: ballast.Value,
  gas: Int,
  handlers: Dict(String, EffectHandler),
) -> Result(ballast.Value, ballast.RuntimeError) {
  case ballast.start_program_with_env(program, env, gas) {
    ballast.EvalDone(value, _) -> Ok(value)
    ballast.EvalError(error) -> Error(error)
    ballast.Yielded(effect, args, cont, remaining_gas) -> {
      case dict.get(handlers, effect) {
        Ok(handler) -> {
          case handler(effect, args) {
            Ok(result) -> run_loop_resume(cont, result, remaining_gas, handlers)
            Error(error) -> Error(error)
          }
        }
        Error(_) -> Error(RuntimeError("Unknown effect: " <> effect))
      }
    }
  }
}

fn run_loop_resume(cont, value, gas, handlers) {
  case ballast.resume(cont, value) {
    ballast.EvalDone(value, _) -> Ok(value)
    ballast.EvalError(error) -> Error(error)
    ballast.Yielded(effect, args, cont, remaining_gas) -> {
      case dict.get(handlers, effect) {
        Ok(handler) -> {
          case handler(effect, args) {
            Ok(result) -> run_loop_resume(cont, result, remaining_gas, handlers)
            Error(error) -> Error(error)
          }
        }
        Error(_) -> Error(RuntimeError("Unknown effect: " <> effect))
      }
    }
  }
}
```

Ballast gives us 90% of this already. The runner is just a `while (yielded) { handle; resume }` loop.

---

## Effect Handlers

### clone_repo handler

```gleam
fn clone_repo_handler() -> EffectHandler {
  fn(_effect, args) {
    let assert [StringVal(url), StringVal(ref)] = args
    // Clone the repo to a temp workspace directory
    case git.clone(url, ref) {
      Ok(workspace_path) -> Ok(StringVal(workspace_path))
      Error(msg) -> Ok(ErrorVal(StringVal(msg)))
    }
  }
}
```

### run_agent handler

```gleam
fn run_agent_handler(runner_for_workspace) -> EffectHandler {
  fn(_effect, args) {
    let assert [RecordVal(fields)] = args
    let fields_dict = dict.from_list(fields)
    let assert Ok(StringVal(workspace)) = dict.get(fields_dict, "workspace")
    let assert Ok(StringVal(task)) = dict.get(fields_dict, "task")
    let assert Ok(StringVal(model)) = dict.get(fields_dict, "model")
    let assert Ok(ListVal(skills)) = dict.get(fields_dict, "skills")

    // Configure pig agent with chute_exec tool
    let chute_exec = chute_exec_tool(runner_for_workspace(workspace))
    let config = pig.new(provider_for_model(model))
      |> pig.with_tool(chute_exec)
      |> pig.with_skills(list.map(skills, fn(s) {
        skill.load("skills/" <> s)
      }))
      |> pig.with_system_prompt("You are a triage agent. Analyze the issue and produce a markdown report.")

    let assert Ok(agent) = pig.start(config)
    case pig.run(agent, task) {
      Ok(result_message) -> {
        // Final message text → StringVal, resume outer chute
        Ok(StringVal(result_message.content))
      }
      Error(_) -> Ok(ErrorVal(StringVal("Agent failed")))
    }
  }
}
```

### post_comment handler

```gleam
fn post_comment_handler() -> EffectHandler {
  fn(_effect, args) {
    let assert [StringVal(repo), IntVal(issue), StringVal(body)] = args
    case github.post_comment(repo, issue, body) {
      Ok(_) -> Ok(OkVal(NilVal))
      Error(msg) -> Ok(ErrorVal(StringVal(msg)))
    }
  }
}
```

---

## The chute_exec Pig Tool

This is the bridge — a pig tool that lets the LLM write and run chute programs against the workspace:

```gleam
fn chute_exec_tool(workspace_runner) -> pig.Tool {
  pig.tool(
    name: "chute_exec",
    description: "Write and execute a chute program to explore the workspace.
                  Declare effects for file operations: read_file, list_dir,
                  grep, file_exists. The program runs sandboxed with guaranteed
                  halting. Return a Result from main.",
  )
  |> pig.with_param("source", String, "Chute source code")
  |> pig.with_param("env", Json, "JSON env passed to main")
  |> pig.with_handler(fn(args) {
    let env_val = json_to_ballast_value(args.env)

    // Compile + type check first (catches LLM syntax errors fast)
    case chute.parse(args.source) {
      Error(msg) -> {
        Ok(json.object([
          #("ok", json.bool(False)),
          #("error", json.string("Parse error: " <> msg)),
        ]))
      }
      Ok(program) -> {
        let program = chute.desugar(program)
        case chute.typecheck(program) {
          Error(type_errors) -> {
            Ok(json.object([
              #("ok", json.bool(False)),
              #("error", json.string("Type error: " <> format_type_errors(type_errors))),
            ]))
          }
          Ok(_) -> {
            // Run with workspace-bound handlers (read_file, list_dir, grep)
            case workspace_runner(program, env_val, 5000) {
              Ok(value) -> Ok(ballast_value_to_json(value))
              Error(error) -> Ok(json.object([
                #("ok", json.bool(False)),
                #("error", json.string(runtime_error_to_string(error))),
              ]))
            }
          }
        }
      }
    }
  })
}
```

When the LLM calls `chute_exec`, it writes a chute program like:

```gleam
// What the LLM writes to explore the repo:
effect read_file(path: String) -> Result(String, Error)
effect list_dir(path: String) -> Result(List(String), Error)

pub fn main(env: { root: String }) -> Result(List(String), Error) {
  perform list_dir("src/")
  |> result.try(fn(files) {
    Ok(list.filter(files, fn(f) { string.contains(f, "error") }))
  })
}
```

The host binds `read_file`, `list_dir`, etc. to the current workspace implicitly — the LLM doesn't pass workspace IDs, just relative paths. The host path-sandboxes automatically.

---

## Workspace Effect Handlers (inner level)

These handle effects from chute programs the LLM writes:

```gleam
fn read_file_handler(workspace_root: String) -> EffectHandler {
  fn(_effect, args) {
    let assert [StringVal(path)] = args
    let full_path = workspace_root <> "/" <> path
    case path_is_safe(path) {
      True -> {
        case file.read(full_path) {
          Ok(content) -> Ok(StringVal(content))
          Error(_) -> Ok(ErrorVal(StringVal("File not found: " <> path)))
        }
      }
      False -> Ok(ErrorVal(StringVal("Path traversal denied: " <> path)))
    }
  }
}

fn list_dir_handler(workspace_root: String) -> EffectHandler {
  fn(_effect, args) {
    let assert [StringVal(path)] = args
    let full_path = workspace_root <> "/" <> path
    case path_is_safe(path) {
      True -> {
        case file.list_dir(full_path) {
          Ok(entries) -> Ok(ListVal(list.map(entries, StringVal)))
          Error(_) -> Ok(ErrorVal(StringVal("Directory not found: " <> path)))
        }
      }
      False -> Ok(ErrorVal(StringVal("Path traversal denied")))
    }
  }
}

fn path_is_safe(path: String) -> Bool {
  // Reject paths containing ".." or starting with "/"
  !string.contains(path, "..") && !string.starts_with(path, "/")
}
```

---

## Host Orchestrator

The top-level component that ties everything together:

```gleam
pub fn main() {
  // Compile actors once at startup
  let assert Ok(triage_actor) = load_actor("actors/triage.chute")

  // Build runner with effect handlers
  let runner = chute_runner.new()
    |> chute_runner.with_handler("clone_repo", clone_repo_handler())
    |> chute_runner.with_handler("run_agent", run_agent_handler(/* ... */))
    |> chute_runner.with_handler("post_comment", post_comment_handler())

  // Start webhook server with configured routes
  http_server.start(fn(req) {
    case req.path {
      ["/webhook", "github"] -> {
        let payload = parse_github_webhook(req.body)
        let env = webhook_to_ballast_env(payload)

        case runner.run(triage_actor, env, 50_000) {
          Ok(_) -> response(200, "OK")
          Error(error) -> response(500, error_to_string(error))
        }
      }
      _ -> response(404, "Not found")
    }
  })
}
```

Actor routes are configured explicitly at startup — no auto-discovery:

```gleam
// routes configuration
let routes = [
  #("/webhook/github", "actors/triage.chute"),
  #("/webhook/slack", "actors/respond.chute"),
]
```

---

## Agent Output

`run_agent` returns `Result(String, Error)` — the agent's final response as a plain string.

pig.run() already returns the assistant's final message text. The agent's skill instructs it to format the output (markdown report, summary, etc). The chute program passes the string directly.

```gleam
// In the chute actor — report is just a string
|> result.try(fn(report) {
    perform post_comment(
      env.repository.full_name,
      env.issue.number,
      report,    // ← markdown string from pig agent
    )
  })
```

**Why string, not structured data?** In most scenarios the chute program is pure plumbing — it delivers the agent's output to its destination. The agent owns the formatting. The chute program doesn't need to understand or branch on the content. If a future scenario needs the chute to branch on agent output fields (e.g., "if severity is critical, also send a Slack alert"), the effect return type can be upgraded to a structured record.

---

## Testing

The chute runner is just a loop over ballast's yield/resume with a dict of handler functions. In tests, you swap real handlers for **deterministic fakes**. The entire actor runs in microseconds — no git clone, no pig agent, no GitHub API.

Each test handler is a pure function: `(effect_name, args) → Result(Value, RuntimeError)`. It inspects the args, asserts what it expects, and returns a canned response.

### Test helper

```gleam
import chute
import ballast
import ballast/value

// Load the real actor — same source that runs in production
const actor_source = "actors/triage.chute"

fn run_actor(handlers, env, gas) {
  let assert Ok(program) = chute.parse(actor_source)
  let program = chute.desugar(program)
  runner.run_loop(program, env, gas, handlers)
}
```

### Test 1: Happy path, issue opened

```gleam
pub fn triage_opened_issue_test() {
  let handlers = dict.from_list([
    // When the actor clones the repo, return a fake workspace ref
    #("clone_repo", fn(_name, args) {
      let assert [StringVal(url), StringVal(ref)] = args
      // Verify the actor passes the right args
      let assert url == "https://github.com/org/repo.git"
      let assert ref == "main"
      Ok(StringVal("ws:test-workspace"))
    }),

    // When the actor runs the agent, return a fake markdown report
    #("run_agent", fn(_name, args) {
      let assert [RecordVal(fields)] = args
      let fields_dict = dict.from_list(fields)
      let assert Ok(StringVal(task)) = dict.get(fields_dict, "task")
      let assert task == "Analyze this issue for severity and reproducibility"
      Ok(StringVal("## Triage Report\n\n**Severity:** low"))
    }),

    // When the actor posts a comment, verify the body contains the report
    #("post_comment", fn(_name, args) {
      let assert [
        StringVal(repo),
        IntVal(issue_num),
        StringVal(body),
      ] = args
      let assert repo == "org/repo"
      let assert issue_num == 42
      let assert string.contains(body, "## Triage Report")
      Ok(OkVal(NilVal))
    }),
  ])

  // Build the webhook payload (what GitHub would send)
  let env = RecordVal([
    #("action", StringVal("opened")),
    #("issue", RecordVal([
      #("number", IntVal(42)),
      #("title", StringVal("Crash on startup")),
      #("body", StringVal("App crashes when launched with no config")),
    ])),
    #("repository", RecordVal([
      #("full_name", StringVal("org/repo")),
      #("clone_url", StringVal("https://github.com/org/repo.git")),
    ])),
  ])

  // Run the real actor with fake handlers
  let result = run_actor(handlers, env, 50_000)

  // Verify final result
  let assert Ok(OkVal(NilVal)) = result
}
```

### Test 2: Non-opened action is ignored

```gleam
pub fn triage_ignores_closed_issue_test() {
  // No handlers needed — nothing should be called
  let handlers = dict.new()

  let env = RecordVal([
    #("action", StringVal("closed")),
    #("issue", RecordVal([
      #("number", IntVal(42)),
      #("title", StringVal("Fixed")),
      #("body", StringVal("All good")),
    ])),
    #("repository", RecordVal([
      #("full_name", StringVal("org/repo")),
      #("clone_url", StringVal("https://github.com/org/repo.git")),
    ])),
  ])

  let result = run_actor(handlers, env, 50_000)
  let assert Ok(OkVal(NilVal)) = result
}
```

### Test 3: Clone failure propagates

```gleam
pub fn triage_clone_failure_test() {
  let handlers = dict.from_list([
    #("clone_repo", fn(_name, _args) {
      // Simulate a git clone failure
      Ok(ErrorVal(StringVal("clone failed: auth error")))
    }),
  ])

  let env = RecordVal([
    #("action", StringVal("opened")),
    #("issue", RecordVal([
      #("number", IntVal(42)),
      #("title", StringVal("Crash")),
      #("body", StringVal("...")),
    ])),
    #("repository", RecordVal([
      #("full_name", StringVal("org/repo")),
      #("clone_url", StringVal("https://github.com/org/repo.git")),
    ])),
  ])

  let result = run_actor(handlers, env, 50_000)

  // result.try short-circuits — run_agent and post_comment never called
  let assert Ok(ErrorVal(StringVal("clone failed: auth error"))) = result
}
```

### Test 4: Unknown effect causes error

```gleam
pub fn triage_unknown_effect_test() {
  let handlers = dict.new()  // empty — no handlers registered

  let env = RecordVal([
    #("action", StringVal("opened")),
    #("issue", RecordVal([
      #("number", IntVal(42)),
      #("title", StringVal("Crash")),
      #("body", StringVal("...")),
    ])),
    #("repository", RecordVal([
      #("full_name", StringVal("org/repo")),
      #("clone_url", StringVal("https://github.com/org/repo.git")),
    ])),
  ])

  let result = run_actor(handlers, env, 50_000)

  // Runner returns error for unhandled effect
  let assert Error(RuntimeError("Unknown effect: clone_repo")) = result
}
```

### What the tests verify

| What's being tested | What's faked |
|---|---|
| The real actor source code (not a mock) | git clone → canned workspace ref |
| Control flow branching (opened vs closed) | pig agent → canned markdown string |
| Pipeline chaining (result.try short-circuits) | GitHub API → asserts args, returns Ok(Nil) |
| Effect argument construction | Zero IO, zero network, runs in <1ms |
| Error propagation from handlers | Fully deterministic, no flakiness |

The test handlers are pure Gleam functions — trivially composable. Share common handlers between tests, layer on assertions, or build a `handlers_for("triage")` helper that returns a standard set with overrides.

---

## Audit Trail

Every webhook processing produces a full trace — both the deterministic chute orchestration and the LLM's exploration programs are fully observable:

```
Actor: actors/triage.chute
├── Yielded: clone_repo("https://github.com/org/repo", "main")
│   └── Resumed: Ok(ws:abc123)
├── Yielded: run_agent({ task: "Analyze...", model: "claude-opus-4-7" })
│   ├── Agent session started (pig)
│   ├── Tool call: chute_exec("effect read_file(...) ...")
│   │   ├── Yielded: read_file("src/main.gleam")
│   │   │   └── Resumed: Ok("pub fn main() { ...")
│   │   └── Result: { ok: true, value: "pub fn main() { ..." }
│   ├── Tool call: chute_exec("effect grep(...) ...")
│   │   ├── Yielded: grep("error", "src/")
│   │   │   └── Resumed: Ok([{ file: "src/error.gleam", line: 42 }])
│   │   └── Result: { ok: true, value: [...] }
│   └── Agent result: "## Triage Report\n\n**Severity:** high..."
│   └── Resumed: Ok("## Triage Report...")
├── Yielded: post_comment("org/repo", 42, "## Triage Report...")
│   └── Resumed: Ok(Nil)
└── Actor completed: Ok(Nil)
```

---

## Design Decisions

### Workspace effects are implicit
Inner chute programs don't reference the workspace by ID. The host binds `read_file`/`list_dir`/`grep` to the current workspace automatically. Paths are relative to the repo root. Keeps LLM programs simple and lets the host enforce path sandboxing.

### Actor routes configured at startup
No auto-discovery. The host maps webhook paths to chute actors explicitly in runtime setup code. Simple, explicit, auditable.

### Agent returns string
`run_agent` returns `Result(String, Error)`. pig.run() already returns the assistant's final message text. The agent's skill tells it to format as markdown. The chute program passes the string directly. If a future scenario needs the chute to branch on agent output fields, the return type can be upgraded to a structured record — the host would extract a schema from the chute type and use it to parse the LLM's response.

### Actor-to-actor messaging
`send_message(actor: String, payload: Value) -> Result(Nil, Error)` effect. The host routes it to another chute actor's runner. Actor model on top of BEAM.

### Concurrent agents
One chute actor can kick off multiple pig agents via `task.dispatch_all` with agent effects. Natural on BEAM — each pig agent is a separate process.

---

## Components to Build

| Component | Depends On | Effort |
|-----------|-----------|--------|
| Chute Runner (effect loop) | ballast API | Small — loop over yield/resume |
| Effect Handler Registry | Nothing | Small — dict of named handlers |
| Workspace Effects (read_file, list_dir, grep) | Runner | Small — thin wrappers over filesystem |
| Chute Exec Tool (pig tool) | pig, runner | Medium — JSON↔Value conversion, error formatting |
| Agent Effect Handler | pig, runner | Medium — agent lifecycle management |
| Host Orchestrator (webhook → actor → runner) | All above | Medium — HTTP, routing, lifecycle |
| Path safety (traversal prevention) | Nothing | Small but critical |
