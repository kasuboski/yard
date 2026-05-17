import chute/ast
import chute/lexer
import chute/parser
import gleam/option
import gleam/result

fn parse(source: String) -> Result(ast.Program, String) {
  use tokens <- result.try(lexer.tokenize(source))
  parser.parse(tokens)
}

// ── Effect declarations ────────────────────────────────────────────────────

pub fn parse_simple_effect_decl_test() {
  let assert Ok(ast.Program(declarations: [
    ast.EffectDecl(name, params, return_type),
  ])) = parse("effect fetch_data(id: String) -> Result(String, Error)")
  assert name == "fetch_data"
  let assert [ast.Param(n, ast.TypeNamed("String", []))] = params
  assert n == "id"
  let assert ast.TypeNamed(
    "Result",
    [ast.TypeNamed("String", []), ast.TypeNamed("Error", [])],
  ) = return_type
}

pub fn parse_effect_no_params_test() {
  let assert Ok(ast.Program(declarations: [
    ast.EffectDecl(name, params, return_type),
  ])) = parse("effect get_time() -> Int")
  assert name == "get_time"
  assert params == []
  let assert ast.TypeNamed("Int", []) = return_type
}

pub fn parse_effect_multiple_params_test() {
  let assert Ok(ast.Program(declarations: [ast.EffectDecl(_, params, _)])) =
    parse("effect send(to: String, body: String) -> Result(Nil, Error)")
  let assert [
    ast.Param(n1, ast.TypeNamed("String", [])),
    ast.Param(n2, ast.TypeNamed("String", [])),
  ] = params
  assert n1 == "to"
  assert n2 == "body"
}

// ── Function declarations ──────────────────────────────────────────────────

pub fn parse_simple_fn_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(name, public, params, return_type, body),
  ])) = parse("fn add(a: Int, b: Int) -> Int { a }")
  assert name == "add"
  assert public == False
  let assert [
    ast.Param("a", ast.TypeNamed("Int", [])),
    ast.Param("b", ast.TypeNamed("Int", [])),
  ] = params
  let assert ast.TypeNamed("Int", []) = return_type
  let assert ast.Block([], option.Some(ast.ExprVar("a"))) = body
}

pub fn parse_pub_fn_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(name, public, _, _, _),
  ])) =
    parse(
      "pub fn main(env: { user_id: String }) -> Result(Int, Error) { Ok(1) }",
    )
  assert name == "main"
  assert public == True
}

// ── Expressions ────────────────────────────────────────────────────────────

pub fn parse_int_literal_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(ast.ExprInt(value)))),
  ])) = parse("fn f() -> Int { 42 }")
  assert value == 42
}

pub fn parse_float_literal_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([], option.Some(ast.ExprFloat(value))),
    ),
  ])) = parse("fn f() -> Float { 3.14 }")
  assert value == 3.14
}

pub fn parse_bool_literal_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([], option.Some(ast.ExprBool(value))),
    ),
  ])) = parse("fn f() -> Bool { True }")
  assert value == True
}

pub fn parse_let_decl_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [ast.LetDecl(name, type_annotation, value)],
        option.Some(ast.ExprVar("x")),
      ),
    ),
  ])) = parse("fn f() -> Int { let x = 42 x }")
  assert name == "x"
  assert type_annotation == option.None
  let assert ast.ExprInt(42) = value
}

pub fn parse_let_with_type_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([ast.LetDecl(name, type_annotation, _)], option.Some(_)),
    ),
  ])) = parse("fn f() -> Int { let x: Int = 42 x }")
  assert name == "x"
  let assert option.Some(ast.TypeNamed("Int", [])) = type_annotation
}

pub fn parse_pipeline_desugars_to_call_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(x: Int) -> Int { x |> double() }")
  // Pipeline desugars: x |> double() => double(x)
  let assert ast.ExprCall(ast.ExprVar("double"), [ast.ExprVar("x")]) = expr
}

pub fn parse_perform_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f() -> Int { perform get_time() }")
  let assert ast.ExprPerform("get_time", []) = expr
}

pub fn parse_pipeline_perform_desugar_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(x: Float) -> String { x |> perform charge_card() }")
  // Pipeline desugars: x |> perform charge_card() => perform charge_card(x)
  let assert ast.ExprPerform("charge_card", [ast.ExprVar("x")]) = expr
}

pub fn parse_record_type_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      [ast.Param("env", type_)],
      _,
      ast.Block([], option.Some(ast.ExprInt(0))),
    ),
  ])) = parse("fn f(env: { user_id: String, age: Int }) -> Int { 0 }")
  let assert ast.TypeRecord([
    ast.TypeField("user_id", ast.TypeNamed("String", [])),
    ast.TypeField("age", ast.TypeNamed("Int", [])),
  ]) = type_
}

pub fn parse_closure_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f() -> Int { fn(x) { x } }")
  let assert ast.ExprClosure(
    ["x"],
    ast.Block([], option.Some(ast.ExprVar("x"))),
  ) = expr
}

pub fn parse_list_literal_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f() -> List(Int) { [1, 2, 3] }")
  let assert ast.ExprList([ast.ExprInt(1), ast.ExprInt(2), ast.ExprInt(3)]) =
    expr
}

pub fn parse_record_literal_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f() -> { x: Int } { { x: 1 } }")
  let assert ast.ExprRecord([ast.RecordField("x", ast.ExprInt(1))]) = expr
}

