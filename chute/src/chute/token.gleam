/// Token types for the Chute lexer.
pub type Token {
  // Keywords
  TokenPub
  TokenFn
  TokenLet
  TokenEffect
  TokenPerform
  TokenCase
  TokenTry
  TokenUnderscore
  TokenTrue
  TokenFalse

  // Literals
  TokenInt(value: Int)
  TokenFloat(value: Float)
  TokenString(parts: List(StringPart))

  // Identifiers
  TokenIdent(name: String)

  // Operators
  TokenPipe
  // |>
  TokenEq
  // ==
  TokenNeq
  // !=
  TokenLt
  // <
  TokenLe
  // <=
  TokenGt
  // >
  TokenGe
  // >=
  TokenPlus
  // +
  TokenMinus
  // -
  TokenStar
  // *
  TokenSlash
  // /
  TokenAssign

  // =
  // Delimiters
  TokenLParen
  // (
  TokenRParen
  // )
  TokenLBrace
  // {
  TokenRBrace
  // }
  TokenLBracket
  // [
  TokenRBracket
  // ]
  TokenComma
  // ,
  TokenDot
  // .
  TokenColon
  // :
  TokenArrow

  // ->
  // Special
  TokenComment(text: String)
  TokenEof
}

/// String parts for token-level string interpolation.
pub type StringPart {
  StringText(text: String)
  /// The interpolation content has been tokenized into real tokens.
  /// The parser will parse these tokens into a proper ast.Expr.
  StringInterpolation(tokens: List(Token))
}
