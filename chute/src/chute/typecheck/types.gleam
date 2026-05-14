import chute/ast
import gleam/dict
import gleam/int
import gleam/list
import gleam/string

// ═══════════════════════════════════════════════════════════════════════════
// Type checker internal types
// ═══════════════════════════════════════════════════════════════════════════

/// Internal type representation for the type checker.
/// Extends source-level types with type variables and union types for inference.
pub type TcType {
  /// Type variable for inference (e.g., ?0, ?1)
  TcVar(id: Int)

  /// Named type, possibly parameterized: Int, String, List(T), Result(T, E)
  TcNamed(name: String, args: List(TcType))

  /// Structural record type: { name: T, ... }
  TcRecord(fields: List(TcTypeField))

  /// Function type: fn(T, U) -> V
  TcFn(params: List(TcType), return_: TcType)

  /// Union type for auto-unioning: T1 | T2 | ...
  TcUnion(types: List(TcType))

  /// Error sentinel — prevents cascading errors
  TcError
}

pub type TcTypeField {
  TcTypeField(name: String, type_: TcType)
}

/// A type error found during type checking.
pub type TypeError {
  TypeError(message: String)
}

// ═══════════════════════════════════════════════════════════════════════════
// Type checking state
// ═══════════════════════════════════════════════════════════════════════════

/// Threaded state for the type checker (pure functional, no mutation).
pub type TypeCheckState {
  TypeCheckState(
    next_var_id: Int,
    subst: dict.Dict(Int, TcType),
    env: dict.Dict(String, TcType),
    effects: dict.Dict(String, EffectSig),
    functions: dict.Dict(String, FnSig),
    errors: List(TypeError),
  )
}

pub type EffectSig {
  EffectSig(params: List(TcType), return_type: TcType)
}

pub type FnSig {
  FnSig(params: List(TcType), return_type: TcType)
}

// ═══════════════════════════════════════════════════════════════════════════
// State management
// ═══════════════════════════════════════════════════════════════════════════

pub fn new_state() -> TypeCheckState {
  TypeCheckState(
    next_var_id: 0,
    subst: dict.new(),
    env: dict.new(),
    effects: dict.new(),
    functions: dict.new(),
    errors: [],
  )
}

pub fn fresh_var(state: TypeCheckState) -> #(TcType, TypeCheckState) {
  #(
    TcVar(state.next_var_id),
    TypeCheckState(..state, next_var_id: state.next_var_id + 1),
  )
}

pub fn add_error(state: TypeCheckState, msg: String) -> TypeCheckState {
  TypeCheckState(..state, errors: [TypeError(msg), ..state.errors])
}

// ═══════════════════════════════════════════════════════════════════════════
// Type resolution (follow substitution chains)
// ═══════════════════════════════════════════════════════════════════════════

pub fn resolve(tc_type: TcType, subst: dict.Dict(Int, TcType)) -> TcType {
  case tc_type {
    TcVar(id) -> {
      case dict.get(subst, id) {
        Ok(t) -> resolve(t, subst)
        Error(_) -> tc_type
      }
    }
    TcNamed(name, args) ->
      TcNamed(name, list.map(args, fn(a) { resolve(a, subst) }))
    TcRecord(fields) ->
      TcRecord(
        list.map(fields, fn(f) { TcTypeField(f.name, resolve(f.type_, subst)) }),
      )
    TcFn(params, ret) ->
      TcFn(list.map(params, fn(p) { resolve(p, subst) }), resolve(ret, subst))
    TcUnion(types) -> TcUnion(list.map(types, fn(t) { resolve(t, subst) }))
    TcError -> TcError
  }
}

