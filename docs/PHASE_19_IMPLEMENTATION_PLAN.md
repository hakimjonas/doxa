# Phase 19 — Ergonomic Edges

Three small features closing Phase 11/12 carry-forwards. Each is independent
and can be implemented in any order. ~120 lines total, 3-5 sessions.

---

## Item 1 — Local `let rec` (~40 lines)

### Goal

`{ val rec f : (x: A) → B = body ; ... }` — a local recursive binding inside block
expressions. The bound name is visible in its own body. Desugars to a `TLet` with
a guarded structural-recursion check.

### Why

Currently only top-level `fun ... and fun ...` blocks can be recursive. Local
`{ val ... ; ... }` bindings are non-recursive only. This forces users to write
top-level functions for even small helper recursions.

### Implementation

#### 1a. Surface syntax

Extend the `_valBinding` parser in `parse.dart` (line 241) to accept `rec`:

```
{ val rec f(x: Nat): Nat = ... ; f(zero) }
```

Add an `_opaqueMod | _recMod` prefix:

```dart
final Parser<ParseError, bool> _recMod =
    _keyword('rec').map((_) => true).optional.map((v) => v as bool? ?? false);
```

Modify `_valBinding` to consume optional `rec` keyword and propagate as a flag.

#### 1b. Surface AST

Add `isRec` field to `SLetKind`:

```dart
final class SLetKind extends SExprKind {
  // ... existing fields ...
  final bool isRec;  // NEW: whether this is a `val rec` binding
}
```

#### 1c. Elaboration

In `_inferExpr` for `SLetKind` (elab.dart line ~1251):

When `isRec` is true:
1. Don't evaluate the bound expression immediately — instead, emit a top-level-like
   structural recursion check using the same walker `_elabFunBlock` uses.
2. The body and bound both see the recursive name via the environment.
3. The elaborator emits a `TLet(domain, RecursiveFix(...), body)` or threads the
   recursive binding through the meta-context.

Simpler approach: desugar local `let rec` into a fresh top-level binding.
This is what Lean 4 and Coq do internally.

```dart
if (kind.isRec) {
  // Desugar to a fresh top-level fun in the current TopEnv,
  // then reference it in the let body.
  final freshName = _freshName(param);
  final freshSFunKind = SFunKind(freshName, [], params, returnType, body,
                                  isOpaque: false);
  final freshSDecl = SDecl(freshSFunKind, decl.span);
  final produced = _elabDecl(topEnv, freshSDecl);
  final checked = checkDeclResult(..., produced);
  // Reference the fresh top-level binding from the let body
  final ref = TTop(freshName);
  return TLet(domain, ref, body, name: param);
}
```

Actually, the simplest approach: just add `isRec` to the block-expr val binding,
and during elaboration of the block, run the structural-recursion walker on the
binding's body, then thread it as a top-level `fun` desugaring.

#### 1d. Evaluation

No new eval machinery needed — the desugaring to top-level `fun` handles it.
The `TLet` body sees the recursive name via `TTop(freshName)`.

Alternatively, extend `TLet` to carry an optional `isRec` flag and handle it
in the evaluator by:
1. Creating a stub `VNeutral(NTop(freshName))` in the env
2. Evaluating the body under this stub
3. The stub resolves via the same VFun guarding as top-level recursive funs

This is more complex. The desugaring approach is simpler and reuses all
existing recursive binding infrastructure.

#### 1e. Tests

| # | Test | Expected |
|---|------|----------|
| 1 | `{ val rec f(x: Nat): Nat = ... ; f(zero) }` | f applied to zero, evaluates correctly |
| 2 | Mutual `{ val rec f(...); val rec g(...); ... }` | Both reference each other |
| 3 | Non-recursive `{ val x = 5; ... }` unchanged | Backward compat |
| 4 | Regression: existing block-expr tests pass | No breakage |

---

## Item 2 — Per-member `{struct <name>}` Annotation (~40 lines)

### Goal

Allow users to specify which argument decreases in mutual recursive functions:

```
fun f(a: Nat)(b: List)(c: Nat): Nat {struct a} = ...
```

Currently, the decreasing argument is always the first explicit value parameter
(SPEC §8.6). This annotation lets users pick a different one (e.g., for lex-order
or when a non-first argument is the structurally decreasing one).

### Implementation

#### 2a. Surface AST

Add `structAnn` field to `SFunKind`:

```dart
final class SFunKind extends SDeclKind {
  // ... existing fields ...
  final String? structAnn;  // NEW: `{struct name}` annotation
}
```

#### 2b. Parser

In the `_funDecl` / `_mkFunBody` parser, after parsing params, accept optional
`{struct name}` annotation:

```dart
final Parser<ParseError, String?> _structAnn = _sym('{')
    .skipThen(_keyword('struct'))
    .skipThen(_ident)
    .thenSkip(_sym('}'))
    .optional
    .map((r) => r?.$1);
```

This is parsed in the `fun` body parser, before the return type.

#### 2c. Elaboration

In `_elabFunBlock` (elab.dart line ~2754), when stamping `recDecreasingArg`:

Instead of always using `typeParams.length`, look up the `structAnn`:

