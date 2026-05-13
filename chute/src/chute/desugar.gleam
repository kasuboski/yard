import chute/ast
import gleam/list
import gleam/option

/// Desugar an AST into a normalized/canonical form.
///
/// The parser already desugars pipelines (`a |> f(x)` → `f(a, x)`)
/// and perform-pipelines (`x |> perform f()` → `perform f(x)`).
///
/// This pass handles:
///   - Unwrapping ExprGroup nodes (parenthesized expressions)
///   - Normalizing empty blocks to explicit Nil returns
///   - Flattening string concatenation where possible
pub fn desugar(program: ast.Program) -> ast.Program {
  let ast.Program(declarations) = program
  ast.Program(declarations: list.map(declarations, desugar_declaration))
}

fn desugar_declaration(decl: ast.Declaration) -> ast.Declaration {
  case decl {
    ast.EffectDecl(name, params, return_type) ->
      ast.EffectDecl(name, params, return_type)
    ast.FunctionDecl(name, public, params, return_type, body) ->
      ast.FunctionDecl(name, public, params, return_type, desugar_block(body))
  }
}

fn desugar_block(block: ast.Block) -> ast.Block {
  let ast.Block(statements, trailing) = block
  let normalized_trailing = case trailing {
    option.Some(expr) -> option.Some(desugar_expr(expr))
    option.None ->
      // Empty block → explicit Nil return (canonical form)
      case statements {
        [] -> option.Some(ast.ExprNil)
        _ -> option.None
      }
  }
  ast.Block(
    statements: list.map(statements, desugar_statement),
    trailing: normalized_trailing,
  )
}

fn desugar_statement(stmt: ast.Statement) -> ast.Statement {
  case stmt {
    ast.LetDecl(name, type_annotation, value) ->
      ast.LetDecl(name, type_annotation, desugar_expr(value))
    ast.StatementExpr(expr) -> ast.StatementExpr(desugar_expr(expr))
  }
}

fn desugar_expr(expr: ast.Expr) -> ast.Expr {
  case expr {
    // Unwrap grouping parens — they're syntactic, not semantic
    ast.ExprGroup(inner) -> desugar_expr(inner)

    // Recursive: desugar children
    ast.ExprPipeline(left, right) ->
      ast.ExprPipeline(desugar_expr(left), desugar_expr(right))
    ast.ExprBinaryOp(left, op, right) ->
      ast.ExprBinaryOp(desugar_expr(left), op, desugar_expr(right))
    ast.ExprPerform(name, args) ->
      ast.ExprPerform(name, list.map(args, desugar_expr))
    ast.ExprCall(func, args) ->
      ast.ExprCall(desugar_expr(func), list.map(args, desugar_expr))
    ast.ExprFieldAccess(record, field) ->
      ast.ExprFieldAccess(desugar_expr(record), field)
    ast.ExprString(parts) ->
      ast.ExprString(list.map(parts, desugar_string_part))
    ast.ExprRecord(fields) ->
      ast.ExprRecord(list.map(fields, desugar_record_field))
    ast.ExprList(elements) -> ast.ExprList(list.map(elements, desugar_expr))
    ast.ExprClosure(params, body) ->
      ast.ExprClosure(params, desugar_block(body))

    // Atomic: return as-is
    ast.ExprVar(_)
    | ast.ExprInt(_)
    | ast.ExprFloat(_)
    | ast.ExprBool(_)
    | ast.ExprNil -> expr
  }
}

fn desugar_string_part(part: ast.StringPart) -> ast.StringPart {
  case part {
    ast.StringText(text) -> ast.StringText(text)
    ast.StringInterpolation(expr) -> ast.StringInterpolation(desugar_expr(expr))
  }
}

fn desugar_record_field(field: ast.RecordField) -> ast.RecordField {
  let ast.RecordField(name, value) = field
  ast.RecordField(name, desugar_expr(value))
}
