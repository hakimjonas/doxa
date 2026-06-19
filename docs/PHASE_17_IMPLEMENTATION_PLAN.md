# Phase 17 — Primitive Projections + Definitional η

## Part A: Design Note (prior-work study)

### Reference models

**Lean 4:** Records are single-constructor non-recursive inductives with primitive projections.
The kernel has:
- `Proj(sname, idx, e)` term form — projects the `idx`-th field from `e` of structure `sname`
- `expand_eta_struct(env, e_type, e)` — η-expands `e` to `mk e.1 e.2 ... e.n`
- `try_eta_struct_core(t, s)` in `is_def_eq_core` — checks if `s` is the form `mk t.1 t.2 ... t.n`
- `is_non_rec_structure(env, name)` — predicate for single-ctor, no-indices, non-recursive

Source: `kernel/expr.h` (`mk_proj`), `kernel/inductive.cpp` (`expand_eta_struct`, `is_non_rec_structure`),
`kernel/type_checker.cpp` (`try_eta_struct_core`, `reduce_proj_core`).

**Coq:** `Set Primitive Projections` flag on record definitions. Projections become kernel-level
primitives (not encoded as match expressions). η-conversion applies: `r ≡ {| field1 := r.field1; ... |}`.

**Gilbert et al. 2019** (POPL): Primitive projections are a prerequisite for SProp's strict
proof irrelevance in record types. Without primitive projections, record η cannot be enforced
without exposing the record's internal structure.

### Decision: Primitive projections on single-constructor data types

**Rationale:**

1. **Reuses existing infrastructure.** Doxa's `VConstr` value form already carries fields
   positionally. No new value form needed — just add a projection term form that extracts
   from `VConstr` by field name/index.

2. **Minimal kernel change.** The main additions are:
   - `TProj` term form + `NProj` neutral form
   - Projection reduction: `apply(VConstr(...), fieldName)` → extracts the field
   - η in `_Conv`: `VConstr × non-VConstr` where the type is a record → project fields
   - One predicate: `_isRecordData(DataDecl)` checks single-ctor + non-recursive + no indices

3. **Matches Lean 4 and Coq design.** Both systems treat records as single-ctor inductives
   with primitive projections. This is the standard, proven approach.

4. **No new surface syntax keyword.** Field access reuses the existing `.` syntax (already
   used for `Nat.rec`-style name qualification). The elaborator disambiguates: if the qualifier
   is a term of record type, `.field` is a projection; otherwise it's a name-qualification.

### Semantics

```
data Pair[A B: Type] : Type {
   mk : A -> B -> Pair A B;
}

// Projection reduction:
eval(TProj(VConstr("Pair", "mk", [A, B, a, b]), "fst"))  →  a   (the first non-param arg)
eval(TProj(VConstr("Pair", "mk", [A, B, a, b]), "snd"))  →  b

// η-conversion:
conv(p, VConstr("Pair", "mk", [A, B, proj(p, "fst"), proj(p, "snd")]))  →  ConvOk
//    where p is a neutral value and both sides have type Pair A B
```

Key constraints:
- Projections only defined for **declared records** (single-ctor, non-recursive, no-indices data types)
- The projection extracts the N-th non-param argument of the constructor
- η applies when one side is a canonical VConstr and the other is convertible to the η-expanded form

---

## Part B: Implementation Plan (~200 lines, 6-8 sessions)

### Step 0 — Kernel term/neutral forms (`term.dart`, `value.dart`)

#### 0a. `TProj` term form (term.dart)

Place near `TApp` (line ~390), as another eliminator form:

```dart
/// Primitive projection: `e.field` for a record.
final class TProj extends Term {
  /// The record expression being projected from.
  final Term expr;

  /// The field name.
  final String fieldName;

  const TProj(this.expr, this.fieldName);

  @override
  bool operator ==(Object other) =>
      other is TProj && other.expr == expr && other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash('TProj', expr, fieldName);
}
```

Update `openTerm`/`closeTerm` — `TProj` recurses into `expr`.

#### 0b. `NProj` neutral form (value.dart)

Place in the `Neutral` hierarchy alongside `NApp`:

```dart
/// A stuck primitive projection: `neutral.fieldName`.
final class NProj extends Neutral {
  /// The stuck record expression being projected from.
  final Value expr;

  /// The field name being accessed.
  final String fieldName;

  const NProj(this.expr, this.fieldName);

  @override
  bool operator ==(Object other) =>
      other is NProj && other.expr == expr && other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash('NProj', expr, fieldName);
}
```

