//// Issue Tracker Sync — Periodic Host Runtime
////
//// Periodically scans GitHub tracking issues and logs what comments
//// would be posted when their status tables are out of date.
//// Uses yard, ballast, chute, and pig.
////
//// The chute actor orchestrates the sync:
////   1. fetch_issue     — GET tracking issue body (markdown table)
////   2. fetch_linked    — batch GET state of all linked issues/PRs
////   3. run_agent       — pig agent compares table vs reality
////   4. update_issue    — logs the comment (does NOT post to GitHub)
////
//// The actor uses `let try` for error propagation and `case` to skip
//// the comment when the agent responds NO_CHANGES.
////
//// Environment variables:
////   OPENAI_COMPAT_BASE_URL  LLM endpoint (default: http://localhost:11434/v1)
////   OPENAI_COMPAT_API_KEY   API key (default: ollama)
////   OPENAI_COMPAT_MODEL     Model name (default: llama3)
////   GITHUB_TOKEN            GitHub personal access token
////
//// Running: `gleam run`
////
//// See GITHUBEXAMPLE.md for the full design document.

import ballast/value.{
  type Value, ErrorVal, IntVal, ListVal, NilVal, OkVal, RecordVal, StringVal,
  error_to_string, value_to_string,
}
import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import pig
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import yard/durability
import yard/loader
import yard/obs/dispatcher
import yard/obs/events.{type HostEvent}
import yard/obs/session
import yard/obs/terminal
import yard/runner.{type EffectHandler, type RunConfig, RunConfig}

// ═══════════════════════════════════════════════════════════════════════
// Chute Actor Source
// ═══════════════════════════════════════════════════════════════════════

/// The sync actor — the deterministic orchestrator.
///
/// Uses `let try` for clean error propagation and `case` with pattern
/// matching to skip the GitHub comment when nothing changed.
pub const sync_actor_source = "
  effect fetch_issue(repo: String, number: Int) -> Result(String, String)
  effect fetch_linked(repo: String, numbers: List(Int)) -> Result(String, String)
  effect run_agent(context: String, task: String) -> Result(String, String)
  effect update_issue(repo: String, number: Int, comment_body: String) -> Result(Nil, String)

  pub fn main(env: { repo: String, tracking_number: Int, linked_numbers: List(Int) }) -> Result(Nil, String) {

    // 1. Fetch data. If any fail, the actor immediately returns the Error.
    let try issue_body = perform fetch_issue(env.repo, env.tracking_number)
    let try linked_state = perform fetch_linked(env.repo, env.linked_numbers)

    // 2. Prepare the prompt
    let prompt_context = \"${issue_body}\\n\\n---\\n\\nLinked issue states:\\n${linked_state}\"
    let task = \"Compare tracking table to state. If no changes, respond NO_CHANGES. Otherwise, comment what changed.\"

    // 3. Run the agent
    let try agent_result = perform run_agent(prompt_context, task)

    // 4. Branch on the result
    case agent_result {
      \"NO_CHANGES\" -> Ok(Nil)
      _ -> perform update_issue(env.repo, env.tracking_number, agent_result)
    }
  }
"

// ═══════════════════════════════════════════════════════════════════════
// Config — Environment Variables
// ═══════════════════════════════════════════════════════════════════════

fn openai_base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn openai_api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn openai_model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

fn github_token() -> Result(String, Nil) {
  envoy.get("GITHUB_TOKEN") |> result.replace_error(Nil)
}

// ═══════════════════════════════════════════════════════════════════════
// Building Environments
// ═══════════════════════════════════════════════════════════════════════

/// Build a sync actor env from repo, tracking issue number, and linked numbers.
pub fn sync_env(
  repo: String,
  tracking_number: Int,
  linked_numbers: List(Int),
) -> Value {
  RecordVal([
    #("repo", StringVal(repo)),
    #("tracking_number", IntVal(tracking_number)),
    #("linked_numbers", ListVal(list.map(linked_numbers, fn(n) { IntVal(n) }))),
  ])
}

// ═══════════════════════════════════════════════════════════════════════
// GitHub API Helpers
// ═══════════════════════════════════════════════════════════════════════

