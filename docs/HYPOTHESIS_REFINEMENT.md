# Hypothesis refinement in match arms

## Problem

When a function parameter is used as both a scrutinee and in a
hypothesis type, pattern-matching on the scrutinee does not refine the
hypothesis's type.  Example:

```doxa
fun even_implies_double(n: Nat, h: Eq Bool (even n) true_)
    : Eq Nat n (mult two (half n)) = match n {
  case zero => refl zero  // goal: Eq Nat zero (mult two (half zero))
  case succ k =>
    // h's type is still `Eq Bool (even n) true_` where n refers
    // to the original parameter, NOT `Eq Bool (even (succ k)) true_`.
    // This blocks using h in the succ arm.
}
```

The elaborator's `_elabMatch` substitutes the scrutinee variable in
the **expected type** of each arm body, but does NOT substitute in
the **types of existing context binders** (like `h`).  This is sometimes
called "hypothesis refinement" or "dependent pattern matching" — the
defining feature that makes match on a dependent index refine the
types of all binders in the context.

## Current code

In `doxa/lib/src/elab.dart`, `_elabMatch` (line ~2798) builds the arm
state by pushing arm binders onto the original state.  The original
binders (`n`, `h`) remain in the context with their original, unrefined
types.

The arm body is checked against a refined expected type (computed via
`substNVar`), but the binder types in the Ctx are never updated.

## Required changes

### 1. Ctx-level substitution (`doxa/lib/src/ctx.dart` or `elab.dart`)

Add a function that substitutes a de Bruijn variable in ALL binder
types within a `Ctx`:

```dart
Ctx substCtx(Ctx ctx, int level, Value replacement)
```

This walks the Ctx's binder list and replaces `NVar(level)` with
`replacement` in each binder's type, using `substNVar` (which already
exists in `eval.dart` and handles VFuns/VData/VPi/neutral chains).

### 2. Match-arm context refinement (`elab.dart` in `_elabMatch`)

After computing `armExpected` (the refined expected type for the arm),
also refine all binder types in `armState.ctx` that reference the
scrutinee variable.  Specifically:

```dart
// At the point where armState is built (lines ~2994-3008),
// before elaborating the arm body:
final refinedCtx = substNVarInCtx(armState.ctx, scrutLevel, ctorResultV);
armState = _ElabState(... ctx: refinedCtx, ...);
```

This ensures that when the arm body elaborates and looks up `h`'s
type via `state.lookupLocal("h")`, it gets the refined type
`Eq Bool (even (succ k)) true_` instead of `Eq Bool (even n) true_`.

The substitution level (`scrutLevel`) is the de Bruijn level of the
scrutinee variable.  The replacement (`ctorResultV`) is the
constructor value (e.g. `VConstr("Nat", "succ", [VNeutral(NVar(k_level))])`).

### 3. Avoid over-substitution

Only substitute binders whose types actually reference the scrutinee
variable.  Unrelated binders should be left unchanged.  `substNVar`
already handles this — it returns the value unchanged if the scrutinee
NVar does not appear.

### 4. Indexed family refinement

For indexed data types (like `Vec A n` or `Acc A R x`), the
constructor result also refines the indices.  The existing
`refineMatchArmExpected` function already computes this refinement
for the expected type.  The same refinement should be applied to
binder types.

## Test

The existing `even_implies_double` proof in `lib/stdlib/case_study.doxa`
currently fails at line 175 with a type mismatch involving `go ?f`.
After this fix, the inner `Nat.ind` call on line 169 (`Nat.ind ...
n h0`) should instead be `Nat.ind ... k hsk` (or removed entirely
in favour of match).  At minimum, the `hsk` parameter in the outer
step lambda should be usable in the inner proof.

A minimal test:

```doxa
val h_refined : (n: Nat) -> (h: Eq Bool (even n) true_) ->
  match n {
    case zero => Eq Bool (even zero) true_
    case succ k => Eq Bool (even (succ k)) true_
  } = (n: Nat) => (h: Eq Bool (even n) true_) => match n {
    case zero => h
    case succ k => h   // currently fails: h's type is not refined
  }
```

## Files to modify

| File | Change |
|---|---|
| `doxa/lib/src/ctx.dart` | Add `substNVarInCtx` function |
| `doxa/lib/src/elab.dart` | Call `substNVarInCtx` in `_elabMatch` per-arm setup |
| `doxa/lib/stdlib/case_study.doxa` | Fix `even_implies_double` to use match or corrected `Nat.ind` args |

## See also

- `docs/IMPLEMENT_P0_ROADMAP.md` for context on the `even_implies_double` proof
- `docs/HANDOVER_SESSION_2024-06-25.md` for detailed session context
- `doxa/lib/src/eval.dart` `substNVar` (line ~7872) — already handles VFun, VData, VConstr, VPi
- `doxa/lib/src/eval.dart` `refineMatchArmExpected` (line ~6813) — indexed-family refinement
