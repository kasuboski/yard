import chute/ast
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// Parse an S-expression string back into an AST Program.
/// This is the inverse of sexp.to_sexp, enabling round-tripping.
pub fn from_sexp(source: String) -> Result(ast.Program, String) {
  use tokens <- result.try(tokenize(source))
  use #(sexp, rest) <- result.try(parse_sexp(tokens))
  case rest {
    [] -> sexp_to_program(sexp)
    _ -> Error("Unexpected tokens after S-expression")
  }
}

// ── S-expression tree type ─────────────────────────────────────────────────

type Sexp {
  SAtom(content: String)
  SList(elements: List(Sexp))
}

// ── Tokenizer ──────────────────────────────────────────────────────────────

type SexpToken {
  TParenOpen
  TParenClose
  TAtom(content: String)
  TString(content: String)
}

fn tokenize(source: String) -> Result(List(SexpToken), String) {
  tokenize_chars(string.to_graphemes(source), [])
}

fn tokenize_chars(chars: List(String), acc: List(SexpToken)) {
  case chars {
    [] -> Ok(list.reverse(acc))
    ["(", ..rest] -> tokenize_chars(rest, [TParenOpen, ..acc])
    [")", ..rest] -> tokenize_chars(rest, [TParenClose, ..acc])
    // Whitespace and newlines: skip
    [" ", ..rest] | ["\n", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      tokenize_chars(rest, acc)
    // String literal
    ["\"", ..rest] -> tokenize_string(rest, [], acc)
    // Atom: anything else until whitespace or paren
    _ -> tokenize_atom(chars, [], acc)
  }
}

fn tokenize_string(
  chars: List(String),
  content: List(String),
  acc: List(SexpToken),
) {
  case chars {
    [] -> Error("Unterminated string in S-expression")
    ["\\", "n", ..rest] -> tokenize_string(rest, ["\n", ..content], acc)
    ["\\", "t", ..rest] -> tokenize_string(rest, ["\t", ..content], acc)
    ["\\", "\"", ..rest] -> tokenize_string(rest, ["\"", ..content], acc)
    ["\\", "\\", ..rest] -> tokenize_string(rest, ["\\", ..content], acc)
    ["\"", ..rest] ->
      tokenize_chars(rest, [
        TString(string.join(list.reverse(content), "")),
        ..acc
      ])
    [c, ..rest] -> tokenize_string(rest, [c, ..content], acc)
  }
}

fn tokenize_atom(
  chars: List(String),
  content: List(String),
  acc: List(SexpToken),
) {
  case chars {
    []
    | ["(", ..]
    | [")", ..]
    | [" ", ..]
    | ["\n", ..]
    | ["\t", ..]
    | ["\"", ..] -> {
      let atom = string.join(list.reverse(content), "")
      tokenize_chars(chars, [TAtom(atom), ..acc])
    }
    [c, ..rest] -> tokenize_atom(rest, [c, ..content], acc)
  }
}

// ── Sexp tree parser ───────────────────────────────────────────────────────

fn parse_sexp(
  tokens: List(SexpToken),
) -> Result(#(Sexp, List(SexpToken)), String) {
  case tokens {
    [] -> Error("Unexpected end of S-expression")
    [TParenOpen, ..rest] -> parse_list(rest, [])
    [TAtom(content), ..rest] -> Ok(#(SAtom(content), rest))
    [TString(content), ..rest] -> Ok(#(SAtom("\"" <> content <> "\""), rest))
    [TParenClose, ..] -> Error("Unexpected closing paren")
  }
}

fn parse_list(tokens: List(SexpToken), acc: List(Sexp)) {
  case tokens {
    [] -> Error("Unterminated list in S-expression")
    [TParenClose, ..rest] -> Ok(#(SList(list.reverse(acc)), rest))
    _ -> {
      use #(sexp, rest) <- result.try(parse_sexp(tokens))
      parse_list(rest, [sexp, ..acc])
    }
  }
}

// ── Sexp tree → AST conversion ─────────────────────────────────────────────

fn sexp_to_program(sexp: Sexp) -> Result(ast.Program, String) {
  case sexp {
    SList([SAtom("program"), ..decl_sexps]) -> {
      use declarations <- result.try(list.try_map(
        decl_sexps,
        sexp_to_declaration,
      ))
      Ok(ast.Program(declarations))
    }
    _ -> Error("Expected (program decls...), got: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_declaration(sexp: Sexp) -> Result(ast.Declaration, String) {
  case sexp {
    SList([SAtom("effect"), SAtom(name), SList(params), return_type_sexp]) -> {
      use params <- result.try(list.try_map(params, sexp_to_param))
      use return_type <- result.try(sexp_to_type(return_type_sexp))
      Ok(ast.EffectDecl(name, params, return_type))
    }

    SList([
      SAtom("fn"),
      SAtom("pub"),
      SAtom(name),
      SList(params),
      return_type_sexp,
      body_sexp,
    ]) -> {
      use params <- result.try(list.try_map(params, sexp_to_param))
      use return_type <- result.try(sexp_to_type(return_type_sexp))
      use body <- result.try(sexp_to_block(body_sexp))
      Ok(ast.FunctionDecl(name, True, params, return_type, body))
    }

    SList([SAtom("fn"), SAtom(name), SList(params), return_type_sexp, body_sexp]) -> {
      use params <- result.try(list.try_map(params, sexp_to_param))
      use return_type <- result.try(sexp_to_type(return_type_sexp))
      use body <- result.try(sexp_to_block(body_sexp))
      Ok(ast.FunctionDecl(name, False, params, return_type, body))
    }

    _ -> Error("Invalid declaration: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_param(sexp: Sexp) -> Result(ast.Param, String) {
  case sexp {
    SList([SAtom(name), type_sexp]) -> {
      use type_ <- result.try(sexp_to_type(type_sexp))
      Ok(ast.Param(name, type_))
    }
    _ -> Error("Invalid param: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_type(sexp: Sexp) -> Result(ast.Type, String) {
  case sexp {
    SAtom(name) -> Ok(ast.TypeNamed(name, []))
    SList([]) -> Error("Empty list in type position")
    SList([SAtom("Record"), ..field_sexps]) -> {
      use fields <- result.try(list.try_map(field_sexps, sexp_to_type_field))
      Ok(ast.TypeRecord(fields))
    }
    SList([SAtom("Fn"), SList(param_type_sexps), return_sexp]) -> {
      use params <- result.try(list.try_map(param_type_sexps, sexp_to_type))
      use return_ <- result.try(sexp_to_type(return_sexp))
      Ok(ast.TypeFn(params, return_))
    }
    SList([SAtom(name), ..arg_sexps]) -> {
      use args <- result.try(list.try_map(arg_sexps, sexp_to_type))
      Ok(ast.TypeNamed(name, args))
    }
    SList([non_atom, ..]) ->
      Error("Type list must start with atom: " <> sexp_to_string(non_atom))
  }
}

fn sexp_to_type_field(sexp: Sexp) -> Result(ast.TypeField, String) {
  case sexp {
    SList([SAtom(name), type_sexp]) -> {
      use type_ <- result.try(sexp_to_type(type_sexp))
      Ok(ast.TypeField(name, type_))
    }
    _ -> Error("Invalid type field: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_block(sexp: Sexp) -> Result(ast.Block, String) {
  case sexp {
    SList([SAtom("block")]) -> Ok(ast.Block([], option.None))
    SList([SAtom("block"), ..item_sexps]) -> {
      // Split into statements (let/stmt) and optional trailing expression
      let #(stmt_sexps, trailing_sexps) = split_block_items(item_sexps)
      use statements <- result.try(list.try_map(stmt_sexps, sexp_to_statement))
      case trailing_sexps {
        [] -> Ok(ast.Block(statements, option.None))
        [expr_sexp] -> {
          use expr <- result.try(sexp_to_expr(expr_sexp))
          Ok(ast.Block(statements, option.Some(expr)))
        }
        _ -> Error("Block has multiple trailing expressions")
      }
    }
    _ -> Error("Invalid block: " <> sexp_to_string(sexp))
  }
}

fn split_block_items(items: List(Sexp)) -> #(List(Sexp), List(Sexp)) {
  // Walk from the end: trailing expression is the last non-statement item
  // Statements: (let ...) or (stmt ...)
  // Everything else at the end is the trailing expression
  split_block_items_acc(items, [])
}

fn split_block_items_acc(
  items: List(Sexp),
  trailing_acc: List(Sexp),
) -> #(List(Sexp), List(Sexp)) {
  case items {
    [] -> #([], list.reverse(trailing_acc))
    [last] -> {
      case is_statement_sexp(last) {
        True -> #([last], list.reverse(trailing_acc))
        False -> #([], [last, ..list.reverse(trailing_acc)])
      }
    }
    [first, ..rest] -> {
      let #(stmts, trailing) = split_block_items_acc(rest, trailing_acc)
      case is_statement_sexp(first) {
        True -> #([first, ..stmts], trailing)
        False -> {
          #([first, ..stmts], trailing)
        }
      }
    }
  }
}

fn is_statement_sexp(sexp: Sexp) -> Bool {
  case sexp {
    SList([SAtom("let"), ..]) -> True
    SList([SAtom("let-try"), ..]) -> True
    SList([SAtom("stmt"), ..]) -> True
    _ -> False
  }
}

fn sexp_to_statement(sexp: Sexp) -> Result(ast.Statement, String) {
  case sexp {
    SList([SAtom("let"), SAtom(name), type_sexp, value_sexp]) -> {
      // let with type annotation
      use type_ <- result.try(sexp_to_type(type_sexp))
      use value <- result.try(sexp_to_expr(value_sexp))
      Ok(ast.LetDecl(name, option.Some(type_), value))
    }
    SList([SAtom("let"), SAtom(name), value_sexp]) -> {
      use value <- result.try(sexp_to_expr(value_sexp))
      Ok(ast.LetDecl(name, option.None, value))
    }
    SList([SAtom("let-try"), SAtom(name), type_sexp, value_sexp]) -> {
      // let-try with type annotation
      use type_ <- result.try(sexp_to_type(type_sexp))
      use value <- result.try(sexp_to_expr(value_sexp))
      Ok(ast.LetTryDecl(name, option.Some(type_), value))
    }
    SList([SAtom("let-try"), SAtom(name), value_sexp]) -> {
      use value <- result.try(sexp_to_expr(value_sexp))
      Ok(ast.LetTryDecl(name, option.None, value))
    }
    SList([SAtom("stmt"), expr_sexp]) -> {
      use expr <- result.try(sexp_to_expr(expr_sexp))
      Ok(ast.StatementExpr(expr))
    }
    _ -> Error("Invalid statement: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_expr(sexp: Sexp) -> Result(ast.Expr, String) {
  case sexp {
    SList([SAtom("var"), SAtom(name)]) -> Ok(ast.ExprVar(name))

    SList([SAtom("int"), SAtom(value_str)]) -> {
      case int.parse(value_str) {
        Ok(value) -> Ok(ast.ExprInt(value))
        Error(_) -> Error("Invalid int literal: " <> value_str)
      }
    }

    SList([SAtom("float"), SAtom(value_str)]) -> {
      case float.parse(value_str) {
        Ok(value) -> Ok(ast.ExprFloat(value))
        Error(_) -> Error("Invalid float literal: " <> value_str)
      }
    }

    SList([SAtom("bool"), SAtom("true")]) -> Ok(ast.ExprBool(True))
    SList([SAtom("bool"), SAtom("false")]) -> Ok(ast.ExprBool(False))

    SList([SAtom("nil")]) -> Ok(ast.ExprNil)

    // String with empty parts list
    SList([SAtom("string")]) -> Ok(ast.ExprString([]))

    // String: check for quoted string content
    SList([SAtom("string"), quoted_text]) -> {
      case unquote_string(quoted_text) {
        Ok(text) -> Ok(ast.ExprString([ast.StringText(text)]))
        Error(e) -> Error(e)
      }
    }

    // String with multiple parts (text + interpolation)
    SList([SAtom("string"), ..part_sexps]) -> {
      use parts <- result.try(list.try_map(part_sexps, sexp_to_string_part))
      Ok(ast.ExprString(parts))
    }

    SList([SAtom("record"), ..field_sexps]) -> {
      use fields <- result.try(list.try_map(field_sexps, sexp_to_record_field))
      Ok(ast.ExprRecord(fields))
    }

    SList([SAtom("list"), ..elem_sexps]) -> {
      use elements <- result.try(list.try_map(elem_sexps, sexp_to_expr))
      Ok(ast.ExprList(elements))
    }

    SList([SAtom("call"), func_sexp]) -> {
      use func <- result.try(sexp_to_expr(func_sexp))
      Ok(ast.ExprCall(func, []))
    }

    SList([SAtom("call"), func_sexp, ..arg_sexps]) -> {
      use func <- result.try(sexp_to_expr(func_sexp))
      use args <- result.try(list.try_map(arg_sexps, sexp_to_expr))
      Ok(ast.ExprCall(func, args))
    }

    SList([SAtom("field-access"), record_sexp, SAtom(field)]) -> {
      use record <- result.try(sexp_to_expr(record_sexp))
      Ok(ast.ExprFieldAccess(record, field))
    }

    SList([SAtom("perform"), SAtom(name)]) -> {
      Ok(ast.ExprPerform(name, []))
    }

    SList([SAtom("perform"), SAtom(name), ..arg_sexps]) -> {
      use args <- result.try(list.try_map(arg_sexps, sexp_to_expr))
      Ok(ast.ExprPerform(name, args))
    }

    SList([SAtom("binop"), SAtom(op_str), left_sexp, right_sexp]) -> {
      use op <- result.try(parse_binop(op_str))
      use left <- result.try(sexp_to_expr(left_sexp))
      use right <- result.try(sexp_to_expr(right_sexp))
      Ok(ast.ExprBinaryOp(left, op, right))
    }

    SList([SAtom("closure"), SList(param_sexps), body_sexp]) -> {
      let params =
        list.map(param_sexps, fn(s) {
          case s {
            SAtom(name) -> name
            _ -> ""
          }
        })
      use body <- result.try(sexp_to_block(body_sexp))
      Ok(ast.ExprClosure(params, body))
    }

    SList([SAtom("pipeline"), left_sexp, right_sexp]) -> {
      use left <- result.try(sexp_to_expr(left_sexp))
      use right <- result.try(sexp_to_expr(right_sexp))
      Ok(ast.ExprPipeline(left, right))
    }

    SList([SAtom("case"), subject_sexp, ..branch_sexps]) -> {
      use subject <- result.try(sexp_to_expr(subject_sexp))
      use branches <- result.try(list.try_map(branch_sexps, sexp_to_case_branch))
      Ok(ast.ExprCase(subject, branches))
    }

    _ -> Error("Invalid expression: " <> sexp_to_string(sexp))
  }
}

fn sexp_to_string_part(sexp: Sexp) -> Result(ast.StringPart, String) {
  case sexp {
    SList([SAtom("interp"), expr_sexp]) -> {
      use expr <- result.try(sexp_to_expr(expr_sexp))
      Ok(ast.StringInterpolation(expr))
    }
    _ -> {
      // Must be a quoted string fragment
      case unquote_string(sexp) {
        Ok(text) -> Ok(ast.StringText(text))
        Error(e) -> Error("Invalid string part: " <> e)
      }
    }
  }
}

fn sexp_to_record_field(sexp: Sexp) -> Result(ast.RecordField, String) {
  case sexp {
    SList([SAtom(name), value_sexp]) -> {
      use value <- result.try(sexp_to_expr(value_sexp))
      Ok(ast.RecordField(name, value))
    }
    _ -> Error("Invalid record field: " <> sexp_to_string(sexp))
  }
}

fn unquote_string(sexp: Sexp) -> Result(String, String) {
  case sexp {
    SAtom(content) -> {
      case
        string.starts_with(content, "\"") && string.ends_with(content, "\"")
      {
        True -> {
          let inner = string.drop_start(content, up_to: string.length("\""))
          let inner = string.drop_end(inner, up_to: string.length("\""))
          Ok(unescape_string(inner))
        }
        False -> Error("Not a quoted string: " <> content)
      }
    }
    _ -> Error("Expected string atom")
  }
}

fn unescape_string(s: String) -> String {
  s
  |> string.replace("\\n", "\n")
  |> string.replace("\\t", "\t")
  |> string.replace("\\\"", "\"")
  |> string.replace("\\\\", "\\")
}

fn sexp_to_case_branch(sexp: Sexp) -> Result(ast.CaseBranch, String) {
  case sexp {
    SList([SAtom("branch"), pattern_sexp, body_sexp]) -> {
      use pattern <- result.try(sexp_to_expr(pattern_sexp))
      use body <- result.try(sexp_to_block(body_sexp))
      Ok(ast.CaseBranch(pattern, body))
    }
    SList([SAtom("wildcard"), body_sexp]) -> {
      use body <- result.try(sexp_to_block(body_sexp))
      Ok(ast.CaseWildcard(body))
    }
    _ -> Error("Invalid case branch: " <> sexp_to_string(sexp))
  }
}

fn parse_binop(op: String) -> Result(ast.BinOp, String) {
  case op {
    "==" -> Ok(ast.OpEq)
    "!=" -> Ok(ast.OpNeq)
    "<" -> Ok(ast.OpLt)
    "<=" -> Ok(ast.OpLe)
    ">" -> Ok(ast.OpGt)
    ">=" -> Ok(ast.OpGe)
    "+" -> Ok(ast.OpAdd)
    "-" -> Ok(ast.OpSub)
    "*" -> Ok(ast.OpMul)
    "/" -> Ok(ast.OpDiv)
    _ -> Error("Unknown operator: " <> op)
  }
}

// ── Debug: sexp tree to string ─────────────────────────────────────────────

fn sexp_to_string(sexp: Sexp) -> String {
  case sexp {
    SAtom(content) -> content
    SList(elements) ->
      "(" <> string.join(list.map(elements, sexp_to_string), " ") <> ")"
  }
}
