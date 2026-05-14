# Ballast Runtime

Tree-walking evaluator for Chute programs. Pure functional — no BEAM process
trickery. The host drives evaluation and handles effects via a yield/resume
protocol.

---

## Architecture

```
ballast/
├── src/
│   ├── ballast.gleam          # Public API (two levels: source & AST)
│   └── ballast/
│       ├── value.gleam        # Value, RuntimeError, formatting, equality
│       ├── env.gleam          # Variable environment (dict wrapper)
│       ├── effect.gleam       # EvalResult, Continuation (opaque), resume
│       └── eval.gleam         # CPS evaluator, stdlib builtins
└── test/
    ├── testing.gleam          # Shared test helpers (equal, run, start)
    ├── ballast_test.gleam     # 6 public API tests
    ├── eval_test.gleam        # 35 expression evaluation tests
    ├── stdlib_test.gleam      # 18 stdlib function tests
    ├── effect_test.gleam      # 5 yield/resume tests
    └── integration_test.gleam # 12 full-program tests (incl. compile-once-run-many)
```

**Dependency graph** (acyclic):

```
chute (parse + desugar)
  ↓
ballast.gleam
  ↓
eval.gleam ← value.gleam, env.gleam, effect.gleam
```

No separate stdlib module — stdlib implementations are inlined in `eval.gleam`
because they need deep integration with the CPS machinery.

---

## Public API (`ballast.gleam`)

Two levels of entrypoint. Every source-level function is parse + desugar +
AST-level function:

### Source level (parse + desugar + run)

| Function | Signature | Purpose |
|----------|-----------|---------|
| `run` | `String → Result(Value, RuntimeError)` | Run a program. Effects cause errors. Default gas. |
| `run_with_gas` | `String, Int → Result(Value, RuntimeError)` | Same, custom gas budget. |
| `start` | `String, Int → Result(EvalResult, String)` | Run with effects. Returns first `EvalResult`. |
| `start_with_env` | `String, Value, Int → Result(EvalResult, String)` | Same, passes env to `main`. |

### AST level (skip parsing — for repeated execution)

| Function | Signature | Purpose |
|----------|-----------|---------|
| `run_program` | `Program, Int → Result(Value, RuntimeError)` | Run a desugared AST. No effects. |
| `run_program_with_env` | `Program, Value, Int → Result(Value, RuntimeError)` | Same, with env. |
| `start_program` | `Program, Int → EvalResult` | Run with effects. |
| `start_program_with_env` | `Program, Value, Int → EvalResult` | Same, with env. |
| `resume` | `Continuation, Value → EvalResult` | Feed a host value back in. |

### Compilation helper

| Function | Signature | Purpose |
|----------|-----------|---------|
| `prepare` | `String → Result(Program, String)` | Parse + desugar. Compile once, run many times. |

**Compile-once-run-many pattern:**

```gleam
let assert Ok(prog) = ballast.prepare(source)
// Run with different envs — no re-parsing
ballast.run_program_with_env(prog, env1, gas)
ballast.run_program_with_env(prog, env2, gas)
```

---

## Evaluation result (`effect.gleam`)

Every evaluation produces one of three outcomes:

```gleam
pub type EvalResult {
  EvalDone(value: Value, gas: Int)
  Yielded(effect: String, args: List(Value), continuation: Continuation, gas: Int)
  EvalError(error: RuntimeError)
}
```

- **EvalDone** — normal completion. Contains the result and remaining gas.
- **Yielded** — hit a `perform`. Contains the effect name, evaluated arguments,
  an opaque continuation, and remaining gas. The host calls `resume(cont, val)`
  to continue.
- **EvalError** — runtime error.

`Continuation` is opaque — the only operation is `resume`. It wraps a Gleam
closure that captures the entire remaining computation.

---

## Values (`value.gleam`)