```dart
final int decreasing;
if (fun.structAnn != null) {
  // Find the index of the annotated parameter
  decreasing = _findParamIndex(fun, fun.structAnn!);
  if (decreasing < 0) {
    throw StructAnnotationNotFound(fun.name, fun.structAnn!, span);
  }
} else {
  decreasing = fun.typeParams.length;  // default: first value param
}
```

#### 2d. Structural recursion walker update

The structural recursion check (elab.dart lines ~2886-2891) needs to validate
that the annotated parameter is in a structurally smaller position in recursive
calls. Currently it checks the first value param. Update to check the
`structAnn`-designated parameter instead.

#### 2e. Tests

| # | Test | Expected |
|---|------|----------|
| 1 | `fun f(a: Nat)(b: List)(c: Nat) {struct b} = ... f a (tail b) c` | Type-checks |
| 2 | `{struct}` references non-existent param | Error |
| 3 | `{struct}` on type parameter | Error |
| 4 | Default (no annotation) still works | First value param |
| 5 | Regression: all existing mutual fun blocks pass | No breakage |

---

## Item 3 — `plus_zero` Match Normalization Bug (~20 lines, investigation)

### Goal

Investigate and fix the infinite normalization bug where a match-based recursive
`fun` with a return type depending on the scrutinee enters an infinite normalization
loop.

### Background

The bug (logged from Phase 12 interlude, DETAILED_PLAN line 1234):

> "Match-based recursive `fun` where the return type depends on the scrutinee
> currently enters infinite normalization. Requires either lazy TTop resolution
> or a reduction-strategy change."

Phase 14.7's opaque flag provides a workaround: marking the function `opaque`
during its own body check prevents unfolding. But the root cause may still
exist for non-opaque functions.

### Investigation steps

1. **Reproduce the bug:**
   ```doxa
   data Nat : Type { zero : Nat; succ : Nat -> Nat; }
   fun plus(m: Nat)(n: Nat): Nat = match m {
     zero => n;
     succ m' => succ (plus m' n);
   }
   fun plus_zero(n: Nat): Eq[Nat] (plus n zero) n = match n {
     zero => refl[Nat] zero;
     succ n' => ...
   }
   ```

2. **Run under the evaluator** — observe where normalization diverges.

3. **Root cause analysis:**
   The evaluator's `_Apply` for `VFun` only unfolds when the decreasing argument
   is a canonical `VConstr`. This should prevent infinite unfolding. If the bug
   still occurs, it means the `VFun` guard is being bypassed somehow — perhaps
   during match motive normalization.

4. **Fix candidates:**
   - If the evaluator is unfolding `VFun` before the decreasing arg is canonical:
     tighten the guard check in `_Apply(VFun)` at eval.dart line ~2621.
   - If match motive normalization triggers eager evaluation before the scrutinee:
     add lazy evaluation of the motive for VMatch.
   - If `plus_zero`'s return type `Eq[Nat] (plus n zero) n` causes the elaborator
     to evaluate `plus n zero` during type inference: restrict type inference to
     not evaluate VFun applications unless the decreasing arg is present.

5. **If root cause is not fixable with small changes:**
   Document the workaround (use `opaque fun` during self-check) and defer to
   a future reduction-strategy overhaul.

### Verification

If fixable:
```shell
doxa check lib/stdlib/proofs.doxa  # must pass (contains plus_zero)
dart test  # all existing tests pass
```

If deferred: update the bug documentation with root cause analysis and
confirmed workaround.

---

## Step 4 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All existing tests pass (413 doxa + 435 doxa_tooling).
New ergonomic tests pass for items that are implemented.
`dart format --set-exit-if-changed` clean.

---

## Files to modify

| Item | File | Changes | Est. lines |
|------|------|---------|-----------|
| 1 | `doxa/lib/src/parse.dart` | `_recMod` parser, extend `_valBinding` | +10 |
| 1 | `doxa/lib/src/surface.dart` | `isRec` field on `SLetKind` | +5 |
| 1 | `doxa/lib/src/elab.dart` | Desugar `val rec` → top-level fun | +25 |
| 2 | `doxa/lib/src/surface.dart` | `structAnn` field on `SFunKind` | +5 |
| 2 | `doxa/lib/src/parse.dart` | `_structAnn` parser in `_mkFunBody` | +10 |
| 2 | `doxa/lib/src/elab.dart` | `_findParamIndex`, use `structAnn` for `recDecreasingArg`, walker update | +20 |
| 3 | `doxa/lib/src/eval.dart` | Investigation — possibly tighten VFun guard or lazy motive | +10 |
| 3 | `doxa/test/` | Reproduction test for `plus_zero` bug | +15 |
| 1+2 | `doxa/test/` or `doxa_tooling/test/` | New tests | +40 |
| **Total** | | | **~140** |

## Risk assessment

**Risk: Low.** Items 1 and 2 are additive syntax sugar — they desugar to existing
forms (top-level `fun` and `recDecreasingArg` respectively). Item 3 is an
investigation with the workaround already in place (Phase 14.7 opaque flag).
No existing behavior changes. If item 3 can't be fixed, it becomes a documented
workaround.