#### 0c. `_isRecordData` predicate (eval.dart)

```dart
/// True iff [dataDecl] is a record: single constructor, non-recursive, no indices.
bool _isRecordData(DataDecl dataDecl) =>
    dataDecl.ctors.length == 1 && dataDecl.indices.isEmpty;
```

The non-recursive check is handled naturally — if the type appears in its own constructor
arguments, it's recursive and `_isRecordData` returns `false`. In Doxa's auto-generated
recursors, the `is_rec` flag on `DataDecl` tells us. We add a field check:

Actually, use the existing `DataDecl` fields. The recursor's `is_rec` is in `registry.dart`.
For the conversion check, we need to resolve the data decl from the VConstr's name
via `topEnv.dataDecls` or the loop-local registry. Add a helper:

```dart
DataDecl? _lookupData(String name, List<DataDecl> dataDecls) {
  for (final d in dataDecls) {
    if (d.name == name) return d;
  }
  return null;
}
```

---

### Step 1 — Evaluation and quote (`eval.dart`, ~40 lines)

#### 1a. `_Eval` dispatch for `TProj`

```dart
case TProj(:final expr, :final fieldName):
  stack.add(_EvalProj(fieldName));
  step = _Eval(expr, env);
```

New frame:
```dart
final class _EvalProj extends _Frame {
  final String fieldName;
  const _EvalProj(this.fieldName);
}
```

Frame yield handler in `_YieldV`:
```dart
case _EvalProj(:final fieldName):
  step = _YieldV(NProj(value, fieldName));
  // Projections stay as stoout neutrals until applied to a VConstr
```

Wait — projection should reduce immediately when the expr is a `VConstr`. So:

```dart
case _EvalProj(:final fieldName):
  if (value is VConstr) {
    step = _YieldV(_projectField(value, fieldName));
  } else {
    step = _YieldV(VNeutral(NProj(value, fieldName)));
  }
```

#### 1b. `_projectField` helper

```dart
/// Extract field [fieldName] from a VConstr by field index.
/// The VConstr's args are [params..., fields...].
Value _projectField(VConstr v, String fieldName) {
  // Look up the data decl to find field index
  // Fields are at positions [paramCount ... paramCount + fieldCount]
  // ...
}
```

Actually, VConstr stores args as `[params..., field0, field1, ...]`. To extract by name,
we need the DataDecl's constructor to map field names to positions. The CtorDecl has
`args: Telescope` — each entry has a name. Fields are at positions `paramCount + i`.

Transition: store the field INDEX in the neutral, not the field NAME. Look up the name→index
mapping once during evaluation, and carry the index. This avoids repeated lookups:

```dart
final class NProj extends Neutral {
  final Value expr;
  final int fieldIndex;  // position in VConstr.args (after params)
  final String fieldName; // diagnostic only
}
```

But for a simple first pass, store the field name and look up each time. Optimization deferred.

#### 1c. `_Apply` dispatch for `NProj`

When `NProj(value, fieldName)` is applied (e.g., as part of a spine), the projection
stays stuck — projections extract from the record, they don't take arguments.

Actually, `NProj` is NOT applicable — it's a value, not a function. Skip apply handling.

Wait, the projection IS the term. `TProj(e, field)` evaluates to either a field value
or a stuck `NProj(e, field)`. The stuck form is wrapped in `VNeutral(NProj(...))`.
When `VNeutral(NProj(e, field))` appears in a spine (applied to something), the `_Apply`
dispatch extends the neutral's spine to `VNeutral(NApp(NProj(e, field), arg))`. This is correct.

#### 1d. `_Quote` dispatch for `NProj`

In the VNeutral quoting path (eval.dart:2848), add the `NProj` case:

```dart
case NProj(:final exprV, :final fieldName):
  step = _YieldT(TProj(
    quote(level, exprV),
    fieldName,
  ));
```

#### 1e. `_Infer` for `TProj`

In the `_Infer` dispatch:
```dart
case TProj(:final expr, :final fieldName):
  // Infer the type of expr, it must be a record type (VData with single ctor).
  // Then look up the field's type from the ctor decl.
  stack.add(_InferProjFieldType(ctx, fieldName));
  step = _Infer(ctx, expr);
```