```gleam
pub type Value {
  IntVal(Int)
  FloatVal(Float)
  StringVal(String)
  BoolVal(Bool)
  NilVal
  RecordVal(fields: List(#(String, Value)))
  ListVal(elements: List(Value))
  ClosureVal(params: List(String), body: ast.Block, env: Dict(String, Value))
  OkVal(value: Value)
  ErrorVal(value: Value)
  SomeVal(value: Value)
  NoneVal
}
```

`ClosureVal` captures its lexical environment at creation time (a dict of
`String → Value`). When called, the closure's env is extended with the
arguments.

Constructors (`Ok`, `Error`, `Some`, `None`) are first-class values, not
special AST nodes. The evaluator recognizes `ExprVar("Ok")` etc. in call
position and produces the corresponding `Value` variant.

`Nil` and `None` also resolve as bare variable references — `ExprVar("Nil")`
→ `NilVal`, `ExprVar("None")` → `NoneVal`.

### Structural equality

`values_equal` compares values recursively. Records are compared field-by-field
(sorted by name for determinism). Different value constructors are never equal
(`OkVal` ≠ `SomeVal` even with the same inner value).

---

## Environment (`env.gleam`)

```gleam
pub type Env = Dict(String, Value)
```

Thin dict wrapper with `new`, `get`, `insert`, `extend`. `extend` pairs name
and value lists positionally.

Scoping is lexical: closures capture the env at creation. Let bindings extend
the env for the remainder of their block. Shadowing works — later bindings
overwrite earlier ones with the same name.

---

## Evaluation (`eval.gleam`)

### CPS core

The evaluator uses continuation-passing style. Every function takes a
continuation `fn(Value, Int) -> EvalResult` and returns `EvalResult` directly.
This makes effect yields at arbitrary expression depth natural — the
continuation captures "what happens next."

```gleam
fn eval_k(expr, env, ctx, gas, k) -> EvalResult
```

Gas is decremented once per `eval_k` call via `tick`. If gas reaches 0,
`EvalError(GasExhausted)` is returned immediately.

### Blocks and statements

`eval_stmts` walks a block's statement list, threading the env through let
bindings:

- `LetDecl(name, _, expr)` — evaluate expr, bind name in env, continue.
- `StatementExpr(expr)` — evaluate for side effects, discard result, continue.
- End of statements — evaluate the trailing expression (or return `NilVal`).

### Expression dispatch

Each `ast.Expr` variant:

| AST variant | Evaluation |
|-------------|------------|
| `ExprInt(n)` | `IntVal(n)` |
| `ExprFloat(f)` | `FloatVal(f)` |
| `ExprBool(b)` | `BoolVal(b)` |
| `ExprNil` | `NilVal` |
| `ExprString(parts)` | Walk parts. `StringText` appends text. `StringInterpolation` evaluates the inner expr, converts to display string, appends. |
| `ExprVar("Nil")` | `NilVal` |
| `ExprVar("None")` | `NoneVal` |
| `ExprVar(name)` | Env lookup. `UndefinedVariable` if not found. |
| `ExprBinaryOp(l, op, r)` | Evaluate both sides, apply operator. `DivisionByZero` check. |
| `ExprPerform(name, args)` | Evaluate args, return `Yielded` with a continuation wrapping `k`. |
| `ExprCall(func, args)` | Dispatch on `func` — see call dispatch below. |
| `ExprFieldAccess(record, field)` | Evaluate record, look up field. `FieldMissing` if absent. |
| `ExprRecord(fields)` | Evaluate each field value, build `RecordVal`. |
| `ExprList(elements)` | Evaluate each element, build `ListVal`. |
| `ExprClosure(params, body)` | Capture current env in `ClosureVal`. |
| `ExprGroup(inner)` | Evaluate inner (desugarer removes these; fallback). |
| `ExprPipeline(_, _)` | Error — should be desugared away. |

### Call dispatch

`ExprCall(func, args)` checks `func` in this order:

1. **Constructors** — `ExprVar("Ok")`, `ExprVar("Error")`, `ExprVar("Some")`,
   `ExprVar("None")`. Evaluate args, wrap in the corresponding value variant.
   `None` takes 0 args; others take 1.
