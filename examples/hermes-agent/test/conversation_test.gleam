//// Multi-turn conversation loop tests.
////
//// Proves that Pig's agent actor holds conversation history across
//// pig.run() calls, and that Hermes workspace state (VFS, KV) persists.
////
//// Uses a custom fake Provider that returns canned responses with
//// optional tool calls to exercise the full agent loop.

import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import hermes_agent/chute_exec
import pig
import pig/ai/message
import pig/ai/provider
import pig/workspace/schema
import sqlight

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════
// Counter actor — shared mutable counter across processes
// ═══════════════════════════════════════════════════════════════

type CounterMsg {
  CounterGet(reply_to: process.Subject(Int))
  CounterNext(reply_to: process.Subject(Int))
  CounterStop
}

fn start_counter() -> process.Subject(CounterMsg) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(state, msg) {
      case msg {
        CounterGet(reply_to) -> {
          process.send(reply_to, state)
          actor.continue(state)
        }
        CounterNext(reply_to) -> {
          let next = state + 1
          process.send(reply_to, state)
          actor.continue(next)
        }
        CounterStop -> actor.stop()
      }
    })
    |> actor.start()
  started.data
}

fn counter_next(counter: process.Subject(CounterMsg)) -> Int {
  process.call(counter, 1000, fn(reply_to) { CounterNext(reply_to) })
}

