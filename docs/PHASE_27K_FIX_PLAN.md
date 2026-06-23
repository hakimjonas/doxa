# Phase 27k — Fix Recursor Handler Type NVar Collision

## Current State

- 452 kernel tests pass
- 519 tooling tests pass
- Only case_study.doxa fails: `expected ?l ?d ?m, found Lt ?d ?e`
- Walked many failed fix attempts (ELevel env, typeTerm re-eval, ENil eval, topBindings threading)

## Root Cause

The recursor type `synthRecursorType` for a data type like `Lt` synthesizes the method handler types with TBound indices relative to the **full recursor Pi chain** (12 binders: motive + 2 methods + method_args + 2 indices + scrutinee). But when the **checker** processes a handler lambda (e.g., the lt_trans handler with 7 binders: a, m, k, p1, p2, ih1, ih2), it only opens the **method's own VPi chain** (7 binders). The handler body's expected return type contains `TBound(motiveDepth)` which references the motive at depth 8 from the method's innermost — beyond the 7-binder depth. This NVar at the wrong absolute level collides with the checker's live binder levels.

## The Correct Fix

The method handler's expected return type should be computed **directly from the MOTIVE** at the checker's live depth, not from the pre-synthesized recursor VPi chain. This is what Coq's kernel does and is the principled CIC approach.

### Implementation

**In `eval.dart` `_Infer` SApp processing (around line 1900-2100, the TApp infer path):**

When checking a recursor application's handler arguments, the `_TInfer` for TApp processes args sequentially. After the motive is processed (arg 0), track the **motive value**. When a handler argument follows, and the recursor is known:

1. Store the motive value from the first recursor argument
2. For each handler argument, compute the expected return type by evaluating:
   ```
   motiveResultIndices (ctor params args)
   ```
   Where `motive` is the stored value, `resultIndices` are the ctor's result indices, and the ctor instance is built from the handler's parameters.
3. Evaluate this **in the checker's live Ctx** (at the current checker depth), producing NVars at correct levels.
4. Use the result as the expected type for the handler body.

### Detection

Detect that the function being applied is a recursor by checking `fn is VRec` or `fn is TRec`. The VRec/IOr handler is on the infer path — in `_Infer` for `TApp`:

```dart
case TApp(:final fn, :final arg):
    // ... infer fn type -> VPi or VRec with VPi chain
    // ... check arg against first VPi domain
    // ... after first arg: if function is VRec, track motive
    // ... for handler args: compute expected return type from motive
```

### Simplification

If this is too complex, a simpler alternative: **after opening the method VPi for the handler body** (in `_Check` TLam vs VPi path), when the expected codomain has been opened for the last handler binder, the remaining codomain should be the handler's return type. At this point, extract the `TBound` term for this return type, and **re-evaluate it at the checker's current depth**:

```dart
// In _Check's TLam-VPi opening (eval.dart ~2720):
final opened = eval(expected.codomain.body, expected.codomain.env.extend(fresh));
// If this is the LAST binder opening (handler body follows):
// Re-evaluate the return type at the checker's Ctx to fix NVar levels
final adjusted = eval(quote(ctx.level, opened), ctx.env);
// Use adjusted as the expected type for the handler body
```

This quote→eval round-trip maps NVars from the closure's level space to the checker's level space.

## Validation

After either fix: `dart test` in both doxa and doxa_tooling should pass 452 + 520 = 972/972.
