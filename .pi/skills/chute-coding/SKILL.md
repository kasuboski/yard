---
name: chute-coding
description: Guidelines, syntax, and best practices for writing scripts in Chute, a sandboxed, strictly functional, Actor-model language. Use this skill whenever tasked with writing or refactoring Chute scripts.
---

# Writing Code in Chute

Chute is a token-efficient, strictly sandboxed language designed for Large Language Models orchestrating Actor-model workflows. It enforces Railway Oriented Programming (ROP), immutability, and explicit separation of logic from I/O (Capabilities).

## 1. Core Paradigms

- **Explicit Error Handling:** The language does not have exceptions or hidden early-return operators. Operations that can fail return a `Result(Value, Error)`, which must be handled explicitly.
- **Immutability & Shadowing:** Variables are strictly immutable. To update a value, shadow the variable by binding it again using `let` (`let x = 1`, `let x = x + 1`).
- **Iteration:** The runtime does not support unbounded loops (`while` or `for`) in order to statically guarantee halting. Perform all iteration using standard library pure functions like `list.map`, `list.filter`, and `list.fold`.
- **Structural Typing:** Chute uses anonymous, JSON-like shapes for data types. Define the shapes directly in place: `let user: { id: Int, role: String } = ...`

## 2. Nouns vs. Verbs (Env & Capabilities)

Chute enforces a strict boundary between Data (Nouns) and side-effects (Verbs).

**Verbs (Capabilities):** 
Declare external I/O at the top of the file using the `effect` keyword. Execute them synchronously using the `perform` keyword.
```chute
effect fetch_user(id: String) -> Result(String, HttpErr)
effect send_email(address: String) -> Result(Nil, MailErr)
```

**Nouns (The Entrypoint):**
Scripts must expose a single `pub fn main(env: {...}) -> Result(T, E)`. All necessary context is injected structurally through this `env` argument, which acts as the strict schema of the incoming trigger or payload.

## 3. Error Handling: `let try` vs `result.try`

Chute relies on Railway Oriented Programming. Choose the correct unwrapping tool based on the task to keep the code linear and readable.

### When to use `result.try` (Data Transformation)
Use `result.try` within a pipeline (`|>`) to linearly transform data when you only need the final output. This keeps the code clean and bypasses intermediate variable assignment.
```chute
// BEST PRACTICE: Pure data transformation pipeline
let formatted_output = 
    env.payload.raw_data
    |> json.parse()
    |> result.try(validate_schema)
    |> result.try(format_output)
```

### When to use `let try` (Orchestration & State Accumulation)
Use `let try` to execute multiple side-effects when you need to retain access to all of their results later in the function. It explicitly short-circuits on `Error`, acting as a flat, safe guard without nesting closures.
```chute
// BEST PRACTICE: Orchestrating multiple pieces of state
let try user = perform fetch_user(env.id)
let try orders = perform fetch_orders(user.id)

// We have access to both `user` and `orders` in the same scope
perform send_email(user.email, orders)
```

## 4. Branching and Control Flow

Use `case` statements for branching logic. It is an expression that evaluates and returns a value. Always provide an exhaustive catch-all branch (`_ ->`) as a fallback to handle unmapped outcomes.

```chute
let try status = case env.action {
    "refund" -> perform process_refund()
    "charge" -> perform process_charge()
    _ -> Error("Unknown action")
}
```

## 5. Concurrent Batching

Chute handles concurrency by deferring execution inside anonymous closures (thunks). To execute multiple effects in parallel, wrap the `perform` calls in `fn() { ... }` and pass the list to `task.dispatch_all`.

```chute
let intents = 
    env.mailbox
    |> list.map(fn(msg) {
        fn() { perform send_reply(msg.sender, "Received") }
    })

// Tell the Host to execute all intents concurrently
let try results = perform task.dispatch_all(intents)
```

## 6. Complete Example (The "Juicy Main" Pattern)

Here is a perfectly formatted Chute script highlighting these best practices:

```chute
// 1. Capability Declarations
effect charge_card(amount: Float) -> Result(String, Error)
effect update_db(tx_id: String, status: String) -> Result(Nil, Error)

// 2. Main Entrypoint & Schema
pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    
    // 3. Local shadowing
    let amount = env.order_total
    let amount = amount * 1.05 // Add tax

    // 4. Using `let try` to short-circuit on errors cleanly
    let try tx_id = perform charge_card(amount)
    
    // 5. Branching logic with implicit block returns
    case tx_id != "" {
        True -> {
            let _ = perform update_db(tx_id, "SUCCESS")
            Ok(tx_id)
        }
        False -> {
            Error("Transaction returned empty ID")
        }
    }
}
```
