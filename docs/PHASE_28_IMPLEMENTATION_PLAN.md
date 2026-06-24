# Phase 28 — Fix recursor type index/method ordering for `Acc.rec`

## Problem

`Acc.rec` cannot be used because the recursor type synthesized by
`synthRecursorType` places method PIs **outside** index PIs.  The step
function receives its own independent `R` and `x` binders that shadow
the outer indices.  When the elaborator processes arguments left-to-right
it checks the step function (argument 3) before `R` and `x` (arguments 4, 5).
The step's `R` and the recursor's `R` live at different de-Bruijn levels;
their metas cannot be unified at check time, producing a type mismatch.

### Current Pi chain (outermost first)

```
synthRecursorType for Acc[A: Type]:
  A : Type                                      ← param (step 6)
  → motive : (R → x → Acc A R x → Type)         ← step 5
  → method  : (R → x → f → PR → ih → result)    ← step 4 (methods before indices)
  → R       : Nat → Nat → Prop                  ← step 3 (index 0)
  → x       : Nat                                ← step 3 (index 1)
  → a       : Acc A R x                          ← step 2 (scrutinee)
  → result
```

The method Pi binds its own `R`/`x`, creating fresh unsolved metas when
the step lambda is checked.  The outer `R`/`x` PIs (arguments 4, 5) are
processed *after* the step, so the metas cannot be resolved in time.

### Target Pi chain (outermost first)

```
synthRecursorType for Acc[A: Type]:
  A : Type                                      ← param (unchanged)
  → motive : (R → x → Acc A R x → Type)         ← (unchanged)
  → R       : Nat → Nat → Prop                  ← index 0, MOVED before method
  → x       : Nat                                ← index 1, MOVED before method
  → method  : (f → PR → ih → result)            ← no own R/x; refs outer via TBound
  → a       : Acc A R x                          ← scrutinee (unchanged)
  → result
```

Indices wrap OUTSIDE the method.  The method no longer rebinds `R`/`x`;
it references the outer index binders through `TBound(k)` at the correct
depth.  The step function's `f` and `ih` types use the same `R`/`x` that
are supplied by the user as explicit arguments before the step.

## User-facing change

### Before

```doxa
Acc.rec Nat
  ((R : Nat -> Nat -> Prop) => (x : Nat) => (a : Acc Nat R x) => motive_body)
  ((R : Nat -> Nat -> Prop) => (x : Nat) =>                    ← step re-binds R, x
    (f : (y : Nat) -> R y x -> Acc Nat R y) =>
    (PR : (x2 : Nat) -> (a2 : Acc Nat R x2) -> motive_at_x2) =>
    (ih : (y : Nat) -> (r : R y x) -> motive_at_y) =>
    (hx : ...) =>
    body)
  ((x: Nat) => (y: Nat) => Lt x y)                              ← R argument
  n                                                              ← x argument
  (nat_wf n)                                                     ← proof
```

### After

```doxa
Acc.rec Nat
  ((R : Nat -> Nat -> Prop) => (x : Nat) => (a : Acc Nat R x) => motive_body)
  ((x : Nat) => (y : Nat) => Lt x y)                             ← R, moved before step
  n                                                               ← x
  ((f : (y : Nat) -> R y x -> Acc Nat R y) =>                   ← step; R, x are outer
    (PR : (x2 : Nat) -> (a2 : Acc Nat R x2) -> motive_at_x2) =>
    (ih : (y : Nat) -> (r : R y x) -> motive_at_y) =>
    (hx : ...) =>
    body)
  (nat_wf n)                                                      ← proof
```

`R` and `x` in the step lambda body are no longer lambda parameters.
They are captured from the outer scope.  The elaborator's auto-implicit-lambda
mechanism in `_checkExprInner` (lines 2182–2198) handles this: when the
expected type is a `VPi`, an implicit `TLam` is inserted.  The method's
`f`/`PR`/`ih` types reference the outer `R`/`x` through `TBound` indices
at the correct depth.

## Implementation

### File: `doxa/lib/src/eval.dart`

#### 1. Swap steps 3 and 4 in `synthRecursorType`

Currently lines ~7305–7402.  Move the index wrap (step 3, lines ~7327–7368)
to AFTER the method wrap (step 4, lines ~7382–7385).

