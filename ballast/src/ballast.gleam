import ballast/effect
import ballast/eval
import ballast/value
import chute
import chute/ast

// ═══════════════════════════════════════════════════════════════════════════
// Public API
//
// Two levels of entrypoint:
//
//   Source level  — parse + desugar + run. Convenience for one-shot use.
//   AST level     — skip parsing. For repeated execution, caching, or
//                   receiving programs from S-expression transport.
//
// Every source-level function is just parse + desugar + AST-level function.
// ═══════════════════════════════════════════════════════════════════════════

/// Default gas budget for evaluation.
pub const default_gas = 10_000

// ═══════════════════════════════════════════════════════════════════════════
// Source-level entrypoints (parse + desugar + run)
// ═══════════════════════════════════════════════════════════════════════════

/// Parse, desugar, and run a Chute program.
/// Effects are not supported (any `perform` causes a runtime error).
pub fn run(source: String) -> Result(value.Value, value.RuntimeError) {
  run_with_gas(source, default_gas)
}

/// Same as run/1 but with a custom gas budget.
pub fn run_with_gas(
  source: String,
  gas: Int,
) -> Result(value.Value, value.RuntimeError) {
  case prepare(source) {
    Error(msg) -> Error(value.RuntimeError("Parse error: " <> msg))
    Ok(prog) -> run_program(prog, gas)
  }
}

/// Parse, desugar, and start a program with effect support.
/// Returns the first EvalResult — caller drives the yield/resume cycle.
pub fn start(source: String, gas: Int) -> Result(effect.EvalResult, String) {
  case prepare(source) {
    Error(msg) -> Error(msg)
    Ok(prog) -> Ok(start_program(prog, gas))
  }
}

/// Parse, desugar, and start with an env value and effect support.
pub fn start_with_env(
  source: String,
  env_value: value.Value,
  gas: Int,
) -> Result(effect.EvalResult, String) {
  case prepare(source) {
    Error(msg) -> Error(msg)
    Ok(prog) -> Ok(start_program_with_env(prog, env_value, gas))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// AST-level entrypoints (skip parsing — for repeated execution)
// ═══════════════════════════════════════════════════════════════════════════

/// Run a desugared program. Effects are not supported.
pub fn run_program(
  program: ast.Program,
  gas: Int,
) -> Result(value.Value, value.RuntimeError) {
  effect.to_result(eval.run(program, gas))
}

/// Run a desugared program with an env value. Effects are not supported.
pub fn run_program_with_env(
  program: ast.Program,
  env_value: value.Value,
  gas: Int,
) -> Result(value.Value, value.RuntimeError) {
  effect.to_result(eval.run_with_env(program, env_value, gas))
}

/// Start a desugared program with effect support.
/// Returns the first EvalResult — caller drives the yield/resume cycle.
pub fn start_program(program: ast.Program, gas: Int) -> effect.EvalResult {
  eval.run(program, gas)
}

/// Start a desugared program with an env value and effect support.
pub fn start_program_with_env(
  program: ast.Program,
  env_value: value.Value,
  gas: Int,
) -> effect.EvalResult {
  eval.run_with_env(program, env_value, gas)
}

// ═══════════════════════════════════════════════════════════════════════════
// Continuation resume
// ═══════════════════════════════════════════════════════════════════════════

/// Resume a yielded continuation with a host-provided value.
pub fn resume(
  continuation: effect.Continuation,
  host_value: value.Value,
) -> effect.EvalResult {
  effect.resume(continuation, host_value)
}

// ═══════════════════════════════════════════════════════════════════════════
// Compilation helper
// ═══════════════════════════════════════════════════════════════════════════

/// Parse and desugar a source string into a ready-to-run AST.
/// Use this when you want to compile once and run many times.
pub fn prepare(source: String) -> Result(ast.Program, String) {
  case chute.parse(source) {
    Ok(prog) -> Ok(chute.desugar(prog))
    Error(msg) -> Error(msg)
  }
}
