import chute/ast
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// Convert a desugared AST Program into an S-expression string.
///
/// S-expression format:
///   (program
///     (effect name ((param type) ...) return_type)
///     (fn name pub ((param type) ...) return_type body)
///     ...)
///
/// This is the transport/storage format per the language spec (Section 7).
pub fn to_sexp(program: ast.Program) -> String {
  let ast.Program(declarations) = program
  let decl_sexps = list.map(declarations, declaration_to_sexp)
  "(program\n" <> string.join(decl_sexps, "\n") <> ")"
}

// ── Declarations ───────────────────────────────────────────────────────────

fn declaration_to_sexp(decl: ast.Declaration) -> String {
  case decl {
    ast.EffectDecl(name, params, return_type) ->
      "(effect "
      <> name
      <> " ("
      <> param_list_to_sexp(params)
      <> ") "
      <> type_to_sexp(return_type)
      <> ")"

    ast.FunctionDecl(name, public, params, return_type, body) -> {
      let pub_str = case public {
        True -> " pub"
        False -> ""
      }
      "(fn"
      <> pub_str
      <> " "
      <> name
      <> " ("
      <> param_list_to_sexp(params)
      <> ") "
      <> type_to_sexp(return_type)
      <> " "
      <> block_to_sexp(body)
      <> ")"
    }
  }
}

// ── Types ──────────────────────────────────────────────────────────────────

fn type_to_sexp(t: ast.Type) -> String {
  case t {
    ast.TypeNamed(name, []) -> name
    ast.TypeNamed(name, args) ->
      "("
      <> name
      <> " "
      <> string.join(list.map(args, type_to_sexp), " ")
      <> ")"
    ast.TypeRecord(fields) ->
      "(Record"
      <> case fields {
        [] -> ""
        _ -> " " <> string.join(list.map(fields, type_field_to_sexp), " ")
      }
      <> ")"
    ast.TypeFn(params, return_) ->
      "(Fn ("
      <> string.join(list.map(params, type_to_sexp), " ")
      <> ") "
      <> type_to_sexp(return_)
      <> ")"
  }
}

fn type_field_to_sexp(field: ast.TypeField) -> String {
  let ast.TypeField(name, type_) = field
  "(" <> name <> " " <> type_to_sexp(type_) <> ")"
}

fn param_list_to_sexp(params: List(ast.Param)) -> String {
  string.join(list.map(params, param_to_sexp), " ")
}

fn param_to_sexp(param: ast.Param) -> String {
  let ast.Param(name, type_) = param
  "(" <> name <> " " <> type_to_sexp(type_) <> ")"
}

// ── Blocks & Statements ───────────────────────────────────────────────────

fn block_to_sexp(block: ast.Block) -> String {
  let ast.Block(statements, trailing) = block
  let stmt_sexps = list.map(statements, statement_to_sexp)
  let all_items = case trailing {
    option.Some(expr) -> list.append(stmt_sexps, [expr_to_sexp(expr)])
    option.None -> stmt_sexps
  }
  case all_items {
    [] -> "(block)"
    items -> "(block " <> string.join(items, " ") <> ")"
  }
}

fn statement_to_sexp(stmt: ast.Statement) -> String {
  case stmt {
    ast.LetDecl(name, type_annotation, value) -> {
      let type_ann = case type_annotation {
        option.Some(t) -> " " <> type_to_sexp(t)
        option.None -> ""
      }
      "(let " <> name <> type_ann <> " " <> expr_to_sexp(value) <> ")"
    }
    ast.StatementExpr(expr) -> "(stmt " <> expr_to_sexp(expr) <> ")"
  }
}

// ── Expressions ────────────────────────────────────────────────────────────

fn expr_to_sexp(expr: ast.Expr) -> String {
  case expr {
    ast.ExprVar(name) -> "(var " <> name <> ")"
    ast.ExprInt(value) -> "(int " <> int.to_string(value) <> ")"
    ast.ExprFloat(value) -> "(float " <> float.to_string(value) <> ")"
    ast.ExprBool(value) ->
      "(bool "
      <> case value {
        True -> "true"
        False -> "false"
      }
      <> ")"
    ast.ExprNil -> "(nil)"
    ast.ExprString(parts) ->
      case parts {
        [] -> "(string \"\")"
        [ast.StringText(text)] -> "(string " <> escape_string(text) <> ")"
        _ ->
          "(string "
          <> string.join(list.map(parts, string_part_to_sexp), " ")
          <> ")"
      }
    ast.ExprRecord(fields) ->
      "(record"
      <> case fields {
        [] -> ""
        _ -> " " <> string.join(list.map(fields, record_field_to_sexp), " ")
      }
      <> ")"
    ast.ExprList(elements) ->
      "(list"
      <> case elements {
        [] -> ""
        _ -> " " <> string.join(list.map(elements, expr_to_sexp), " ")
      }
      <> ")"
    ast.ExprCall(func, args) ->
      "(call "
      <> expr_to_sexp(func)
      <> case args {
        [] -> ")"
        _ -> " " <> string.join(list.map(args, expr_to_sexp), " ") <> ")"
      }
    ast.ExprFieldAccess(record, field) ->
      "(field-access " <> expr_to_sexp(record) <> " " <> field <> ")"
    ast.ExprPerform(name, args) ->
      "(perform "
      <> name
      <> case args {
        [] -> ")"
        _ -> " " <> string.join(list.map(args, expr_to_sexp), " ") <> ")"
      }
    ast.ExprBinaryOp(left, op, right) ->
      "(binop "
      <> binop_to_sexp(op)
      <> " "
      <> expr_to_sexp(left)
      <> " "
      <> expr_to_sexp(right)
      <> ")"
    ast.ExprClosure(params, body) ->
      "(closure ("
      <> string.join(params, " ")
      <> ") "
      <> block_to_sexp(body)
      <> ")"
    // ExprGroup should be desugared away, but handle gracefully
    ast.ExprGroup(inner) -> expr_to_sexp(inner)
    // Pipeline should be desugared away by parser, but handle gracefully
    ast.ExprPipeline(left, right) ->
      "(pipeline " <> expr_to_sexp(left) <> " " <> expr_to_sexp(right) <> ")"
  }
}

fn binop_to_sexp(op: ast.BinOp) -> String {
  case op {
    ast.OpEq -> "=="
    ast.OpNeq -> "!="
    ast.OpLt -> "<"
    ast.OpLe -> "<="
    ast.OpGt -> ">"
    ast.OpGe -> ">="
    ast.OpAdd -> "+"
    ast.OpSub -> "-"
    ast.OpMul -> "*"
    ast.OpDiv -> "/"
  }
}

fn string_part_to_sexp(part: ast.StringPart) -> String {
  case part {
    ast.StringText(text) -> escape_string(text)
    ast.StringInterpolation(expr) -> "(interp " <> expr_to_sexp(expr) <> ")"
  }
}

fn record_field_to_sexp(field: ast.RecordField) -> String {
  let ast.RecordField(name, value) = field
  "(" <> name <> " " <> expr_to_sexp(value) <> ")"
}

fn escape_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  |> wrap_in_quotes
}

fn wrap_in_quotes(s: String) -> String {
  "\"" <> s <> "\""
}