```dart
// Step 2: scrutinee (unchanged)

// Step 3: indices (was step 3, now wrapped OUTSIDE methods)
for (var k = 0; k < indexCount; k++) { ... }

// Step 4: methods (was step 4, now wrapped INSIDE indices)
for (var i = ctorCount - 1; i >= 0; i--) { ... }

// Step 5: motive (unchanged)

// Step 6: params (unchanged)
```

Because indices now sit at a different depth relative to methods, the
`_synthMethodType` depth computation must be adjusted.

#### 2. Update `_synthMethodType` to drop leading `R`/`x` PIs

Currently `_synthMethodType` builds the method type as:

```
Π(R : A → A → Prop). Π(x : A). Π(f : ...). Π(PR : P R). Π(ih : ...). P R x (ctor ...)
```

After the change, `R` and `x` are already outer binders.  The method type
should start from `f`.  Two changes:

**A. Remove the R/x Pi wrappers from the method type.**  These two PIs are
no longer part of `_synthMethodType`'s result.  They are provided by the
outer recursor structure (step 3).

**B. Adjust TBound indices.**  Inside the method body, TBounds that
previously pointed at the method's local `R`/`x` now point at the outer
index binders.  The method's `remapAtInner` function computes depths
relative to an innermost point.  With indices now further out, the depth
of a param reference must cross:

```
  indexCount   // indices sit between params and method
  + 1          // method's own Pi (or 0 depending on base)
```

The precise offset depends on which step in `synthRecursorType` we're at.
The easiest approach: build the method type using `TBound` references
that are correct for the NEW ordering.  In `_synthMethodType`, where
`TBound(k)` for param `k` is computed via `paramDepthAtInner(k)`, the
formula adds `indexCount` to the offset (since index Pi's now sit outside
the method but inside the params).

Concretely, change the depth formulas in `_synthMethodType`:

```dart
// Old (indices are inside methods):
int motiveDepthAtInner  = ihCount + argCount + ctorIndex;
int paramDepthAtInner(int i) => 
    ihCount + argCount + ctorIndex + 1 + (paramCount - 1 - i);

// New (indices are outside methods; indexCount layers between):
int motiveDepthAtInner  = ihCount + argCount + ctorIndex + indexCount;
int paramDepthAtInner(int i) => 
    ihCount + argCount + ctorIndex + indexCount + 1 + (paramCount - 1 - i);
```

The `remapAtInner` function in `_synthMethodType` uses these depths, so
only the depth formulas need updating — the remap logic is unchanged.

#### 3. Update `_synthMotiveType`

The motive type's structure doesn't change (it still binds `R` and `x`
before the scrutinee type).  No changes needed.

#### 4. Verify that auto-λ in `_checkExprInner` handles the shift

The elaborator's `_checkExprInner` (elab.dart, lines 2182–2198) inserts
implicit lambdas for trailing VPi binders.  When the step function body
is checked, the expected type has `R` and `x` as implicit PIs wrapping
it.  The elaborator should insert implicit lambdas for them automatically.
This path is already exercised by `Nat.ind` and `Eq.rec` — verify that
the binders land at the correct de-Bruijn levels.

#### 5. Update `_recursorArity` and ι-reduction paths

The recursor arity (`_recursorArity`, line 7111) counts the total number
of parameters for ι-reduction.  With indices now outside methods, the
arity formula changes:

```dart
int _recursorArity(DataDecl d) =>
    d.params.length + d.ctors.length + 1 + d.indices.length + 1;
    //            params           methods    motive  indices     scrutinee
```

Verify that ι-reduction in the checker correctly dispatches after the
full spine is applied.  The offset at which methods are located in the
recursor's spine changes — update `_recursorMethodOffset` or equivalent.

## Validation

```
doxa check lib/stdlib/case_study.doxa      -- even_implies_double compiles
dart test                                   -- 452 + 520 pass
dart analyze doxa/                          -- clean
```

## Risk

- The reordering affects ALL indexed families (`Vec`, `Lt`, `Eq`, `Acc`),
  not just `Acc`.  Existing recursor calls in the test suite and stdlib
  must continue to work.
- `Eq.rec` and `Lt.rec` are used in existing proofs (`succ_ne_zero`,
  `nat_wf`'s `Lt.rec` call).  Verify those still type-check.
- The i-reduction path in `_Eval` for TRec/VRec assumes a specific
  spine layout.  The offset of the method handlers in the spine changes.
  Verify that ι-reduction still dispatches correctly.
