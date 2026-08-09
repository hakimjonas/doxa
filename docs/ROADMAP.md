# Doxa Roadmap — Surface syntax, elaboration, and tooling

This roadmap covers improvements to Doxa's surface syntax, elaborator bridge,
developer experience, and proof ecosystem.  Phase 28 (recursor index/method
ordering) is already implemented; this plan picks up from there.

---

## 1. Surface syntax modernization (Fungal alignment)

### a) Expression-level `val` bindings (P0)

Fungal's `{ val x = e; result }` pattern.  Without this, proofs are monolithic
`trans_e` chains — `even_square_eq` in `case_study.doxa` is a single 800-char
expression.  The parser already supports block-level `val` bindings.  The gap
is that annotated binders (`val x : T = e`) infer the body instead of checking
it against `T`, which means type errors surface at the *use site* instead of
the *definition site*.

**Deliverable**: Annotated `val` in block expressions elaborates the body in
check mode against the annotation.  (Revert and fix the `_inferExpr`/`_checkExpr`
change from this session.)

### b) `let...in` for kernel alignment (P0)

The kernel has `TLet` as a first-class construct.  The surface syntax should
expose it directly.  Currently `TLet(isRec: true)` exists but is only produced
by parser for the `val rec` syntax, and the elaborator doesn't support
self-reference in the lambda body (only in the result body).

**Deliverable**: Recursive `val` block bindings where the lambda body can
reference itself, matching Fungal's implicit recursion model.

### c) Arrow syntax alignment (P2)

Fungal uses `->` (thin arrow) for function types and `=>` (fat arrow) for
match cases.  Doxa currently uses `->` and `=>` inconsistently across function
types, lambdas, and match arms.  Standardising reduces cognitive overhead for
users familiar with Fungal.

**Deliverable**: Single-arrow-style surface syntax with `->` for types and
lambdas, `=>` for matches, consistent across the parser.

---

## 2. Elaboration bridge robustness

### a) `match` return-type substitution (P0)

`match n { case zero => ... }` doesn't fully substitute `n` in the return
type.  The substitution works for simple occurrences (LHS of `Eq`) but fails
for occurrences inside function calls in the RHS (e.g. `mult two (half n)`),
producing an unsolved meta.  This blocks structural-recursive `fun` proofs for
any non-trivial return type.

**Deliverable**: Structural and complete substitution of the scrutinee in the
expected type of every match branch.  Test: `refl zero` works in
`case zero =>` when the goal is `Eq Nat zero (mult two (half zero))`.

### b) Recursive value bindings (P1)

Fungal makes all `fun` definitions implicitly recursive.  Doxa's `fun` only
accepts `match`-based structural recursion.  The kernel's `TLet(isRec: true)`
supports recursion via VFun guards.  The surface syntax should expose this
more broadly — either via a `rec` keyword on `val`, or by making `fun`
implicitly recursive (like Fungal).

**Deliverable**: `val rec` where the lambda body can reference itself, OR
`fun` definitions that can call themselves inside `Nat.ind` step functions
(not just `match` arms).  Test: `even_implies_double` type-checks.

### c) Implicit argument mechanism (P2)

Functions like `Eq.rec` sometimes require explicit type arguments, sometimes
don't.  The elaborator guesses based on heuristics.  A more principled
implicit-argument mechanism (Agda-style `{}` or Coq-style `{}`) would
eliminate the guesswork and make type inference predictable.

**Deliverable**: Explicit/implicit binder syntax in the surface syntax,
desugaring to kernel-level `Icit` annotations.

---

## 3. Developer experience

### a) Error messages (P1)

Current errors show fully-expanded kernel terms with unsolved metas:
```
expected ?1 ?a ?b ?c ?d ?e ?f ?g ?h (Eq.rec Bool ((a: Bool) => ...) ...), found Nat
```

Error messages should show surface-level types with source spans, eliding
metas when they can't contribute useful information.

