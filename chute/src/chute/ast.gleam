import gleam/option

/// The top-level program: a sequence of effect declarations and function declarations.
pub type Program {
  Program(declarations: List(Declaration))
}

pub type Declaration {
  /// effect fetch_data(id: String) -> Result(String, HttpErr)
  EffectDecl(name: String, params: List(Param), return_type: Type)

  /// pub fn main(env: { user_id: String }) -> Result(Int, Error) { ... }
  /// or: fn helper(x: Int) -> Int { ... }
  FunctionDecl(
    name: String,
    public: Bool,
    params: List(Param),
    return_type: Type,
    body: Block,
  )
}

/// A named, typed parameter: `id: String`
pub type Param {
  Param(name: String, type_: Type)
}

// ── Types ──────────────────────────────────────────────────────────────────

pub type Type {
  /// Named type, possibly parameterized: `Int`, `String`, `List(Int)`, `Result(String, Error)`
  TypeNamed(name: String, args: List(Type))

  /// Structural record type: `{ name: String, age: Int }`
  TypeRecord(fields: List(TypeField))

  /// Function type: `fn(Int, String) -> Bool`
  TypeFn(params: List(Type), return_: Type)
}

pub type TypeField {
  TypeField(name: String, type_: Type)
}

// ── Blocks & Statements ───────────────────────────────────────────────────

/// A block: `{ stmt1; stmt2; expr }`. The optional trailing expression is the
/// implicit return value. If absent, the block evaluates to `Nil`.
pub type Block {
  Block(statements: List(Statement), trailing: option.Option(Expr))
}

pub type Statement {
  /// let x = expr
  /// let x: Int = expr
  LetDecl(name: String, type_annotation: option.Option(Type), value: Expr)

  /// A bare expression used as a statement (e.g., `perform send_receipt(...)`)
  StatementExpr(expr: Expr)
}

// ── Expressions ────────────────────────────────────────────────────────────

/// The core expression type. Ordered by precedence (lowest to highest)
/// as described in the grammar.
pub type Expr {
  /// Pipeline: `a |> b |> c`
  ExprPipeline(left: Expr, right: Expr)

  /// Comparison: `a == b`, `a < b`, etc.
  ExprBinaryOp(left: Expr, op: BinOp, right: Expr)

  /// perform keyword: `perform charge_card(amount)`
  ExprPerform(name: String, args: List(Expr))

  /// Function call: `f(a, b)`
  ExprCall(func: Expr, args: List(Expr))

  /// Field access: `record.field`
  ExprFieldAccess(record: Expr, field: String)

  /// Variable reference
  ExprVar(name: String)

  /// Integer literal
  ExprInt(value: Int)

  /// Float literal
  ExprFloat(value: Float)

  /// Boolean literal
  ExprBool(value: Bool)

  /// String literal (without interpolation segments)
  ExprString(parts: List(StringPart))

  /// Record literal: `{ name: expr, ... }`
  ExprRecord(fields: List(RecordField))

  /// List literal: `[a, b, c]`
  ExprList(elements: List(Expr))

  /// Closure: `fn(x, y) { ... }`
  ExprClosure(params: List(String), body: Block)

  /// Grouped expression: `(expr)`
  ExprGroup(expr: Expr)

  /// Nil literal
  ExprNil
}

/// Binary operators (comparison + arithmetic)
pub type BinOp {
  OpEq
  OpNeq
  OpLt
  OpLe
  OpGt
  OpGe
  OpAdd
  OpSub
  OpMul
  OpDiv
}

/// Parts of a string literal — either plain text or an interpolated expression.
pub type StringPart {
  StringText(text: String)
  StringInterpolation(expr: Expr)
}

/// A field in a record literal: `name: expr`
pub type RecordField {
  RecordField(name: String, value: Expr)
}