The type of `e.field` is the type of the `fieldName`-th field in the record's constructor.

---

### Step 2 — Conversion η rule (`eval.dart`, ~40 lines)

#### 2a. Record η: VConstr × non-VConstr where type is a record

In the `_Conv` dispatch, add BEFORE the structural switch (after the VFun handling):

```dart
// Record η: if one side is a VConstr from a record type and
// the other side is not a VConstr, η-expand by projecting all
// fields from both sides and comparing pointwise.
if (a is VConstr && b is! VConstr) {
  final dDecl = _lookupData(a.dataName, dataDecls ?? const []);
  if (dDecl != null && _isRecordData(dDecl)) {
    // Project each field from b and build a VConstr to compare
    final fields = <Value>[];
    final ctor = dDecl.ctors.first;
    for (var i = 0; i < ctor.args.length; i++) {
      // a already has fields at positions [params...]
      fields.add(a.args[dDecl.params.length + i]);
    }
    // Compare a against a rebuilt VConstr with fields projected from b
    // Actually, the simpler approach: compare each field individually
    final pending = <_Frame>[];
    for (var i = 0; i < ctor.args.length; i++) {
      final projB = VNeutral(NProj(b, ctor.args[i].name));
      pending.add(_ConvThen(_Conv(
        a.args[dDecl.params.length + i],
        projB,
        level,
      )));
    }
    // Schedule in reverse for forward-order comparison
    for (final f in pending.reversed) {
      stack.add(f);
    }
    step = const _YieldC(_ok); // head succeeds, ConvThen checks fields
    break;
  }
}
// Symmetric: b is VConstr, a is not
if (b is VConstr && a is! VConstr) {
  // ... same logic, swapped
}
```

This implements: if we have `VConstr(data, ctor, [params..., f0, f1])` on one side
and something else (neutral, lambda, stuck rec/match) on the other, AND the data type
is a record, then project each field from the non-VConstr side and compare pointwise.
This is η: the constructor's fields must match the projections.

Note: This approach projects from `b` into the structure of `a`. A more complete
η would build `VConstr(data, ctor, [params..., proj(b, f0), proj(b, f1)])` and compare.
But constructing a VConstr in the conv loop is tricky. The field-by-field approach
works because constructor injectivity already establishes the forward direction.

Wait — actually, the simpler and more correct approach: on `VConstr × non-VConstr`,
push the non-VConstr side through η-expansion by comparing fields pointwise.
Since we're comparing `conv(VConstr, b)`, we check if the VConstr's fields convert
with projections of `b`. If all fields match, the η-expanded form `mk(b.f0, b.f1, ...)`
converts with the VConstr. This is correct by constructor injectivity.

#### 2b. Record η: VConstr × VConstr (already handled)

The existing `VConstr × VConstr` case at lines 1948-1962 already compares fields
pointwise. No change needed for the VConstr × VConstr case.

#### 2c. `_Subtype` η for records

In `_Subtype`, records follow standard subtype delegation to conv. No special rules.

---

### Step 3 — Elaborator + surface syntax (~40 lines)

#### 3a. Projection disambiguation in dot syntax

The existing `.` syntax parses `expr.ident` as `SDotKind(expr, name)`. The elaborator
currently flattens dots into a single qualified name (`Nat.rec` → `TTop("Nat.rec")`).
For field projection, we need to:

1. Elaborate `expr` first (get its type)
2. If the type is a record type (VData with single ctor), resolve `.name` as a field projection
3. Otherwise, resolve as name qualification (existing behavior)

In `_inferExpr` / `_checkExpr` for `SDotKind`:

```dart
case SDotKind(:final qualifier, :final name):
  final (qualT, qualV) = _inferExpr(state, qualifier);
  // Check if qualV is a record type
  if (qualV is VData && _isRecord(qualV.name, state.topEnv.dataDecls)) {
    // Field projection
    return (TProj(qualT, name), _fieldType(qualV.name, name, state.topEnv.dataDecls));
  }
  // Fall through: name qualification
  final flat = _flattenDottedIdent(expr);
  if (state.topEnv.indexOfFromEnd(flat) < 0) {
    throw UnresolvedName(flat, expr.span);
  }
  return (TTop(flat), _typeForName(state, flat));
```

