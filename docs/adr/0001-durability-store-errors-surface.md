# Durability store errors surface, never swallow

When a durability store `record` fails (e.g. PostgreSQL unreachable), the Run
fails loudly rather than continuing silently. `lookup` stays optimistic — a
missing or corrupt checkpoint falls through to fresh execution, which is the
normal first-run and recovery path.

## Considered options

- **Optimistic everywhere** (swallow both lookup and record errors). Rejected:
  Yard's core promise is that Runs survive crashes and resume. Silently
  swallowing record errors means a store outage breaks that promise
  invisibly — Runs keep "succeeding" but nothing is durable, and the data loss
  only surfaces after a later crash. For a system whose identity is durability,
  that is the worst failure mode.
- **Strict everywhere** (propagate lookup errors too). Rejected: `lookup`
  returning "not found" is the normal first-run case and must fall to fresh
  execution. Treating lookup as best-effort is correct — it is an optimization
  (skip work), not a guarantee.

## Consequences

- A record failure fails the Run *after* the side effect has already happened.
  This is not a correctness problem — the `Idempotent handler` contract (see
  `CONTEXT.md`) makes retry safe — but it means a Run can fail on bookkeeping.
  The failure communicates "this Run is not safely resumable," which is true
  and useful to surface.
- `lookup` is best-effort, `record` is a guarantee. The asymmetry is
  principled, not accidental.
- This does not relax the `Idempotent handler` requirement: double-execution
  still occurs on retry (the checkpoint was never saved, so the handler
  re-runs). Strict-record surfaces store unreachability; it does not prevent
  re-execution.
