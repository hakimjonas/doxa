# Phase 16 — SProp + Strict Proof Irrelevance

## Part A: Design Note (prior-work study)

### Reference models

**Lean 4:** SProp is NOT a kernel-level sort. The kernel has a single `Sort u` constructor
(where `0` = Prop, `1+` = Type). SProp in Lean 4 is an ELABORATOR concept — certain
inductives are marked as `is_SProp` and the elaborator enforces stricter elimination rules.
The kernel's `is_def_eq_proof_irrel` only fires for `Sort 0` (Prop). Source: `kernel/expr.h`
(`mk_Prop()` = `mk_sort(mk_level_zero())`), `kernel/type_checker.cpp:is_def_eq_proof_irrel`.

**Gilbert et al. 2019** (POPL paper): Provides the theoretical framework for strict
proof irrelevance without K. Two SProp values are definitionally equal regardless of
their content. SProp inductives have restricted elimination — can only eliminate
into SProp (no large elimination into Type).

### Decision: Kernel-level SProp as a distinct sort

**Rationale:**

1. **Follows existing Doxa architecture.** Doxa already has separate `VProp` / `VType` value
   types (not just `Sort u` levels). Adding `VSProp` / `TSProp` is the natural extension.

2. **Simpler than Lean 4's approach.** Lean 4 defers SProp to the elaborator, requiring
   a separate `is_SProp` flag on inductive declarations and per-declaration checks.
   Doxa's kernel-level approach puts the enforcement directly in the converter where
   it's guaranteed correct.

3. **Strict irrelevance is a conversion rule.** The key SProp property — any two SProp
   values are definitionally equal — is a conversion rule. Putting it in the kernel's
   `_Conv` is the right layer.

4. **Small scope.** The Gilbert et al. design is additive — it extends the existing
   CIC rules with one new sort and one new conversion short-circuit. It does NOT
   change existing Prop or Type behavior.

### SProp semantics

| Aspect | Prop | SProp | Type n |
|--------|------|-------|--------|
| Proof irrelevance | Yes (per-declaration, registry-gated) | Yes (strict, definitional) | No |
| Singleton elimination | Yes (one-ctor, non-informative args) | No (elim into SProp only) | N/A |
| Pi sort: cod in X | Pi : X | Pi : SProp | Pi : Type n |
| Pi sort: Type m → X | Pi : max(m, level(X)) | Pi : max(m, 0) = Type m | Pi : Type max(m, n) |
| PTS: two X sort values | Propositionally equal | Definitionally equal | Distinct |

### Key implementation differences from Prop

1. Prop irrelevance uses `_mismatchOrIrrelevance(a, b, dataDecls)` — a fallback at
   conversion mismatch sites that checks if BOTH types are Prop-sorted via the registry.
   SProp irrelevance does NOT need the registry — two SProp values are equal by
   construction, no type lookup required.

2. In `_Conv`, add an EARLY case:
   ```dart
   case (VSProp(), VSProp()):
     step = const _YieldC(_ok);  // strict irrelevance
   ```
   This fires BEFORE any structural comparison. Two SProp values converge immediately.

3. For `VSProp × non-SProp`: structural mismatch. SProp and Prop are DISTINCT sorts.

---

## Part B: Implementation Plan (~150 lines, 4-6 sessions)

### Step 0 — Kernel term/value forms (`term.dart`, `value.dart`)

#### 0a. `TSProp` (term.dart)

Add alongside `TProp`:

```dart
/// The SProp universe sort. SProp is strict: any two SProp values
/// are definitionally equal (Gilbert et al. 2019).
final class TSProp extends Term {
  const TSProp();

  @override
  bool operator ==(Object other) => other is TSProp;

  @override
  int get hashCode => Object.hash('TSProp', 0);

  @override
  String toString() => 'TSProp';
}
```

Update `openTerm`/`closeTerm` — `TSProp` is a leaf (no subterms).

