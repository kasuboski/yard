---

# Appendix A: Formal Grammar & Lexical Rules

## A.1 Lexical Rules

*   **Identifiers:** Must start with a letter or underscore, followed by alphanumeric characters or underscores: `[a-zA-Z_][a-zA-Z0-9_]*`
*   **Keywords:** The following are reserved and cannot be used as identifiers: 
    `pub`, `fn`, `let`, `try`, `effect`, `perform`, `case`, `_`, `True`, `False`
*   **Booleans:** Strictly capitalized `True` and `False`.
*   **Integers:** `[0-9]+`
*   **Floats:** `[0-9]+ \. [0-9]+`
*   **Comments:** Only single-line comments are supported, starting with `//` and ending at the newline.
*   **Delimiters:** The `->` arrow is used in `case` branches, effect declarations, and function signatures.
*   **Strings & Interpolation:** Enclosed in double quotes `""`. 
    *   Supported escape sequences: `\n` (newline), `\t` (tab), `\"` (quote), `\\` (backslash).
    *   String interpolation is natively supported via `${...}` where the content inside the braces evaluates as an `Expr`.

## A.2 Operator Precedence
Operations follow the standard mathematical order (Principle of Least Surprise). They are evaluated in the following order (from highest precedence to lowest):

1.  **Grouping & Access:** Parentheses `()`, Function Calls `f()`, Field Access `.`
2.  **Effects:** `perform` (evaluates right-hand capability call immediately)
3.  **Multiplication / Division:** `*`, `/`
4.  **Addition / Subtraction:** `+`, `-`
5.  **Comparison:** `==`, `!=`, `<`, `>`, `<=`, `>=`
6.  **Pipeline:** `|>` (Left-associative: passes the left expression as the first argument to the right expression).
7.  **Branching:** `case` (Treated as a top-level expression — lowest precedence).

## A.3 Block and Return Semantics
*   **Blocks:** Bounded by `{ }`. A block consists of zero or more statements (`let` declarations or standalone expressions).
*   **Implicit Returns:** There is no `return` keyword. The last expression evaluated in a block is implicitly returned. If a block has no trailing expression, it implicitly returns `Nil`.

## A.4 Formal Grammar (EBNF)

This grammar allows for fully nested JSON-like structural types and enforces trailing comma support across parameters, arrays, and records.

```ebnf
Program         ::= { EffectDecl | FunctionDecl }

(* Declarations *)
EffectDecl      ::= "effect" Identifier "(" [ ParamList ] ")" "->" Type
FunctionDecl    ::= [ "pub" ] "fn" Identifier "(" [ ParamList ] ")" "->" Type Block

(* Type Definitions *)
Type            ::= Identifier [ "(" TypeList ")" ]
                  | "{" [ RecordTypeList ] "}"
TypeList        ::= Type { "," Type } [ "," ]
RecordTypeList  ::= Identifier ":" Type { "," Identifier ":" Type } [ "," ]

(* Parameters & Arguments *)
ParamList       ::= Param { "," Param } [ "," ]
Param           ::= Identifier ":" Type
ArgList         ::= Expr { "," Expr } [ "," ]
IdList          ::= Identifier { "," Identifier } [ "," ]

(* Blocks & Statements *)
Block           ::= "{" { Statement } [ Expr ] "}"
Statement       ::= LetDecl | LetTryDecl | Expr
LetDecl         ::= "let" Identifier [ ":" Type ] "=" Expr
LetTryDecl      ::= "let" "try" Identifier [ ":" Type ] "=" Expr

(* Expressions (Ordered by Precedence, lowest to highest) *)
Expr            ::= CaseExpr | PipelineExpr
CaseExpr        ::= "case" Expr "{" CaseBranch { CaseBranch } "}"
CaseBranch      ::= Expr "->" ( Expr | Block )
                  | "_" "->" ( Expr | Block )
PipelineExpr    ::= LogicExpr { "|>" LogicExpr }
LogicExpr       ::= MathExpr [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) MathExpr ]
MathExpr        ::= Term { ( "+" | "-" ) Term }
Term            ::= Factor { ( "*" | "/" ) Factor }
Factor          ::= PerformExpr | CallExpr | FieldAccess | Primary

(* Effect & Function Invocation *)
PerformExpr     ::= "perform" Identifier "(" [ ArgList ] ")"
CallExpr        ::= Primary "(" [ ArgList ] ")"
FieldAccess     ::= Primary "." Identifier

(* Primary & Literals *)
Primary         ::= Literal | Identifier | RecordLit | ListLit | Closure | "(" Expr ")"
Closure         ::= "fn" "(" [ IdList ] ")" Block

(* Structural Data Types *)
RecordLit       ::= "{" [ RecordFieldList ] "}"
RecordFieldList ::= Identifier ":" Expr { "," Identifier ":" Expr } [ "," ]
ListLit         ::= "[" [ ArgList ] "]"

(* Literals *)
Literal         ::= IntLit | FloatLit | "True" | "False" | StringTemplate
StringTemplate  ::= '"' { TextChar | "${" Expr "}" | EscapeSequence } '"'
```