/// Make an authenticated GET request to the GitHub API.
fn github_get(url: String) -> Result(String, String) {
  case github_token() {
    Error(Nil) -> Error("GITHUB_TOKEN not set")
    Ok(token) -> {
      let assert Ok(req) = request.to(url)
      let req =
        req
        |> request.set_header("accept", "application/vnd.github+json")
        |> request.set_header("authorization", "Bearer " <> token)
        |> request.set_header("user-agent", "yard-issue-triage-example")
      case httpc.send(req) {
        Ok(resp) -> {
          case resp.status >= 200 && resp.status < 300 {
            True -> Ok(resp.body)
            False ->
              Error(
                "GitHub API error: HTTP "
                <> int.to_string(resp.status)
                <> " — "
                <> resp.body,
              )
          }
        }
        Error(err) -> Error("HTTP request failed: " <> string.inspect(err))
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// JSON Decoders
// ═══════════════════════════════════════════════════════════════════════

/// Decode the issue body from a GitHub issue JSON response.
fn decode_issue_body(json_str: String) -> String {
  let decoder =
    decode.optional_field("body", "", decode.string, fn(body) {
      decode.success(body)
    })
  case json.parse(json_str, using: decoder) {
    Ok(body) -> body
    Error(_) -> ""
  }
}

/// Decode state and title from a GitHub issue JSON response.
fn decode_issue_state_title(
  json_str: String,
) -> Result(#(String, String), Nil) {
  let decoder =
    decode.field("state", decode.string, fn(state) {
      decode.field("title", decode.string, fn(title) {
        decode.success(#(state, title))
      })
    })
  case json.parse(json_str, using: decoder) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(Nil)
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Extracting Linked Issue Numbers
// ═══════════════════════════════════════════════════════════════════════

/// Extract all #NNN references from a markdown body.
/// Returns deduplicated, sorted issue numbers.
pub fn extract_issue_numbers(body: String) -> List(Int) {
  extract_numbers(body, set.new(), [])
  |> list.unique()
  |> list.sort(int.compare)
}

fn extract_numbers(
  s: String,
  seen: set.Set(String),
  acc: List(Int),
) -> List(Int) {
  case string.pop_grapheme(s) {
    Error(Nil) -> acc
    Ok(pair) -> {
      let #(ch, rest) = pair
      case ch {
        "#" -> {
          case scan_digits(rest, "") {
            "" -> extract_numbers(rest, seen, acc)
            digits -> {
              case set.contains(seen, digits) {
                True -> extract_numbers(rest, seen, acc)
                False ->
                  extract_numbers(
                    rest,
                    set.insert(seen, digits),
                    [result.unwrap(int.parse(digits), 0), ..acc]
                      |> list.filter(fn(n) { n > 0 }),
                  )
              }
            }
          }
        }
        _ -> extract_numbers(rest, seen, acc)
      }
    }
  }
}

fn scan_digits(s: String, acc: String) -> String {
  case string.pop_grapheme(s) {
    Ok(pair) -> {
      let #(ch, rest) = pair
      case is_digit(ch) {
        True -> scan_digits(rest, acc <> ch)
        False -> acc
      }
    }
    Error(Nil) -> acc
  }
}

fn is_digit(ch: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], ch)
}

// ═══════════════════════════════════════════════════════════════════════
// Real Effect Handlers
// ═══════════════════════════════════════════════════════════════════════

/// fetch_issue handler — GET the issue body via GitHub API.
pub fn fetch_issue_handler() -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(repo), IntVal(number)] -> {
        let url =
          "https://api.github.com/repos/"
          <> repo
          <> "/issues/"
          <> int.to_string(number)
        case github_get(url) {
          Ok(body) -> Ok(OkVal(StringVal(decode_issue_body(body))))
          Error(err) -> Ok(ErrorVal(StringVal(err)))
        }
      }
      _ -> Ok(ErrorVal(StringVal("Invalid args for fetch_issue")))
    }
  }
}

/// fetch_linked handler — batch GET state for all linked issue numbers.
///
/// Returns structured text, one line per issue:
///   #134: open, title: "Fix: N+1 queries..."
///   #147: closed, title: "Fix issues #127, #128..."
pub fn fetch_linked_handler() -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(repo), ListVal(numbers)] -> {
        let lines =
          numbers
          |> list.map(fn(val) {
            case val {
              IntVal(num) -> {
                let url =
                  "https://api.github.com/repos/"
                  <> repo
                  <> "/issues/"
                  <> int.to_string(num)
                case github_get(url) {
                  Ok(body) -> {
                    case decode_issue_state_title(body) {
                      Ok(#(state, title)) ->
                        "#"
                        <> int.to_string(num)
                        <> ": "
                        <> state
                        <> ", title: \""
                        <> title
                        <> "\""
                      Error(Nil) ->
                        "#" <> int.to_string(num) <> ": ERROR — decode failed"
                    }
                  }
                  Error(err) -> "#" <> int.to_string(num) <> ": ERROR — " <> err
                }
              }
              _ -> "INVALID"
            }
          })
          |> string.join("\n")
        Ok(OkVal(StringVal(lines)))
      }
      _ -> Ok(ErrorVal(StringVal("Invalid args for fetch_linked")))
    }
  }
}

