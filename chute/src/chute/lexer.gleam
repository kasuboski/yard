import chute/token
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Tokenize a Chute source string into a list of tokens.
pub fn tokenize(source: String) -> Result(List(token.Token), String) {
  do_tokenize(source, [])
}

fn do_tokenize(
  src: String,
  acc: List(token.Token),
) -> Result(List(token.Token), String) {
  let rest = drop_whitespace(src)
  case string.first(rest) {
    Ok("/") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok("/") -> {
          let comment = take_until_newline(rest)
          let after = string.drop_start(rest, string.length(comment))
          do_tokenize(after, [
            token.TokenComment(string.drop_start(comment, 2)),
            ..acc
          ])
        }
        _ -> do_tokenize(string.drop_start(rest, 1), [token.TokenSlash, ..acc])
      }
    }
    Ok("|") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok(">") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenPipe, ..acc])
        _ -> Error("Unexpected character: |")
      }
    }
    Ok("=") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok("=") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenEq, ..acc])
        _ -> do_tokenize(string.drop_start(rest, 1), [token.TokenAssign, ..acc])
      }
    }
    Ok("!") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok("=") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenNeq, ..acc])
        _ -> Error("Unexpected character: !")
      }
    }
    Ok("<") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok("=") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenLe, ..acc])
        Ok(">") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenNeq, ..acc])
        _ -> do_tokenize(string.drop_start(rest, 1), [token.TokenLt, ..acc])
      }
    }
    Ok(">") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok("=") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenGe, ..acc])
        _ -> do_tokenize(string.drop_start(rest, 1), [token.TokenGt, ..acc])
      }
    }
    Ok("-") -> {
      case string.first(string.drop_start(rest, 1)) {
        Ok(">") ->
          do_tokenize(string.drop_start(rest, 2), [token.TokenArrow, ..acc])
        _ -> do_tokenize(string.drop_start(rest, 1), [token.TokenMinus, ..acc])
      }
    }
    Ok("+") -> do_tokenize(string.drop_start(rest, 1), [token.TokenPlus, ..acc])
    Ok("*") -> do_tokenize(string.drop_start(rest, 1), [token.TokenStar, ..acc])
    Ok("(") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenLParen, ..acc])
    Ok(")") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenRParen, ..acc])
    Ok("{") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenLBrace, ..acc])
    Ok("}") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenRBrace, ..acc])
    Ok("[") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenLBracket, ..acc])
    Ok("]") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenRBracket, ..acc])
    Ok(",") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenComma, ..acc])
    Ok(":") ->
      do_tokenize(string.drop_start(rest, 1), [token.TokenColon, ..acc])
    Ok(".") -> do_tokenize(string.drop_start(rest, 1), [token.TokenDot, ..acc])
    Ok("\"") -> {
      use #(tok, consumed) <- result.try(lex_string(string.drop_start(rest, 1)))
      do_tokenize(string.drop_start(rest, consumed + 1), [tok, ..acc])
    }
    Ok(c) -> {
      let is_d = is_digit_char(c)
      let is_a = is_alpha_char(c)
      case is_d, is_a {
        True, _ -> lex_number(rest, acc)
        _, True -> {
          let word = take_ident(rest)
          let tok = word_to_keyword(word)
          do_tokenize(string.drop_start(rest, string.length(word)), [tok, ..acc])
        }
        _, _ -> Error("Unexpected character: " <> c)
      }
    }
    Error(Nil) -> Ok(list.reverse([token.TokenEof, ..acc]))
  }
}

// ── Keywords ───────────────────────────────────────────────────────────────

fn word_to_keyword(word: String) -> token.Token {
  case word {
    "pub" -> token.TokenPub
    "fn" -> token.TokenFn
    "let" -> token.TokenLet
    "effect" -> token.TokenEffect
    "perform" -> token.TokenPerform
    "case" -> token.TokenCase
    "try" -> token.TokenTry
    "_" -> token.TokenUnderscore
    "True" -> token.TokenTrue
    "False" -> token.TokenFalse
    other -> token.TokenIdent(name: other)
  }
}

// ── Number lexing ──────────────────────────────────────────────────────────

fn lex_number(
  src: String,
  acc: List(token.Token),
) -> Result(List(token.Token), String) {
  let int_part = take_digits(src)
  let after_int = string.drop_start(src, string.length(int_part))
  case string.first(after_int) {
    Ok(".") -> {
      let after_dot = string.drop_start(after_int, 1)
      let frac_part = take_digits(after_dot)
      let full = int_part <> "." <> frac_part
      case float.parse(full) {
        Ok(f) ->
          do_tokenize(string.drop_start(after_dot, string.length(frac_part)), [
            token.TokenFloat(value: f),
            ..acc
          ])
        Error(Nil) -> Error("Invalid float literal: " <> full)
      }
    }
    _ ->
      case int.parse(int_part) {
        Ok(n) ->
          do_tokenize(string.drop_start(src, string.length(int_part)), [
            token.TokenInt(value: n),
            ..acc
          ])
        Error(Nil) -> Error("Invalid integer literal: " <> int_part)
      }
  }
}

// ── String lexing ──────────────────────────────────────────────────────────

/// Lex a string from after the opening quote.
/// Returns the token and the number of characters consumed (from after the opening quote).
fn lex_string(src: String) -> Result(#(token.Token, Int), String) {
  do_lex_string(src, 0, [])
}

