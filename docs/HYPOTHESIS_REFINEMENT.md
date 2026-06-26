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

In `doxa/lib/src/elab.dart`, `_elabMatch` (line ~2807) builds the arm
state by pushing arm binders onto the original state.  The original
binders (`n`, `h`) remain in the context with their original, unrefined
types.

The arm body is checked against a refined expected type (computed via
`substNVar`), but the binder types in the Ctx are never updated.

## Required changes

### 1. Ctx-level substitution (`doxa/lib/src/elab.dart`)

Add a function that substitutes a de Bruijn variable in ALL binder
types within a `Ctx`:

```dart
Ctx substNVarInCtx(Ctx ctx, int scrutLevel, Value replacement)
```

The Ctx chain is immutable (`CCons` fields are `final`), so this walks
the chain and creates new `CCons` nodes for binders whose types
changed; unchanged nodes can be shared.  Uses `substNVar` from
`eval.dart` (line ~7872) which already handles VFuns/VData/VPi/neutral
chains.

Place this in `elab.dart` (not `ctx.dart`) since it depends on
`substNVar` from `eval.dart` and is only called from `_elabMatch`.

### 2. Match-arm context refinement (`elab.dart` in `_elabMatch`)

After building `armState` (lines ~3010-3030) but before elaborating
the arm body, refine all existing binder types that reference the
scrutinee variable.  The arm state's `Ctx` has arm binders pushed on
top of the original context; existing binders (`h`, etc.) are deeper
but their stored type values still reference the scrutinee at the
**original** level (pre-arm-binder-push).  Walk the Ctx chain and
substitute at that original level.

```dart
// At the point where armState is built (around lines 3010-3030),
// before elaborating the arm body:
final scrutLevel = (scrutineeValue.neutral as NVar).level;  // original level
final refinedCtx = substNVarInCtx(armState.ctx, scrutLevel, ctorResultV);
// Rebuild armState with refinedCtx.  The value/env chain stays the same.
armState = _ElabState(
  topEnv: armState.topEnv,
  ctx: refinedCtx,
  names: armState.names,
);
```

This ensures that when the arm body elaborates and looks up `h`'s
type via `state.lookupLocal("h")`, it gets the refined type
`Eq Bool (even (succ k)) true_` instead of `Eq Bool (even n) true_`.

The `scrutLevel` is the scrutinee's level in the ORIGINAL context
(before arm binders were pushed).  The `ctorResultV` uses NVars at
the ARM context's levels — this is fine because the substituted
types will be evaluated in the arm's env where those levels resolve
correctly.

**Ctx immutability**: `CCons` is immutable, so `substNVarInCtx`
creates a new CCons for each binder whose type changed.  The
`_ElabState` must be rebuilt to point at the new Ctx; the
`value` and `env` fields of each CCons stay unchanged (arm binders
already have their values, and the env chain is parallel to the
original Ctx).

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

A minimal test that the type-check succeeds (even if the term uses
the refined hypothesis in a way that matches the new type):

```doxa
val h_refined : (n: Nat) -> (h: Eq Bool (even n) true_) ->
  match n {
    case zero => Eq Bool (even zero) true_
    case succ k => Eq Bool (even (succ k)) true_
  } = (n: Nat) => (h: Eq Bool (even n) true_) => match n {
    case zero => h   // after refinement, h: Eq Bool (even zero) true_ ✓
    case succ k => h // after refinement, h: Eq Bool (even (succ k)) true_ ✓
  }
```

**Caveat**: after refinement, `h`'s TYPE changes but `h`'s VALUE still
refers to the original `n` parameter.  The term `h` is still valid
because `even n` and `even (succ k)` become definitionally equal once
`even` is computed (via VFun unfolding) — this works for the base
case (`even zero` = `true_`) and for the `succ k` case (`even (succ k)`
unfolds to `not (even k)` which IS NOT the same as `even n` stuck).
So the `succ k` branch `h` may still fail at the kernel check step
if `even (succ k) ≠ even n` in the evaluator.  The fix enables the
*elaboration* of the refined type, but the resulting kernel term must
still be type-correct.  The `even_implies_double` proof is the proper
test — it uses `hsk` (already typed at `Eq Bool (even (succ k)) true_`)
in the inner proof.

## Files to modify

| File | Change |
|---|---|
| `doxa/lib/src/ctx.dart` | Add `substNVarInCtx` function |
| `doxa/lib/src/elab.dart` | Call `substNVarInCtx` in `_elabMatch` per-arm setup |
| `doxa/lib/stdlib/case_study.doxa` | Fix `even_implies_double` to use match or corrected `Nat.ind` args |

## See also

- `docs/IMPLEMENT_P0_ROADMAP.md` for context on the `even_implies_double` proof
- `docs/HANDOVER_SESSION_2024-06-25.md` for detailed session context
- `doxa/lib/src/eval.dart` `substNVar` (line ~7872) — handles VFun, VData, VConstr, VPi, and neutral chains
- `doxa/lib/src/eval.dart` `refineMatchArmExpected` (line ~6813) — indexed-family refinement (for `Vec`/`Acc` style data types)
- `doxa/lib/src/ctx.dart` `CCons` (line ~165) — immutable context node; `substNVarInCtx` must reconstruct the chain
- `doxa/lib/src/value.dart` `VFun` (line ~206) — VFun values in binder types; `substNVar` already handles their spines