#### 3b. `_isRecord` helper (elab.dart)

```dart
bool _isRecord(String dataName, List<DataDecl> dataDecls) {
  for (final d in dataDecls) {
    if (d.name == dataName) return _isRecordData(d);
  }
  return false;
}
```

#### 3c. No new surface syntax keyword

Records are declared using the existing `data` syntax. The elaborator detects
single-ctor non-recursive data types and enables projections automatically.
This matches Lean 4's approach — `structure` is sugar that desugars to `inductive`.

---

### Step 4 — Tooling updates (`doxa_tooling`, ~15 lines)

#### 4a. `DoxaToken` (syntax.dart)

No new keyword needed — projections use existing `.`. But add `TProj` to the term
syntax enum if needed for CST.

#### 4b. `web_check.dart`

Add `TProj` to any exhaustive switch on `Term` subclasses:

```dart
// In the term-formatter switch:
TProj _ => 'proj',
```

#### 4c. `meta.dart` — `inlineSolvedMetas`

Add `TProj` to the sealed switch for meta-inlining:

```dart
TProj(:final expr, :final fieldName) =>
    TProj(walk(expr), fieldName),
```

---

### Step 5 — Tests (`doxa/test/record_test.dart`, ~80 lines)

| # | Test | Expected |
|---|------|----------|
| 1 | Projection from VConstr: `Pair.mk(a, b).fst` evaluates to `a` | VConstr field extracted |
| 2 | Projection from stuck neutral: `p.fst` stays as NProj | Stuck neutral |
| 3 | η: `p` conv `mk(p.fst, p.snd)` where `p` is neutral of record type | ConvOk |
| 4 | η: `Pair.mk(a, b)` conv `Pair.mk(a, b)` (existing VConstr × VConstr) | ConvOk (already works) |
| 5 | Projection type inference: `(mk a b).fst : A` | Type is first field type |
| 6 | `p.fst.snd` nested projection | Works on stuck neutral |
| 7 | Record used in `fun` argument position, projected in body | Type-checks |
| 8 | Non-record dot: `Nat.rec` still works as name qualification | Backward compat |
| 9 | Regression: all existing proofs type-check | No breakage |
| 10 | `struct` declaration desugars to `data` with single ctor | Future: sugar layer |

---

### Step 6 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 406 existing doxa tests pass. New record tests pass (10 tests).
`dart format --set-exit-if-changed` clean.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/term.dart` | `TProj` class. `openTerm`/`closeTerm` handler. | +20 |
| `doxa/lib/src/value.dart` | `NProj` neutral class. | +15 |
| `doxa/lib/src/eval.dart` | `_EvalProj` frame. `_projectField`. `_Infer` for TProj. `_Quote` for NProj. Record η in `_Conv`. `_isRecordData` predicate. All NProj switch cases. | +60 |
| `doxa/lib/src/elab.dart` | Projection disambiguation in `SDotKind` elaboration. `_isRecord` helper. `TProj` in meta-inlining. | +25 |
| `doxa/lib/src/meta.dart` | `TProj` in `inlineSolvedMetas` / `inlineSolvedBareMetas`. | +5 |
| `doxa/lib/src/pretty.dart` | `TProj` pretty-printing. | +5 |
| `doxa_tooling/lib/src/web_check.dart` | `TProj` in term-formatter switch. | +2 |
| `doxa_tooling/lib/src/syntax.dart` | If needed for CST (NProj neutral). | +3 |
| `doxa/test/record_test.dart` | **New file** — 10 tests. | +80 |
| **Total** | | **~215** |

---

## Risk assessment

**Risk: Low-Medium.** The main risk is the dot-syntax disambiguation — name-qualified
`.rec` vs field-projection `.field`. Mitigation: the elaborator resolves the qualifier's
type first; if it's a record, use projection; otherwise use name qualification.
This is the standard approach in both Lean 4 and Coq.

Backward compatibility risk: if a dot-qualified name happens to resolve against a record
type first, existing `Nat.rec`-style notation could break. Mitigation: the check is
AFTER elaboration of the qualifier — `Nat` elaborates to `VType(0)`, not a record,
so `Nat.rec` continues to work as name qualification.

The sealed class additions (`TProj`, `NProj`) are purely additive — no existing code
paths change. The η rule in `_Conv` only fires for VConstr × non-VConstr with record
types, which is a new case.
