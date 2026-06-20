# Phase 24 — Well-Founded Recursion (Infrastructure)

## Goal

Write functions that terminate by a well-founded measure (Euclid's
algorithm, Ackermann) with a `termination_by` annotation. Desugars to
`Acc.rec` — no kernel changes.

## Why Now

The plan deferred this to "after Phase 20 (tactics)." Tactics (Phase 20)
can synthesize `Acc.rec` proof terms. The elaborator just needs a
desugaring pass that replaces recursive calls with accessibility-recursor
invocations. Structural recursion (Phase 11) already provides the
termination-checker infrastructure; `termination_by` bypasses the
structural check for non-constructor-based recursion.

## Current State

**`Acc` does not exist.** No accessibility inductive type is defined.

**No `termination_by` syntax.** The only termination annotation is
`{struct name}` (Phase 11), which selects the decreasing argument for
structural recursion. The `_checkStructuralRecursion` checker demands
every recursive call's decreasing argument be a strict syntactic
sub-term of the designated parameter — anything else is rejected.

**Structural recursion only.** `_elabFunBlock`:
1. Runs `_checkStructuralRecursion` on every member's body/return-type
   before elaborating any body (early rejection of non-structural code).
2. If the block has actual recursion (`_hasRecursiveReference`), stamps
   each member with `recDecreasingArg`/`recArity` so eval produces a
   guarded `VFun` that stays stuck until the decreasing argument is a
   canonical constructor.
3. If non-recursive, emits plain unguarded bindings.

**VFun guard.** The `VFun` mechanism (eval.dart) checks `spine[decreasingArg]
is VConstr` before unfolding. Non-structural recursion (e.g., Ackermann's
inner call `ack m n'` where the first argument is unchanged) would fail
this guard — the VFun stays stuck forever.

## Design Decisions

**`Acc` in the prelude.** A minimal accessibility inductive, added to
the const `_preludeSource` string in `doxa.dart` (and the canonical
`lib/stdlib/prelude.doxa` for sync). Auto-emission produces `Acc.rec`
as a usable recursor.

**`termination_by` as infrastructure.** Phase 24 provides the annotation
syntax and bypasses the structural recursion check. The function is
emitted as non-recursive (no `VFun` guard, no `CorecursiveGroup`). Users
write recursion manually via `Acc.rec` with tactics, using the pattern:

```
fun f(args) : T := termination_by (a, b) = by {
  -- Use Acc.rec with a measure on a, b
}
```

**The full desugaring** (elaborator synthesizes `Acc.rec` calls
automatically) is deferred to a follow-on session. Phase 24 provides
the building blocks: `Acc` type, `termination_by` syntax, structural
check bypass, and a verified example.

**Measure syntax.** `termination_by (id, id, ...)` — a parenthesized
list of parameter names that form the lexicographic decreasing measure.
These names MUST exist as value parameters of the function.

**No kernel changes.** `Acc` is a regular `data` declaration. The
auto-emitted `Acc.rec` is a regular `TRec` term. No new term/value
forms needed.

## Deliverables

1. `Acc` inductive in the prelude.
2. `termination_by (arg1, arg2)` annotation parsed and stored on
   `SFunKind`.
3. When `termination_by` is present on a `fun` that references itself:
   - Structural recursion check is **skipped** for that function
   - The function is emitted as **non-recursive** (no `VFun` guard,
     no `CorecursiveGroup` — the `recDecreasingArg`/`recArity` fields
     are null)
   - `_hasRecursiveReference` returns `false` for the function (the
     body references itself via `Acc.rec`, not direct `TTop`)
4. When `termination_by` is present but the function has no
   self-references: emit normally (non-recursive, unguarded).
5. Validation: `termination_by` parameters must exist in the function's
   value parameter list.
6. A verified example: `gcd` written via `termination_by` + `Acc.rec`.

## Step-by-Step Implementation

### Step 1 — Add `terminationBy` to `SFunKind`

**File:** `doxa/lib/src/surface.dart` (lines 719-786)

Add field after `structAnn`:

