# Yard

A token-efficient, sandboxed scripting language for LLM agents (Chute), its pure
functional evaluator (Ballast), and the host runtime that drives it (Yard).

## Language

**Chute**:
A pipeline-first programming language designed for LLM token generation, with declared effects and no unbounded loops.
_Avoid_: script, DSL, config

**Ballast**:
A pure functional evaluator for Chute programs that cannot touch the outside world directly.
_Avoid_: interpreter, VM, runtime (see Yard)

**Yard**:
The host runtime that loops over Ballast's yield/resume cycle and wires it to the real world.
_Avoid_: server, platform, framework

## Execution

**Actor**:
A loaded Chute program, identified by where it lives (`actor_path`) and what code it is (`actor_hash`).
_Avoid_: agent, bot, worker

**Effect**:
A capability a Chute program declares and invokes via `perform`; the host decides what actually happens.
_Avoid_: function, procedure, command, API call

**Run**:
One invocation of an Actor through the Yard runner.
_Avoid_: execution, invocation, session

## Durability

**Checkpoint**:
A stored Effect result, keyed by its position and name, enabling a crashed Run to resume without re-executing side effects.
_Avoid_: snapshot, cache, state

**Replay**:
Feeding stored Checkpoints to Ballast instead of calling Effect handlers, so side effects are not repeated on retry.
_Avoid_: restore, re-execute, fast-forward

**Idempotent handler**:
An Effect handler that is safe to run more than once with the same inputs — the load-bearing contract that makes durability correct under at-least-once execution.
_Avoid_: pure function, stateless handler
