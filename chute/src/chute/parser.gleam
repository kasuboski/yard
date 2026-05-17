import chute/ast
import chute/token
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/result

/// Parse a list of tokens into a Program AST.
pub fn parse(tokens: List(token.Token)) -> Result(ast.Program, String) {
  let state = State(tokens: tokens, pos: 0)
  parse_program(state)
}

// ── Internal State ─────────────────────────────────────────────────────────

type State {
  State(tokens: List(token.Token), pos: Int)
}

fn list_at(tokens: List(token.Token), index: Int) -> token.Token {
  case list.drop(tokens, index) {
    [t, ..] -> t
    [] -> token.TokenEof
  }
}

fn current(state: State) -> token.Token {
  list_at(state.tokens, state.pos)
}

fn advance(state: State) -> State {
  State(..state, pos: state.pos + 1)
}

fn expect(state: State, expected: token.Token) -> Result(State, String) {
  case current(state) {
    t if t == expected -> Ok(advance(state))
    t ->
      Error(
        "Expected "
        <> token_to_string(expected)
        <> " but found "
        <> token_to_string(t),
      )
  }
}

// ── Program ────────────────────────────────────────────────────────────────

fn parse_program(state: State) -> Result(ast.Program, String) {
  parse_declarations(state, [])
}

fn parse_declarations(
  state: State,
  acc: List(ast.Declaration),
) -> Result(ast.Program, String) {
  case current(state) {
    token.TokenEof | token.TokenRBrace ->
      Ok(ast.Program(declarations: list.reverse(acc)))
    token.TokenEffect -> {
      use #(decl, state) <- result.try(parse_effect_decl(state))
      parse_declarations(state, [decl, ..acc])
    }
    token.TokenPub -> {
      use #(decl, state) <- result.try(parse_fn_decl(state))
      parse_declarations(state, [decl, ..acc])
    }
    token.TokenFn -> {
      use #(decl, state) <- result.try(parse_fn_decl(state))
      parse_declarations(state, [decl, ..acc])
    }
    token.TokenComment(_) -> parse_declarations(advance(state), acc)
    t -> Error("Unexpected token at top level: " <> token_to_string(t))
  }
}

// ── Effect Declaration ─────────────────────────────────────────────────────

fn parse_effect_decl(
  state: State,
) -> Result(#(ast.Declaration, State), String) {
  let state = advance(state)
  use #(name, state) <- result.try(expect_ident(state))
  use state <- result.try(expect(state, token.TokenLParen))
  use #(params, state) <- result.try(parse_param_list(state))
  use state <- result.try(expect(state, token.TokenRParen))
  use state <- result.try(expect(state, token.TokenArrow))
  use #(ret_type, state) <- result.try(parse_type(state))
  Ok(#(ast.EffectDecl(name:, params:, return_type: ret_type), state))
}

// ── Function Declaration ───────────────────────────────────────────────────

fn parse_fn_decl(state: State) -> Result(#(ast.Declaration, State), String) {
  let public = case current(state) {
    token.TokenPub -> True
    _ -> False
  }
  let state = case public {
    True -> advance(state)
    False -> state
  }
  use state <- result.try(expect(state, token.TokenFn))
  use #(name, state) <- result.try(expect_ident(state))
  use state <- result.try(expect(state, token.TokenLParen))
  use #(params, state) <- result.try(parse_param_list(state))
  use state <- result.try(expect(state, token.TokenRParen))
  use state <- result.try(expect(state, token.TokenArrow))
  use #(ret_type, state) <- result.try(parse_type(state))
  use #(body, state) <- result.try(parse_block(state))
  Ok(#(
    ast.FunctionDecl(name:, public:, params:, return_type: ret_type, body:),
    state,
  ))
}

// ── Parameters ─────────────────────────────────────────────────────────────

fn parse_param_list(state: State) -> Result(#(List(ast.Param), State), String) {
  parse_comma_separated(state, parse_param, token.TokenRParen)
}

