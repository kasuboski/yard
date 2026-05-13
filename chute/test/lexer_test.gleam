import chute/lexer
import chute/token

pub fn tokenize_integers_test() {
  let assert Ok(tokens) = lexer.tokenize("42")
  let assert [token.TokenInt(42), token.TokenEof] = tokens
}

pub fn tokenize_floats_test() {
  let assert Ok(tokens) = lexer.tokenize("3.14")
  let assert [token.TokenFloat(3.14), token.TokenEof] = tokens
}

pub fn tokenize_bools_test() {
  let assert Ok(tokens) = lexer.tokenize("True False")
  let assert [token.TokenTrue, token.TokenFalse, token.TokenEof] = tokens
}

pub fn tokenize_string_test() {
  let assert Ok(tokens) = lexer.tokenize("\"hello world\"")
  let assert [
    token.TokenString([token.StringText("hello world")]),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_string_escape_test() {
  let assert Ok(tokens) = lexer.tokenize("\"hello\\nworld\"")
  let assert [
    token.TokenString([token.StringText("hello\nworld")]),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_string_interpolation_test() {
  let assert Ok(tokens) = lexer.tokenize("\"Hello ${name}\"")
  let assert [
    token.TokenString([
      token.StringText("Hello "),
      token.StringInterpolation(tokens: [token.TokenIdent("name")]),
    ]),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_keywords_test() {
  let assert Ok(tokens) = lexer.tokenize("pub fn let effect perform")
  let assert [
    token.TokenPub,
    token.TokenFn,
    token.TokenLet,
    token.TokenEffect,
    token.TokenPerform,
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_operators_test() {
  let assert Ok(tokens) = lexer.tokenize("|> == != < <= > >= + - * / = ->")
  let assert [
    token.TokenPipe,
    token.TokenEq,
    token.TokenNeq,
    token.TokenLt,
    token.TokenLe,
    token.TokenGt,
    token.TokenGe,
    token.TokenPlus,
    token.TokenMinus,
    token.TokenStar,
    token.TokenSlash,
    token.TokenAssign,
    token.TokenArrow,
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_delimiters_test() {
  let assert Ok(tokens) = lexer.tokenize("( ) { } [ ] , . :")
  let assert [
    token.TokenLParen,
    token.TokenRParen,
    token.TokenLBrace,
    token.TokenRBrace,
    token.TokenLBracket,
    token.TokenRBracket,
    token.TokenComma,
    token.TokenDot,
    token.TokenColon,
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_identifiers_test() {
  let assert Ok(tokens) = lexer.tokenize("foo bar_baz x123")
  let assert [
    token.TokenIdent("foo"),
    token.TokenIdent("bar_baz"),
    token.TokenIdent("x123"),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_comments_stripped_test() {
  let assert Ok(tokens) = lexer.tokenize("x // comment\ny")
  // Comments are kept as tokens (parser will skip them)
  let assert [
    token.TokenIdent("x"),
    token.TokenComment(" comment"),
    token.TokenIdent("y"),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_complex_expr_test() {
  let assert Ok(tokens) =
    lexer.tokenize("env.order_total |> perform charge_card()")
  let assert [
    token.TokenIdent("env"),
    token.TokenDot,
    token.TokenIdent("order_total"),
    token.TokenPipe,
    token.TokenPerform,
    token.TokenIdent("charge_card"),
    token.TokenLParen,
    token.TokenRParen,
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_empty_input_test() {
  let assert Ok(tokens) = lexer.tokenize("")
  let assert [token.TokenEof] = tokens
}

pub fn tokenize_unterminated_string_test() {
  let assert Error("Unterminated string literal") = lexer.tokenize("\"hello")
}

// ── String interpolation re-tokenization ───────────────────────────────

pub fn tokenize_interpolation_simple_ident_test() {
  let assert Ok(tokens) = lexer.tokenize("\"${x}\"")
  let assert [
    token.TokenString([
      token.StringInterpolation(tokens: [token.TokenIdent("x")]),
    ]),
    token.TokenEof,
  ] = tokens
}

pub fn tokenize_interpolation_expression_test() {
  let assert Ok(tokens) = lexer.tokenize("\"${a + b}\"")
  let assert [
    token.TokenString([token.StringInterpolation(tokens: interp_tokens)]),
    token.TokenEof,
  ] = tokens
  let assert [token.TokenIdent("a"), token.TokenPlus, token.TokenIdent("b")] =
    interp_tokens
}

pub fn tokenize_interpolation_field_access_test() {
  let assert Ok(tokens) = lexer.tokenize("\"${env.name}\"")
  let assert [
    token.TokenString([token.StringInterpolation(tokens: interp_tokens)]),
    token.TokenEof,
  ] = tokens
  let assert [token.TokenIdent("env"), token.TokenDot, token.TokenIdent("name")] =
    interp_tokens
}

pub fn tokenize_interpolation_mixed_test() {
  let assert Ok(tokens) = lexer.tokenize("\"Hello ${name}, you are ${age}!\"")
  let assert [
    token.TokenString([
      token.StringText("Hello "),
      token.StringInterpolation(tokens: [token.TokenIdent("name")]),
      token.StringText(", you are "),
      token.StringInterpolation(tokens: [token.TokenIdent("age")]),
      token.StringText("!"),
    ]),
    token.TokenEof,
  ] = tokens
}
