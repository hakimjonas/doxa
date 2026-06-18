# Phase 14.5 — Implement Quotient Types

Implement quotient types as kernel primitives in Doxa. This is ~200 lines
of kernel code across 5 files. All existing tests (766) must continue to pass.
`dart analyze` 0 issues, `dart format` clean, in both `doxa/` and `doxa_tooling/`.

## What to build

### Step 1 — Term and value forms (`doxa/lib/src/term.dart`, `doxa/lib/src/value.dart`)

Add three new term subclasses and three corresponding value subclasses.

**Terms:**

```dart
/// Quotient type formation: `Quot(A, R)` where A is the carrier and
/// R: A → A → Prop is the equivalence relation.
final class TQuot extends Term {
  final Term carrier;   // A
  final Term relation;  // R
  const TQuot(this.carrier, this.relation);
  // implement ==, hashCode, toString
}

/// Inject an element into a quotient: `Quot.mk(a)`.
final class TQuotMk extends Term {
  final Term arg;       // the element a of type A
  const TQuotMk(this.arg);
  // implement ==, hashCode, toString
}

/// Eliminate from a quotient: `Quot.lift(quot, f, proof)`.
/// f: A → B, proof: (x y: A) → R x y → Eq B (f x) (f y)
final class TQuotLift extends Term {
  final Term quot;      // the quotient being eliminated
  final Term fn;        // the function being lifted
  final Term proof;     // compatibility proof
  const TQuotLift(this.quot, this.fn, this.proof);
  // implement ==, hashCode, toString
}
```

**Values:**

```dart
/// A quotient type value.
final class VQuot extends Value {
  final Value carrier;
  final Value relation;
  const VQuot(this.carrier, this.relation);
}

/// A quotient element.
final class VQuotMk extends Value {
  final Value arg;
  const VQuotMk(this.arg);
}

/// A stuck quotient lift (waiting for the quot argument to become VQuotMk).
/// Once the quot is canonical, ι-reduction fires: lift(mk(a), f, proof) → f(a).
final class VQuotLift extends Value {
  final Value quot;
  final Value fn;
  final Value proof;
  const VQuotLift(this.quot, this.fn, this.proof);
}
```

Update `openTerm`/`closeTerm` to handle the three new term forms (they're
structural — recursively open/close sub-terms, same pattern as every other
form).

### Step 2 — Evaluation and conversion (`doxa/lib/src/eval.dart`)

The defunctionalized driver (`_drive`) dispatches over a sealed `_Step` ADT
and an explicit `_Frame` stack. Add new steps and frames for quotients.

**Eval:** In the `_Eval` step, add three new dispatch arms:

```dart
case TQuot(:final carrier, :final relation):
  stack.add(_EvalQuot());
  return _eval(carrier, env);

case TQuotMk(:final arg):
  stack.add(_EvalQuotMk());
  return _eval(arg, env);

case TQuotLift(:final quot, :final fn, :final proof):
  stack.add(_EvalQuotLift(fn, proof));
  return _eval(quot, env);
```

New frames:

```dart
final class _EvalQuot extends _Frame {
  Value? _carrier;
}

final class _EvalQuotMk extends _Frame {
  // no stored state — just wrap evaluated arg in VQuotMk
}

final class _EvalQuotLift extends _Frame {
  final Term fn;
  final Term proof;
  Value? _quot;
  // When _quot is populated, next eval the fn
}
```

Frame dispatch logic:
- `_EvalQuot` — when control returns with a value, if `_carrier` is null,
  store it, then eval `relation`. When both are ready, produce `VQuot(carrier, relation)`.
- `_EvalQuotMk` — when control returns with a value, produce `VQuotMk(value)`.
- `_EvalQuotLift` — when control returns with a value, store as `_quot`.
  Then eval `fn`. When `fn` value is ready, eval `proof`. When all three
  are ready, produce `VQuotLift(quot, fn, proof)`.

**Apply / ι-reduction:** The key reduction rule is:

```
apply(VQuotLift(VQuotMk(a), f, proof))  →  apply(f, a)
```

When a `VQuotLift` whose `quot` is `VQuotMk(a)` is applied (zero remaining
args after this operation — the lift itself is the term being reduced),
it reduces to `f(a)`. Add a dispatch arm in the `_Apply` path:

```dart
case VQuotLift(quot: final VQuotMk(:final arg), :final fn, :final proof):
  return _apply(fn, arg);
```

If the `VQuotLift`'s `quot` is NOT a `VQuotMk` (it's a neutral or stuck),
the `VQuotLift` stays stuck. This is the "cannot reduce until the quot is
canonical" rule — same pattern as `VRec` and `VMatch`.

