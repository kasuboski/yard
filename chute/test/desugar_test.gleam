import chute/ast
import chute/desugar
import gleam/option
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── ExprGroup unwrapping ───────────────────────────────────────────────────

pub fn unwrap_expr_group_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block([], option.Some(ast.ExprGroup(ast.ExprInt(42)))),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprInt(42)))),
  ]) = desugared
}

pub fn unwrap_nested_expr_group_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block([], option.Some(ast.ExprGroup(ast.ExprGroup(ast.ExprInt(7))))),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprInt(7)))),
  ]) = desugared
}

pub fn unwrap_group_in_binary_op_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block(
          [],
          option.Some(ast.ExprBinaryOp(
            ast.ExprGroup(ast.ExprVar("x")),
            ast.OpAdd,
            ast.ExprGroup(ast.ExprVar("y")),
          )),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [],
        option.Some(ast.ExprBinaryOp(
          ast.ExprVar("x"),
          ast.OpAdd,
          ast.ExprVar("y"),
        )),
      ),
    ),
  ]) = desugared
}

// ── Empty block normalization ──────────────────────────────────────────────

pub fn empty_block_gets_nil_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Nil", []),
        ast.Block([], option.None),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprNil))),
  ]) = desugared
}

pub fn block_with_stmts_no_trailing_stays_test() {
  // Block with statements but no trailing expression stays as-is
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Nil", []),
        ast.Block([ast.StatementExpr(ast.ExprInt(1))], option.None),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([ast.StatementExpr(ast.ExprInt(1))], option.None),
    ),
  ]) = desugared
}

// ── Recursive desugaring ──────────────────────────────────────────────────

pub fn desugar_in_closure_body_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block(
          [],
          option.Some(ast.ExprClosure(
            ["x"],
            ast.Block([], option.Some(ast.ExprGroup(ast.ExprVar("x")))),
          )),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [],
        option.Some(ast.ExprClosure(
          ["x"],
          ast.Block([], option.Some(ast.ExprVar("x"))),
        )),
      ),
    ),
  ]) = desugared
}

pub fn desugar_in_let_value_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("Int", []),
        ast.Block(
          [
            ast.LetDecl("x", option.None, ast.ExprGroup(ast.ExprInt(42))),
          ],
          option.Some(ast.ExprVar("x")),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [ast.LetDecl("x", option.None, ast.ExprInt(42))],
        option.Some(ast.ExprVar("x")),
      ),
    ),
  ]) = desugared
}

pub fn desugar_in_record_field_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeRecord([]),
        ast.Block(
          [],
          option.Some(
            ast.ExprRecord([
              ast.RecordField("x", ast.ExprGroup(ast.ExprInt(1))),
            ]),
          ),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [],
        option.Some(ast.ExprRecord([ast.RecordField("x", ast.ExprInt(1))])),
      ),
    ),
  ]) = desugared
}

pub fn desugar_in_list_elements_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("List", [ast.TypeNamed("Int", [])]),
        ast.Block(
          [],
          option.Some(
            ast.ExprList([
              ast.ExprGroup(ast.ExprInt(1)),
              ast.ExprGroup(ast.ExprInt(2)),
            ]),
          ),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([], option.Some(ast.ExprList([ast.ExprInt(1), ast.ExprInt(2)]))),
    ),
  ]) = desugared
}

pub fn desugar_in_string_interpolation_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "f",
        False,
        [],
        ast.TypeNamed("String", []),
        ast.Block(
          [],
          option.Some(
            ast.ExprString([
              ast.StringText("val: "),
              ast.StringInterpolation(ast.ExprGroup(ast.ExprVar("x"))),
            ]),
          ),
        ),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [],
        option.Some(ast.ExprString([
          ast.StringText("val: "),
          ast.StringInterpolation(ast.ExprVar("x")),
        ])),
      ),
    ),
  ]) = desugared
}

// ── Effect declarations pass through unchanged ────────────────────────────

pub fn effect_decl_unchanged_test() {
  let program =
    ast.Program([
      ast.EffectDecl(
        "fetch_data",
        [ast.Param("id", ast.TypeNamed("String", []))],
        ast.TypeNamed("Result", [
          ast.TypeNamed("String", []),
          ast.TypeNamed("Error", []),
        ]),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert True = desugared == program
}

// ── Public function preserved ─────────────────────────────────────────────

pub fn public_flag_preserved_test() {
  let program =
    ast.Program([
      ast.FunctionDecl(
        "main",
        True,
        [],
        ast.TypeNamed("Nil", []),
        ast.Block([], option.None),
      ),
    ])
  let desugared = desugar.desugar(program)
  let assert ast.Program([
    ast.FunctionDecl(
      "main",
      True,
      [],
      _,
      ast.Block([], option.Some(ast.ExprNil)),
    ),
  ]) = desugared
}
