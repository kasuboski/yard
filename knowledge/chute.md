---

## 1. Product Vision & Goals
To create a token-efficient, strictly sandboxed scripting language designed specifically for Large Language Models (LLMs) and Actor-Model agent architectures. The language separates **pure computation (logic)** from **capabilities (I/O)**. It guarantees safe execution, prevents infinite loops, and allows for static capability verification, enabling zero-trust execution of LLM-generated code.

## 2. Core Design Principles
*   **Linear Token Generation:** Syntax is designed for left-to-right, top-to-bottom generation using pipelines (`|>`). Deeply nested scopes and "pyramids of doom" are avoided.
*   **Explicit over Magic:** No hidden control flows (`?` operators), implicit unwraps, or magical return types.
*   **Structural over Nominal:** JSON-like structural typing (`{ name: String }`) is preferred over named definitions, mapping naturally to LLM data-processing habits.
*   **Nouns vs. Verbs:** "Nouns" (data/triggers) are passed exclusively via the `main` entrypoint. "Verbs" (capabilities/I/O) are declared at the top of the file as `effect` signatures.

---

## 3. Language Syntax & Semantics

### 3.1 Variables & Immutability
*   The language is strictly immutable. Data cannot be mutated in place.
*   **Shadowing is required:** To support linear writing, variables can be shadowed in the same scope (`let x = 1`, followed by `let x = x + 1`).

### 3.2 Data Types
*   **Primitives:** `Int`, `Float`, `String`, `Bool`.
*   **Structural Records:** Anonymous JSON-like objects (e.g., `{ id: 1, action: "refund" }`). Dictionaries/HashMaps represent these natively at runtime.
*   **Wrappers:** `List(T)`, `Option(T)` (for missing data), `Result(T, E)` (for error handling).
*   **Strings:** Template literals must be supported (`"Hello ${name}"`).

### 3.3 Control Flow & Iteration
*   **No Unbounded Loops:** `while` loops and general recursion are strictly **banned** to statically guarantee halting.
*   **Iteration:** Handled exclusively via standard library pure functions (`list.map`, `list.filter`, `list.fold`).

### 3.4 Error Handling (Railway Oriented Programming)
*   No `try/catch` exceptions. Operations that can fail return a `Result(T, E)`.
*   Pipelines process Results using standard library functions like `result.try` (which short-circuits the pipeline on `Error`) and `result.map`.
*   **Auto-Unioning:** The type-checker must automatically union error types in a pipeline (e.g., piping a `HttpErr` into a `ParseErr` implicitly returns `Result(T, HttpErr | ParseErr)`).

For specific language syntax read [syntax.md](./syntax.md)
---

## 4. Capabilities & Orchestration (The FFI)

### 4.1 Effect Declarations
External interactions (HTTP, DB, Messaging) are represented as Algebraic Effects. They must be declared at the top of the file.
```gleam
effect fetch_data(id: String) -> Result(String, HttpErr)
```

### 4.2 The `perform` Keyword
*   The `perform` keyword is the only way to trigger side effects.
*   **Semantics:** When evaluated, `perform` must pause the VM/Evaluator, yield the "Intent" to the Host Runtime, and wait to be resumed with the Host's response. To the LLM, this looks like a synchronous function call.

### 4.3 Concurrency & Batching
*   Concurrency is achieved by wrapping `perform` calls inside anonymous closures (`thunks`), representing delayed execution.
*   Batches are dispatched via the standard library (`task.dispatch_all`). The language itself has no threading primitives.
```gleam
let intents =[
    fn() { perform do_a() },
    fn() { perform do_b() }
]
perform task.dispatch_all(intents) // Yields the batch to the Host
```

---

## 5. The Entrypoint

### 5.1 The "Juicy Main" Pattern
Every script must export a `main` function. Global execution is forbidden. 
*   The `main` function takes a single `env` envelope.
*   The `env` structure acts as a strict schema definition for the LLM, standardizing triggers, metadata, and payloads.
*   The script's lifecycle ends when `main` returns a `Result`.

```gleam
pub fn main(env: { payload: { user_id: String } }) -> Result(Int, Error) { ... }
```

---

## 6. Host Runtime & Evaluator Requirements

The implementer must guarantee the following via the underlying interpreter (e.g., Zig, BEAM):

1.  **Pausable VM / Coroutines:** The evaluator must be capable of pausing execution mid-AST when a `Perform` node is hit, yielding to the host orchestrator without blocking OS threads, and resuming when the host replies.
2.  **O(1) Memory Teardown:** The evaluator must use an Arena Allocator (or process-isolated heap). When `main` returns, all memory allocated by the script must be instantly dropped.
3.  **Guaranteed Halting:** Because unbounded loops are syntactically banned, the runtime either requires no gas limit, or a simple instruction counter to prevent massive `list.fold` abuse.
4.  **Static Capability Verification:** Before evaluation, the host must do a fast AST pass to verify all `effect` declarations match the Host’s capability registry (firewall). Hallucinated endpoints or mismatched payload shapes must fail pre-execution.

---

## 7. Transport & AST

*   **Source Format:** The Gleam-like pipeline syntax is the *surface language* generated by the LLM.
*   **Transport/Storage Format:** The surface language is parsed and desugared into **S-Expressions**.
    *   *Requirement:* Syntactic sugar like pipelines (`|>`) must be desugared into standard nested function calls during parsing.
*   **Evaluation Format:** The S-Expressions are loaded into memory as strictly typed Abstract Syntax Trees (ADTs / Tagged Unions). The evaluator is a pure tree-walking interpreter traversing this ADT.

---

## 8. Example Program Reference

```gleam
// 1. Verbs (Declared Capabilities)
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

// 2. Nouns (Standardized Entrypoint)
pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    
    // 3. Linear compute + ROP Pipeline
    env.order_total
    |> perform charge_card()
    |> result.try(fn(tx_id) {
        // 4. Pausable execution
        let _ = perform send_receipt(env.user_id, tx_id)
        Ok(tx_id)
    })
}
```