2. **Stdlib** — `ExprFieldAccess(ExprVar(module), function)`. Matched on
   `(module, function)` pairs. See stdlib section below.
3. **User-defined functions** — `ExprVar(name)` where `name` exists in the
   program's function declarations. Evaluate args, bind params in a fresh env,
   evaluate the function body.
4. **Closures in env** — `ExprVar(name)` resolved from the env as a
   `ClosureVal`. Evaluate args, extend the closure's captured env with params,
   evaluate the closure body.
5. **General case** — Evaluate `func` to a value, apply if it's a `ClosureVal`,
   otherwise `NotCallable`.

### Binary operators

Arithmetic (`+`, `-`, `*`, `/`) and comparison (`==`, `!=`, `<`, `<=`, `>`,
`>=`) on `IntVal` only. Division checks for zero. Comparison of any two values
uses `values_equal` for `==`/`!=`. Ordered comparisons require `IntVal` on both
sides.

### String interpolation

`ExprString(parts)` walks the parts list, building a concatenated string:

- `StringText(text)` — append the literal text.
- `StringInterpolation(expr)` — evaluate expr, convert result to display form:
  `StringVal` unwraps to the raw string, `IntVal`/`BoolVal` etc. use their
  display representation.

---

## Stdlib builtins

Implemented inline in `eval.gleam`. Each matches on the AST pattern
`ExprFieldAccess(ExprVar(module), function)` and handles args using the same
CPS style as the core evaluator.

### list.*

| Function | Signature (Chute) | Behavior |
|----------|-------------------|----------|
| `list.map` | `(List(a), fn(a) → b) → List(b)` | Apply closure to each element. |
| `list.filter` | `(List(a), fn(a) → Bool) → List(a)` | Keep elements where closure returns `True`. |
| `list.fold` | `(List(a), b, fn(b, a) → b) → b` | Left fold with accumulator. |
| `list.length` | `(List(a)) → Int` | Count elements. |

### result.*

| Function | Signature (Chute) | Behavior |
|----------|-------------------|----------|
| `result.try` | `(Result(a, e), fn(a) → Result(b, e)) → Result(b, e)` | If `Ok`, apply closure. If `Error`, short-circuit. |
| `result.map` | `(Result(a, e), fn(a) → b) → Result(b, e)` | If `Ok`, apply closure and re-wrap in `Ok`. If `Error`, pass through. |
| `result.is_ok` | `(Result(a, e)) → Bool` | `True` for `Ok`, `False` for `Error` (or anything else). |
| `result.is_error` | `(Result(a, e)) → Bool` | `True` for `Error`, `False` for anything else. |

### option.*

| Function | Signature (Chute) | Behavior |
|----------|-------------------|----------|
| `option.map` | `(Option(a), fn(a) → b) → Option(b)` | If `Some`, apply closure and re-wrap. If `None`, pass through. |

### string.*

| Function | Signature (Chute) | Behavior |
|----------|-------------------|----------|
| `string.length` | `(String) → Int` | Character count. |
| `string.concat` | `(String, String) → String` | Concatenation. |

### task.*

| Function | Signature (Chute) | Behavior |
|----------|-------------------|----------|
| `task.dispatch_all` | `(List(fn() → Result(a, e))) → Result(Nil, String)` | Call each thunk. If any returns `Error`, short-circuit. Otherwise `Ok(Nil)`. |

---

## Effect protocol

Evaluation of `perform effect_name(args)`:

1. Evaluate all args to values.
2. Return `Yielded("effect_name", arg_values, continuation, remaining_gas)`.
3. The `continuation` wraps the current CPS continuation — a closure that,
   given a host value, resumes evaluation from that point.
4. The host does its work (call external services, etc.).
5. The host calls `ballast.resume(continuation, host_result)`.
6. The continuation feeds `host_result` back into the evaluator.
7. Evaluation continues until the next `Yielded`, `EvalDone`, or `EvalError`.

Multiple performs in sequence yield one at a time. The host resumes each one
individually. The continuation captures all remaining computation including
subsequent performs.