fn occurs_check(
  var_id: Int,
  tc_type: TcType,
  subst: dict.Dict(Int, TcType),
) -> Bool {
  let resolved = resolve(tc_type, subst)
  case resolved {
    TcVar(id) -> id == var_id
    TcNamed(_, args) -> list.any(args, fn(a) { occurs_check(var_id, a, subst) })
    TcRecord(fields) ->
      list.any(fields, fn(f) { occurs_check(var_id, f.type_, subst) })
    TcFn(params, ret) ->
      list.any(params, fn(p) { occurs_check(var_id, p, subst) })
      || occurs_check(var_id, ret, subst)
    TcUnion(types) -> list.any(types, fn(t) { occurs_check(var_id, t, subst) })
    TcError -> False
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Unification
// ═══════════════════════════════════════════════════════════════════════════

pub fn unify(t1: TcType, t2: TcType, state: TypeCheckState) -> TypeCheckState {
  let t1 = resolve(t1, state.subst)
  let t2 = resolve(t2, state.subst)

  case t1 == t2 {
    True -> state
    False -> unify_inner(t1, t2, state)
  }
}

fn unify_inner(
  t1: TcType,
  t2: TcType,
  state: TypeCheckState,
) -> TypeCheckState {
  case t1, t2 {
    // Error sentinel: compatible with anything to prevent cascading
    TcError, _ -> state
    _, TcError -> state

    // Type variable: bind it
    TcVar(id), other | other, TcVar(id) -> {
      case occurs_check(id, other, state.subst) {
        True ->
          add_error(
            state,
            "Infinite type: "
              <> tc_type_to_string(t1)
              <> " ~ "
              <> tc_type_to_string(t2),
          )
        False ->
          TypeCheckState(..state, subst: dict.insert(state.subst, id, other))
      }
    }

    // Named types: name and arity must match, unify args
    TcNamed(n1, a1), TcNamed(n2, a2) -> {
      case n1 == n2 && list.length(a1) == list.length(a2) {
        False ->
          add_error(
            state,
            "Type mismatch: "
              <> tc_type_to_string(t1)
              <> " ≠ "
              <> tc_type_to_string(t2),
          )
        True -> unify_lists(a1, a2, state)
      }
    }

    // Record types: structural matching (same fields, same types)
    TcRecord(f1), TcRecord(f2) -> unify_records(f1, f2, state)

    // Function types: arity + param types + return type
    TcFn(p1, r1), TcFn(p2, r2) -> {
      case list.length(p1) == list.length(p2) {
        False ->
          add_error(
            state,
            "Function arity mismatch: "
              <> tc_type_to_string(t1)
              <> " ≠ "
              <> tc_type_to_string(t2),
          )
        True -> {
          let state = unify_lists(p1, p2, state)
          unify(r1, r2, state)
        }
      }
    }

    // Union types: unify each member with the target
    TcUnion(types), target -> {
      unify_union_with(types, target, state)
    }
    target, TcUnion(types) -> {
      unify_union_with(types, target, state)
    }

    // Incompatible types
    _, _ ->
      add_error(
        state,
        "Type mismatch: "
          <> tc_type_to_string(t1)
          <> " ≠ "
          <> tc_type_to_string(t2),
      )
  }
}

fn unify_lists(
  l1: List(TcType),
  l2: List(TcType),
  state: TypeCheckState,
) -> TypeCheckState {
  case l1, l2 {
    [], [] -> state
    [h1, ..t1], [h2, ..t2] -> {
      let state = unify(h1, h2, state)
      unify_lists(t1, t2, state)
    }
    _, _ -> state
  }
}

fn unify_records(
  f1: List(TcTypeField),
  f2: List(TcTypeField),
  state: TypeCheckState,
) -> TypeCheckState {
  case list.length(f1) == list.length(f2) {
    False ->
      add_error(
        state,
        "Record field count mismatch: "
          <> int.to_string(list.length(f1))
          <> " vs "
          <> int.to_string(list.length(f2)),
      )
    True -> {
      let s1 = list.sort(f1, fn(a, b) { string.compare(a.name, b.name) })
      let s2 = list.sort(f2, fn(a, b) { string.compare(a.name, b.name) })
      unify_record_fields(s1, s2, state)
    }
  }
}

fn unify_record_fields(
  f1: List(TcTypeField),
  f2: List(TcTypeField),
  state: TypeCheckState,
) -> TypeCheckState {
  case f1, f2 {
    [], [] -> state
    [TcTypeField(n1, t1_), ..rest1], [TcTypeField(n2, t2_), ..rest2] -> {
      case n1 == n2 {
        False ->
          add_error(state, "Record field mismatch: " <> n1 <> " ≠ " <> n2)
        True -> {
          let state = unify(t1_, t2_, state)
          unify_record_fields(rest1, rest2, state)
        }
      }
    }
    _, _ -> state
  }
}

fn unify_union_with(
  types: List(TcType),
  target: TcType,
  state: TypeCheckState,
) -> TypeCheckState {
  case types {
    [] -> state
    [t, ..rest] -> {
      let state = unify(t, target, state)
      unify_union_with(rest, target, state)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// AST type → Type checker type conversion
// ═══════════════════════════════════════════════════════════════════════════

pub fn ast_type_to_tc(t: ast.Type) -> TcType {
  case t {
    ast.TypeNamed(name, args) -> TcNamed(name, list.map(args, ast_type_to_tc))
    ast.TypeRecord(fields) ->
      TcRecord(
        list.map(fields, fn(f) { TcTypeField(f.name, ast_type_to_tc(f.type_)) }),
      )
    ast.TypeFn(params, ret) ->
      TcFn(list.map(params, ast_type_to_tc), ast_type_to_tc(ret))
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Type formatting (for error messages)
// ═══════════════════════════════════════════════════════════════════════════

pub fn tc_type_to_string(t: TcType) -> String {
  case t {
    TcVar(id) -> "?" <> int.to_string(id)
    TcNamed(name, []) -> name
    TcNamed(name, args) ->
      name <> "(" <> string.join(list.map(args, tc_type_to_string), ", ") <> ")"
    TcRecord(fields) ->
      "{ "
      <> string.join(
        list.map(fields, fn(f) { f.name <> ": " <> tc_type_to_string(f.type_) }),
        ", ",
      )
      <> " }"
    TcFn(params, ret) ->
      "fn("
      <> string.join(list.map(params, tc_type_to_string), ", ")
      <> ") -> "
      <> tc_type_to_string(ret)
    TcUnion(types) -> string.join(list.map(types, tc_type_to_string), " | ")
    TcError -> "<error>"
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared utilities
// ═══════════════════════════════════════════════════════════════════════════

pub fn check_arity(
  context: String,
  expected: Int,
  actual: Int,
  state: TypeCheckState,
) -> TypeCheckState {
  case expected == actual {
    True -> state
    False ->
      add_error(
        state,
        context
          <> " expects "
          <> int.to_string(expected)
          <> " argument(s), got "
          <> int.to_string(actual),
      )
  }
}

pub fn unify_arg_types(
  expected: List(TcType),
  actual: List(TcType),
  state: TypeCheckState,
) -> TypeCheckState {
  case expected, actual {
    [], [] -> state
    [e, ..exp_rest], [a, ..act_rest] -> {
      let state = unify(e, a, state)
      unify_arg_types(exp_rest, act_rest, state)
    }
    _, _ -> state
  }
}