pub fn parse_field_access_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(env: { x: Int }) -> Int { env.x }")
  let assert ast.ExprFieldAccess(ast.ExprVar("env"), "x") = expr
}

pub fn parse_binary_op_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f() -> Int { 1 + 2 * 3 }")
  // Precedence: 1 + (2 * 3)
  let assert ast.ExprBinaryOp(
    ast.ExprInt(1),
    ast.OpAdd,
    ast.ExprBinaryOp(ast.ExprInt(2), ast.OpMul, ast.ExprInt(3)),
  ) = expr
}

// ── Full program test ─────────────────────────────────────────────────────

pub fn parse_full_program_test() {
  let source =
    "
effect charge_card(amount: Float) -> Result(String, Error)
effect send_receipt(user_id: String, tx_id: String) -> Result(Nil, Error)

pub fn main(env: { user_id: String, order_total: Float }) -> Result(String, Error) {
    env.order_total
    |> perform charge_card()
}
"
  let assert Ok(ast.Program(declarations: [
    ast.EffectDecl("charge_card", _, _),
    ast.EffectDecl("send_receipt", _, _),
    ast.FunctionDecl("main", True, _, _, _),
  ])) = parse(source)
}

// ── Case expressions ──────────────────────────────────────────────────────

pub fn parse_simple_case_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(x: Int) -> Int { case x { 1 -> 2  _ -> 0 } }")
  let assert ast.ExprCase(
    ast.ExprVar("x"),
    [
      ast.CaseBranch(ast.ExprInt(1), ast.Block([], option.Some(ast.ExprInt(2)))),
      ast.CaseWildcard(ast.Block([], option.Some(ast.ExprInt(0)))),
    ],
  ) = expr
}

pub fn parse_case_with_block_body_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(x: Int) -> Int { case x { 1 -> { let y = x y } _ -> 0 } }")
  let assert ast.ExprCase(
    ast.ExprVar("x"),
    [
      ast.CaseBranch(
        ast.ExprInt(1),
        ast.Block(
          [ast.LetDecl("y", option.None, ast.ExprVar("x"))],
          option.Some(ast.ExprVar("y")),
        ),
      ),
      ast.CaseWildcard(ast.Block([], option.Some(ast.ExprInt(0)))),
    ],
  ) = expr
}

pub fn parse_case_string_pattern_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) =
    parse(
      "fn f(action: String) -> Int { case action { \"hello\" -> 1  _ -> 0 } }",
    )
  let assert ast.ExprCase(
    ast.ExprVar("action"),
    [
      ast.CaseBranch(
        ast.ExprString([ast.StringText("hello")]),
        ast.Block([], option.Some(ast.ExprInt(1))),
      ),
      ast.CaseWildcard(ast.Block([], option.Some(ast.ExprInt(0)))),
    ],
  ) = expr
}

pub fn parse_case_bool_pattern_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(b: Bool) -> Int { case b { True -> 1 False -> 0 } }")
  let assert ast.ExprCase(
    ast.ExprVar("b"),
    [
      ast.CaseBranch(
        ast.ExprBool(True),
        ast.Block([], option.Some(ast.ExprInt(1))),
      ),
      ast.CaseBranch(
        ast.ExprBool(False),
        ast.Block([], option.Some(ast.ExprInt(0))),
      ),
    ],
  ) = expr
}

pub fn parse_case_expression_body_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(_, _, _, _, ast.Block([], option.Some(expr))),
  ])) = parse("fn f(x: Int) -> Int { case x { 1 -> x + 10  _ -> x * 2 } }")
  let assert ast.ExprCase(
    ast.ExprVar("x"),
    [
      ast.CaseBranch(
        ast.ExprInt(1),
        ast.Block(
          [],
          option.Some(ast.ExprBinaryOp(
            ast.ExprVar("x"),
            ast.OpAdd,
            ast.ExprInt(10),
          )),
        ),
      ),
      ast.CaseWildcard(ast.Block(
        [],
        option.Some(ast.ExprBinaryOp(
          ast.ExprVar("x"),
          ast.OpMul,
          ast.ExprInt(2),
        )),
      )),
    ],
  ) = expr
}

// ── Let try ───────────────────────────────────────────────────────────────

pub fn parse_let_try_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [ast.LetTryDecl(name, type_annotation, value)],
        option.Some(ast.ExprVar("x")),
      ),
    ),
  ])) = parse("fn f() -> Result(Int, String) { let try x = Ok(42) x }")
  assert name == "x"
  assert type_annotation == option.None
  let assert ast.ExprCall(ast.ExprVar("Ok"), [ast.ExprInt(42)]) = value
}

pub fn parse_let_try_with_type_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block([ast.LetTryDecl(name, type_annotation, _)], option.Some(_)),
    ),
  ])) = parse("fn f() -> Result(Int, String) { let try x: Int = Ok(42) x }")
  assert name == "x"
  let assert option.Some(ast.TypeNamed("Int", [])) = type_annotation
}

pub fn parse_let_try_with_perform_test() {
  let assert Ok(ast.Program(declarations: [
    ast.FunctionDecl(
      _,
      _,
      _,
      _,
      ast.Block(
        [
          ast.LetTryDecl(
            "body",
            option.None,
            ast.ExprPerform("fetch", [ast.ExprString([ast.StringText("test")])]),
          ),
        ],
        option.Some(ast.ExprVar("body")),
      ),
    ),
  ])) =
    parse(
      "fn f() -> Result(String, Error) { let try body = perform fetch(\"test\") body }",
    )
}