fn parse_param(state: State) -> Result(#(ast.Param, State), String) {
  use #(name, state) <- result.try(expect_ident(state))
  use state <- result.try(expect(state, token.TokenColon))
  use #(type_, state) <- result.try(parse_type(state))
  Ok(#(ast.Param(name:, type_:), state))
}

// ── Types ──────────────────────────────────────────────────────────────────

fn parse_type(state: State) -> Result(#(ast.Type, State), String) {
  case current(state) {
    token.TokenLBrace -> parse_record_type(state)
    token.TokenIdent(name) -> {
      let state = advance(state)
      case current(state) {
        token.TokenLParen -> {
          let state = advance(state)
          use #(args, state) <- result.try(parse_type_list(state))
          use state <- result.try(expect(state, token.TokenRParen))
          Ok(#(ast.TypeNamed(name:, args:), state))
        }
        _ -> Ok(#(ast.TypeNamed(name:, args: []), state))
      }
    }
    token.TokenFn -> parse_fn_type(state)
    t -> Error("Expected type but found: " <> token_to_string(t))
  }
}

/// Parse a function type: fn(A, B) -> C
fn parse_fn_type(state: State) -> Result(#(ast.Type, State), String) {
  // current is TokenFn
  let state = advance(state)
  use state <- result.try(expect(state, token.TokenLParen))
  use #(params, state) <- result.try(parse_type_list(state))
  use state <- result.try(expect(state, token.TokenRParen))
  use state <- result.try(expect(state, token.TokenArrow))
  use #(return_, state) <- result.try(parse_type(state))
  Ok(#(ast.TypeFn(params:, return_:), state))
}

fn parse_record_type(state: State) -> Result(#(ast.Type, State), String) {
  let state = advance(state)
  use #(fields, state) <- result.try(parse_record_type_fields(state, []))
  use state <- result.try(expect(state, token.TokenRBrace))
  Ok(#(ast.TypeRecord(fields:), state))
}

fn parse_record_type_fields(
  state: State,
  acc: List(ast.TypeField),
) -> Result(#(List(ast.TypeField), State), String) {
  case current(state) {
    token.TokenRBrace -> Ok(#(list.reverse(acc), state))
    _ -> {
      use #(name, state) <- result.try(expect_ident(state))
      use state <- result.try(expect(state, token.TokenColon))
      use #(type_, state) <- result.try(parse_type(state))
      let new_acc = [ast.TypeField(name:, type_:), ..acc]
      case current(state) {
        token.TokenComma -> parse_record_type_fields(advance(state), new_acc)
        _ -> Ok(#(list.reverse(new_acc), state))
      }
    }
  }
}

fn parse_type_list(state: State) -> Result(#(List(ast.Type), State), String) {
  parse_comma_separated(state, parse_type, token.TokenRParen)
}

// ── Block ──────────────────────────────────────────────────────────────────

fn parse_block(state: State) -> Result(#(ast.Block, State), String) {
  use state <- result.try(expect(state, token.TokenLBrace))
  parse_block_body(state, [])
}

fn parse_block_body(
  state: State,
  acc: List(ast.Statement),
) -> Result(#(ast.Block, State), String) {
  // Skip comments
  case current(state) {
    token.TokenComment(_) -> parse_block_body(advance(state), acc)
    _ -> parse_block_body_inner(state, acc)
  }
}

fn parse_block_body_inner(
  state: State,
  acc: List(ast.Statement),
) -> Result(#(ast.Block, State), String) {
  case current(state) {
    token.TokenRBrace ->
      Ok(#(
        ast.Block(statements: list.reverse(acc), trailing: option.None),
        advance(state),
      ))
    token.TokenLet -> {
      use #(stmt, state) <- result.try(parse_let_decl(state))
      parse_block_body(state, [stmt, ..acc])
    }
    _ -> {
      use #(expr, state) <- result.try(parse_expr(state))
      case current(state) {
        token.TokenRBrace ->
          Ok(#(
            ast.Block(
              statements: list.reverse(acc),
              trailing: option.Some(expr),
            ),
            advance(state),
          ))
        _ -> parse_block_body(state, [ast.StatementExpr(expr: expr), ..acc])
      }
    }
  }
}

// ── Let Declaration ────────────────────────────────────────────────────────

fn parse_let_decl(state: State) -> Result(#(ast.Statement, State), String) {
  let state = advance(state)
  // Check for `let try`
  case current(state) {
    token.TokenTry -> {
      let state = advance(state)
      use #(name, state) <- result.try(expect_ident(state))
      use #(type_annotation, state) <- result.try(
        parse_optional_type_annotation(state),
      )
      use state <- result.try(expect(state, token.TokenAssign))
      use #(value, state) <- result.try(parse_expr(state))
      Ok(#(ast.LetTryDecl(name, type_annotation, value), state))
    }
    _ -> {
      use #(name, state) <- result.try(expect_ident(state))
      use #(type_annotation, state) <- result.try(
        parse_optional_type_annotation(state),
      )
      use state <- result.try(expect(state, token.TokenAssign))
      use #(value, state) <- result.try(parse_expr(state))
      Ok(#(ast.LetDecl(name, type_annotation, value), state))
    }
  }
}

fn parse_optional_type_annotation(
  state: State,
) -> Result(#(option.Option(ast.Type), State), String) {
  case current(state) {
    token.TokenColon -> {
      let state = advance(state)
      use #(t, state) <- result.try(parse_type(state))
      Ok(#(option.Some(t), state))
    }
    _ -> Ok(#(option.None, state))
  }
}

// ── Expressions (by precedence) ───────────────────────────────────────────

fn parse_expr(state: State) -> Result(#(ast.Expr, State), String) {
  case current(state) {
    token.TokenCase -> parse_case_expr(state)
    _ -> parse_pipeline(state)
  }
}

fn parse_pipeline(state: State) -> Result(#(ast.Expr, State), String) {
  use #(left, state) <- result.try(parse_logic(state))
  parse_pipeline_tail(left, state)
}

fn parse_pipeline_tail(
  left: ast.Expr,
  state: State,
) -> Result(#(ast.Expr, State), String) {
  case current(state) {
    token.TokenPipe -> {
      let state = advance(state)
      use #(right, state) <- result.try(parse_logic(state))
      let desugared = desugar_pipeline(left, right)
      parse_pipeline_tail(desugared, state)
    }
    _ -> Ok(#(left, state))
  }
}

fn desugar_pipeline(left: ast.Expr, right: ast.Expr) -> ast.Expr {
  case right {
    ast.ExprCall(func, args) -> ast.ExprCall(func, [left, ..args])
    ast.ExprPerform(name, args) -> ast.ExprPerform(name, [left, ..args])
    _ -> ast.ExprPipeline(left:, right:)
  }
}

fn parse_logic(state: State) -> Result(#(ast.Expr, State), String) {
  use #(left, state) <- result.try(parse_math(state))
  let op = token_to_binop(current(state))
  case op {
    option.Some(op) -> {
      let state = advance(state)
      use #(right, state) <- result.try(parse_math(state))
      Ok(#(ast.ExprBinaryOp(left:, op:, right:), state))
    }
    option.None -> Ok(#(left, state))
  }
}

fn parse_math(state: State) -> Result(#(ast.Expr, State), String) {
  use #(left, state) <- result.try(parse_term_expr(state))
  parse_math_tail(left, state)
}

fn parse_math_tail(
  left: ast.Expr,
  state: State,
) -> Result(#(ast.Expr, State), String) {
  let op = token_to_binop(current(state))
  case op {
    option.Some(actual_op) -> {
      let is_add_or_sub = case actual_op {
        ast.OpAdd -> True
        ast.OpSub -> True
        _ -> False
      }
      case is_add_or_sub {
        True -> {
          let state = advance(state)
          use #(right, state) <- result.try(parse_term_expr(state))
          parse_math_tail(ast.ExprBinaryOp(left, actual_op, right), state)
        }
        False -> Ok(#(left, state))
      }
    }
    option.None -> Ok(#(left, state))
  }
}

fn parse_term_expr(state: State) -> Result(#(ast.Expr, State), String) {
  use #(left, state) <- result.try(parse_factor(state))
  parse_term_tail(left, state)
}

fn parse_term_tail(
  left: ast.Expr,
  state: State,
) -> Result(#(ast.Expr, State), String) {
  let op = token_to_binop(current(state))
  case op {
    option.Some(actual_op) -> {
      let is_mul_or_div = case actual_op {
        ast.OpMul -> True
        ast.OpDiv -> True
        _ -> False
      }
      case is_mul_or_div {
        True -> {
          let state = advance(state)
          use #(right, state) <- result.try(parse_factor(state))
          parse_term_tail(ast.ExprBinaryOp(left, actual_op, right), state)
        }
        False -> Ok(#(left, state))
      }
    }
    option.None -> Ok(#(left, state))
  }
}

fn parse_factor(state: State) -> Result(#(ast.Expr, State), String) {
  case current(state) {
    token.TokenPerform -> parse_perform(state)
    _ -> parse_postfix(state)
  }
}

// ── Case Expression ────────────────────────────────────────────────────────

fn parse_case_expr(state: State) -> Result(#(ast.Expr, State), String) {
  // current is TokenCase
  let state = advance(state)
  use #(subject, state) <- result.try(parse_pipeline(state))
  use state <- result.try(expect(state, token.TokenLBrace))
  use #(branches, state) <- result.try(parse_case_branches(state, []))
  use state <- result.try(expect(state, token.TokenRBrace))
  Ok(#(ast.ExprCase(subject:, branches:), state))
}

fn parse_case_branches(
  state: State,
  acc: List(ast.CaseBranch),
) -> Result(#(List(ast.CaseBranch), State), String) {
  // Skip comments
  case current(state) {
    token.TokenComment(_) -> parse_case_branches(advance(state), acc)
    token.TokenRBrace -> Ok(#(list.reverse(acc), state))
    _ -> {
      use #(branch, state) <- result.try(parse_one_case_branch(state))
      parse_case_branches(state, [branch, ..acc])
    }
  }
}

fn parse_one_case_branch(
  state: State,
) -> Result(#(ast.CaseBranch, State), String) {
  case current(state) {
    token.TokenUnderscore -> {
      let state = advance(state)
      use state <- result.try(expect(state, token.TokenArrow))
      use #(body, state) <- result.try(parse_case_branch_body(state))
      Ok(#(ast.CaseWildcard(body:), state))
    }
    _ -> {
      use #(pattern, state) <- result.try(parse_pipeline(state))
      use state <- result.try(expect(state, token.TokenArrow))
      use #(body, state) <- result.try(parse_case_branch_body(state))
      Ok(#(ast.CaseBranch(pattern:, body:), state))
    }
  }
}

fn parse_case_branch_body(state: State) -> Result(#(ast.Block, State), String) {
  case current(state) {
    // If the body starts with `{`, parse as a block (child scope)
    token.TokenLBrace -> parse_block(state)
    // Otherwise parse as a single expression, wrap in Block
    _ -> {
      use #(expr, state) <- result.try(parse_pipeline(state))
      Ok(#(ast.Block(statements: [], trailing: option.Some(expr)), state))
    }
  }
}

fn parse_perform(state: State) -> Result(#(ast.Expr, State), String) {
  let state = advance(state)
  use #(name, state) <- result.try(expect_ident(state))
  case current(state) {
    token.TokenLParen -> {
      let state = advance(state)
      use #(args, state) <- result.try(parse_arg_list(state))
      use state <- result.try(expect(state, token.TokenRParen))
      Ok(#(ast.ExprPerform(name:, args:), state))
    }
    _ -> Ok(#(ast.ExprPerform(name:, args: []), state))
  }
}

fn parse_postfix(state: State) -> Result(#(ast.Expr, State), String) {
  use #(expr, state) <- result.try(parse_primary(state))
  parse_postfix_tail(expr, state)
}

fn parse_postfix_tail(
  expr: ast.Expr,
  state: State,
) -> Result(#(ast.Expr, State), String) {
  case current(state) {
    token.TokenLParen -> {
      let state = advance(state)
      use #(args, state) <- result.try(parse_arg_list(state))
      use state <- result.try(expect(state, token.TokenRParen))
      parse_postfix_tail(ast.ExprCall(func: expr, args:), state)
    }
    token.TokenDot -> {
      let state = advance(state)
      use #(name, state) <- result.try(expect_field_name(state))
      parse_postfix_tail(ast.ExprFieldAccess(record: expr, field: name), state)
    }
    _ -> Ok(#(expr, state))
  }
}

fn parse_primary(state: State) -> Result(#(ast.Expr, State), String) {
  case current(state) {
    token.TokenInt(value) -> Ok(#(ast.ExprInt(value), advance(state)))
    token.TokenFloat(value) -> Ok(#(ast.ExprFloat(value), advance(state)))
    token.TokenTrue -> Ok(#(ast.ExprBool(True), advance(state)))
    token.TokenFalse -> Ok(#(ast.ExprBool(False), advance(state)))
    token.TokenString(parts) -> {
      let expr_parts = list.map(parts, token_string_part_to_ast)
      Ok(#(ast.ExprString(parts: expr_parts), advance(state)))
    }
    token.TokenIdent(name) -> Ok(#(ast.ExprVar(name), advance(state)))
    token.TokenLParen -> {
      let state = advance(state)
      use #(expr, state) <- result.try(parse_expr(state))
      use state <- result.try(expect(state, token.TokenRParen))
      Ok(#(ast.ExprGroup(expr:), state))
    }
    token.TokenLBrace -> parse_record_literal(state)
    token.TokenLBracket -> parse_list_literal(state)
    token.TokenFn -> parse_closure(state)
    t -> Error("Expected expression but found: " <> token_to_string(t))
  }
}

fn parse_closure(state: State) -> Result(#(ast.Expr, State), String) {
  let state = advance(state)
  use state <- result.try(expect(state, token.TokenLParen))
  use #(params, state) <- result.try(parse_id_list(state))
  use state <- result.try(expect(state, token.TokenRParen))
  use #(body, state) <- result.try(parse_block(state))
  Ok(#(ast.ExprClosure(params:, body:), state))
}

fn parse_id_list(state: State) -> Result(#(List(String), State), String) {
  parse_comma_separated(
    state,
    fn(s) {
      case current(s) {
        token.TokenIdent(name) -> Ok(#(name, advance(s)))
        token.TokenUnderscore -> Ok(#("_", advance(s)))
        t -> Error("Expected identifier but found: " <> token_to_string(t))
      }
    },
    token.TokenRParen,
  )
}

fn parse_record_literal(state: State) -> Result(#(ast.Expr, State), String) {
  let state = advance(state)
  use #(fields, state) <- result.try(parse_record_fields(state, []))
  use state <- result.try(expect(state, token.TokenRBrace))
  Ok(#(ast.ExprRecord(fields:), state))
}

fn parse_record_fields(
  state: State,
  acc: List(ast.RecordField),
) -> Result(#(List(ast.RecordField), State), String) {
  case current(state) {
    token.TokenRBrace -> Ok(#(list.reverse(acc), state))
    _ -> {
      use #(name, state) <- result.try(expect_ident(state))
      use state <- result.try(expect(state, token.TokenColon))
      use #(value, state) <- result.try(parse_expr(state))
      let new_acc = [ast.RecordField(name:, value:), ..acc]
      case current(state) {
        token.TokenComma -> parse_record_fields(advance(state), new_acc)
        _ -> Ok(#(list.reverse(new_acc), state))
      }
    }
  }
}

fn parse_list_literal(state: State) -> Result(#(ast.Expr, State), String) {
  let state = advance(state)
  use #(elements, state) <- result.try(parse_comma_separated(
    state,
    parse_expr,
    token.TokenRBracket,
  ))
  use state <- result.try(expect(state, token.TokenRBracket))
  Ok(#(ast.ExprList(elements:), state))
}

fn parse_arg_list(state: State) -> Result(#(List(ast.Expr), State), String) {
  parse_comma_separated(state, parse_expr, token.TokenRParen)
}

// ── Generic comma-separated parser ─────────────────────────────────────────

fn parse_comma_separated(
  state: State,
  parser: fn(State) -> Result(#(a, State), String),
  terminator: token.Token,
) -> Result(#(List(a), State), String) {
  case current(state) {
    t if t == terminator -> Ok(#([], state))
    _ -> {
      use #(first, state) <- result.try(parser(state))
      parse_comma_tail(state, parser, terminator, [first])
    }
  }
}

fn parse_comma_tail(
  state: State,
  parser: fn(State) -> Result(#(a, State), String),
  terminator: token.Token,
  acc: List(a),
) -> Result(#(List(a), State), String) {
  case current(state) {
    token.TokenComma -> {
      let state = advance(state)
      case current(state) {
        t if t == terminator -> Ok(#(list.reverse(acc), state))
        _ -> {
          use #(item, state) <- result.try(parser(state))
          parse_comma_tail(state, parser, terminator, [item, ..acc])
        }
      }
    }
    t if t == terminator -> Ok(#(list.reverse(acc), state))
    _ -> Ok(#(list.reverse(acc), state))
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn expect_ident(state: State) -> Result(#(String, State), String) {
  case current(state) {
    token.TokenIdent(name) -> Ok(#(name, advance(state)))
    token.TokenUnderscore -> Ok(#("_", advance(state)))
    t -> Error("Expected identifier but found: " <> token_to_string(t))
  }
}

fn expect_field_name(state: State) -> Result(#(String, State), String) {
  case current(state) {
    token.TokenIdent(name) -> Ok(#(name, advance(state)))
    token.TokenUnderscore -> Ok(#("_", advance(state)))
    // Keywords that are valid as field names (e.g. result.try, list.filter)
    token.TokenTry -> Ok(#("try", advance(state)))
    token.TokenCase -> Ok(#("case", advance(state)))
    t -> Error("Expected field name but found: " <> token_to_string(t))
  }
}

fn token_to_binop(tok: token.Token) -> option.Option(ast.BinOp) {
  case tok {
    token.TokenEq -> option.Some(ast.OpEq)
    token.TokenNeq -> option.Some(ast.OpNeq)
    token.TokenLt -> option.Some(ast.OpLt)
    token.TokenLe -> option.Some(ast.OpLe)
    token.TokenGt -> option.Some(ast.OpGt)
    token.TokenGe -> option.Some(ast.OpGe)
    token.TokenPlus -> option.Some(ast.OpAdd)
    token.TokenMinus -> option.Some(ast.OpSub)
    token.TokenStar -> option.Some(ast.OpMul)
    token.TokenSlash -> option.Some(ast.OpDiv)
    _ -> option.None
  }
}

fn token_to_string(tok: token.Token) -> String {
  case tok {
    token.TokenPub -> "pub"
    token.TokenFn -> "fn"
    token.TokenLet -> "let"
    token.TokenEffect -> "effect"
    token.TokenPerform -> "perform"
    token.TokenCase -> "case"
    token.TokenTry -> "try"
    token.TokenUnderscore -> "_"
    token.TokenTrue -> "True"
    token.TokenFalse -> "False"
    token.TokenInt(value) -> "Int(" <> int.to_string(value) <> ")"
    token.TokenFloat(value) -> "Float(" <> float.to_string(value) <> ")"
    token.TokenString(..) -> "String(...)"
    token.TokenIdent(name) -> name
    token.TokenPipe -> "|>"
    token.TokenEq -> "=="
    token.TokenNeq -> "!="
    token.TokenLt -> "<"
    token.TokenLe -> "<="
    token.TokenGt -> ">"
    token.TokenGe -> ">="
    token.TokenPlus -> "+"
    token.TokenMinus -> "-"
    token.TokenStar -> "*"
    token.TokenSlash -> "/"
    token.TokenAssign -> "="
    token.TokenLParen -> "("
    token.TokenRParen -> ")"
    token.TokenLBrace -> "{"
    token.TokenRBrace -> "}"
    token.TokenLBracket -> "["
    token.TokenRBracket -> "]"
    token.TokenComma -> ","
    token.TokenDot -> "."
    token.TokenColon -> ":"
    token.TokenArrow -> "->"
    token.TokenComment(text) -> "//" <> text
    token.TokenEof -> "EOF"
  }
}

fn token_string_part_to_ast(part: token.StringPart) -> ast.StringPart {
  case part {
    token.StringText(text) -> ast.StringText(text)
    token.StringInterpolation(tokens) -> {
      // Parse the tokenized interpolation content as a real expression
      let inner_state = State(tokens: tokens, pos: 0)
      case parse_expr(inner_state) {
        Ok(#(expr, _)) -> ast.StringInterpolation(expr)
        Error(_) -> ast.StringInterpolation(ast.ExprNil)
      }
    }
  }
}
