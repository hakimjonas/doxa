# Phase 24 Implementer Prompt

> Copy this message as a prompt to a fresh implementer session.
> After implementation, we audit together.

---

Implement Phase 24 (Well-Founded Recursion) for the Doxa proof checker.
Follow the plan in `docs/PHASE_24_IMPLEMENTATION_PLAN.md`. Read that
document first — it contains the design rationale and full step-level
detail. This prompt is the execution specification.

## Context

Doxa is a Dart monorepo with two packages:
- `doxa/` — kernel library (elaborator, parser, evaluator, type checker)
- `doxa_tooling/` — CLI, WASM, LSP, REPL, tests

Structural recursion (Phase 11) works: recursive `fun` declarations are
guarded by `VFun` which only unfolds when the decreasing argument is a
canonical constructor. Non-structural recursion (Ackermann, gcd) is
rejected by `_checkStructuralRecursion`.

Phase 24 adds `termination_by` annotation and the `Acc` accessibility
inductive, providing the infrastructure for well-founded recursion.
No kernel changes.

**Active branch:** `doxa-extended`

## Requirement

After Phase 24:
1. `Acc` inductive type exists in the prelude with auto-emitted
   `Acc.rec` recursor
2. `termination_by (a, b)` annotation parsed and stored on `SFunKind`
3. When `termination_by` is present on a `fun`:
   - Structural recursion check is SKIPPED
   - The function is emitted as NON-recursive (no VFun guard,
     no CorecursiveGroup)
4. Invalid `termination_by` parameter names produce clear errors
5. All 896 existing tests continue to pass
6. `lib/stdlib/prelude.doxa` type-checks with `Acc`

## Design (critical — follow exactly)

**No kernel changes.** Zero changes to `term.dart`, `eval.dart`,
`conv.dart`, `value.dart`. The `Acc` type is a regular `data`
declaration in the prelude — its recursor is auto-emitted via the
existing `_makeRecBindings` infrastructure.

**How `termination_by` interacts with the pipeline:**