```dart
/// When non-null, this function terminates by a well-founded measure
/// over the named parameters. Overrides structural recursion: the
/// checker does not validate constructor-descending calls, and the
/// binding is emitted non-recursive (the user writes recursion via
/// `Acc.rec`). The names must all be value parameters of the function.
final List<String>? terminationBy;
```

Update constructor, `==`, `hashCode`, `toString`.

### Step 2 — Parse `termination_by (args)` syntax

**File:** `doxa/lib/src/parse.dart` (lines 931-961)

After `{struct name}` and before `= body`, parse optional
`termination_by (id, id, ...)`:

```
fun name params : returnType {struct name}? termination_by (a, b, ...)? = body
```

Parser combinator:

```dart
final Parser<ParseError, List<String>?> _terminationBy =
    _keyword('termination_by')
        .skipThen(_sym('('))
        .skipThen(_ident.sepBy(_sym(',')))
        .thenSkip(_sym(')'))
        .optional;
```

Insert into `_mkFunBody` between `_structAnn` and `= body`.

### Step 3 — Add `Acc` to the prelude

**File:** `doxa_tooling/bin/doxa.dart` (lines 174-178)

Append to `_preludeSource`:

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

**File:** `lib/stdlib/prelude.doxa` (sync)

Add the same `Acc` declaration.

### Step 4 — `_elabFunBlock` handles `termination_by`

**File:** `doxa/lib/src/elab.dart` (lines 3583-3737)

Three changes in `_elabFunBlock`:

**4a. Validate termination_by parameter names** (after line 3614)

After the `{struct}` validation loop, add:

```dart
// Validate termination_by: every named parameter must exist.
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

**4b. Skip structural recursion check** (modify line 3607-3615)

When `terminationBy` is non-null, skip `_checkStructuralRecursion` for
that member:

```dart
for (final m in members) {
  if (m.fun.terminationBy == null) {
    _checkStructuralRecursion(m.fun, memberNames);
  }
  // ... structAnn validation unchanged ...
}
```

**4c. Suppress recursion detection for termination_by funs** (modify lines 3675-3679)

`_hasRecursiveReference` must return `false` for functions with
`terminationBy` set — they are NOT considered recursive (their
self-references are via `Acc.rec`, not direct `TTop`):

```dart
final isRecursive = members.any(
  (m) =>
      m.fun.terminationBy == null &&
      (_hasRecursiveReference(m.fun.body, memberNames) ||
       _hasRecursiveReference(m.fun.returnType, memberNames)),
);
```

If no member is recursive, the block returns unguarded (non-recursive)
bindings — which is what we want for `termination_by` funs.

**4d. Bypass `VFun` guarding** (lines 3703-3735)

The guarded-binding stamping loop already handles this: members without
`recDecreasingArg` (null) get no guard. Since `isRecursive` is false
for termination_by funs, they go through the non-recursive path that
emits unguarded bindings. No code change needed here — it already works.

### Step 5 — Error type: `TerminationByParamNotFound`

**File:** `doxa/lib/src/elab.dart` (near `StructAnnotationNotFound`, line ~617)

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

Add to the error-reporting pipeline (if consumed by the CLI).

### Step 6 — Tests

**New file:** `doxa_tooling/test/wf_recursion_test.dart`

Tests:
1. `termination_by` parsed correctly — `fun` with annotation parses
2. `termination_by` accepted on non-recursive fun — parses + type-checks
3. `termination_by` with nonexistent parameter → error
4. Structural recursion still works — existing `fun` tests pass
5. `Acc` type exists in prelude — `Acc A R x` is a valid type
6. `Acc.rec` recursor exists — can be used as a term

**Existing tests must still pass.** All 896 tests, including all
recursion and structural-check tests.

### Step 7 — Verified example: `gcd` via `Acc.rec`

**New file:** `example/gcd.doxa`

A gcd function using `termination_by` + explicit `Acc.rec`:

```
import "../lib/stdlib/nat.doxa"