fn do_lex_string(
  src: String,
  consumed: Int,
  parts: List(token.StringPart),
) -> Result(#(token.Token, Int), String) {
  case string.first(src) {
    Error(Nil) -> Error("Unterminated string literal")
    Ok("\"") ->
      Ok(#(token.TokenString(parts: list.reverse(parts)), consumed + 1))
    Ok("\\") -> {
      let after_backslash = string.drop_start(src, 1)
      case string.first(after_backslash) {
        Ok("n") ->
          do_lex_string(
            string.drop_start(after_backslash, 1),
            consumed + 2,
            append_text(parts, "\n"),
          )
        Ok("t") ->
          do_lex_string(
            string.drop_start(after_backslash, 1),
            consumed + 2,
            append_text(parts, "\t"),
          )
        Ok("\"") ->
          do_lex_string(
            string.drop_start(after_backslash, 1),
            consumed + 2,
            append_text(parts, "\""),
          )
        Ok("\\") ->
          do_lex_string(
            string.drop_start(after_backslash, 1),
            consumed + 2,
            append_text(parts, "\\"),
          )
        _ -> Error("Invalid escape sequence in string")
      }
    }
    Ok("$") -> {
      let after_dollar = string.drop_start(src, 1)
      case string.first(after_dollar) {
        Ok("{") -> {
          let #(expr_text, rest_str) =
            take_interpolation(string.drop_start(after_dollar, 1), 0, 1)
          let inner_consumed =
            string.length(after_dollar) - string.length(rest_str)
          let new_parts = case expr_text {
            "" -> parts
            _ -> {
              // Re-tokenize the interpolation content into real tokens
              let interpolated = case do_tokenize(expr_text, []) {
                Ok(tokens) -> strip_eof(tokens)
                Error(_) -> []
              }
              [token.StringInterpolation(tokens: interpolated), ..parts]
            }
          }
          do_lex_string(rest_str, consumed + 2 + inner_consumed, new_parts)
        }
        _ -> do_lex_string(after_dollar, consumed + 1, append_text(parts, "$"))
      }
    }
    Ok(c) ->
      do_lex_string(
        string.drop_start(src, 1),
        consumed + 1,
        append_text(parts, c),
      )
  }
}

/// Append text to the last StringText part, or create a new one.
fn append_text(
  parts: List(token.StringPart),
  text: String,
) -> List(token.StringPart) {
  case parts {
    [token.StringText(t), ..rest] -> [token.StringText(text: t <> text), ..rest]
    _ -> [token.StringText(text: text), ..parts]
  }
}

/// Take characters until matching closing `}`, handling nested braces.
/// Returns #(captured_text, remaining_string).
fn take_interpolation(
  src: String,
  consumed: Int,
  depth: Int,
) -> #(String, String) {
  case string.first(src) {
    Ok("}") -> {
      let new_depth = depth - 1
      case new_depth {
        0 -> #("", string.drop_start(src, 1))
        _ -> {
          let #(text, rest) =
            take_interpolation(
              string.drop_start(src, 1),
              consumed + 1,
              new_depth,
            )
          #("}" <> text, rest)
        }
      }
    }
    Ok("{") -> {
      let #(text, rest) =
        take_interpolation(string.drop_start(src, 1), consumed + 1, depth + 1)
      #("{" <> text, rest)
    }
    Ok(c) -> {
      let #(text, rest) =
        take_interpolation(string.drop_start(src, 1), consumed + 1, depth)
      #(c <> text, rest)
    }
    Error(Nil) -> #("", src)
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn drop_whitespace(s: String) -> String {
  case string.first(s) {
    Ok(" ") -> drop_whitespace(string.drop_start(s, 1))
    Ok("\n") -> drop_whitespace(string.drop_start(s, 1))
    Ok("\t") -> drop_whitespace(string.drop_start(s, 1))
    Ok("\r") -> drop_whitespace(string.drop_start(s, 1))
    _ -> s
  }
}

fn take_until_newline(s: String) -> String {
  let graphemes = string.to_graphemes(s)
  let taken = take_until_grapheme(graphemes, "\n")
  string.concat(taken)
}

fn take_until_grapheme(graphemes: List(String), stop: String) -> List(String) {
  case graphemes {
    [g, ..rest] -> {
      let is_stop = g == stop
      case is_stop {
        True -> []
        False -> [g, ..take_until_grapheme(rest, stop)]
      }
    }
    _ -> []
  }
}

fn take_ident(s: String) -> String {
  case string.first(s) {
    Ok(c) -> {
      let is_a = is_alpha_char(c)
      let is_d = is_digit_char(c)
      let is_under = c == "_"
      case is_a, is_d, is_under {
        _, _, True -> {
          let rest = take_ident(string.drop_start(s, 1))
          c <> rest
        }
        True, _, _ -> {
          let rest = take_ident(string.drop_start(s, 1))
          c <> rest
        }
        _, True, _ -> {
          let rest = take_ident(string.drop_start(s, 1))
          c <> rest
        }
        _, _, _ -> ""
      }
    }
    Error(Nil) -> ""
  }
}

fn take_digits(s: String) -> String {
  case string.first(s) {
    Ok(c) -> {
      let is_d = is_digit_char(c)
      case is_d {
        True -> {
          let rest = take_digits(string.drop_start(s, 1))
          c <> rest
        }
        False -> ""
      }
    }
    Error(Nil) -> ""
  }
}

fn is_alpha_char(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", c)
  || string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
  || c == "_"
}

fn is_digit_char(c: String) -> Bool {
  string.contains("0123456789", c)
}

/// Remove the trailing TokenEof from a token list.
fn strip_eof(tokens: List(token.Token)) -> List(token.Token) {
  list.filter(tokens, fn(t) { t != token.TokenEof })
}