**Deliverable**: Error formatter that renders kernel terms back through the
printer, with meta-variables condensed and equality chains truncated.

### b) LSP features (P3)

The LSP exists (diagnostics, completions, semantic tokens) but could surface
more information:
- Type-on-hover for identifiers and expressions
- Go-to-definition for lemmas and constructors
- Proof-state display for tactic blocks

**Deliverable**: Three new LSP requests — `textDocument/hover`,
`textDocument/definition`, and proper error diagnostic formatting.

### c) Formatter (P2)

The formatter exists (`doxa_tooling/lib/src/format.dart`) but is minimal.
Long `trans_e` chains and nested SApp trees aren't broken across lines.
A proper pretty-printer with configurable width and consistent indentation
makes the codebase scannable.

**Deliverable**: Formatter that wraps long lines, indents nested applications,
and aligns match arms.

---

## 4. Proof ecosystem

### a) Standard library organisation (P2)

The stdlib (`lib/stdlib/`) is a flat collection.  `plus_succ`, `plus_comm`,
`mult_2`, etc. are in `proofs.doxa`.  `eq.doxa` has `sym`, `trans`, `cong`.
These should be organised by domain: `Nat/either/`, `Bool/`, `List/`, `Eq/`,
with explicit re-exports.

**Deliverable**: Directory-structured stdlib with `export` or `import`-based
re-exports, matching Fungal's module conventions.

### b) Tactic expansion (P3)

The `by { ... }` tactic block exists but only supports `trivial` (a
simplified `refl` search).  Adding `intro`, `exact`, `apply`, `rewrite`,
`induction` would dramatically reduce proof verbosity by automating the
construction of `trans_e` chains.

**Deliverable**: At least `intro`, `exact`, and `rewrite` tactics.

---

## Recommended implementation order

| Priority | Area | Item | Why |
|----------|------|------|-----|
| P0 | 1a | Expression-level `val` bindings | Unblocks readable proofs immediately |
| P0 | 2a | Fix `match` substitution | Enables natural structural-recursive proofs |
| P1 | 2b | Recursive `val` / `fun` without match | Enables `Nat.ind`-based induction proofs |
| P1 | 3a | Error message quality | Makes debugging feasible |
| P2 | 1c | Fungal arrow syntax alignment | Consistency |
| P2 | 2c | Implicit argument mechanism | Reduces annotation burden |
| P2 | 3c | Formatter | Codebase scannability |
| P2 | 4a | stdlib organisation | Maintainability |
| P3 | 3b | LSP type-on-hover | Interactive development |
| P3 | 4b | Tactic expansion | Reduces proof verbosity |

---

## Target: `even_implies_double`

After P0+P1, the proof becomes a straightforward `fun`+`match` structural
recursion:

```doxa
fun even_implies_double(n: Nat, h: Eq Bool (even n) true_) : Eq Nat n (mult two (half n)) = match n {
  case zero => refl zero           // P0 fix: match substitution
  case succ k => match k {
    case zero => contradiction
    case succ m => {
      val even_m_true : Eq Bool (even m) true_ = ...;   // P0: annotated val
      val rec_m : Eq Nat m (mult two (half m)) = go m even_m_true;   // P1: recursive
      trans_e Nat (succ (succ m)) (succ (succ (mult two (half m))))
        (mult two (half (succ (succ m))))
        (cong ((x: Nat) => succ (succ x)) rec_m)
        (sym_e Nat (mult two (half (succ (succ m))))
          (succ (succ (mult two (half m))))
          (mult_two_succ (half m)))
    }
  }
}
```

No kernel changes needed — all items are in the surface syntax / elaborator /
tooling layer.

---

## Related documents

- [`docs/RELEASE_0_9_PLAN.md`](RELEASE_0_9_PLAN.md) — current release plan
- This document supersedes the "Remaining lemmas" sections in
  `lib/stdlib/case_study.doxa` — those are now organised under this roadmap.
