//// Actor loader — parse source, compute version hash.
////
//// Loads chute source into a ready-to-run `LoadedActor` with a canonical
//// SHA-256 hash for version identity. The hash is of the S-expression output,
//// which is canonical (comments stripped, formatting normalized).

import ballast
import chute
import chute/ast.{type Program}

// ── FFI ──────────────────────────────────────────────────────────────

@external(erlang, "yard_obs_ffi", "sha256_first8")
fn sha256_first8(input: String) -> String

// ── Public Types ─────────────────────────────────────────────────────

/// A loaded actor, ready to run.
///
/// Created by `load()` — parses source, computes hash, returns the
/// program with identity metadata.
pub type LoadedActor {
  LoadedActor(
    /// Compiled (desugared) program, ready for ballast.
    program: Program,
    /// File path (e.g. "actors/triage.chute").
    actor_path: String,
    /// SHA-256 of canonical S-expression, first 8 hex chars.
    /// Same source always produces the same hash.
    actor_hash: String,
  )
}

// ── Public API ───────────────────────────────────────────────────────

/// Load a chute actor from source code.
///
/// Parses and desugars the source (via `ballast.prepare`), then computes
/// a version hash from the canonical S-expression. The hash identifies the
/// actor version — same source always produces the same hash, regardless
/// of comments or formatting.
///
/// Returns `Error(msg)` if the source fails to parse.
pub fn load(source: String, path: String) -> Result(LoadedActor, String) {
  case ballast.prepare(source) {
    Error(msg) -> Error(msg)
    Ok(program) -> {
      let sexp = chute.to_sexp(program)
      let hash = sha256_first8(sexp)
      Ok(LoadedActor(program:, actor_path: path, actor_hash: hash))
    }
  }
}