#### 0b. `VSProp` (value.dart)

Add alongside `VProp`:

```dart
/// The SProp sort value. Two VSProp values are definitionally equal
/// (strict proof irrelevance).
final class VSProp extends Value {
  const VSProp();

  @override
  bool operator ==(Object other) => other is VSProp;

  @override
  int get hashCode => Object.hash('VSProp', 0);

  @override
  String toString() => 'VSProp';
}
```

---

### Step 1 — Converter changes (`eval.dart`, ~30 lines)

#### 1a. `_Conv` early short-circuit for SProp (add BEFORE the structural switch)

In the `_Conv` case, after meta-forcing and VDelayed handling, before `switch ((a, b))`:

```dart
// Strict proof irrelevance: any two SProp values are
// definitionally equal regardless of their internal structure.
// This fires before the structural switch, so SProp-to-SProp
// comparison never descends into inner terms.
if (a is VSProp && b is VSProp) {
  step = const _YieldC(_ok);
  break;
}
```

This is the KEY change. It means:
- `VSProp()` conv `VSProp()` → Ok (both are the SProp sort)
- A data declaration in SProp with multiple ctors: `ctor1` conv `ctor2` → the values
  are `VConstr(...)` whose types are `VSProp`, so they have been flagged by
  `_isProofIrrelevantType`, and the mismatch site passes through `_mismatchOrIrrelevance`
  which now also checks SProp.

Wait — the mismatch site check needs updating too. See 1c.

#### 1b. `_Conv` structural switch: add `VSProp × VSProp` case

```dart
case (VSProp(), VSProp()):
  step = const _YieldC(_ok);
```

This handles the case where both sides reach the structural switch as `VSProp`.
It's redundant with 1a for pure `VSProp` values but needed for consistency.

Also add mismatch cases:

```dart
// VSProp vs VType or VProp: distinct sorts
case (VSProp(), VType()):
case (VType(), VSProp()):
case (VSProp(), VProp()):
case (VProp(), VSProp()):
  step = _YieldC(ConvMismatch(a, b));
```

#### 1c. `_mismatchOrIrrelevance` and `_isPropSorted` — extend to SProp

Rename `_isPropSorted` to `_isProofIrrelevantSort` or add a parallel check:

```dart
/// True iff [type] is SProp-sorted. SProp values are definitionally
/// equal — no registry needed.
bool _isSPropSorted(Value type, List<DataDecl> dataDecls) {
  switch (type) {
    case VSProp(): return true;   // It IS SProp itself
    case VData(:final name):
      for (final d in dataDecls) {
        if (d.name == name) return d.sort is TSProp;
      }
      return false;
    case VPi():
      return _isSPropSortedTerm(type.codomain.body, type.codomain.env.dataDecls);
    default: return false;
  }
}
```

In `_mismatchOrIrrelevance`:
```dart
// Existing Prop check:
if (ta != null && _isPropSorted(ta, dataDecls) &&
    tb != null && _isPropSorted(tb, dataDecls)) {
  return const ConvOk();
}
// New SProp check:
if (ta != null && _isSPropSorted(ta, dataDecls) &&
    tb != null && _isSPropSorted(tb, dataDecls)) {
  return const ConvOk();
}
```

Note: the SProp check does NOT gate on `dataDecls != null` — SProp irrelevance
is strict and unconditional. But we still need dataDecls to resolve `VData` names.

#### 1d. `_Subtype` — add SProp rules

```dart
case (VSProp(), VSProp()):
  step = const _YieldC(_ok);

// SProp ≤ Prop (SProp eliminates into Prop)
case (VSProp(), VProp()):
  step = const _YieldC(_ok);

// Prop ≤ SProp? NO — Prop does not eliminate into SProp.
case (VProp(), VSProp()):
  step = _YieldC(ConvMismatch(got, expected));
```