Performs inside closures work correctly — the thunk captures the perform in its
body, and the yield happens when the thunk is called (e.g., by
`task.dispatch_all`).

---

## Gas

Every `eval_k` call decrements a gas counter by 1. Default budget: 10,000
steps. The host can configure via `run_with_gas` or `start(source, gas)`.

When gas reaches 0, the evaluator returns `EvalError(GasExhausted)` immediately.
This prevents unbounded resource consumption (e.g., `list.fold` over a huge
list).

---

## Error types

```gleam
pub type RuntimeError {
  RuntimeError(message: String)
  UndefinedVariable(name: String)
  UndefinedFunction(name: String)
  UndefinedEffect(name: String)
  TypeMismatch(expected: String, actual: String)
  ArityMismatch(context: String, expected: Int, actual: Int)
  FieldMissing(record: String, field: String)
  DivisionByZero
  GasExhausted
  NotCallable(type_: String)
}
```

All errors are non-recoverable — the evaluator does not continue after
producing an `EvalError`. The host must handle or report.

---

## Execution flow (spec example)

```
Source:
  effect charge_card(amount: Float) -> Result(String, Error)
  pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
      env.order_total
      |> perform charge_card()
      |> result.try(fn(tx_id) {
          let _ = perform send_receipt(env.user_id, tx_id)
          Ok(tx_id)
      })
  }

1.  Host calls ballast.start(source, 10_000)
2.  Ballast parses + desugars, then calls eval.run(program, gas)
3.  Eval finds `main`, binds `env` param to NilVal (no env passed)
4.  Evaluates `env.order_total` → FloatVal(99.9)
5.  Hits `perform charge_card(FloatVal(99.9))`
6.  Returns Yielded("charge_card", [FloatVal(99.9)], cont, gas)
7.  Host calls ballast.resume(cont, OkVal(StringVal("TX-123")))
8.  Eval continues: binds tx_id = StringVal("TX-123")
9.  Hits `perform send_receipt(StringVal("user-1"), StringVal("TX-123"))`
10. Returns Yielded("send_receipt", [...], cont, gas)
11. Host sends receipt, calls ballast.resume(cont, OkVal(NilVal))
12. Eval continues: evaluates Ok(StringVal("TX-123"))
13. Returns EvalDone(OkVal(StringVal("TX-123")), remaining_gas)
```

---

## Relationship to Chute

Ballast consumes a `chute.Program` AST directly. It depends on the `chute`
package for the AST types and the parse/desugar pipeline.

The `prepare` function is the bridge: it calls `chute.parse` then
`chute.desugar`. At the AST level, Ballast expects a desugared program
(`ExprGroup` removed, empty blocks normalized). The evaluator handles
`ExprGroup` as a fallback but the desugarer should have removed them.

S-expressions are the storage/transport format (handled by `chute`). Ballast
never touches them — if a consumer loads an S-expression from disk, they call
`chute.from_sexp()` first, then `ballast.start_program()` on the resulting AST.

---

## Design decisions

### Why CPS, not BEAM processes?

The evaluator is pure functional. It returns `EvalResult` values. The host
decides how to drive it — synchronous loop, GenServer, distributed process,
whatever. Testing is trivial (no process setup). The continuation is just a
Gleam closure — no BEAM process trickery needed.

### Why gas?

The spec requires guaranteed halting (§6.3). Unbounded loops are syntactically
banned, but `list.fold` over a huge list can still burn resources. A gas
counter is the simplest solution. Default: 10,000 eval steps. Host configures.

### Why separate value types from AST types?

AST nodes are syntactic (source structure). Values are semantic (computed
results). A `ClosureVal` captures its environment — no AST equivalent.
`OkVal`/`ErrorVal` are runtime-tagged, not AST constructors. Separate types
avoid coupling the evaluator to parser internals.

### Why no separate stdlib module?

Stdlib functions need deep integration with the CPS evaluator (they call back
into `eval_k` for closure arguments). Extracting them to a separate module
would require passing `eval_k` as a callback (like the type checker does).
Inlining is simpler and avoids the indirection.