/// run_agent handler — pig agent compares tracking table vs reality.
///
/// The agent receives the tracking issue body + linked issue states
/// and responds with either "NO_CHANGES" or a markdown diff.
pub fn run_agent_handler() -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(context), StringVal(task)] -> {
        let provider =
          openai.provider_with_base_url(
            openai_api_key(),
            openai_model(),
            openai_base_url(),
          )

        let cfg =
          pig.new(provider.call)
          |> pig.with_model("issue_sync")
          |> pig.with_system_prompt(sync_system_prompt())
          |> pig.with_terminal_output()

        case pig.start(cfg) {
          Error(_) -> Ok(ErrorVal(StringVal("Failed to start pig agent")))
          Ok(agent) -> {
            let prompt = context <> "\n\nTask: " <> task
            let pig_result = pig.run_with_timeout(agent, prompt, 120_000)
            pig.stop(agent)

            case pig_result {
              Ok(message.Assistant(content:, ..)) ->
                Ok(OkVal(StringVal(content)))
              Ok(_) ->
                Ok(ErrorVal(StringVal("Agent returned unexpected response")))
              Error(error.Timeout) -> Ok(ErrorVal(StringVal("Agent timed out")))
              Error(error.RateLimited) ->
                Ok(ErrorVal(StringVal("Agent rate limited")))
              Error(error.ApiError(msg)) ->
                Ok(ErrorVal(StringVal("Agent API error: " <> msg)))
              Error(error.InvalidResponse(detail)) ->
                Ok(ErrorVal(StringVal("Agent invalid response: " <> detail)))
            }
          }
        }
      }
      _ -> Ok(ErrorVal(StringVal("Invalid args for run_agent")))
    }
  }
}

/// The system prompt for the sync agent.
fn sync_system_prompt() -> String {
  "You are a tracking issue synchronizer. You receive:\n"
  <> "\n"
  <> "1. The tracking issue body (markdown with status tables)\n"
  <> "2. The current state of every linked issue/PR\n"
  <> "\n"
  <> "Your job:\n"
  <> "- Parse the status table in the tracking issue body.\n"
  <> "- For each row, compare the stored status to the actual state.\n"
  <> "- If ALL statuses match reality, respond with exactly: NO_CHANGES\n"
  <> "- If ANY status differs, respond with a markdown comment showing:\n"
  <> "  - A summary of what changed\n"
  <> "  - The updated table rows\n"
  <> "\n"
  <> "Rules:\n"
  <> "- A closed issue should show with the closing PR if known.\n"
  <> "- A merged PR should show with a reference to what it fixed.\n"
  <> "- If an open issue might already be fixed in code, note it but don't change the status.\n"
  <> "- Never be overzealous. Only report real state changes.\n"
  <> "- Format changes as a GitHub comment in markdown.\n"
}

