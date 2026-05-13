import chute/ast
import chute/lexer
import chute/parser
import gleam/result

/// Parse a Chute source string into an AST.
pub fn parse(source: String) -> Result(ast.Program, String) {
  use tokens <- result.try(lexer.tokenize(source))
  parser.parse(tokens)
}