**Quote:** Add three quote dispatch arms:

```dart
case VQuot(:final carrier, :final relation):
  return TQuot(quote(level, carrier), quote(level, relation));

case VQuotMk(:final arg):
  return TQuotMk(quote(level, arg));

case VQuotLift(:final quot, :final fn, :final proof):
  return TQuotLift(
    quote(level, quot),
    quote(level, fn),
    quote(level, proof),
  );
```

**Conversion:** Add conv dispatch arms:

```dart
case (VQuot(:final c1, :final r1), VQuot(:final c2, :final r2)):
  // Compare carriers and relations pointwise.
  // Push _ConvOnResult([c2, r2] order) then _Conv(c1, c2).

case (VQuotMk(:final a1), VQuotMk(:final a2)):
  // Do NOT compare a1 with a2 pointwise. Different elements of a
  // quotient are NOT definitionally equal. Only identity (a1 == a2
  // by pointer equality) succeeds. A neutral VQuotMk is compared by
  // identity through the default _Conv(VNeutral, VNeutral) path.
  // This arm handles the "both are canonical VQuotMk" case — it
  // returns mismatch unless they are the same object.
  return a1.identical(a2) ? ConvOk() : ConvMismatch(v1, v2);

case (VQuotLift(:final q1, :final f1, :final p1),
      VQuotLift(:final q2, :final f2, :final p2)):
  return _convQuotLift(level, q1, f1, p1, q2, f2, p2);
```

**Important:** `VQuotMk` on both sides is NOT pointwise equality. Two
elements `mk(a)` and `mk(b)` where `a` and `b` are different but related
by the equivalence `R` should be provably equal (via `Eq.rec`), NOT
definitionally equal (via `conv`). Definitional equality of quotients
only holds for identity. This is the standard semantics across Lean 4,
Coq, and Agda.

### Step 3 — Type inference and checking (`doxa/lib/src/eval.dart` infer/check)

**Infer:**

```dart
case TQuot(:final carrier, :final relation):
  return _inferQuot(ctx, carrier, relation);

case TQuotMk(:final arg):
  // A TQuotMk's type is a VQuot — but which one depends on context.
  // The elaborator ensures TQuotMk only appears in a context that
  // provides the expected quotient type. At the kernel level, this
  // infers the type of arg and wraps it in a VQuot(_, _) made fresh.
  // Actually — TQuotMk can't be inferred alone. It must be checked
  // against a VQuot expected type. Throw NotAType or a new error
  // if reached in infer mode without the expected type.
  return _inferQuotMk(ctx, arg);

case TQuotLift(:final quot, :final fn, :final proof):
  return _inferQuotLift(ctx, quot, fn, proof);
```

**Infer logic:**
- `infer(TQuot)`: infer `carrier` → must be `VType(n)`. Check `relation`
  against `VPi(carrier, VPi(carrier, VProp))` (i.e., `A → A → Prop`).
  Result type is `VType(max(n, 0))`.
- `infer(TQuotMk)`: NOT SUPPORTED in infer mode. The kernel expects the
  elaborator to have placed this in a check context with a `VQuot` expected
  type. In the kernel, infer fails with a clear error. The elaborator
  handles this by threading the expected type through `_checkExpr`.
- `infer(TQuotLift)`: infer `quot` → must be `VQuot(A, R)` (or a neutral
  that converts to one). Check `fn` against `VPi(A, B)` for some `B`.
  Check `proof` against `(x:A)(y:A) → R x y → Eq B (fn x) (fn y)`.
  Result type is `B`.

**Check:** Add dispatches for the new forms in the `_Check` step.

**New check-error types** (add to `doxa/lib/src/check.dart`):
- `NotAQuotient(Value actual)` — a term expected to be a quotient type
  but the inferring yielded a non-quotient.
- `QuotMkInInferMode(DoxaSpan span)` — `TQuotMk` cannot be inferred;
  it must appear in a check context.
- `QuotFnNotRespectingRelation(Value got, Value expected)` — the
  compatibility proof for `Quot.lift` does not have the correct type.

### Step 4 — Elaboration (`doxa/lib/src/elab.dart`)

Surface syntax tokens (add to `doxa/lib/src/parse.dart`):
- `Quot(A, R)` — type expression
- `mk a` — quotient injection
- `lift fn proof` (or similar — match existing syntax conventions)

New surface AST kinds (add to `doxa/lib/src/surface.dart`):
- `SQuotKind(A, R)` 
- `SQuotMkKind(a)`
- `SQuotLiftKind(fn, proof)`

Parser additions parse these into `SExpr` nodes with spans.

