import chute/ast
import chute/desugar
import chute/lexer
import chute/parser
import chute/sexp
import chute/sexp_parse
import chute/typecheck
import chute/typecheck/types as tc
import gleam/list
import gleam/result
import gleam/string

/// Parse a Chute source string into an AST.
pub fn parse(source: String) -> Result(ast.Program, String) {
  use tokens <- result.try(lexer.tokenize(source))
  parser.parse(tokens)
}

/// Desugar a parsed AST into canonical form.
/// Unwraps grouping parens, normalizes empty blocks, etc.
pub fn desugar(program: ast.Program) -> ast.Program {
  desugar.desugar(program)
}

/// Convert a desugared AST to an S-expression string (transport/storage format).
pub fn to_sexp(program: ast.Program) -> String {
  sexp.to_sexp(program)
}

/// Parse an S-expression string back into an AST.
/// Inverse of to_sexp — enables round-tripping.
pub fn from_sexp(source: String) -> Result(ast.Program, String) {
  sexp_parse.from_sexp(source)
}

/// Type-check a parsed, desugared program.
/// Returns a list of type errors. Empty list = well-typed.
pub fn typecheck(program: ast.Program) -> List(tc.TypeError) {
  typecheck.typecheck(program)
}

/// Full compilation pipeline: source → parse → desugar → typecheck → S-expression string.
pub fn compile(source: String) -> Result(String, String) {
  use program <- result.try(parse(source))
  let desugared = desugar(program)
  let errors = typecheck(desugared)
  case errors {
    [] -> Ok(to_sexp(desugared))
    _ ->
      Error(
        string.join(
          list.map(errors, fn(e) {
            let tc.TypeError(message: msg) = e
            msg
          }),
          "\n",
        ),
      )
  }
}