Actually, the relationship should be: SProp is below Prop in the sort hierarchy.
`SProp ≤ Prop` allows SProp terms to be used where Prop terms are expected
(SProp is stricter, so it's a subtype). `Prop ≰ SProp` — Prop terms carry
more information and can't be used as SProp terms.

Wait, that's not right either. SProp is STRICTER — all values are equal. So
SProp is a MORE restrictive sort. `SProp ≤ Prop` makes sense: an SProp term
can be viewed as a Prop term (all its equalities still hold). But `Prop ≰ SProp`
since Prop doesn't enforce strictness.

For now: SProp ≤ Prop, nothing else. This matches the POPL 2019 paper.

#### 1e. `_Sort` / `_asSort` / `_sortToValue` — add SProp

```dart
final class _SProp extends _Sort {
  const _SProp();
}
const _SProp _sPropSort = _SProp();
```

In `_asSort`:
```dart
VSProp() => _sPropSort,
```

In `_sortToValue`:
```dart
_SProp() => const VSProp(),
```

#### 1f. `_piSort` — handle SProp codomain

```dart
Value _piSort(_Sort domSort, _Sort codSort) {
  if (codSort is _Prop || codSort is _SProp) {
    // Impredicative: Pi is in the same impredicative sort as its codomain.
    return codSort is _Prop ? const VProp() : const VSProp();
  }
  // codSort is Type m
  final codLevel = (codSort as _TypeN).level;
  final domLevel = domSort is _Prop || domSort is _SProp
      ? _l0
      : (domSort as _TypeN).level;
  return VType(_normalizeLevel(LMax(domLevel, codLevel)));
}
```

#### 1g. `_Infer` for `TSProp`

```dart
case TSProp():
  // SProp : Type 1 (same as Prop : Type 1)
  step = const _YieldV(_vType1);
```

#### 1h. `_inferValueType` for `VSProp`

```dart
case VSProp():
  return _vType1;
```

#### 1i. Quote handling

In `_Quote`:
```dart
case VSProp():
  step = const _YieldT(TSProp());
```

#### 1j. Eval handling

In `_Eval`:
```dart
case TSProp():
  step = const _YieldV(VSProp());
```

---

### Step 2 — Elaborator + surface syntax (~20 lines)

#### 2a. `SSPropKind` (surface.dart)

Add alongside `SPropKind`:

```dart
/// The `SProp` sort literal.
final class SSPropKind extends SExprKind {
  const SSPropKind();

  @override
  bool operator ==(Object other) => other is SSPropKind;

  @override
  int get hashCode => Object.hash('SSPropKind', 0);

  @override
  String toString() => 'SSPropKind';
}
```

#### 2b. Parser (parse.dart)

Add `SProp` keyword handler alongside `Prop`:

```dart
// In the atom parser, alongside the _keyword('Prop') handler:
_keyword('SProp').map<SExprKind>((_) => const SSPropKind()),
```

#### 2c. Elaborator (elab.dart)

Handle `SSPropKind` in `_inferExpr` (same pattern as `SPropKind`):

```dart
case SSPropKind():
  return (const TSProp(), _vType1);
```

---

### Step 3 — SProp inductive support (~40 lines)

#### 3a. Data declaration sort

When a `data` is declared with sort `SProp`:
- All constructor argument types must be SProp-sorted (no Type-sorted args)
- Singleton elimination DOES NOT apply (SProp data can only eliminate into SProp)
- The recursor's motive sort is restricted to SProp

In `_elabData` / `_validateCtorArgs`, add check:
```dart
if (dataSort is TSProp) {
  // Verify all ctor fields are SProp-sorted
  for (final field in ctorArgs) {
    if (!_isSPropSortedTerm(field.type, dataDecls)) {
      throw SPropFieldNotProofIrrelevant(field.name);
    }
  }
}
```

#### 3b. Recursor generation for SProp data

In `_makeRecBindings`:
- For SProp-sorted data, emit only the default `.rec` (no `.ind`/`.rect`)
- The motive sort stays as SProp

```dart
if (dataDecl.sort is TSProp) {
  // SProp data: only eliminate into SProp
  bindings.add(TopBinding(
    name: '${dataDecl.name}.rec',
    type: synthRecursorType(dataDecl, motiveSort: const TSProp()),
    term: TRec(dataDecl.name, motiveSort: const TSProp()),
    span: span,
  ));
  // No .ind/.rect for SProp data
}
```

#### 3c. Conversion for SProp data constructors

SProp data constructors are automatically equal via the `_mismatchOrIrrelevance`
fallback (since their type is SProp-sorted). No special handling needed — the
existing `VConstr × VConstr` path fires the mismatch, then `_mismatchOrIrrelevance`
admits by SProp sorting.

---

### Step 4 — Tests (~60 lines, `doxa/test/sprop_test.dart`)

| # | Test | Expected |
|---|------|----------|
| 1 | `VSProp() conv VSProp()` | ConvOk (strict irrelevance) |
| 2 | `VSProp() conv VProp()` | ConvMismatch (distinct sorts) |
| 3 | `VType(LLevel(0)) conv VSProp()` | ConvMismatch (Type vs SProp) |
| 4 | SProp data: two distinct proofs conv | ConvOk (with dataDecls, SProp irrelevance fires) |
| 5 | SProp data: ctor field must be SProp-sorted | Rejected by elaborator |
| 6 | SProp data: `.rec` exists, no `.ind`/`.rect` | Only `.rec` emitted |
| 7 | Pi type: `(x: Type 0) → SProp` | Pi sort is Type 0 (domain Type → SProp = max(0, 0) = Type 0) |
| 8 | Pi type: `(x: SProp) → SProp` | Pi sort is SProp (impredicative) |
| 9 | `TSProp()` parsed and elaborated | Yields `TSProp`/`VSProp` |
| 10 | Regression: all existing Prop tests pass | No behavioral change for Prop |

---

### Step 5 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 383 existing doxa tests pass. New SProp tests pass (10 tests).
`dart format --set-exit-if-changed` clean in both packages.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/term.dart` | `TSProp` class. `openTerm`/`closeTerm` handler. | +15 |
| `doxa/lib/src/value.dart` | `VSProp` class. | +15 |
| `doxa/lib/src/eval.dart` | SProp early conv short-circuit. `_Sort._SProp`. `_asSort`/`_sortToValue`/`_piSort`/`_Infer`/`_inferValueType`/`_Quote`/`_Eval`. `_isSPropSorted`. `_mismatchOrIrrelevance` SProp case. `_Subtype` SProp rules. | +50 |
| `doxa/lib/src/surface.dart` | `SSPropKind`. | +10 |
| `doxa/lib/src/parse.dart` | `SProp` keyword parser. | +3 |
| `doxa/lib/src/elab.dart` | `SSPropKind` elaboration. SProp data validation. Recursor restriction. `_computePiSort` SProp case. | +25 |
| `doxa/lib/src/pretty.dart` | `SProp` pretty-printing. | +5 |
| `doxa/test/sprop_test.dart` | **New file** — 10 tests. | +60 |
| **Total** | | **~183** |

---

## Risk assessment

**Risk: Very Low.** SProp is purely additive — no existing code paths change.
- Prop irrelevance uses a registry-gated check; SProp uses a different
  short-circuit early in `_Conv`. They are independent.
- `VSProp` and `VProp` are distinct types; no existing code matches `VSProp`
  via wildcard patterns (the sealed switch match already handles this).
- SProp inductive data is gated by the elaborator, not the kernel.
- The existing `SPropKind` surface node for `Prop` is untouched.

**Mitigation:** All new code is in `_Conv` early-exit paths and new switch cases.
The existing `_mismatchOrIrrelevance` function gains one new conditional.
No existing test should need modification.
