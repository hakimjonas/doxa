# Fix Elaborator Stack-Depth Vulnerability

The elaborator (`doxa/lib/src/elab.dart`) overflows the Dart call stack when
type-checking deeply nested function applications (~1000 levels).
The evaluator (`eval.dart`) is defunctionalized and stack-safe, but the
elaborator's `_inferExpr` → `_inferExprInner` → `_checkExpr` → `_checkExprInner`
mutual recursion was never given the same treatment.

## Root Cause

The recursive call chain for `id(id(id(zero)))` at depth N:

```
_inferExprInner(SApp at depth N)
  → _inferExpr(fn)                    // line 1238 — recursive call into
      → _inferExprInner(SApp depth N-1) // _inferExprInner for nested SApp
        → _inferExpr(fn)                // another recursive layer
          → _inferExprInner(SApp depth N-2)
            ...
```

Each nesting level consumes ~4 stack frames. The Dart call stack overflows
at approximately 1000-2000 levels. This manifests as a `StackOverflowError`
during elaboration of deeply nested expressions like `id(id(id(...(zero)...)))`.

The affected code is in `_inferExprInner`'s `SAppKind` case
(`doxa/lib/src/elab.dart`, lines 1212–1294). The critical recursive call
is line 1238:

```dart
final (rawFT, rawFV) = _inferExpr(state, fn);
```

where `fn` is itself an `SExpr` that may be another `SAppKind`, triggering
recursive entry into `_inferExprInner`.

## Fix

Replace the recursive `_inferExpr(state, fn)` call with an explicit loop
that accumulates nested applications onto a stack, then processes them
in left-to-right order without recursion.

### Approach

The elaborated expression tree for `f(a1)(a2)...(aN)` is:

```
SApp(SApp(SApp(f, a1), a2), ..., aN)
```

The elaborator currently handles this recursively by walking down the left
spine, which creates a call chain proportional to N. The fix flattens this
spine into a list, processes the innermost (leftmost) function head once,
then iterates outward applying each argument:

```
1. Walk left spine, collecting (fn, arg) pairs onto a list `apps`
2. Pop the innermost fn → elab it once → (fT, fV)
3. For each arg in `apps` (left-to-right):
   a. Insert implicits: advance fV past implicit Pi binders
   b. Check arg against fV.domain (or infer if fV is not VPi)
   c. Build result term/value
   d. Advance fV to codomain
4. Return final (resultT, resultV)
```

This is analogous to how `eval.dart`'s `_Eval(TApp)` case uses an explicit
`_EvalApp` frame instead of recursive `_Eval` calls.

### Code Location

**File:** `doxa/lib/src/elab.dart`
**Function:** `_inferExprInner`
**Case:** `SAppKind` (line 1212)

### Implementation Steps

**Step 1 — Refactor the SAppKind case to flatten applications.**

Replace lines 1238–1294 with an iterative version. The key change:

```dart
case SAppKind(:final fn, :final arg):
  // 1. Collect all nested SApp layers into a flat list.
  //    innermost `fn` is on the left, outermost `arg` is on the right.
  final apps = <(SExpr fn, SExpr arg)>[];
  var curFn = expr;       // start at the outermost SApp
  while (curFn.kind is SAppKind) {
    final outer = curFn.kind as SAppKind;
    apps.add((outer.fn, outer.arg));
    curFn = outer.fn;     // walk left
  }
  // `curFn` is now the innermost function head (NOT an SApp).

  // 2. Elaborate the innermost function head once (RECURSIVE — but only
  //    one level, since curFn is not an SApp).
  final (rawFT, rawFV) = _inferExpr(state, curFn);
  var fT = rawFT;
  var fV = rawFV;

  // 3. Iterate left-to-right through the collected args.
  //    `apps` has the innermost (fn, arg) first.
  //    We actually need to process in left-to-right application order,
  //    i.e. apply arg at apps[apps.length-1] to fn, then arg at
  //    apps[apps.length-2], etc.
  //    So we reverse `apps` to get outermost-first.
  for (final pair in apps.reversed) {
    final arg = pair.arg;
    // 3a. Insert implicits
    final (impT, impV) = _insertImplicits(state, fT, fV);
    fT = impT; fV = impV;
    // 3b. Check arg against domain
    final Term argT;
    if (fV is VPi) {
      argT = _checkExpr(state, arg, fV.domain);
    } else {
      argT = _inferExpr(state, arg).$1;
    }
    // 3c. Build result term
    fT = switch (fT) {
      TData(:final name, :final args) => TData(name, [...args, argT]),
      TConstr(:final dataName, :final ctorName, :final args) =>
        TConstr(dataName, ctorName, [...args, argT]),
      _ => TApp(fT, argT),
    };
    // 3d. Advance to codomain
    if (fV is VPi) {
      final argV = eval(argT, state.ctx.env);
      fV = apply(state.ctx.env, fV.codomain, argV);
    }
  }
  return (fT, fV);
```

### Step 2 — Verify existing implicit-insertion behavior is preserved.

`_insertImplicits` (called at line 1239) advances past implicit Pi binders
and inserts metavariables. Confirm this is called once per application layer
(same as the recursive version). The iterative version preserves this by
calling `_insertImplicits` inside the loop for each arg.

### Step 3 — Verify the special-cased `TData`/`TConstr` path still works.

Lines 1261–1269 fold arguments into `TData.args` and `TConstr.args` by
positional append. The iterative version must do this for every argument
in the chain, not just the innermost. The loop above handles this by
reassigning `fT` on each iteration.

### Step 4 — Verify the result Value computation (line 1281+) still works.

After building the result term, the original code computes `resultV` by
applying the codomain. The iterative version must do this for every
argument layer. The loop above handles this by reassigning `fV` on each
iteration.

### Step 5 — Test.

```shell
cd doxa && dart analyze lib/ && dart test
```

All 373 kernel tests pass. No regressions on any existing proof file.

### Step 6 — Stress test.

```shell
cd /home/hakim/google/doxa && dart run tool/benchmark.dart --only=church --depth=100,500,1000,5000 --repeat=1 --warmup=1
```

Before the fix: depth 1000 overflows (`StackOverflowError`).
After the fix: depth 1000 and 5000 complete without overflow.
Update `docs/BENCHMARKS.md` with the new depth-ladder numbers.

## Design Constraints

- **Localized change.** Only the `SAppKind` case in `_inferExprInner` is
  modified. No other elaboration path is touched.
- **Semantics preserved.** The elaborator produces the same kernel terms
  and type values as before. The only change is stack safety.
- **No new kernel term/value forms.** Pure elaborator change.
- **Follow existing patterns.** The `while (curFn.kind is SAppKind)` loop
  is already used elsewhere in `elab.dart` (see `_walkForRecursion` line
  3036, `_collectRefs` line 3547).

## What This Does NOT Fix

The elaborator still has mutual recursion between `_inferExpr` and
`_checkExpr` on other expression shapes (Pi, Lambda, Match). Those paths
can still overflow on deeply nested Pi/lambda chains. The SApp case is
the hot path — it's the one that triggers on real and stress workloads.
The other paths can be converted iteratively when they cause observable
problems.

## Verification

```shell
cd doxa && dart analyze lib/ && dart test
cd doxa_tooling && dart analyze lib/ bin/ test/ && dart test
```

Both packages must pass with 0 errors, 0 warnings. 373 + 424 = 797 tests
must pass. `dart run tool/benchmark.dart --depth=100,500,1000,5000` must
complete without `StackOverflowError`.