When `_elabFunBlock` processes a member with `terminationBy != null`:
1. `_checkStructuralRecursion` is NOT called for that member (the
   structural sub-term check is for constructor-descending recursion;
   well-founded recursion doesn't need it)
2. `_hasRecursiveReference` returns `false` for that member (the
   function body references itself via `Acc.rec`, not direct `TTop`)
3. Because no member is flagged recursive, the block returns unguarded
   bindings — no `VFun` guard, no `CorecursiveGroup`
4. The function is a normal non-recursive lambda — it unfolds eagerly
   at eval time

**This means:** `termination_by` funs CANNOT use direct self-reference
(`TTop(funName)` in their body). They use `Acc.rec` manually. A future
session will add automatic desugaring that replaces recursive calls
with `Acc.rec` invocations. For now, the annotation provides the
infrastructure and `Acc` type.

## Files to Change (in order)

### 1. `doxa/lib/src/surface.dart` — `SFunKind.terminationBy`

Add field after `structAnn` (line ~745):

```dart
/// Well-founded termination measure: the value-parameter names
/// whose lexicographic tuple decreases at every recursive call.
/// When non-null, structural-recursion checking is skipped and
/// the binding is emitted non-recursive (the user writes recursion
/// via `Acc.rec`). All names must be value parameters of the fun.
final List<String>? terminationBy;
```

Add to constructor (currently 6 named params):

```dart
const SFunKind(
  this.name,
  this.typeParams,
  this.params,
  this.returnType,
  this.body, {
  this.isOpaque = false,
  this.structAnn,
  this.terminationBy,
});
```

Update `==` to compare `terminationBy` (use `_listEq` like `typeParams`/`params`).
Update `hashCode` to include `Object.hashAll(terminationBy ?? [])`.
Update `toString` to print `termination_by: $terminationBy` when non-null.

### 2. `doxa/lib/src/parse.dart` — Parse `termination_by (args)`

Add a parser combinator before `_mkFunBody`:

```dart
final Parser<ParseError, List<String>?> _terminationBy =
    _keyword('termination_by')
        .skipThen(_sym('('))
        .skipThen(_ident.sepBy(_sym(',')))
        .thenSkip(_sym(')'))
        .optional;
```

Locate `_mkFunBody` (around line 938). It's a flatMap chain that parses:
`name [typeParams] (valueParams) : returnType {struct}? = body`

Insert `_terminationBy` between `_structAnn` and `=`:

```dart
// In _mkFunBody's flatMap chain, after parsing structAnn:
// ...existing code that binds structAnn...
// NEW:
.flatMap(
  (structAnn) => _terminationBy.flatMap(
    (tby) => _sym('=').skipThen(/* ... body parsing ... */)
      .zip(/* ... span ... */)
      .map((pair) => SFunKind(
        name, typeParams, params, returnType, pair.$1,
        isOpaque: opaque, structAnn: structAnn,
        terminationBy: tby,  // NEW
      )),
  ),
)
```

The exact integration depends on the existing combinator structure
inside `_mkFunBody`. Follow the pattern used for `_structAnn` —
`_terminationBy` is another `.optional`-yielding combinator zipped
into the chain.

**Parser forms to support:**
```
fun f(x : Nat) : Nat := body                              -- no termination_by
fun f(x : Nat) : Nat {struct x} := body                    -- struct only
fun f(x : Nat) : Nat termination_by (x) := body            -- tby only
fun f(x : Nat) : Nat {struct x} termination_by (x) := body -- both (unusual)
```

### 3. `doxa_tooling/bin/doxa.dart` — Add `Acc` to prelude

Append to `_preludeSource` (lines 174-178):

```dart
const String _preludeSource = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}

data Acc[A: Type](R: A -> A -> Prop)(x: A) : Prop {
  acc_intro : ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
''';
```

**Important:** The `Acc` type uses `R: A -> A -> Prop` (a binary
Prop-valued relation on A) and `x: A` as parameters. The constructor
`acc_intro` says: if for all `y` such that `R y x` we have `Acc A R y`,
then `x` is accessible. This is the standard accessibility inductive
(see Paulin-Mohring 1993, Coq's `Init/Wf.v`).

### 4. `lib/stdlib/prelude.doxa` — Sync prelude

Add the same `Acc` declaration. The canonical source lives here; the
`_preludeSource` const in `doxa.dart` is a snapshot.

```
data Acc[A: Type](R: A -> A -> Prop)(x: A) : Prop {
  acc_intro : ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
```

### 5. `doxa/lib/src/elab.dart` — Error type

Add near `StructAnnotationNotFound` (which is around line 617):

```dart
final class TerminationByParamNotFound extends ElabError {
  final String funName;
  final String paramName;
  final DoxaSpan span;

  const TerminationByParamNotFound(this.funName, this.paramName, this.span);

  @override
  String get message => 'termination_by parameter "$paramName" not found '
      'in value parameters of fun "$funName"';
}
```

### 6. `doxa/lib/src/elab.dart` — `_elabFunBlock` changes

**Location:** Lines 3583-3737.

**6a. Validate termination_by parameters** (after line 3614)

After the `{struct}` validation loop, add a second loop:

```dart
// Validate termination_by parameter names.
for (final m in members) {
  final tby = m.fun.terminationBy;
  if (tby != null) {
    for (final p in tby) {
      if (_findParamIndex(m.fun, p) < 0) {
        throw TerminationByParamNotFound(m.fun.name, p, m.span);
      }
    }
  }
}
```

**6b. Skip structural recursion check** (modify line 3607-3615)

Currently:
```dart
for (final m in members) {
  _checkStructuralRecursion(m.fun, memberNames);
  // validate structAnn...
}
```

Change to:
```dart
for (final m in members) {
  if (m.fun.terminationBy == null) {
    _checkStructuralRecursion(m.fun, memberNames);
  }
  // validate structAnn (unchanged)...
}
```

**6c. Suppress recursion detection** (modify lines 3675-3679)

Replace:
```dart
final isRecursive = members.any(
  (m) =>
      _hasRecursiveReference(m.fun.body, memberNames) ||
      _hasRecursiveReference(m.fun.returnType, memberNames),
);
```

With:
```dart
final isRecursive = members.any(
  (m) =>
      m.fun.terminationBy == null &&
      (_hasRecursiveReference(m.fun.body, memberNames) ||
       _hasRecursiveReference(m.fun.returnType, memberNames)),
);
```

This ensures `termination_by` funs never produce a `CorecursiveGroup`
or get `VFun`-guarded.

### 7. Tests — `doxa_tooling/test/wf_recursion_test.dart`

New file following the pattern of existing test files. Use `runSource`
helper (copy from `namespace_test.dart` or `import_test.dart`).

Tests:
1. `Acc` type exists — `val x : Acc A R a` type-checks (parameterised Acc)
2. `acc_intro` constructor accessible — can reference `Acc.acc_intro`
3. `Acc.rec` recursor exists — can reference via `Acc.rec`
4. `termination_by` parsed on a simple non-recursive fun — parses OK
5. `fun f(x : Nat) : Nat := termination_by (x) = x` type-checks (non-recursive)
6. Invalid `termination_by` parameter → `TerminationByParamNotFound`
7. `termination_by` with multiple params parses — `termination_by (a, b)`
8. `termination_by` with `{struct}` — parses (both annotations)
9. Structural recursion still works — existing recursive funs pass
10. `Acc.acc_intro` has correct type — `(y: A) -> R y x -> Acc A R y`

### 8. Verify

```bash
dart analyze doxa/
dart analyze doxa_tooling/
dart run doxa_tooling:test -r expanded
dart format --set-exit-if-changed doxa/ doxa_tooling/
dart run doxa_tooling:bin/doxa check lib/stdlib/prelude.doxa
dart run doxa_tooling:bin/doxa check example/proofs.doxa
dart run doxa_tooling:bin/doxa check lib/stdlib/proofs.doxa
```

All 896 existing tests must pass.

## Edge Cases

1. **`Acc` singleton elimination.** `Acc` is Prop-sorted with 1
   constructor. The existing logic in `_makeRecBindings` detects
   this and emits both `Acc.rec` and `Acc.rect`. Verify `Acc.rect`
   is also usable (the additional binding won't hurt).

2. **`termination_by` with 0 params.** `termination_by ()` is valid
   (empty list). The parser should handle it — `_ident.sepBy(_sym(','))`
   with an empty list should produce `[]`. If the parser rejects empty
   parens, that's acceptable (the annotation is meaningless with no
   parameters).

3. **`termination_by` on a fun with no value params.** A fun like
   `fun f(A : Type) : Type := A` with `termination_by (x)` should
   error (no value params to select from). The `_findParamIndex` check
   catches this.

4. **`termination_by` in a mutual block.** If a mutual block has one
   member with `termination_by` and another without, the structural
   check runs only on the non-`tby` member. The `isRecursive` check
   excludes `tby` members. This is correct.

5. **`Acc` namespace.** With Phase 23, the prelude gets namespace
   prefix `Prelude`. `Acc` is accessible as both `Acc` (unqualified)
   and `Prelude.Acc` (qualified). The auto-emitted `Acc.rec` is
   accessible as `Acc.rec` and `Prelude.Acc.rec`. Tests can use
   either form.

6. **`Acc.rec` in types.** The recursor type involves the motive sort.
   Since `Acc` is Prop-sorted, `Acc.rec`'s motive sort is Prop
   (default). The auto-emission logic in `_makeRecBindings` handles
   this — verify `Acc.rec` typechecks by using it in a type annotation.

7. **Parser: `termination_by` vs `struct` ordering.** Both are optional.
   The parser must handle:
   - Neither: standard `fun`
   - `{struct x}` only: structural
   - `termination_by (x)` only: well-founded
   - Both: unusual but valid (the `termination_by` wins — structural check skipped)

## Sanity Check During Audit

When we audit, verify:
- [ ] `dart analyze` 0 issues in both packages
- [ ] `dart format` clean
- [ ] All 896 existing tests pass
- [ ] New wf_recursion tests pass
- [ ] `lib/stdlib/prelude.doxa` type-checks (now has `Acc`)
- [ ] `example/proofs.doxa` type-checks
- [ ] `lib/stdlib/proofs.doxa` type-checks
- [ ] `Acc` type and constructor exist in prelude
- [ ] `Acc.rec` recursor binding emitted + type-checks
- [ ] `Acc.rect` (if emitted) type-checks
- [ ] `termination_by (args)` parsed correctly (all 4 combinations with `struct`)
- [ ] Invalid param name produces `TerminationByParamNotFound`
- [ ] `_checkStructuralRecursion` skipped when `terminationBy != null`
- [ ] `_hasRecursiveReference` returns false for `terminationBy` funs
- [ ] No `CorecursiveGroup` emitted for `terminationBy`-only blocks
- [ ] No `VFun` guard stamped on `terminationBy` funs