-- gcd using Acc.rec with termination_by (a, b)
data Ordering { lt; eq; gt; }

fun compare(a b : Nat) : Ordering :=
  match a with {
    zero => match b with { zero => eq; succ _ => lt; };
    succ a' => match b with { zero => gt; succ b' => compare a' b'; };
  }

fun gcd(a b : Nat) : Nat := termination_by (a, b) =
  match compare a b with {
    lt => gcd b a;
    eq => a;
    gt => match a with {
      zero => b;
      succ a' => gcd (succ a') (sub a b);
    };
  }
```

Note: this example is aspirational — the actual implementation of gcd
via `Acc.rec` in Doxa surface syntax requires the user to write the
`Acc.rec` application explicitly. A future session will add the
automatic desugaring. For Phase 24, the example serves as a
documentation artifact showing the pattern.

### Step 8 — Verify

```bash
dart analyze doxa/
dart analyze doxa_tooling/
dart run doxa_tooling:test -r expanded
dart format --set-exit-if-changed doxa/ doxa_tooling/
dart run doxa_tooling:bin/doxa check lib/stdlib/prelude.doxa
```

All 896 existing tests must pass. The prelude must type-check with the
new `Acc` declaration (its auto-emitted recursor binding is verified by
the `checkDeclResult` pipeline).

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `doxa/lib/src/surface.dart` | `SFunKind.terminationBy` field | ~5 |
| `doxa/lib/src/parse.dart` | `_terminationBy` parser combinator, integrate into `_mkFunBody` | ~15 |
| `doxa_tooling/bin/doxa.dart` | Add `Acc` to `_preludeSource` | ~6 |
| `lib/stdlib/prelude.doxa` | Add `Acc` declaration (sync) | ~6 |
| `doxa/lib/src/elab.dart` | `_elabFunBlock`: validate + skip check + suppress recursion | ~20 |
| `doxa/lib/src/elab.dart` | `TerminationByParamNotFound` error type | ~8 |
| `doxa_tooling/test/wf_recursion_test.dart` | New test file | ~80 |
| `example/gcd.doxa` | Example program | ~20 |
| **Total** | | **~160 lines** |

## Risks

1. **`Acc` in prelude expands the prelude.** The prelude is elaborated
   for every file. Adding `Acc` (~6 lines of source, ~2 auto-emitted
   bindings) adds negligible overhead (~0.1ms elaboration time for a
   simple 1-constructor Prop-sorted inductive).

2. **`Acc.rec` singleton elimination.** `Acc` is Prop-sorted with a
   single constructor, so it qualifies for singleton elimination (Phase
   12). The auto-emission produces `Acc.rec` AND `Acc.rect`. Both must
   verify — the existing `_makeRecBindings` logic handles this
   automatically if `Acc` satisfies the singleton criteria.

3. **Namespace for `Acc`.** With Phase 23, the prelude gets a namespace
   prefix `Prelude` (from `prelude.doxa` → `Prelude`). Users can
   write `Prelude.Acc` or bare `Acc` — both work via the dual
   registration.

4. **Acc.rec arity mismatch.** The recursor arity computation in
   `_makeRecBindings` depends on `d.params.length`, `d.ctors.length`,
   and `d.indices.length`. `Acc` has 3 params (A, R, x), 1 constructor,
   and 0 indices. Arity = 3 + 1 + 1 + 0 + 1 = 6. This is correct:
   params (3) + motive (1) + case per ctor (1) + indices (0) + 1 = 6.

## Exit Criteria

- [ ] `Acc` inductive in prelude, `Acc.rec` recursor auto-emitted
- [ ] `termination_by (a, b)` parsed and stored on `SFunKind`
- [ ] Structural recursion check skipped for `termination_by` funs
- [ ] `termination_by` funs emitted as non-recursive (no VFun guard)
- [ ] Invalid `termination_by` parameter → clear error
- [ ] All 896 existing tests pass
- [ ] `dart analyze` 0 issues
- [ ] `dart format` clean
- [ ] `lib/stdlib/prelude.doxa` type-checks with `Acc`