/// update_issue handler — logs the comment instead of posting to GitHub.
///
/// Only called when the actor detected real changes (the `case` branch
/// in the actor skips this effect on NO_CHANGES). Prints what would
/// have been commented for safe local testing.
pub fn update_issue_handler() -> EffectHandler {
  fn(_name, args) {
    case args {
      [StringVal(repo), IntVal(number), StringVal(comment_body)] -> {
        io.println(
          "[update_issue] Would comment on "
          <> repo
          <> "#"
          <> int.to_string(number)
          <> ":",
        )
        io.println(comment_body)
        Ok(OkVal(NilVal))
      }
      _ -> Ok(ErrorVal(StringVal("Invalid args for update_issue")))
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Listing Tracking Issues
// ═══════════════════════════════════════════════════════════════════════

/// List open tracking issues for a repo (issues with the "tracking" label).
/// Returns a list of tuples: #(number, title, body).
pub fn list_tracking_issues(
  repo: String,
) -> Result(List(#(Int, String, String)), String) {
  let url =
    "https://api.github.com/repos/"
    <> repo
    <> "/issues?labels=tracking&state=open"
  case github_get(url) {
    Ok(body) -> Ok(parse_issue_list(body))
    Error(err) -> Error(err)
  }
}

/// Parse the GitHub API response for a list of issues using proper JSON decoding.
fn parse_issue_list(json_str: String) -> List(#(Int, String, String)) {
  let decoder = decode.list(of: issue_summary_decoder())
  case json.parse(json_str, using: decoder) {
    Ok(issues) -> issues
    Error(_) -> []
  }
}

fn issue_summary_decoder() {
  decode.field("number", decode.int, fn(number) {
    decode.field("title", decode.string, fn(title) {
      decode.optional_field("body", "", decode.string, fn(body) {
        decode.success(#(number, title, body))
      })
    })
  })
}

// ═══════════════════════════════════════════════════════════════════════
// Config Builder
// ═══════════════════════════════════════════════════════════════════════

/// Load the sync actor and build a RunConfig.
pub fn make_config(
  handlers: dict.Dict(String, EffectHandler),
  env: Value,
  emit: fn(HostEvent) -> Nil,
  run_id: String,
) -> RunConfig {
  let assert Ok(actor) = loader.load(sync_actor_source, "actors/sync.chute")
  RunConfig(
    program: actor.program,
    env:,
    gas: 50_000,
    handlers:,
    emit:,
    actor_path: actor.actor_path,
    actor_hash: actor.actor_hash,
    run_id:,
    trigger_type: "cron",
    trigger_source: "periodic",
    depth: 0,
    store: durability.none(),
  )
}

// ═══════════════════════════════════════════════════════════════════════
// Main — Run the Example
// ═══════════════════════════════════════════════════════════════════════

pub fn main() {
  io.println("╔══════════════════════════════════════════════════╗")
  io.println("║  Issue Tracker Sync — yard + pig host runtime    ║")
  io.println("╚══════════════════════════════════════════════════╝")
  io.println("")

  // ── 1. Start the yard observability stack ──────────────────────
  let assert Ok(dispatcher_subject) = dispatcher.start()

  let assert Ok(terminal_subject) = terminal.start()
  process.send(
    dispatcher_subject,
    dispatcher.RegisterConsumer(terminal_subject),
  )

  let session_path = "/tmp/yard_sync_" <> session.iso_timestamp() <> ".jsonl"
  let assert Ok(session_subject) = session.start_consumer(session_path)
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(session_subject))

  io.println("Yard observability started")
  io.println("Session: " <> session_path)
  io.println("")

  // ── 2. List tracking issues ───────────────────────────────────
  //    Edit this to target a real repo.
  let repo = "kasuboski/mediaz"

  io.println("Fetching tracking issues for " <> repo <> "...")
  io.println("LLM: " <> openai_model() <> " @ " <> openai_base_url())
  io.println("")

  case list_tracking_issues(repo) {
    Error(err) -> io.println("Failed to list tracking issues: " <> err)
    Ok([]) -> io.println("No tracking issues found.")
    Ok(issues) -> {
      io.println(
        "Found " <> int.to_string(list.length(issues)) <> " tracking issues",
      )
      io.println("")

      list.each(issues, fn(issue) {
        let #(number, title, body) = issue
        io.println(
          "Syncing " <> repo <> "#" <> int.to_string(number) <> ": " <> title,
        )
        let linked = extract_issue_numbers(body)
        let env = sync_env(repo, number, linked)

        let handlers =
          dict.from_list([
            #("fetch_issue", fetch_issue_handler()),
            #("fetch_linked", fetch_linked_handler()),
            #("run_agent", run_agent_handler()),
            #("update_issue", update_issue_handler()),
          ])

        let emit = runner.emit_to_dispatcher(dispatcher_subject)
        let config =
          make_config(
            handlers,
            env,
            emit,
            "r_" <> int.to_string(number) <> "_" <> session.iso_timestamp(),
          )

        let result = runner.run(config)
        let result_str = case result {
          Ok(v) -> "Ok(" <> value_to_string(v) <> ")"
          Error(e) -> "Error(" <> error_to_string(e) <> ")"
        }
        io.println("  Result: " <> result_str)
        io.println("")
      })
    }
  }

  process.sleep(50)
  io.println("Session: " <> session_path)
  io.println("")
  process.send(dispatcher_subject, dispatcher.Stop)
}