Elaborator handling (`_elabExpr` / `_inferExpr`):
- `SQuotKind` → `TQuot(A, R)` after elaborating A and R.
- `SQuotMkKind(a)` → `TQuotMk(a)` with the elaborator determining
  the quotient context from the expected type (same pattern as
  constructor inference with implicit type parameters).
- `SQuotLiftKind(fn, proof)` → `TQuotLift(quot, fn, proof)`. The
  `quot` argument is inferred from context (what quotient is `fn`
  expecting as input?), or the user provides it explicitly.

### Step 5 — Tests

Create `doxa/test/quotient_test.dart` with at minimum:

1. **Basic formation.** `Quot(Nat, (a b: Nat) => Eq[Nat] a b)` typechecks
   and its sort is `Type 0`.

2. **mk injection.** A value `val zero_mod2 : Quot(Nat, ...) = mk zero`
   typechecks.

3. **lift reduction.** Define `f : Nat → Nat` as `plus one`. Define a
   compatibility proof that `f` respects the equivalence. Lift `f` to a
   function on the quotient. Verify the reduction rule fires on `mk zero`.

4. **Singleton elimination.** Verify that `Quot` elimination into `Type`
   is rejected when the quotient's relation is not a Prop (or when the
   singleton-elim check otherwise doesn't hold — confirm the existing
   Phase 12 guard catches this).

5. **Lean 3 regression.** Attempt to construct the known inconsistency
   (if a test case exists in the Lean 4 test suite or the Coq bug tracker,
   adapt it). Expected: rejection by singleton-elim guard.

6. **VQuotMk not definitionally equal.** Verify that `conv` does NOT
   equate `VQuotMk(a)` with `VQuotMk(b)` for different `a`, `b`.

7. **Lossless round-trip.** eval → quote produces identical structure.

8. **Neutral quotient.** A `VQuotLift` whose `quot` is a neutral
   `VNeutral` stays stuck and quotes correctly.

### Step 6 — Verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

Both must pass with 0 analyze issues (info-level `implementation_imports`
in `doxa_tooling` is acceptable, same as current). All 766 existing
tests pass. New quotient tests pass.

`doxa check example/proofs.doxa` → `OK: 26 declarations checked`.

## Files to modify

| File | What changes |
|---|---|
| `doxa/lib/src/term.dart` | `TQuot`, `TQuotMk`, `TQuotLift` sealed subclasses. `openTerm`/`closeTerm` handlers. |
| `doxa/lib/src/value.dart` | `VQuot`, `VQuotMk`, `VQuotLift` sealed subclasses. |
| `doxa/lib/src/eval.dart` | Eval dispatch arms. New `_EvalQuot`, `_EvalQuotMk`, `_EvalQuotLift` frames. `_Apply` arm for `VQuotLift(VQuotMk(a), ...)`. Quote dispatch arms. Conv dispatch arms. Infer/check dispatch arms. |
| `doxa/lib/src/check.dart` | New check error types: `NotAQuotient`, `QuotMkInInferMode`, `QuotFnNotRespectingRelation`. |
| `doxa/lib/src/elab.dart` | Elaboration of surface syntax into kernel terms. |
| `doxa/lib/src/parse.dart` | Surface grammar additions. |
| `doxa/lib/src/surface.dart` | Surface AST kind additions. |
| `doxa/lib/src/pretty.dart` | Pretty-printer dispatch for new term forms. |
| `doxa/test/quotient_test.dart` | New test file (Step 5). |
| `doxa_tooling/lib/src/lsp/handler.dart` | If the LSP does exhaustive switches on `DoxaCheckError` subtypes, add new error kinds. |
| `doxa_tooling/lib/src/web_check.dart` | If `_checkErrorKind` does exhaustive switches, add new error kind mappings. |

## Design constraints

- **No new dependencies.** Use existing `dart:core` types only.
- **Follow existing patterns.** Every new sealed subclass follows the
  same pattern as existing ones (equals/hashCode/toString, immutable
  final fields, const constructors).
- **Defunctionalized driver discipline.** Every new operation goes through
  the frame stack. No recursive function calls within the driver. No
  new public entry points.
- **Backward compatibility.** No existing test breaks. No existing proof
  file fails to type-check.
- **Linear-time invariant.** New operations must be O(N) in term size.
  No quadratic traversals.

## References (optional reading)

- Lean 4: `src/kernel/quot.cpp`, `src/Init/Prelude.lean` (search `Quot`)
- Coq: `kernel/quotient.ml` (since 8.17)
- Lean 3 Quot inconsistency: `https://github.com/leanprover/lean/issues/1813`
- Doxa SPEC.md §8.2 (singleton elimination — the guard that prevents the Lean 3 bug)
