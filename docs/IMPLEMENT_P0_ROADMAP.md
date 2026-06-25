# Implement P0 Roadmap Items — expression-level `val` bindings + `match` substitution

## Context

Two surface-syntax issues block writing natural structural-recursive proofs in
Doxa (e.g. `even_implies_double` in `lib/stdlib/case_study.doxa`).  Both are
in the tooling elaborator (`doxa/lib/src/elab.dart`), not in the kernel.

After these two fixes, `even_implies_double` should type-check as a `fun` with
`match` recursion:

```doxa
fun even_implies_double(n: Nat, h: Eq Bool (even n) true_) : Eq Nat n (mult two (half n)) = match n {
  case zero => refl zero           // after fix 1
  case succ k => match k {
    case zero => <contradiction>
    case succ m => {
      val even_m_true : Eq Bool (even m) true_ = ...;   // after fix 2
      val rec_m : Eq Nat m (mult two (half m)) = go m even_m_true;  // after fix 2
      <algebraic step with rec_m and mult_two_succ>
    }
  }
}
```

---

## Fix 1: `match` return-type substitution

**File**: `doxa/lib/src/elab.dart`

**Problem**: When elaborating `match n { case zero => body }`, the expected
type for each branch is computed by substituting `n` with the pattern in the
overall expected type.  The substitution works for direct occurrences (`n` on
the LHS of `Eq`) but fails for occurrences inside function call arguments
(e.g. `mult two (half n)` in `Eq Nat n (mult two (half n))`).  This produces
an unsolved meta `?a` for `n`.

**Observed error**:
```
error: type mismatch
  case zero => refl zero
               ^^^^^^^^^ expected Eq Nat zero (plus (half ?a) (plus (half ?a) zero))
                         found Eq (?0 ?a ?b) zero zero
```

The `?a` is the unsubstituted `n`.  The RHS `mult two (half ?a)` didn't get
the substitution `?a ↦ zero`.

**Location**: The match elaboration is in `_elabMatch` (infer path) and
`_checkExprInner` (check path).  The substitution happens somewhere around
the point where per-arm expected types are computed from the overall expected
type by replacing the scrutinee variable with each pattern's constructor.

**Likely fix**: In the match arm elaboration (around when the arm's expected
type is computed), ensure the substitution is STRUCTURAL — every occurrence
of `n` (the scrutinee variable) in the expected type TERM must be replaced
with the pattern's de Bruijn index — not just the head occurrences but also
occurrences inside function arguments.

**Test**: With the fix, `refl zero` should type-check as a valid body for
`case zero =>` when the goal is `Eq Nat n (mult two (half n))` with `n=zero`.
The existing test `test/let_test.dart: Block type inference block with one
annotated binding parses to SLetKind` should still pass.

---

## Fix 2: Expression-level `val` bindings with check mode

**File**: `doxa/lib/src/elab.dart`, lines ~1857–1874 (`SLetKind` handler)

**Problem**: Annotated `val x : T = e` in a block expression `{ val x : T = e;
result }` elaborates `e` in INFER mode (`_inferExpr`), even though `x` has a
type annotation that could be used as the expected type.  This means type
errors in `e` are deferred to the kernel's post-elab `TLet` check, which has
poor error messages and occurs after the whole block is elaborated.

**The fix**: When `domain != null` (the binder has a type annotation),
elaborate the bound expression `e` in CHECK mode against the domain:

```dart
// Before (infer mode):
final (inferredBound, _) = _inferExpr(state, bound);
boundTerm = inferredBound;

// After (check mode):
final domainV = eval(domainTerm, state.ctx.env);
boundTerm = _checkExpr(state, bound, domainV);
```

**One test must be updated**: `test/let_test.dart: Block type inference block
with ill-typed bound expression fails at check time` expects the error to
occur at `check` time (kernel post-elab), not at elab time.  With check mode,
the error occurs during `elabProgram`, so the test should be updated to
`expect(() => elabProgram(prog), throwsA(isA<TypeMismatch>()))`.

**Other tests that may break**: `test/let_test.dart: Block with matching types
succeeds (Type 1 annotation)` should still pass because the body matches the
annotation.  If it fails, the check-mode subtype check is too strict — use
`subtype` instead of `conv` to compare inferred vs expected (see existing
`_checkExprInner` fallback).

---

## After both fixes

With both fixes applied:

1. `doxa check lib/stdlib/case_study.doxa` should pass
2. `dart test` in `doxa/` should pass (452/452)
3. `dart test` in `doxa_tooling/` should pass (520/520)
4. `dart analyze` in both packages should be clean (0 errors, 0 warnings)
5. `dart format --set-exit-if-changed` in both packages should be clean

---

## Reference

- The current `even_implies_double` proof is in
  `lib/stdlib/case_study.doxa` (lines ~164–177)
- `mult_two_succ` helper lemma is already defined in the same file
- The structural recursion checker already accepts `go m even_m_true` as a
  recursive call (from the `a36715f` commit)
- See `docs/ROADMAP.md` for the full priority table
- See `docs/HANDOVER_SESSION_2024-06-25.md` for detailed session context