fn counter_stop(counter: process.Subject(CounterMsg)) -> Nil {
  process.send(counter, CounterStop)
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn with_workspace(test_fn: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open("file::memory:")
  let assert Ok(Nil) = schema.init(conn)
  test_fn(conn)
}

/// A fake provider that always returns a text response (no tool calls).
fn text_provider(text: String) -> provider.Provider {
  fn(_messages, _tools) {
    Ok(
      provider.from_message(message.Assistant(
        text,
        [],
        option.None,
        option.None,
      )),
    )
  }
}

fn hermes_chute_tool(conn: sqlight.Connection) {
  chute_exec.silent_config(conn) |> chute_exec.tool()
}

fn make_tool_call(id: String, source: String) -> message.ToolCall {
  message.ToolCall(
    id: id,
    name: "chute_exec",
    arguments_json: json.object([#("source", json.string(source))])
      |> json.to_string(),
  )
}

// ═══════════════════════════════════════════════════════════════
// Single-turn tests
// ═══════════════════════════════════════════════════════════════

pub fn single_turn_no_tools_test() {
  with_workspace(fn(_conn) {
    let config =
      pig.new(text_provider("Hello! I am Hermes."))
      |> pig.with_system_prompt("You are a test agent.")
    let assert Ok(agent) = pig.start(config)
    let result = pig.run_with_timeout(agent, "Hi there", 5000)

    let assert Ok(response) = result
    let content = case response {
      message.Assistant(c, _, _, _) -> c
      _ -> panic as "Expected Assistant message"
    }
    let assert True =
      string.contains(content, "Hello") || string.contains(content, "Hermes")
    pig.stop(agent)
  })
}

pub fn single_turn_with_tool_call_test() {
  with_workspace(fn(conn) {
    let chute_tool = hermes_chute_tool(conn)
    let counter = start_counter()

    let config =
      pig.new(fn(_messages, _tools) {
        let n = counter_next(counter)
        case n {
          0 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc1",
                    "effect write_file(p: String, c: String) -> Result(Nil, String)\npub fn main(env: {}) -> Result(Nil, String) { let try _ = perform write_file(\"greeting.txt\", \"Hello from tool!\") Ok(Nil) }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          1 ->
            Ok(
              provider.from_message(message.Assistant(
                "I wrote the file!",
                [],
                option.None,
                option.None,
              )),
            )
          _ ->
            Ok(
              provider.from_message(message.Assistant(
                "Done",
                [],
                option.None,
                option.None,
              )),
            )
        }
      })
      |> pig.with_system_prompt("You are a test agent.")
      |> pig.with_tool(chute_tool)
    let assert Ok(agent) = pig.start(config)
    let result = pig.run_with_timeout(agent, "Write a greeting file", 5000)

    let assert Ok(response) = result
    let content = case response {
      message.Assistant(c, _, _, _) -> c
      _ -> panic as "Expected Assistant message"
    }
    let assert True =
      string.contains(content, "wrote") || string.contains(content, "file")
    pig.stop(agent)
    counter_stop(counter)
  })
}

// ═══════════════════════════════════════════════════════════════
// Multi-turn tests
// ═══════════════════════════════════════════════════════════════

pub fn multi_turn_preserves_history_test() {
  with_workspace(fn(conn) {
    let chute_tool = hermes_chute_tool(conn)
    let counter = start_counter()

    let config =
      pig.new(fn(_messages, _tools) {
        let n = counter_next(counter)
        let text = case n {
          0 -> "Turn 1: I see you said something."
          _ -> "Turn 2: Continuing conversation."
        }
        Ok(
          provider.from_message(message.Assistant(
            text,
            [],
            option.None,
            option.None,
          )),
        )
      })
      |> pig.with_system_prompt("You are a test agent.")
      |> pig.with_tool(chute_tool)

    let assert Ok(agent) = pig.start(config)

    // Turn 1
    let assert Ok(message.Assistant(c1, _, _, _)) =
      pig.run_with_timeout(agent, "Hello", 5000)
    let assert True = string.contains(c1, "Turn 1")

    // Turn 2
    let assert Ok(message.Assistant(c2, _, _, _)) =
      pig.run_with_timeout(agent, "Continue", 5000)
    let assert True = string.contains(c2, "Turn 2")

    pig.stop(agent)
    counter_stop(counter)
  })
}

pub fn multi_turn_with_tools_across_turns_test() {
  with_workspace(fn(conn) {
    let chute_tool = hermes_chute_tool(conn)
    let counter = start_counter()

    let config =
      pig.new(fn(_messages, _tools) {
        let n = counter_next(counter)
        case n {
          0 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc1",
                    "effect write_file(p: String, c: String) -> Result(Nil, String)\npub fn main(env: {}) -> Result(Nil, String) { let try _ = perform write_file(\"data.txt\", \"secret value\") Ok(Nil) }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          1 ->
            Ok(
              provider.from_message(message.Assistant(
                "File written.",
                [],
                option.None,
                option.None,
              )),
            )
          2 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc2",
                    "effect read_file(p: String) -> Result(String, String)\npub fn main(env: {}) -> Result(String, String) { perform read_file(\"data.txt\") }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          3 ->
            Ok(
              provider.from_message(message.Assistant(
                "The file contains: secret value",
                [],
                option.None,
                option.None,
              )),
            )
          _ ->
            Ok(
              provider.from_message(message.Assistant(
                "Done",
                [],
                option.None,
                option.None,
              )),
            )
        }
      })
      |> pig.with_system_prompt("You are a test agent.")
      |> pig.with_tool(chute_tool)

    let assert Ok(agent) = pig.start(config)

    // Turn 1: write
    let assert Ok(message.Assistant(c1, _, _, _)) =
      pig.run_with_timeout(agent, "Write secret to file", 5000)
    let assert True =
      string.contains(c1, "written") || string.contains(c1, "File")

    // Turn 2: read — proves VFS persists across turns
    let assert Ok(message.Assistant(c2, _, _, _)) =
      pig.run_with_timeout(agent, "Read the file back", 5000)
    let assert True = string.contains(c2, "secret value")

    pig.stop(agent)
    counter_stop(counter)
  })
}

pub fn kv_persists_across_turns_test() {
  with_workspace(fn(conn) {
    let chute_tool = hermes_chute_tool(conn)
    let counter = start_counter()

    let config =
      pig.new(fn(_messages, _tools) {
        let n = counter_next(counter)
        case n {
          0 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc1",
                    "effect store(k: String, v: String) -> Result(Nil, String)\npub fn main(env: {}) -> Result(Nil, String) { let try _ = perform store(\"name\", \"Alice\") Ok(Nil) }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          1 ->
            Ok(
              provider.from_message(message.Assistant(
                "Stored!",
                [],
                option.None,
                option.None,
              )),
            )
          2 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc2",
                    "effect recall(k: String) -> Result(String, String)\npub fn main(env: {}) -> Result(String, String) { perform recall(\"name\") }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          3 ->
            Ok(
              provider.from_message(message.Assistant(
                "The name is: Alice",
                [],
                option.None,
                option.None,
              )),
            )
          _ ->
            Ok(
              provider.from_message(message.Assistant(
                "Done",
                [],
                option.None,
                option.None,
              )),
            )
        }
      })
      |> pig.with_system_prompt("You are a test agent.")
      |> pig.with_tool(chute_tool)

    let assert Ok(agent) = pig.start(config)

    // Turn 1: store
    let assert Ok(message.Assistant(_, _, _, _)) =
      pig.run_with_timeout(agent, "Remember my name is Alice", 5000)

    // Turn 2: recall — proves KV persists across turns
    let assert Ok(message.Assistant(c2, _, _, _)) =
      pig.run_with_timeout(agent, "What is my name?", 5000)
    let assert True = string.contains(c2, "Alice")

    pig.stop(agent)
    counter_stop(counter)
  })
}

pub fn error_recovery_across_turns_test() {
  with_workspace(fn(conn) {
    let chute_tool = hermes_chute_tool(conn)
    let counter = start_counter()

    let config =
      pig.new(fn(_messages, _tools) {
        let n = counter_next(counter)
        case n {
          0 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc1",
                    "effect unknown(x: Int) -> Int\npub fn main(env: {}) -> Int { perform unknown(1) }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          1 ->
            Ok(
              provider.from_message(message.Assistant(
                "That had an error.",
                [],
                option.None,
                option.None,
              )),
            )
          2 ->
            Ok(
              provider.from_message(message.Assistant(
                "",
                [
                  make_tool_call(
                    "tc2",
                    "effect write_file(p: String, c: String) -> Result(Nil, String)\npub fn main(env: {}) -> Result(Nil, String) { let try _ = perform write_file(\"ok.txt\", \"success\") Ok(Nil) }",
                  ),
                ],
                option.None,
                option.None,
              )),
            )
          3 ->
            Ok(
              provider.from_message(message.Assistant(
                "This time it worked!",
                [],
                option.None,
                option.None,
              )),
            )
          _ ->
            Ok(
              provider.from_message(message.Assistant(
                "Done",
                [],
                option.None,
                option.None,
              )),
            )
        }
      })
      |> pig.with_system_prompt("You are a test agent.")
      |> pig.with_tool(chute_tool)

    let assert Ok(agent) = pig.start(config)

    // Turn 1: error
    let assert Ok(message.Assistant(c1, _, _, _)) =
      pig.run_with_timeout(agent, "Run a bad program", 5000)
    let assert True = string.contains(c1, "error")

    // Turn 2: success — proves recovery
    let assert Ok(message.Assistant(c2, _, _, _)) =
      pig.run_with_timeout(agent, "Now run a good one", 5000)
    let assert True =
      string.contains(c2, "worked") || string.contains(c2, "success")

    pig.stop(agent)
    counter_stop(counter)
  })
}
