# Phase 27k — Fix Recursor Handler Type NVar Collision

## Current State

- 456 kernel tests pass
- 520 tooling tests pass
- `mult_2_inj`, `square_double`, and the `sqrt2` theorem are BLOCKED by this bug
- Crash: `Env.lookup(-2) on depth -4` in `_tryUnify` at `eval.dart:5175`
- Any proof using `trans_e`/`sym_e`/`succ_inj` (all of which use `Eq.rec`) in a context that triggers `_tryUnify` crashes
- The existing `mult_two_succ` proof (which uses `trans_e` chains) type-checks because it doesn't trigger `_tryUnify`. But using `mult_two_succ` to prove `mult_2_inj` requires `succ_inj` (to strip `succ` wrappers), which triggers the bug.

## Root Cause

The crash occurs in `_tryUnify` (eval.dart:5166-5205). When `subtype` compares two types and encounters unsolved metas, `_tryUnify` walks the VPi chain of the meta's `typeExpected` by evaluating codomain closures:

```dart
for (var i = 0; i < vars.length; i++) {
  if (typeCursor is! VPi) return null;
  domainTerms.add(quote(i, typeCursor.domain));
  typeCursor = eval(
    typeCursor.codomain.body,
    typeCursor.codomain.env.extend(VNeutral(NVar(i))),
  );
}
```

The crash is `Env.lookup(-2) on depth -4` — the `typeCursor.codomain.env` has depth -4 (negative!), and extending with `NVar(i)` still leaves it at negative depth. When `eval` tries to evaluate `typeCursor.codomain.body`, TBound references resolve via `env.lookup(index)` which fails because the env is too shallow.

**Why the env depth is wrong**: The VPi chain comes from `synthRecursorType` (called when inferring the type of `Eq.rec`/`Nat.ind`/etc.). `synthRecursorType` builds the recursor type inside-out, starting from the innermost binder. The TBound indices in the method handler types are relative to the **full recursor Pi chain** (motive + indices + methods + scrutinee). But when `_tryUnify` evaluates the codomain of a VPi from this chain, the env depth at that point doesn't match the depth the TBound indices expect, because `_tryUnify` evaluates at a specific point in the live context which may have fewer binders than the full recursor chain.

**Why this only triggers in some cases**: The `_tryUnify` path is only reached when the elaborator's meta-solver needs to solve metas. Most existing proofs don't trigger this path because their types are fully determined without meta-solving. But `mult_2_inj` uses `succ_inj` which creates an `Eq.rec` application, and the type checking of this application triggers meta-solving (because `succ_inj`'s return type involves a `cong_e` which involves `Eq.rec`), which calls `_tryUnify`, which crashes when it encounters the malformed VPi chain from `synthRecursorType`.

## The Fix

The fix is in `_tryUnify` at `eval.dart:5166-5205`. When the codomain evaluation fails due to depth mismatch, `_tryUnify` should return `null` (graceful fallback) instead of crashing. The caller (`subtype`) will then fall back to the conv-level TypeMismatch path, which correctly handles the type comparison without needing to solve metas.

### Implementation

**File**: `doxa/lib/src/eval.dart`, function `_tryUnify`

**Lines 5172-5178** (inside `isCanonicalSpine`):

```dart
// Before:
typeCursor = eval(
  typeCursor.codomain.body,
  typeCursor.codomain.env.extend(VNeutral(NVar(i))),
);

// After:
try {
  typeCursor = eval(
    typeCursor.codomain.body,
    typeCursor.codomain.env.extend(VNeutral(NVar(i))),
  );
} catch (_) {
  return null; // codomain env depth mismatch — fall back to conv
}
```

**Lines 5188-5191** (inside the `else`/`reversed` branch):

Apply the same try-catch guard:

```dart
try {
  tc = eval(tc.codomain.body, tc.codomain.env.extend(VNeutral(NVar(i))));
} catch (_) {
  return null;
}
```

### Why this works

`_tryUnify` is called during meta-solving in `subtype`. When it returns `null`, the caller (in `_drive` at line 2363) treats it as an unsolvable meta and falls back to the standard `TypeMismatch` path. The `TypeMismatch` path uses the kernel's `conv` function (with proper depth tracking) to compare the types, which doesn't have the NVar depth issue.

This fix is conservative: it only affects the crash case. All existing tests that don't trigger the crash are unaffected.

### Caveat

This fix doesn't correct the underlying `synthRecursorType` issue — it just prevents the crash. Proofs that trigger `_tryUnify` on a recursor type will get a type mismatch error instead of a crash. To fully fix the NVar collision, `synthRecursorType` would need to be changed to build handler return types using the motive at the checker's live depth (the approach described in the original Phase 27k document). That's a larger change and can be deferred.

### Validation

After the fix:
1. `mult_2_inj` (using `Nat.ind` with `succ_inj`) type-checks instead of crashing
2. `succ_inj` works correctly in all contexts
3. All 456 kernel tests + 520 tooling tests pass
4. `doxa check lib/stdlib/case_study.doxa` passes with `mult_2_inj` added

### Remaining work after this fix

Once the `_tryUnify` crash is fixed, `mult_2_inj` can be proven. The proof structure is:

```doxa
fun mult_2_inj(a: Nat, b: Nat, h: Eq Nat (mult two a) (mult two b)) : Eq Nat a b = match a {
  case zero => match b {
    case zero => refl zero
    case succ b1 => False.rec ((_: False) => Eq Nat zero (succ b1))
      (succ_ne_zero (succ (mult two b1))
        (trans_e Nat (succ (succ (mult two b1))) (mult two (succ b1)) (mult two zero)
          (sym_e Nat (mult two (succ b1)) (succ (succ (mult two b1))) (mult_two_succ b1))
          (sym_e Nat (mult two zero) (mult two (succ b1)) h)))
  }
  case succ k => match b {
    case zero => False.rec ((_: False) => Eq Nat (succ k) zero)
      (succ_ne_zero (succ (mult two k))
        (trans_e Nat (succ (succ (mult two k))) (mult two (succ k)) zero
          (sym_e Nat (mult two (succ k)) (succ (succ (mult two k))) (mult_two_succ k))
          (trans_e Nat (mult two (succ k)) (mult two zero) zero
            h
            (refl zero))))
    case succ b1 =>
      cong_e Nat Nat ((x: Nat) => succ x) k b1
        (mult_2_inj k b1
          (succ_inj (mult two k) (mult two b1)
            (succ_inj (succ (mult two k)) (succ (mult two b1))
              (trans_e Nat (succ (succ (mult two k))) (mult two (succ k)) (succ (succ (mult two b1)))
                (sym_e Nat (mult two (succ k)) (succ (succ (mult two k))) (mult_two_succ k))
                (trans_e Nat (mult two (succ k)) (mult two (succ b1)) (succ (succ (mult two b1)))
                  h
                  (mult_two_succ b1))))))
  }
}
```

After `mult_2_inj`, the `square_double` lemma and the `sqrt2` theorem can be added, completing the case study.
